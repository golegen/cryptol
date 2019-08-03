-- |
-- Module      :  Cryptol.Parser.NoPat
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable
--
-- The purpose of this module is to convert all patterns to variable
-- patterns.  It also eliminates pattern bindings by de-sugaring them
-- into `Bind`.  Furthermore, here we associate signatures and pragmas
-- with the names to which they belong.

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
module Cryptol.Parser.NoPat (RemovePatterns(..),Error(..)) where

import Cryptol.Parser.AST
import Cryptol.Parser.Position(Range(..),emptyRange,start,at)
import Cryptol.Parser.Names (namesP)
import Cryptol.Utils.PP
import Cryptol.Utils.Panic(panic)

import           MonadLib hiding (mapM)
import           Data.Maybe(maybeToList)
import qualified Data.Map as Map

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

class RemovePatterns t where
  -- | Eliminate all patterns in a program.
  removePatterns :: t -> (t, [Error])

instance RemovePatterns (Program PName) where
  removePatterns p = runNoPatM (noPatProg p)

instance RemovePatterns (Expr PName) where
  removePatterns e = runNoPatM (noPatE e)

instance RemovePatterns (Module PName) where
  removePatterns m = runNoPatM (noPatModule m)

instance RemovePatterns [Decl PName] where
  removePatterns ds = runNoPatM (noPatDs ds)

simpleBind :: Located PName -> Expr PName -> Bind PName
simpleBind x e = Bind { bName = x, bParams = []
                      , bDef = at e (Located emptyRange (DExpr e))
                      , bSignature = Nothing, bPragmas = []
                      , bMono = True, bInfix = False, bFixity = Nothing
                      , bDoc = Nothing
                      }

sel :: Pattern PName -> PName -> Selector -> Bind PName
sel p x s = let (a,ts) = splitSimpleP p
            in simpleBind a (foldl ETyped (ESel (EVar x) s) ts)

-- | Given a pattern, transform it into a simple pattern and a set of bindings.
-- Simple patterns may only contain variables and type annotations.

-- XXX: We can replace the types in the selectors with annotations on the bindings.
noPat :: Pattern PName -> NoPatM (Pattern PName, [Bind PName])
noPat pat =
  case pat of
    PVar x -> return (PVar x, [])

    PWild ->
      do x <- newName
         r <- getRange
         return (pVar r x, [])

    PTuple ps ->
      do (as,dss) <- unzip `fmap` mapM noPat ps
         x <- newName
         r <- getRange
         let len      = length ps
             ty       = TTuple (replicate len TWild)
             getN a n = sel a x (TupleSel n (Just len))
         return (pTy r x ty, zipWith getN as [0..] ++ concat dss)

    PList [] ->
      do x <- newName
         r <- getRange
         return (pTy r x (TSeq (TNum 0) TWild), [])

    PList ps ->
      do (as,dss) <- unzip `fmap` mapM noPat ps
         x <- newName
         r <- getRange
         let len      = length ps
             ty       = TSeq (TNum (toInteger len)) TWild
             getN a n = sel a x (ListSel n (Just len))
         return (pTy r x ty, zipWith getN as [0..] ++ concat dss)

    PRecord fs ->
      do (as,dss) <- unzip `fmap` mapM (noPat . value) fs
         x <- newName
         r <- getRange
         let shape    = map (thing . name) fs
             ty       = TRecord (map (fmap (\_ -> TWild)) fs)
             getN a n = sel a x (RecordSel n (Just shape))
         return (pTy r x ty, zipWith getN as shape ++ concat dss)

    PTyped p t ->
      do (a,ds) <- noPat p
         return (PTyped a t, ds)

    -- XXX: We can do more with type annotations here
    PSplit p1 p2 ->
      do (a1,ds1) <- noPat p1
         (a2,ds2) <- noPat p2
         x <- newName
         tmp <- newName
         r <- getRange
         let bTmp = simpleBind (Located r tmp) (ESplit (EVar x))
             b1   = sel a1 tmp (TupleSel 0 (Just 2))
             b2   = sel a2 tmp (TupleSel 1 (Just 2))
         return (pVar r x, bTmp : b1 : b2 : ds1 ++ ds2)

    PLocated p r1 -> inRange r1 (noPat p)

  where
  pVar r x   = PVar (Located r x)
  pTy  r x t = PTyped (PVar (Located r x)) t


