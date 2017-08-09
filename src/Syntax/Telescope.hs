{-# LANGUAGE
  DeriveFoldable,
  DeriveFunctor,
  DeriveTraversable,
  FlexibleContexts,
  GADTs,
  GeneralizedNewtypeDeriving,
  OverloadedStrings,
  Rank2Types,
  TemplateHaskell,
  ViewPatterns
 #-}
module Syntax.Telescope where

import Bound
import Bound.Scope
import Bound.Var
import Control.Monad.Morph
import Data.Bifoldable
import Data.Bifunctor
import Data.Bitraversable
import Data.Deriving
import qualified Data.Foldable as Foldable
import Data.Functor.Classes
import Data.Hashable
import Data.List as List
import Data.Maybe
import Data.Monoid
import Data.String
import Data.Traversable
import Data.Vector(Vector)
import qualified Data.Vector as Vector

import Pretty
import Syntax.Annotation
import Syntax.GlobalBind
import Syntax.Hint
import Syntax.Name
import Util

newtype Tele = Tele Int
  deriving (Eq, Enum, Hashable, Ord, Show, Num)

unTele :: Tele -> Int
unTele (Tele i) = i

newtype Telescope anno expr v = Telescope (Vector (TeleArg anno expr v))
  deriving (Eq, Ord, Show, Foldable, Functor, Traversable)

-- TODO instances for TeleArg
data TeleArg anno expr v = TeleArg !NameHint !anno !(Scope Tele expr v)
  deriving (Eq, Ord, Show, Foldable, Functor, Traversable)

unTelescope :: Telescope anno expr v -> Vector (TeleArg anno expr v)
unTelescope (Telescope xs) = xs

mapAnnotations :: (a -> a') -> Telescope a e v -> Telescope a' e v
mapAnnotations f (Telescope xs) = Telescope $ (\(TeleArg h a s) -> (TeleArg h (f a) s)) <$> xs

bimapAnnotatedTelescope
  :: Bifunctor e
  => (a -> a')
  -> (v -> v')
  -> Telescope a (e a) v
  -> Telescope a' (e a') v'
bimapAnnotatedTelescope f g (Telescope xs)
  = Telescope $ (\(TeleArg h a s) -> TeleArg h (f a) $ bimapScope f g s) <$> xs

bifoldMapAnnotatedTelescope
  :: (Bifoldable e, Monoid m)
  => (a -> m)
  -> (v -> m)
  -> Telescope a (e a) v
  -> m
bifoldMapAnnotatedTelescope f g (Telescope xs)
  = Foldable.fold $ (\(TeleArg _ a s) -> f a <> bifoldMapScope f g s) <$> xs

bitraverseAnnotatedTelescope
  :: (Bitraversable e, Applicative f)
  => (a -> f a')
  -> (v -> f v')
  -> Telescope a (e a) v
  -> f (Telescope a' (e a') v')
bitraverseAnnotatedTelescope f g (Telescope xs)
  = Telescope <$> traverse (\(TeleArg h a s) -> TeleArg h <$> f a <*> bitraverseScope f g s) xs

bimapTelescope
  :: Bifunctor e
  => (a -> a')
  -> (v -> v')
  -> Telescope p (e a) v
  -> Telescope p (e a') v'
bimapTelescope f g (Telescope xs)
  = Telescope $ (\(TeleArg h p s) -> TeleArg h p (bimapScope f g s)) <$> xs

bifoldMapTelescope
  :: (Bifoldable e, Monoid m)
  => (a -> m)
  -> (v -> m)
  -> Telescope p (e a) v
  -> m
bifoldMapTelescope f g (Telescope xs)
  = Foldable.fold $ (\(TeleArg _ _ s) -> bifoldMapScope f g s) <$> xs

bitraverseTelescope
  :: (Bitraversable e, Applicative f)
  => (a -> f a')
  -> (v -> f v')
  -> Telescope p (e a) v
  -> f (Telescope p (e a') v')
bitraverseTelescope f g (Telescope xs)
  = Telescope <$> traverse (\(TeleArg h p s) -> TeleArg h p <$> bitraverseScope f g s) xs

teleLength :: Telescope a e v -> Int
teleLength = Vector.length . unTelescope

dropTele
  :: Functor expr
  => Int
  -> Telescope a expr v
  -> Telescope a expr v
dropTele n
  = Telescope
  . fmap (\(TeleArg h p s) -> (TeleArg h p $ mapBound (subtract $ Tele n) s))
  . Vector.drop n
  . unTelescope

takeTele
  :: Int
  -> Telescope a expr v
  -> Telescope a expr v
takeTele n = Telescope . Vector.take n . unTelescope

instantiatePrefix
  :: Monad expr
  => Vector (expr v)
  -> Telescope a expr v
  -> Telescope a expr v
instantiatePrefix es (Telescope tele)
  = Telescope
  $ (\(TeleArg h p s) -> TeleArg h p $ toScope $ instantiate f $ F <$> s)
  <$> Vector.drop len tele
  where
    es' = fmap F <$> es
    len = Vector.length es
    f (Tele i)
      | i < len = es' Vector.! i
      | otherwise = pure $ B $ Tele $! i - len

teleNames :: Telescope a expr v -> Vector NameHint
teleNames (Telescope t) = (\(TeleArg h _ _) -> h) <$> t

addTeleNames :: Telescope a expr v -> Vector NameHint -> Telescope a expr v
addTeleNames (Telescope t) hs = Telescope $ Vector.imap (\i (TeleArg h a s) -> TeleArg (maybe h (h <>) $ hs Vector.!? i) a s) t

teleAnnotations :: Telescope a expr v -> Vector a
teleAnnotations (Telescope t) = (\(TeleArg _ a _) -> a) <$> t

teleTypes :: Telescope a expr v -> Vector (Scope Tele expr v)
teleTypes (Telescope t) = (\(TeleArg _ _ x) -> x) <$> t

quantify
  :: Monad expr
  => (NameHint -> a
               -> expr (Var Tele v)
               -> Scope () expr (Var Tele v')
               -> expr (Var Tele v'))
  -> Scope Tele expr v'
  -> Telescope a expr v
  -> expr v'
quantify pifun s (Telescope ps) =
   unvar err id <$> Vector.ifoldr
     (\i (TeleArg h p s') -> pifun h p (fromScope s') . abstract (abstr i))
     (fromScope s)
     ps
  where
    abstr i (B (Tele i')) | i == i' = Just ()
    abstr _ _ = Nothing
    err = error "quantify Telescope"

withTeleHints
  :: Telescope a expr v
  -> (Vector Name -> PrettyM p)
  -> PrettyM p
withTeleHints = withNameHints . teleNames

prettyTeleVars
  :: PrettyAnnotation a
  => Vector Name
  -> Telescope a expr v
  -> PrettyM Doc
prettyTeleVars ns t = hsep
  [ prettyAnnotation a $ prettyM $ ns Vector.! i
  | (i, a) <- zip [0..] $ Vector.toList $ teleAnnotations t
  ]

prettyTeleVarTypes
  :: (Eq1 expr, Eq v, Pretty (expr v), Monad expr, IsString v, PrettyAnnotation a, Eq a)
  => Vector Name
  -> Telescope a expr v
  -> PrettyM Doc
prettyTeleVarTypes ns (Telescope v) = hcat $ map go grouped
  where
    inst = instantiateTele (pure . fromName) ns
    vlist = Vector.toList v
    grouped = [ (n : [n' | (Hint n', _) <- vlist'], a, t)
              | (Hint n, TeleArg _ a t):vlist' <- List.group $ zip (map Hint [(0 :: Int)..]) vlist]
    go (xs, a, t)
      = prettyAnnotationParens a
      $ hsep (map (prettyM . (ns Vector.!)) xs) <+> ":" <+> prettyM (inst t)

forMTele
  :: Monad m
  => Telescope a expr v
  -> (NameHint -> a -> Scope Tele expr v -> m v')
  -> m (Vector v')
forMTele (Telescope t) f = forM t $ \(TeleArg h d s) -> f h d s

forTeleWithPrefixM
  :: Monad m
  => Telescope a expr v
  -> (NameHint -> a -> Scope Tele expr v -> Vector v' -> m v')
  -> m (Vector v')
forTeleWithPrefixM (Telescope t) f = mapWithPrefixM (\(TeleArg h d s) -> f h d s) t

forTele
  :: Telescope a expr v
  -> (NameHint -> a -> Scope Tele expr v -> v')
  -> Vector v'
forTele (Telescope t) f = (\(TeleArg h d s) -> f h d s) <$> t

iforMTele
  :: Monad m
  => Telescope a expr v
  -> (Int -> NameHint -> a -> Scope Tele expr v -> m v')
  -> m (Vector v')
iforMTele (Telescope t) f = flip Vector.imapM t $ \i (TeleArg h d s) -> f i h d s

iforTeleWithPrefixM
  :: Monad m
  => Telescope a expr v
  -> (Int -> NameHint -> a -> Scope Tele expr v -> Vector v' -> m v')
  -> m (Vector v')
iforTeleWithPrefixM (Telescope t) f = mapWithPrefixM (\(i, TeleArg h d s) -> f i h d s) $ Vector.indexed t

iforTele
  :: Telescope a expr v
  -> (Int -> NameHint -> a -> Scope Tele expr v -> v')
  -> Vector v'
iforTele (Telescope t) f = (\(i, TeleArg h d s) -> f i h d s) <$> Vector.indexed t

instantiateTele
  :: Monad f
  => (v -> f a)
  -> Vector v
  -> Scope Tele f a
  -> f a
instantiateTele f vs
  = instantiate (f . fromMaybe (error "instantiateTele") . (vs Vector.!?) . unTele)

teleAbstraction :: Eq a => Vector a -> a -> Maybe Tele
teleAbstraction vs = fmap Tele . (`Vector.elemIndex` vs)

-- | View consecutive bindings at the same time
bindingsViewM
  :: (Monad expr, Monad expr')
  => (forall v'. expr' v' -> Maybe (NameHint, a, expr v', Scope1 expr' v'))
  -> expr' v
  -> Maybe (Telescope a expr v, Scope Tele expr' v)
bindingsViewM f expr@(f -> Just _) = Just $ bindingsView f expr
bindingsViewM _ _ = Nothing

-- | View consecutive bindings at the same time
bindingsView
  :: (Monad expr, Monad expr')
  => (forall v'. expr' v' -> Maybe (NameHint, a, expr v', Scope1 expr' v'))
  -> expr' v
  -> (Telescope a expr v, Scope Tele expr' v)
bindingsView f expr = go 0 $ F <$> expr
  where
    go x (f -> Just (n, p, e, s)) = (Telescope $ pure (TeleArg n p $ toScope e) <> ns, s')
      where
        (Telescope ns, s') = (go $! x + 1) $ Util.instantiate1 (return $ B x) s
    go _ e = (Telescope mempty, toScope e)

-------------------------------------------------------------------------------
-- Instances
instance (a ~ Plicitness, Eq1 expr, Eq v, Pretty (expr v), Monad expr, IsString v)
  => Pretty (Telescope a expr v) where
  prettyM tele = withTeleHints tele $ \ns -> prettyTeleVarTypes ns tele

instance GlobalBound (Telescope a) where
  bound f g (Telescope tele)
    = Telescope $ (\(TeleArg h a s) -> TeleArg h a $ bound f g s) <$> tele

instance MFunctor (Telescope a) where
  hoist f (Telescope xs)
    = Telescope $ (\(TeleArg h p s) -> TeleArg h p $ hoist f s) <$> xs

$(return mempty)

instance (Eq anno, Eq1 expr, Monad expr) => Eq1 (Telescope anno expr) where
  liftEq = $(makeLiftEq ''Telescope)

instance (Ord anno, Ord1 expr, Monad expr) => Ord1 (Telescope anno expr) where
  liftCompare = $(makeLiftCompare ''Telescope)

instance (Show anno, Show1 expr, Monad expr) => Show1 (Telescope anno expr) where
  liftShowsPrec = $(makeLiftShowsPrec ''Telescope)

instance (Eq anno, Eq1 expr, Monad expr) => Eq1 (TeleArg anno expr) where
  liftEq = $(makeLiftEq ''TeleArg)

instance (Ord anno, Ord1 expr, Monad expr) => Ord1 (TeleArg anno expr) where
  liftCompare = $(makeLiftCompare ''TeleArg)

instance (Show anno, Show1 expr, Monad expr) => Show1 (TeleArg anno expr) where
  liftShowsPrec = $(makeLiftShowsPrec ''TeleArg)
