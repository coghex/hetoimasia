-- | Whether a value is evaluated all the way down, for the registry's state:
-- nothing reachable from it is a computation that holds on to what it was built
-- from (GUIDE-5).
module Test.Render.TwoD.Vulkan.Evaluated (unevaluatedParts) where

import GHC.Exts.Heap (Box, GenClosure (..), allClosures, areBoxesEqual, asBox, getBoxedClosureData)

-- | Every closure reachable from a value that is not a constructor: a thunk, an
-- application, a function or a partial application, each of which holds on to
-- what it was built from. Empty exactly when the value is fully evaluated.
unevaluatedParts ∷ a → IO [String]
unevaluatedParts root = go [asBox root] [] []
  where
    go ∷ [Box] → [Box] → [String] → IO [String]
    go [] _ found = pure (reverse found)
    go (box : rest) seen found = do
      known ← anySame box seen
      if known
        then go rest seen found
        else do
          closure ← getBoxedClosureData box
          case closure of
            ConstrClosure {} → go (allClosures closure <> rest) (box : seen) found
            IndClosure {indirectee = pointee} → go (pointee : rest) (box : seen) found
            ThunkClosure {} → go rest (box : seen) ("a thunk" : found)
            APClosure {} → go rest (box : seen) ("an application" : found)
            APStackClosure {} → go rest (box : seen) ("a stacked application" : found)
            SelectorClosure {} → go rest (box : seen) ("a selector" : found)
            BlackholeClosure {} → go rest (box : seen) ("a blackhole" : found)
            FunClosure {} → go rest (box : seen) ("a function" : found)
            PAPClosure {} → go rest (box : seen) ("a partial application" : found)
            _ → go rest (box : seen) ("a closure that is not a constructor" : found)
    anySame _ [] = pure False
    anySame box (other : others) = areBoxesEqual box other >>= \same → if same then pure True else anySame box others