splitSimpleP :: Pattern PName -> (Located PName, [Type PName])
splitSimpleP (PVar x)     = (x, [])
splitSimpleP (PTyped p t) = let (x,ts) = splitSimpleP p
                            in (x, t:ts)
splitSimpleP p            = panic "splitSimpleP"
                                  [ "Non-simple pattern", show p ]

--------------------------------------------------------------------------------

noPatE :: Expr PName -> NoPatM (Expr PName)
noPatE expr =
  case expr of
    EVar {}       -> return expr
    ELit {}       -> return expr
    ENeg e        -> ENeg    <$> noPatE e
    EComplement e -> EComplement <$> noPatE e
    EGenerate e   -> EGenerate <$> noPatE e
    ETuple es     -> ETuple  <$> mapM noPatE es
    ERecord es    -> ERecord <$> mapM noPatF es
    ESel e s      -> ESel    <$> noPatE e <*> return s
    EUpd mb fs    -> EUpd    <$> traverse noPatE mb <*> traverse noPatUF fs
    EList es      -> EList   <$> mapM noPatE es
    EFromTo {}    -> return expr
    EInfFrom e e' -> EInfFrom <$> noPatE e <*> traverse noPatE e'
    EComp e mss   -> EComp  <$> noPatE e <*> mapM noPatArm mss
    EApp e1 e2    -> EApp   <$> noPatE e1 <*> noPatE e2
    EAppT e ts    -> EAppT  <$> noPatE e <*> return ts
    EIf e1 e2 e3  -> EIf    <$> noPatE e1 <*> noPatE e2 <*> noPatE e3
    EWhere e ds   -> EWhere <$> noPatE e <*> noPatDs ds
    ETyped e t    -> ETyped <$> noPatE e <*> return t
    ETypeVal {}   -> return expr
    EFun ps e     -> do (ps1,e1) <- noPatFun ps e
                        return (EFun ps1 e1)
    ELocated e r1 -> ELocated <$> inRange r1 (noPatE e) <*> return r1

    ESplit e      -> ESplit  <$> noPatE e
    EParens e     -> EParens <$> noPatE e
    EInfix x y f z-> EInfix  <$> noPatE x <*> pure y <*> pure f <*> noPatE z

  where noPatF x = do e <- noPatE (value x)
                      return x { value = e }

noPatUF :: UpdField PName -> NoPatM (UpdField PName)
noPatUF (UpdField h ls e) = UpdField h ls <$> noPatE e

noPatFun :: [Pattern PName] -> Expr PName -> NoPatM ([Pattern PName], Expr PName)
noPatFun ps e =
  do (xs,bs) <- unzip <$> mapM noPat ps
     e1 <- noPatE e
     let body = case concat bs of
                        [] -> e1
                        ds -> EWhere e1 $ map DBind ds
     return (xs, body)


noPatArm :: [Match PName] -> NoPatM [Match PName]
noPatArm ms = concat <$> mapM noPatM ms

noPatM :: Match PName -> NoPatM [Match PName]
noPatM (Match p e) =
  do (x,bs) <- noPat p
     e1     <- noPatE e
     return (Match x e1 : map MatchLet bs)
noPatM (MatchLet b) = (return . MatchLet) <$> noMatchB b

