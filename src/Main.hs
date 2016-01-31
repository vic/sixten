module Main where

import Control.Monad.Except
import Control.Monad.State
import Data.Bifoldable
import Data.Bifunctor
import Data.Bitraversable
import qualified Data.HashMap.Lazy as HM
import Data.HashSet(HashSet)
import qualified Data.HashSet as HS
import Data.Monoid
import qualified Data.Text.IO as Text
import qualified Data.Vector as V
import System.Environment

import Builtin
import Erasure
import Infer
import TCM
import Syntax
import qualified Syntax.Abstract as Abstract
import qualified Syntax.Concrete as Concrete
import qualified Syntax.Resolve
import qualified Syntax.Parse
import TopoSort
import Util

inferProgram :: HashSet Constr -> Program Plicitness Concrete.Expr Name -> TCM s ()
inferProgram constrs p' = mapM_ tcGroup sorted
  where
    p = (\(x, y, _) -> (x, y)) <$> p'
    deps   = HM.map (bifoldMap defNames toHashSet) p <> HM.fromList constructorMappings
    defNames (DataDefinition d) = toHashSet (constructorNames d) <> toHashSet d
    defNames x = toHashSet x
    sorted = fmap (\n -> (n, bimap (>>>= instCon) (>>= instCon) $ p HM.! n))
           . filter (`HM.member` p) <$> topoSort deps
    -- TODO check for duplicate constructors
    constructorMappings = [ (c, HS.singleton n)
                          | (n, (DataDefinition d, _)) <- HM.toList p
                          , c <- constructorNames d
                          ]
    constructors = constrs <> HS.fromList (map fst constructorMappings)
    instCon v
      | v `HS.member` constructors = Concrete.Con $ Left v
      | otherwise = pure v

    tcGroup tls = do
      let abstractedScopes = recursiveAbstractDefs [(n, d) | (n, (d, _)) <- tls]
          abstractedTypes = recursiveAbstract [(n, t) | (n, (_, t)) <- tls]
          abstractedTls = [ ( Hint $ Just n
                            , s >>>= unvar (pure . B) Concrete.Global
                            , t >>>= Concrete.Global
                            )
                          | ((s, t), (n, _))
                            <- zip (zip abstractedScopes abstractedTypes) tls]
      checkedTls <- checkRecursiveDefs $ V.fromList abstractedTls

      let vf :: a -> TCM s b
          vf _ = throwError "inferProgram"
      checkedTls' <- traverse (bitraverse (traverse $ traverse vf) (traverse vf)) checkedTls
      let reledTls'' = (\(d, s) ->
            ((bimapDef (Annotation Relevant) id d,
             bimapScope (Annotation Relevant) id s),
             Relevant)) <$> checkedTls'
      let names = V.fromList [n | (n, (_, _)) <- tls]
          instTls = HM.fromList
            [(names V.! i, ( instantiateDef (Abstract.Global . (names V.!)) d
                           , instantiate (Abstract.Global . (names V.!)) t
                           , Annotation r Explicit
                           ))
            | (i, ((d, t), r)) <- zip [0..] $ V.toList reledTls''
            ]
      addContext instTls

test :: FilePath -> IO ()
test inp = do
  mp <- fmap Syntax.Resolve.program <$> Syntax.Parse.parseFromFile Syntax.Parse.program inp
  case mp of
    Nothing         -> return ()
    Just (Left err) -> Text.putStrLn err
    Just (Right p)  -> case runTCM (do
      addContext Builtin.context
      constrs <- HS.fromList . HM.keys <$> gets tcConstrs
      inferProgram constrs p
      gets tcContext) mempty of
      (Left err, tr) -> do mapM_ putStrLn tr; putStrLn err
      (Right res, _) -> do
        mapM_ print $ (show . (\(x, (d, t, a)) -> runPrettyM $ prettyM x <+> prettyM "=" <+> prettyTypedDef (fe d) (fe t) (fst $ bindingsView Abstract.piView $ fe t))) <$> HM.toList res
        putStrLn "------------- erased ------------------"
        mapM_ print $ (show . pretty) <$> [(x, fe e') | (x, (e, _, a)) <- HM.toList res, isRelevant a, let Definition e' = eraseDef e]
  where
    fe :: Functor f => f Empty -> f String
    fe = fmap fromEmpty

main :: IO ()
main = do
  x:_ <- getArgs
  test x