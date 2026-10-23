-- | The adapter under the real prerequisite machinery: a real content root, verified read, bounded decode, the
-- texture pipeline's lanes, banks and leases, and a real supervised Lua owner whose instances ask for textures,
-- over the fake owner. What these examples add to the backend-level ones is the other side of the port: that
-- instance end, cancellation and release reach the backend through the pipeline's own ownership, that banks
-- return only on the backend's evidence, and that a device fault is not made data by an optional request.
module Test.LuaEngine.Graphics.Composed (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, finally, try)
import Control.Monad (void)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Fault (..))
import Hetoimasia.LuaEngine.Texture (OwnerReading (..), ownerReading)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Png (opaque)
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "the adapter under the pipeline, the leases and a real Lua owner" $ do
  it "gives the instance its texture and dimensions only once the registration resolved" $
    composed defaultFakeConfig {fcInitialHolds = [HoldBind]} $ \fake _ comp vm → do
      admit comp vm "a"
      commandLoad comp vm "a" "k" "a.png" False
      command comp vm "a" "wait_take" "k"
      awaitEvent fake "upload completed"
      notesNow comp >>= \seen → filter (Text.isInfixOf "wait_take") seen `shouldBe` []
      release fake HoldBind
      line ← awaitNoteContaining comp "a wait_take k"
      line `shouldSatisfy` Text.isInfixOf "status=success"
      line `shouldSatisfy` Text.isInfixOf "width=4"
      line `shouldSatisfy` Text.isInfixOf "height=2"
      command comp vm "a" "use" "k"
      _ ← awaitNoteContaining comp "a use k"
      pure ()

  it "returns the instance's banks only when the table proves the texture retired" $
    composed defaultFakeConfig $ \fake _ comp vm → do
      admit comp vm "a"
      commandLoad comp vm "a" "k" "a.png" False
      command comp vm "a" "wait_take" "k"
      _ ← awaitNoteContaining comp "a wait_take k"
      owner ← ownerOf vm "a"
      held ← atomically (ownerReading owner)
      ownerSlotsHeld held `shouldBe` 1
      -- A batch still maps the slot: the texture is released but not retired.
      hold fake HoldReclaim
      setVersionHolders fake 1
      command comp vm "a" "release" "k"
      awaitEvent fake "released"
      still ← atomically (ownerReading owner)
      ownerSlotsHeld still `shouldBe` 1
      setVersionHolders fake 0
      release fake HoldReclaim
      atomically (ownerReading owner >>= \r → if ownerSlotsHeld r == 0 then pure () else retry)

  it "frees everything when the instance ends with its request in flight, at every stage" $
    mapM_ stageEnd [HoldOwner, HoldAllocate, HoldUploadStart, HoldUploadFinish, HoldRegister]

  it "owns a success nobody took, and releases it with the instance" $
    composed defaultFakeConfig $ \fake _ comp vm → do
      admit comp vm "a"
      commandLoad comp vm "a" "k" "a.png" False
      awaitEvent fake "registered"
      stopInstance comp vm "a"
      void (awaitFailure comp "a")
      awaitFake fake ((== 0) . readingRegistrations)
      owner ← ownerOf vm "a"
      atomically (ownerReading owner >>= \r → if ownerSlotsHeld r == 0 then pure () else retry)

  it "keeps a peer instance's independent texture across the end of the other" $
    composed defaultFakeConfig $ \fake _ comp vm → do
      admit comp vm "a"
      admit comp vm "b"
      commandLoad comp vm "a" "k" "a.png" False
      commandLoad comp vm "b" "k" "a.png" False
      command comp vm "a" "wait_take" "k"
      command comp vm "b" "wait_take" "k"
      _ ← awaitNoteContaining comp "a wait_take k"
      _ ← awaitNoteContaining comp "b wait_take k"
      stopInstance comp vm "a"
      void (awaitFailure comp "a")
      awaitFake fake ((== 1) . readingRegistrations)
      command comp vm "b" "use" "k"
      line ← awaitNoteContaining comp "b use k"
      line `shouldSatisfy` (not . Text.isInfixOf "error")

  it "does not turn a device fault into data because the request was optional" $ do
    outcome ← try @SomeException . composed defaultFakeConfig $ \fake _ comp vm → do
      inject fake (FailAllocate (FaultFatal "no device memory"))
      admit comp vm "a"
      commandLoad comp vm "a" "k" "a.png" True
      command comp vm "a" "wait_take" "k"
      -- The instance is failed by the pipeline's own failure; the script never saw an image error.
      void (awaitFailure comp "a")
      notesNow comp >>= \seen → filter (Text.isInfixOf "status=failure") seen `shouldBe` []
    case outcome of
      Left _ → pure ()
      Right () → expectationFailure "the scope returned although the backend failed"
  where
    stageEnd stage =
      composed defaultFakeConfig $ \fake _ comp vm → do
        hold fake stage
        admit comp vm "a"
        commandLoad comp vm "a" "k" "a.png" False
        case stage of
          HoldOwner → awaitFake fake ((== 1) . readingActsQueued)
          HoldAllocate → awaitFake fake ((== 0) . readingActsQueued)
          HoldUploadStart → awaitEvent fake "upload admitted"
          HoldUploadFinish → awaitEvent fake "upload started"
          _ → awaitFake fake (const True)
        stopInstance comp vm "a"
        release fake stage
        void (awaitFailure comp "a")
        owner ← ownerOf vm "a"
        atomically (ownerReading owner >>= \r → if ownerSlotsHeld r == 0 then pure () else retry)
        awaitFake fake (\r → readingRegistrations r == 0 && readingImagesAlive r == 0)

-- | A composition over a fake owner: one backend, the pipeline over it, a Lua owner, one VM; and the checks every
-- example owes afterwards.
composed ∷ FakeConfig → (Fake → Rig → Composition → Vm → IO a) → IO a
composed cfg body = do
  fake ← newFake cfg
  value ←
    bounded . withFakeOwner fake $
      withBackendOnRaw fake $ \rig →
        withComposition compositionProfile [("a.png", opaque 4 2)] (rigPort rig) $ \comp _ runtime → do
          vm ← startVm comp runtime "graphics-vm"
          body fake rig comp vm `finally` openAll fake
  problems ← atomically (leaked fake)
  problems `shouldBe` []
  pure value
  where
    openAll fake = mapM_ (release fake) [minBound .. maxBound]

notesNow ∷ Composition → IO [Text.Text]
notesNow = notes

_unused ∷ InstancePhase
_unused = Active
