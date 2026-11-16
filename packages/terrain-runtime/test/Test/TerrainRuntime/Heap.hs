-- | What a value retains, measured on the heap after a major collection ("GHC.Exts.Heap"): the closures
-- reachable from it, the unevaluated ones among them, their bytes, and how many of them are a given
-- constructor. Suite-local: the regional build's examples measure what a build keeps with it, which no
-- public interface can show (a thunk that keeps a region's plan alive answers like the value it becomes).
module Test.TerrainRuntime.Heap
  ( Retained (..)
  , retainedBy
  ) where

import Control.Monad (foldM)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import GHC.Exts (Any)
import GHC.Exts.Heap (Box (..), GenClosure (..), allClosures, asBox, getBoxedClosureData)
import GHC.Exts.Heap.Closures (closureSize)
import System.Mem.StableName (StableName, eqStableName, hashStableName, makeStableName)

-- | What a value retains.
data Retained = Retained
  { retClosures ∷ !Int
  , retThunks ∷ !Int
  -- ^ Closures not yet evaluated (thunks, applications, selectors).
  , retBytes ∷ !Int
  -- ^ The bytes of every closure reachable, headers included.
  , retConstructors ∷ !(Map String Int)
  -- ^ How many reachable closures each counted constructor has.
  }
  deriving stock (Eq, Show)

-- | Walk everything reachable from a value, once each, after a major collection. Closures of the
-- constructors named in @skip@ are neither counted nor entered (something the caller shares with the
-- value and does not measure, such as a discovery environment); the constructors named in @count@ are
-- counted.
retainedBy ∷ [String] → [String] → a → IO Retained
retainedBy skip count value = do
  (_, r) ← go (IntMap.empty, Retained 0 0 0 Map.empty) (asBox value)
  pure r
  where
    go ∷ (IntMap [StableName Any], Retained) → Box → IO (IntMap [StableName Any], Retained)
    go (seen, r) box@(Box x) = do
      sn ← makeStableName x
      let key = hashStableName sn
      if any (eqStableName sn) (IntMap.findWithDefault [] key seen)
        then pure (seen, r)
        else do
          closure ← getBoxedClosureData box
          let seen' = IntMap.insertWith (<>) key [sn] seen
          case closure of
            ConstrClosure {name = con}
              | con `elem` skip → pure (seen', r)
              | otherwise →
                  descend seen' closure r {retConstructors = if con `elem` count then Map.insertWith (+) con 1 (retConstructors r) else retConstructors r}
            _ → descend seen' closure r {retThunks = retThunks r + if unevaluated closure then 1 else 0}
      where
        descend seen' closure r' =
          foldM go (seen', r' {retClosures = retClosures r' + 1, retBytes = retBytes r' + 8 * closureSize box}) (allClosures closure)
    unevaluated = \case
      ThunkClosure {} → True
      APClosure {} → True
      APStackClosure {} → True
      SelectorClosure {} → True
      _ → False
