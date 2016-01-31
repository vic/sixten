{-# LANGUAGE ViewPatterns #-}
module Unify where

import Control.Monad.Except
import Control.Monad.ST.Class
import Data.Bifunctor
import Data.Foldable
import Data.Monoid
import qualified Data.Set as S
import Data.STRef

import qualified Builtin
import Meta
import TCM
import Normalise
import Syntax
import Syntax.Abstract
import Util

type Abstract s = AbstractM s () Plicitness
type Concrete s = ConcreteM s () Plicitness

occurs :: Level -> MetaVar s () Plicitness -> Abstract s -> TCM s ()
occurs l tv = traverse_ go
  where
    go tv'@(MetaVar _ typ _ _ mr)
      | tv == tv' = throwError "occurs check"
      | otherwise = do
        occurs l tv typ
        case mr of
          Nothing -> return ()
          Just r  -> do
            sol <- solution r
            case sol of
              Left l'    -> liftST $ writeSTRef r $ Left $ min l l'
              Right typ' -> occurs l tv typ'

unify :: Abstract s -> Abstract s -> TCM s ()
unify type1 type2 = do
  ftype1 <- freeze type1
  ftype2 <- freeze type2
  tr "unify t1" ftype1
  tr "      t2" ftype2
  go True ftype1 ftype2
  where
    go reduce t1 t2
      | t1 == t2 = return ()
      | otherwise = case (t1, t2) of
        -- If we have 'unify (f xs) t', where 'f' is an existential, and 'xs'
        -- are distinct universally quantified variables, then 'f = \xs. t' is
        -- a most general solution (see Miller, Dale (1991) "A Logic
        -- programming...")
        (appsView -> (Var v@(metaRef -> Just r), distinctForalls -> Just pvs), _) -> solveVar r v pvs t2
        (_, appsView -> (Var v@(metaRef -> Just r), distinctForalls -> Just pvs)) -> solveVar r v pvs t1
        (Pi h1 p1 a s1, Pi h2 p2 b s2) | p1 == p2 -> absCase (h1 <> h2) a b s1 s2
        (Lam h1 p1 a s1, Lam h2 p2 b s2) | p1 == p2 -> absCase (h1 <> h2) a b s1 s2
        -- If we've already tried reducing the application,
        -- we can only hope to unify it pointwise.
        (App e1 p1 e1', App e2 p2 e2') | p1 == p2 && not reduce -> do
          unify e1  e2
          unify e1' e2'
        (Lit 0, appsView -> (Global ((== Builtin.addSize) -> True) , [(_, x), (_, y)])) -> do
          unify (Lit 0) x
          unify (Lit 0) y
        (appsView -> (Global ((== Builtin.addSize) -> True) , [(_, x), (_, y)]), Lit 0) -> do
          unify x (Lit 0)
          unify y (Lit 0)
        _ | reduce -> do
          t1' <- whnf mempty plicitness t1
          t2' <- whnf mempty plicitness t2
          go False t1' t2'
        _ -> throwError $ "Can't unify types: "
                           ++ show (pretty (show <$> type1, show <$> type2))
    absCase h a b s1 s2 = do
      go True a b
      v <- forallVar h a ()
      go True (instantiate1 v s1) (instantiate1 v s2)
    distinctForalls pes | distinct pes = traverse isForall pes
                        | otherwise    = Nothing
    isForall (p, Var v@(metaRef -> Nothing)) = Just (p, v)
    isForall _                               = Nothing
    distinct pes = S.size (S.fromList es) == length es where es = map snd pes
    solveVar r v pvs t = do
      unify (metaType v) =<< typeOf t
      sol <- solution r
      case sol of
        Left l -> do
          occurs l v t
          solve r =<< lams pvs t
        Right c -> go True (apps c $ map (second pure) pvs) t
    lams pvs t = foldrM (\(p, v) -> fmap (Lam (Hint Nothing) p $ metaType v) . abstract1M v) t pvs

subtype :: Plicitness -> Abstract s -> Abstract s -> Abstract s -> TCM s (Abstract s, Abstract s)
subtype surrounding expr type1 type2 = do
  tr "subtype e"  =<< freeze expr
  tr "        t1" =<< freeze type1
  tr "        t2" =<< freeze type2
  modifyIndent succ
  (e', type') <- go True True expr type1 type2
  modifyIndent pred
  tr "subtype res e'" =<< freeze e'
  tr "            type'" =<< freeze type'
  return (e', type')
  where
    go reduce1 reduce2 e typ1 typ2
      | typ1 == typ2 = return (e, typ2)
      | otherwise = case (typ1, typ2) of
        (Global _, _) | reduce1 -> do
          typ1' <- whnf mempty plicitness typ1
          go False reduce2 e typ1' typ2
        (_, Global _) | reduce2 -> do
          typ2' <- whnf mempty plicitness typ2
          go reduce1 False e typ1 typ2'
        (Pi h1 p1 t1 s1, Pi h2 p2 t2 s2) | p1 == p2 -> do
          let h = h1 <> h2
          x2  <- forall_ h t2 ()
          (x1, _)   <- subtype p1 (pure x2) t2 t1
          (ex, s2') <- subtype surrounding
                               (betaApp e p1 x1)
                               (instantiate1 x1 s1)
                               (instantiate1 (pure x2) s2)
          e2    <- etaLamM h p1 t2 =<< abstract1M x2 ex
          typ2' <- Pi h p1 t2 <$> abstract1M x2 s2'
          return (e2, typ2')
        (Var v@(metaRef -> Just r), Pi h p t2 s2) -> do
          sol <- solution r
          case sol of
            Left l -> do
              occurs l v typ2
              unify (metaType v) (Builtin.typeN Explicit 1)
              t11TypeSize <- existsVarAtLevel (metaHint v) Builtin.sizeE () l
              t12TypeSize <- existsVarAtLevel (metaHint v) Builtin.sizeE () l
              t11 <- existsVarAtLevel (metaHint v) (Builtin.typeE Explicit t11TypeSize) () l
              t12 <- existsVarAtLevel (metaHint v) (Builtin.typeE Explicit t12TypeSize) () l
              solve r $ Pi h p t11 $ abstractNone t12
              x2  <- forall_ h t2 ()
              (x1, t11') <- subtype p (pure x2) t2 t11
              (ex, s2')  <- subtype surrounding (betaApp e p x1) t12 (instantiate1 (pure x2) s2)
              solve r . Pi h p t11' =<< abstract1M x2 s2'
              e2    <- etaLamM h p t2 =<< abstract1M x2 ex
              typ2' <- Pi h p t2 <$> abstract1M x2 s2'
              return (e2, typ2')
            Right c -> subtype surrounding e c typ2
        (_, Var (metaRef -> Just r)) -> do
          sol <- solution r
          case sol of
            Left _ -> do unify typ1 typ2; return (e, typ2)
            Right c -> subtype surrounding e typ1 c
        (_, Pi h p t2 s2) | p == Implicit || surrounding == Implicit -> do
          x2 <- forall_ h t2 ()
          (e2, s2') <- subtype surrounding e typ1 (instantiate1 (pure x2) s2)
          e2'   <- etaLamM h p t2 =<< abstract1M x2 e2
          typ2' <- Pi h p t2 <$> abstract1M x2 s2'
          return (e2', typ2')
        (Pi h p t1 s1, _) -> do
          v1 <- existsVar h t1 ()
          subtype surrounding (betaApp e p v1) (instantiate1 v1 s1) typ2
        _ | reduce1 || reduce2-> do
          typ1' <- whnf mempty plicitness typ1
          typ2' <- whnf mempty plicitness typ2
          go False False e typ1' typ2'
        _ -> do unify typ1 typ2; return (e, typ2)

typeOf
  :: Abstract s
  -> TCM s (Abstract s)
typeOf expr = do
  tr "typeOf" expr
  modifyIndent succ
  t <- case expr of
    Global v -> do
      (_, typ, _) <- context v
      return $ first plicitness typ
    Var v -> return $ metaType v
    Con qc -> do
      typ <- qconstructor qc
      return $ first plicitness typ
    Lit _ -> return $ Global Builtin.size
    Pi {} -> return $ Builtin.typeN Explicit 1
    Lam n p t s -> do
      x <- forall_ n t ()
      resType  <- typeOf (instantiate1 (pure x) s)
      abstractedResType <- abstract1M x resType
      return $ Pi n p t abstractedResType
    App e1 p e2 -> do
      e1type <- typeOf e1
      e1type' <- whnf mempty plicitness e1type
      case e1type' of
        Pi _ p' _ resType | p == p' -> return $ instantiate1 e2 resType
        _ -> throwError $ "typeOf: expected pi type" ++ show e1type'
    Case _ (ConBranches _ t) -> return t
    Case _ (LitBranches _ def) -> typeOf def
  modifyIndent pred
  tr "typeOf res" =<< freeze t
  return t