noMatchB :: Bind PName -> NoPatM (Bind PName)
noMatchB b =
  case thing (bDef b) of

    DPrim | null (bParams b) -> return b
          | otherwise        -> panic "NoPat" [ "noMatchB: primitive with params"
                                              , show b ]

    DExpr e ->
      do (ps,e') <- noPatFun (bParams b) e
         return b { bParams = ps, bDef = DExpr e' <$ bDef b }

noMatchD :: Decl PName -> NoPatM [Decl PName]
noMatchD decl =
  case decl of
    DSignature {}   -> return [decl]
    DPragma {}      -> return [decl]
    DFixity{}       -> return [decl]

    DBind b         -> do b1 <- noMatchB b
                          return [DBind b1]

    DPatBind p e    -> do (p',bs) <- noPat p
                          let (x,ts) = splitSimpleP p'
                          e1 <- noPatE e
                          let e2 = foldl ETyped e1 ts
                          return $ DBind Bind { bName = x
                                              , bParams = []
                                              , bDef = at e (Located emptyRange (DExpr e2))
                                              , bSignature = Nothing
                                              , bPragmas = []
                                              , bMono = False
                                              , bInfix = False
                                              , bFixity = Nothing
                                              , bDoc = Nothing
                                              } : map DBind bs
    DType {}        -> return [decl]
    DProp {}        -> return [decl]

    DLocated d r1   -> do bs <- inRange r1 $ noMatchD d
                          return $ map (`DLocated` r1) bs

noPatDs :: [Decl PName] -> NoPatM [Decl PName]
noPatDs ds =
  do ds1 <- concat <$> mapM noMatchD ds
     let fixes = Map.fromListWith (++) $ concatMap toFixity ds1
         amap = AnnotMap
           { annPragmas = Map.fromListWith (++) $ concatMap toPragma ds1
           , annSigs    = Map.fromListWith (++) $ concatMap toSig ds1
           , annValueFs = fixes
           , annTypeFs  = fixes
           , annDocs    = Map.empty
           }

     (ds2, AnnotMap { .. }) <- runStateT amap (annotDs ds1)

     forM_ (Map.toList annPragmas) $ \(n,ps) ->
       forM_ ps $ \p -> recordError $ PragmaNoBind (p { thing = n }) (thing p)

     forM_ (Map.toList annSigs) $ \(n,ss) ->
       do _ <- checkSigs n ss
          forM_ ss $ \s -> recordError $ SignatureNoBind (s { thing = n })
                                                         (thing s)

     -- Generate an error if a fixity declaration is not used for
     -- either a value-level or type-level operator.
     forM_ (Map.toList (Map.intersection annValueFs annTypeFs)) $ \(n,fs) ->
       forM_ fs $ \f -> recordError $ FixityNoBind f { thing = n }

     return ds2



noPatTopDs :: [TopDecl PName] -> NoPatM [TopDecl PName]
noPatTopDs tds =
  do desugared <- concat <$> mapM desugar tds

     let allDecls  = map tlValue (decls desugared)
         fixes     = Map.fromListWith (++) $ concatMap toFixity allDecls

     let ann = AnnotMap
           { annPragmas = Map.fromListWith (++) $ concatMap toPragma allDecls
           , annSigs    = Map.fromListWith (++) $ concatMap toSig    allDecls
           , annValueFs = fixes
           , annTypeFs  = fixes
           , annDocs    = Map.fromListWith (++) $ concatMap toDocs $ decls tds
          }

     (tds', AnnotMap { .. }) <- runStateT ann (annotTopDs desugared)

     forM_ (Map.toList annPragmas) $ \(n,ps) ->
       forM_ ps $ \p -> recordError $ PragmaNoBind (p { thing = n }) (thing p)

     forM_ (Map.toList annSigs) $ \(n,ss) ->
       do _ <- checkSigs n ss
          forM_ ss $ \s -> recordError $ SignatureNoBind (s { thing = n })
                                                         (thing s)

     -- Generate an error if a fixity declaration is not used for
     -- either a value-level or type-level operator.
     forM_ (Map.toList (Map.intersection annValueFs annTypeFs)) $ \(n,fs) ->
       forM_ fs $ \f -> recordError $ FixityNoBind f { thing = n }

     return tds'

  where
  decls xs = [ d | Decl d <- xs ]

  desugar d =
    case d of
      Decl tl -> do ds <- noMatchD (tlValue tl)
                    return [ Decl tl { tlValue = d1 } | d1 <- ds ]
      x      -> return [x]


noPatProg :: Program PName -> NoPatM (Program PName)
noPatProg (Program topDs) = Program <$> noPatTopDs topDs

noPatModule :: Module PName -> NoPatM (Module PName)
noPatModule m =
  do ds1 <- noPatTopDs (mDecls m)
     return m { mDecls = ds1 }

--------------------------------------------------------------------------------

data AnnotMap = AnnotMap
  { annPragmas  :: Map.Map PName [Located  Pragma       ]
  , annSigs     :: Map.Map PName [Located (Schema PName)]
  , annValueFs  :: Map.Map PName [Located  Fixity       ]
  , annTypeFs   :: Map.Map PName [Located  Fixity       ]
  , annDocs     :: Map.Map PName [Located  String       ]
  }

type Annotates a = a -> StateT AnnotMap NoPatM a

-- | Add annotations to exported declaration groups.
--
-- XXX: This isn't quite right: if a signature and binding have different
-- export specifications, this will favor the specification of the binding.
-- This is most likely the intended behavior, so it's probably fine, but it does
-- smell a bit.
annotTopDs :: Annotates [TopDecl PName]
annotTopDs tds =
  case tds of

    d : ds ->
      case d of
        Decl d1 ->
          do ignore <- runExceptionT (annotD (tlValue d1))
             case ignore of
               Left _   -> annotTopDs ds
               Right d2 -> (Decl (d1 { tlValue = d2 }) :) <$> annotTopDs ds

        DPrimType tl ->
          do pt <- annotPrimType (tlValue tl)
             let d1 = DPrimType tl { tlValue = pt }
             (d1 :) <$> annotTopDs ds

        DParameterType p ->
          do p1 <- annotParameterType p
             (DParameterType p1 :) <$> annotTopDs ds

        DParameterConstraint {} -> (d :) <$> annotTopDs ds

        DParameterFun p ->
          do AnnotMap { .. } <- get
             let rm _ _ = Nothing
                 name = thing (pfName p)
             case Map.updateLookupWithKey rm name annValueFs of
               (Nothing,_)  -> (d :) <$> annotTopDs ds
               (Just f,fs1) ->
                 do mbF <- lift (checkFixs name f)
                    set AnnotMap { annValueFs = fs1, .. }
                    let p1 = p { pfFixity = mbF }
                    (DParameterFun p1 :) <$> annotTopDs ds

        -- XXX: we may want to add pragmas to newtypes?
        TDNewtype {} -> (d :) <$> annotTopDs ds
        Include {}   -> (d :) <$> annotTopDs ds

    [] -> return []


-- | Add annotations, keeping track of which annotations are not yet used up.
annotDs :: Annotates [Decl PName]
annotDs (d : ds) =
  do ignore <- runExceptionT (annotD d)
     case ignore of
       Left ()   -> annotDs ds
       Right d1  -> (d1 :) <$> annotDs ds
annotDs [] = return []

-- | Add annotations, keeping track of which annotations are not yet used up.
-- The exception indicates which declarations are no longer needed.
annotD :: Decl PName -> ExceptionT () (StateT AnnotMap NoPatM) (Decl PName)
annotD decl =
  case decl of
    DBind b       -> DBind <$> lift (annotB b)
    DSignature {} -> raise ()
    DFixity{}     -> raise ()
    DPragma {}    -> raise ()
    DPatBind {}   -> raise ()
    DType tysyn   -> DType <$> lift (annotTySyn tysyn)
    DProp propsyn -> DProp <$> lift (annotPropSyn propsyn)
    DLocated d r  -> (`DLocated` r) <$> annotD d

-- | Add pragma/signature annotations to a binding.
annotB :: Annotates (Bind PName)
annotB Bind { .. } =
  do AnnotMap { .. } <- get
     let name       = thing bName
         remove _ _ = Nothing
         (thisPs    , ps') = Map.updateLookupWithKey remove name annPragmas
         (thisSigs  , ss') = Map.updateLookupWithKey remove name annSigs
         (thisFixes , fs') = Map.updateLookupWithKey remove name annValueFs
         (thisDocs  , ds') = Map.updateLookupWithKey remove name annDocs
     s <- lift $ checkSigs name $ jn thisSigs
     f <- lift $ checkFixs name $ jn thisFixes
     d <- lift $ checkDocs name $ jn thisDocs
     set AnnotMap { annPragmas = ps'
                  , annSigs    = ss'
                  , annValueFs = fs'
                  , annDocs    = ds'
                  , ..
                  }
     return Bind { bSignature = s
                 , bPragmas = map thing (jn thisPs) ++ bPragmas
                 , bFixity = f
                 , bDoc = d
                 , ..
                 }
  where jn x = concat (maybeToList x)

annotTyThing :: PName -> StateT AnnotMap NoPatM (Maybe Fixity)
annotTyThing name =
  do AnnotMap { .. } <- get
     let remove _ _ = Nothing
         (thisFixes, ts') = Map.updateLookupWithKey remove name annTypeFs
     f <- lift $ checkFixs name $ concat $ maybeToList thisFixes
     set AnnotMap { annTypeFs = ts', .. }
     pure f


-- | Add fixity annotations to a type synonym binding.
annotTySyn :: Annotates (TySyn PName)
annotTySyn (TySyn ln _ params rhs) =
  do f <- annotTyThing (thing ln)
     pure (TySyn ln f params rhs)

-- | Add fixity annotations to a constraint synonym binding.
annotPropSyn :: Annotates (PropSyn PName)
annotPropSyn (PropSyn ln _ params rhs) =
  do f <- annotTyThing (thing ln)
     pure (PropSyn ln f params rhs)

-- | Annotate a primitive type declaration.
annotPrimType :: Annotates (PrimType PName)
annotPrimType pt =
  do f <- annotTyThing (thing (primTName pt))
     pure pt { primTFixity = f }

-- | Annotate a module's type parameter.
annotParameterType :: Annotates (ParameterType PName)
annotParameterType pt =
  do f <- annotTyThing (thing (ptName pt))
     pure pt { ptFixity = f }




-- | Check for multiple signatures.
checkSigs :: PName -> [Located (Schema PName)] -> NoPatM (Maybe (Schema PName))
checkSigs _ []             = return Nothing
checkSigs _ [s]            = return (Just (thing s))
checkSigs f xs@(s : _ : _) = do recordError $ MultipleSignatures f xs
                                return (Just (thing s))

checkFixs :: PName -> [Located Fixity] -> NoPatM (Maybe Fixity)
checkFixs _ []       = return Nothing
checkFixs _ [f]      = return (Just (thing f))
checkFixs f fs@(x:_) = do recordError $ MultipleFixities f $ map srcRange fs
                          return (Just (thing x))


checkDocs :: PName -> [Located String] -> NoPatM (Maybe String)
checkDocs _ []       = return Nothing
checkDocs _ [d]      = return (Just (thing d))
checkDocs f ds@(d:_) = do recordError $ MultipleDocs f (map srcRange ds)
                          return (Just (thing d))


-- | Does this declaration provide some signatures?
toSig :: Decl PName -> [(PName, [Located (Schema PName)])]
toSig (DLocated d _)      = toSig d
toSig (DSignature xs s)   = [ (thing x,[Located (srcRange x) s]) | x <- xs ]
toSig _                   = []

-- | Does this declaration provide some signatures?
toPragma :: Decl PName -> [(PName, [Located Pragma])]
toPragma (DLocated d _)   = toPragma d
toPragma (DPragma xs s)   = [ (thing x,[Located (srcRange x) s]) | x <- xs ]
toPragma _                = []

-- | Does this declaration provide fixity information?
toFixity :: Decl PName -> [(PName, [Located Fixity])]
toFixity (DFixity f ns) = [ (thing n, [Located (srcRange n) f]) | n <- ns ]
toFixity _              = []

-- | Does this top-level declaration provide a documentation string?
toDocs :: TopLevel (Decl PName) -> [(PName, [Located String])]
toDocs TopLevel { .. }
  | Just txt <- tlDoc = go txt tlValue
  | otherwise = []
  where
  go txt decl =
    case decl of
      DSignature ns _ -> [ (thing n, [txt]) | n <- ns ]
      DFixity _ ns    -> [ (thing n, [txt]) | n <- ns ]
      DBind b         -> [ (thing (bName b), [txt]) ]
      DLocated d _    -> go txt d
      DPatBind p _    -> [ (thing n, [txt]) | n <- namesP p ]

      -- XXX revisit these
      DPragma _ _     -> []
      DType _         -> []
      DProp _         -> []


--------------------------------------------------------------------------------
newtype NoPatM a = M { unM :: ReaderT Range (StateT RW Id) a }

data RW     = RW { names :: !Int, errors :: [Error] }

data Error  = MultipleSignatures PName [Located (Schema PName)]
            | SignatureNoBind (Located PName) (Schema PName)
            | PragmaNoBind (Located PName) Pragma
            | MultipleFixities PName [Range]
            | FixityNoBind (Located PName)
            | MultipleDocs PName [Range]
              deriving (Show,Generic, NFData)

instance Functor NoPatM where fmap = liftM
instance Applicative NoPatM where pure = return; (<*>) = ap
instance Monad NoPatM where
  return x  = M (return x)
  fail x    = M (fail x)
  M x >>= k = M (x >>= unM . k)


-- | Pick a new name, to be used when desugaring patterns.
newName :: NoPatM PName
newName = M $ sets $ \s -> let x = names s
                           in (NewName NoPat x, s { names = x + 1 })

-- | Record an error.
recordError :: Error -> NoPatM ()
recordError e = M $ sets_ $ \s -> s { errors = e : errors s }

getRange :: NoPatM Range
getRange = M ask

inRange :: Range -> NoPatM a -> NoPatM a
inRange r m = M $ local r $ unM m


runNoPatM :: NoPatM a -> (a, [Error])
runNoPatM m
  = getErrs
  $ runId
  $ runStateT RW { names = 0, errors = [] }
  $ runReaderT (Range start start "")    -- hm
  $ unM m
  where getErrs (a,rw) = (a, errors rw)

--------------------------------------------------------------------------------

instance PP Error where
  ppPrec _ err =
    case err of
      MultipleSignatures x ss ->
        text "Multiple type signatures for" <+> quotes (pp x)
        $$ nest 2 (vcat (map pp ss))

      SignatureNoBind x s ->
        text "At" <+> pp (srcRange x) <.> colon <+>
        text "Type signature without a matching binding:"
         $$ nest 2 (pp (thing x) <+> colon <+> pp s)

      PragmaNoBind x s ->
        text "At" <+> pp (srcRange x) <.> colon <+>
        text "Pragma without a matching binding:"
         $$ nest 2 (pp s)

      MultipleFixities n locs ->
        text "Multiple fixity declarations for" <+> quotes (pp n)
        $$ nest 2 (vcat (map pp locs))

      FixityNoBind n ->
        text "At" <+> pp (srcRange n) <.> colon <+>
        text "Fixity declaration without a matching binding for:" <+>
         pp (thing n)

      MultipleDocs n locs ->
        text "Multiple documentation blocks given for:" <+> pp n
        $$ nest 2 (vcat (map pp locs))
