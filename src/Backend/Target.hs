{-# LANGUAGE OverloadedStrings #-}
module Backend.Target where

import Data.Monoid
import qualified Data.List as List
import qualified Text.PrettyPrint.ANSI.Leijen as Leijen

import Pretty

data Target = Target
  { architecture :: String
  , ptrBits :: Integer
  , ptrBytes :: Integer
  , ptrAlign :: Integer
  } deriving (Eq, Ord, Show)

x86 :: Target
x86 = Target
  { architecture = "x86"
  , ptrBits = 32
  , ptrBytes = 4
  , ptrAlign = 4
  }

x86_64 :: Target
x86_64 = Target
  { architecture = "x86-64"
  , ptrBits = 64
  , ptrBytes = 8
  , ptrAlign = 8
  }

intBytes, intBits :: Target -> Integer
intBytes = ptrBytes
intBits = ptrBits

targets :: [Target]
targets = [x86, x86_64]

architectures :: [String]
architectures = architecture <$> targets

findTarget :: String -> Either Doc Target
findTarget arch = case List.find ((== arch) . architecture) targets of
  Nothing -> Left
    $ "There is no target architecture called "
    <> Leijen.red (pretty arch)
    <> ". Available targets are: "
    <> prettyHumanList "and" (Leijen.dullgreen . pretty <$> architectures)
    <> "."
  Just t -> Right t

defaultTarget :: Target
defaultTarget = x86_64
