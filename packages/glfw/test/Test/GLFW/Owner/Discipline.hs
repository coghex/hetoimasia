-- | The owner's GLFW discipline: every native call made from the owner's thread
-- is the authorized wake, read from the seam's own record of each call and the
-- thread that made it.
module Test.GLFW.Owner.Discipline (spec) where

import Control.Concurrent.STM (atomically, check, readTVarIO)
import qualified Data.Map.Strict as Map
import Hetoimasia.GLFW.Internal.Seam (NativeCall (..))
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Drive
  ( awaitTerminal
  , handedOver
  , observed
  , sampledObservation
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..))
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost)
import Test.GLFW.Support (boundedExample, unexpected)
import Test.Hspec (Spec, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec =
  it "makes no GLFW call of its own: every native call from its thread is the authorized wake"
    (boundedExample testOwnerMakesNoGlfwCall)

-- | Every native call made from the owner's thread is the authorized wake, and
-- nothing else.
testOwnerMakesNoGlfwCall ∷ IO ()
testOwnerMakesNoGlfwCall = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    seen ← sampledObservation host window
    _ ← observed owner service 1 seen
    -- Folded, so the owner really did consume the observation rather than
    -- merely having been handed it.
    atomically (readOwnerGeometry owner >>= check . Map.member (graphicsAttachment service))
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pure ()
  calls ← readTVarIO (rigNative rig)
  threads ← readTVarIO (fakeThreads (rigFake rig))
  -- The operations all ran on one thread, which is the owner's.
  fromOwner ← case threads of
    [ownerThread] → pure [call | (caller, call) ← calls, caller == ownerThread]
    other → unexpected ("the fake operations ran on " <> show (length other) <> " threads")
  -- Everything that thread reached across for is the wake, which is
  -- publication and not a GLFW operation of the owner's.
  filter (/= PostEmptyEvent) fromOwner `shouldBe` []
  -- And the wake really was used, so the assertion above is not vacuous.
  fromOwner `shouldSatisfy` (not . null)
