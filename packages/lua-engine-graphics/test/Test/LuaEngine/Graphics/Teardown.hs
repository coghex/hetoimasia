-- | The end of the backend's scope: it takes outstanding work apart in dependency order and waits for the
-- owner's own evidence, outside any uninterruptible release; a cancellation delivered while it waits is
-- remembered and raised after; and it neither closes the shared owner nor disturbs a peer's texture.
module Test.LuaEngine.Graphics.Teardown (spec) where

import Control.Concurrent (throwTo)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (AsyncException (UserInterrupt))
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Graphics.Texture.Port (Standing (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "the backend's scope ends in dependency order" $ do
  it "withdraws a request in flight, releases a texture nobody released, and returns only when both are retired" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded $ do
      withBackendOnRaw fake $ \rig → do
        done ← newProbe
        _ ← submit rig done 2 2 255
        _ ← awaitTerminal done
        _ ← delivered done
        hold fake HoldUploadStart
        inflight ← newProbe
        _ ← submit rig inflight 2 2 255
        awaitEvent fake "upload admitted 1"
      problems ← atomically (leaked fake)
      problems `shouldBe` []
    -- The texture was released by the scope, once; the request in flight was cancelled before it started.
    eventCount fake "release attempted" `shouldReturn` 1
    eventCount fake "upload cancelled 1" `shouldReturn` 1
    eventCount fake "discarded 1" `shouldReturn` 1

  it "waits for the table's evidence when it closes, and returns the moment the evidence is in" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded $ do
      forked ← forkScope $ do
        withBackendOnRaw fake $ \rig → do
          probe ← newProbe
          _ ← submit rig probe 2 2 255
          _ ← awaitTerminal probe
          hold fake HoldReclaim
          setVersionHolders fake 1
        noteEvent fake "scope returned"
      -- The scope has closed and released the texture; a batch still maps its slot.
      awaitEvent fake "released"
      noteEvent fake "evidence supplied"
      setVersionHolders fake 0
      release fake HoldReclaim
      forkedJoin forked >>= either (\failure → expectationFailure (show failure)) pure
      assertBefore fake "evidence supplied" "scope returned"

  it "remembers a cancellation delivered while it waits, finishes the drain, and raises it after" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded $ do
      forked ← forkScope $ do
        withBackendOnRaw fake $ \rig → do
          probe ← newProbe
          _ ← submit rig probe 2 2 255
          _ ← awaitTerminal probe
          hold fake HoldReclaim
          setVersionHolders fake 1
        noteEvent fake "scope returned"
      awaitEvent fake "released"
      throwTo (forkedThread forked) UserInterrupt
      noteEvent fake "evidence supplied"
      setVersionHolders fake 0
      release fake HoldReclaim
      forkedJoin forked >>= \case
        Left _ → pure ()
        Right () → expectationFailure "the cancellation was lost"
      -- The drain ran to its end first: the evidence was in before the scope left, and nothing native is left.
      problems ← atomically (leaked fake)
      problems `shouldBe` []

  it "leaves a peer's texture to its own release when another is released" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded . withBackendOnRaw fake $ \rig → do
      keeper ← newProbe
      _ ← submit rig keeper 2 2 255
      _ ← awaitTerminal keeper
      peer ← delivered keeper
      other ← newProbe
      _ ← submit rig other 2 2 255
      _ ← awaitTerminal other
      mine ← delivered other
      reading ← textureRelease mine
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      -- The peer is untouched: still registered, and its release has not been asked.
      fakeReading ← atomically (readFake fake)
      readingRegistrations fakeReading `shouldBe` 1
      eventCount fake "release attempted" `shouldReturn` 1
      again ← textureRelease peer
      atomically (again >>= \case ProviderComplete → pure (); _ → retry)

  it "fails a request honestly when the owner has already ended, and says so" $ do
    fake ← newFake defaultFakeConfig
    withFakeOwner fake . bounded . withBackendOnRaw fake $ \rig → do
      setStanding fake (Ended "gone")
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      failed ← awaitTerminal probe
      failed `shouldSatisfy` (\case SeFailed _ → True; _ → False)
      reading ← readingNow rig
      readingEnded reading `shouldBe` Just "gone"
