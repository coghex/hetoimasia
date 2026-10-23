{-# LANGUAGE OverloadedStrings #-}

-- | The pipeline's own end: admission closes before anything drains, started work and delayed
-- retirement are awaited and nothing is reported over while the backend still holds a buffer, a texture
-- delivered while draining is released once and awaited, and a fault while draining is kept and does
-- not cut the drain short.
module Test.LuaEngine.Texture.Lifecycle (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, fromException, tryWithContext)
import Control.Monad (forM_, void)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Data.Word (Word64)
import Control.Concurrent.MVar (readMVar)
import Control.Exception (try)
import System.Timeout (timeout)
import Test.HUnit.Lang (HUnitFailure)
import Test.Hspec
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..))
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (layout, loadAs, small, started)
import Test.LuaEngine.Texture.Support

bytes ∷ [(ByteLimit, Word64)]
bytes =
  [ (PngEncodedBytes, 65536)
  , (PngInflatedScanlineBytes, 65536)
  , (PngPipelineWorkspaceBytes, 1048576)
  , (TextureBytesPerUiInstance, 16384)
  , (TextureBytesPerSession, 32768)
  ]

containsText ∷ String → String → Bool
containsText needle = any (\suffix → take (length needle) suffix == needle) . tails'
  where
    tails' text = [drop n text | n ← [0 .. length text]]

spec ∷ Spec
spec = describe "the pipeline's end" $ do
  it "closes admission first, then waits for an upload the backend still holds, reporting nothing over until the backend has ended it" $
    withSession (config small layout) $ \session _ runtime → do
      let say entry = note session entry
      withNested
        session
        ( \nested → do
            vm ← startVm nested runtime "closing" OnArrival
            admitDriver nested vm "i"
            started nested vm "i" "k0" "a.png"
            awaitUploads (ssFake nested) 1
            held ← uploadN (ssFake nested) 0
            stopInstance nested vm "i"
            awaitUploadCancelled held
        )
        ( \nested → do
            -- The scope has closed admission and is draining: the upload is still held, and the pipeline
            -- is not reporting itself over.
            reading ← pipelineNow nested
            say ("closed open=" <> Text.pack (show (readingOpen reading)) <> " uploading=" <> Text.pack (show (readingUploading reading)))
            held ← uploadN (ssFake nested) 0
            -- The backend still holds the level: the condition the scope waits for is not met.
            atomically (pipelineDrained (ssPipeline nested)) `shouldReturn` False
            -- Recorded before the backend lets go, so nothing the scope does can precede it.
            say "backend ending the upload"
            void (withdrawUpload (ssFake nested) held)
        )
      seen ← history session
      filter (\entry → "closed " `Text.isPrefixOf` entry || entry `elem` ["backend ending the upload", "nested scope returned"]) seen
        `shouldBe` ["closed open=False uploading=1", "backend ending the upload", "nested scope returned"]

  it "drains with every normal bank full: the request place, the pipeline's accepted-work record and the instance's lease capacity are all held, and the drain still ends the work" $
    withSession ((config (smaller [(RequestsPerInstance, 1), (PngPixels, 1024), (PngAxisMaximum, 32)] bytes) layout) {cfgJobs = 1, cfgLeases = 1}) $ \session _ runtime → do
      withNested
        session
        ( \nested → do
            vm ← startVm nested runtime "full" OnArrival
            admitDriver nested vm "i"
            started nested vm "i" "k0" "a.png"
            loadAs nested vm "i" "z" "b.png" >>= (`shouldSatisfy` Text.isInfixOf "busy")
            awaitUploads (ssFake nested) 1
            held ← uploadN (ssFake nested) 0
            stopInstance nested vm "i"
            awaitUploadCancelled held
        )
        ( \nested → do
            held ← uploadN (ssFake nested) 0
            void (withdrawUpload (ssFake nested) held)
        )
      note session "drained"
      history session >>= (`shouldSatisfy` elem "drained")

  it "releases a texture delivered while it drains, once, and does not return until the backend proves it retired" $
    withSession (config small layout) $ \session _ runtime → do
      withNested
        session
        ( \nested → do
            vm ← startVm nested runtime "delivered" OnArrival
            admitDriver nested vm "i"
            started nested vm "i" "k0" "a.png"
            awaitUploads (ssFake nested) 1
            held ← uploadN (ssFake nested) 0
            stopInstance nested vm "i"
            awaitUploadCancelled held
        )
        ( \nested → do
            held ← uploadN (ssFake nested) 0
            -- The backend ignores the cancellation and finishes while the pipeline drains.
            identity ← finishUpload (ssFake nested) held
            awaitReleaseCalls (ssFake nested) 1
            releaseCalls (ssFake nested) `shouldReturn` [identity]
            note session "released while draining"
            -- The texture is released and not retired: the condition the scope waits for is not met,
            -- and it is met once the backend proves the retirement.
            atomically (pipelineDrained (ssPipeline nested)) `shouldReturn` False
            -- Recorded before the backend proves the retirement: the scope cannot have returned yet.
            note session "backend proving retirement"
            retireTexture (ssFake nested) identity
            atomically (pipelineDrained (ssPipeline nested) >>= \done → if done then pure () else retry)
        )
      seen ← history session
      filter (`elem` ["released while draining", "backend proving retirement", "nested scope returned"]) seen
        `shouldBe` ["released while draining", "backend proving retirement", "nested scope returned"]

  it "keeps a fault raised while it drains, raises it when the scope ends, still waits for everything else, and reports the failed release to the owner whose request it was as cleanup evidence" $ do
    ExceptionWithContext _ ownerFailure ← fatalSession (config small layout) $ \session _ runtime → do
      outcome ←
        tryWithContext @SomeException $
          withNested
            session
            ( \nested → do
                vm ← startVm nested runtime "faulty" OnArrival
                admitDriver nested vm "i"
                started nested vm "i" "k0" "a.png"
                awaitUploads (ssFake nested) 1
                held ← uploadN (ssFake nested) 0
                stopInstance nested vm "i"
                awaitUploadCancelled held
            )
            ( \nested → do
                setRaiseOnRelease (ssFake nested) True
                held ← uploadN (ssFake nested) 0
                identity ← finishUpload (ssFake nested) held
                awaitReleaseCalls (ssFake nested) 1
                releaseCalls (ssFake nested) `shouldReturn` [identity]
            )
      -- The scope was not cut short by the fault, and raised it once it was over.
      case outcome of
        Left (ExceptionWithContext _ failure) →
          fmap show (fromException failure ∷ Maybe IOError) `shouldSatisfy` maybe False (containsText "could not release the texture")
        Right () → expectationFailure "the scope should have raised the failure of the release"
    -- A texture whose release failed is never reported retired: the request's retirement reading says so,
    -- and that is fatal to the owner, as every cleanup failure is.
    show ownerFailure `shouldSatisfy` containsText "could not release the texture"

  forM_ [("throws", PollThrows, "reading threw", "retirement failed"), ("answers that the retirement failed", PollFails, "could not retire", "retirement failed"), ("is a lazy error when the release returns it", PollLazy, "lazy reading", "lazy reading")] $ \(label, mode, expected, scopeText) →
    it ("does not retry a retirement reading that " <> label <> ": the failure is recorded once, the charge stays held and the drain goes on") $ do
      ExceptionWithContext _ ownerFailure ← fatalSession (config small layout) $ \session _ runtime → do
        seen ← newIORef Nothing
        outcome ←
          tryWithContext @SomeException $
            withNested
              session
              ( \nested → do
                  writeIORef seen (Just nested)
                  vm ← startVm nested runtime "poll" OnArrival
                  admitDriver nested vm "i"
                  started nested vm "i" "k0" "a.png"
                  awaitUploads (ssFake nested) 1
                  held ← uploadN (ssFake nested) 0
                  stopInstance nested vm "i"
                  awaitUploadCancelled held
              )
              ( \nested → do
                  setPollMode (ssFake nested) mode
                  held ← uploadN (ssFake nested) 0
                  identity ← finishUpload (ssFake nested) held
                  awaitReleaseCalls (ssFake nested) 1
                  releaseCalls (ssFake nested) `shouldReturn` [identity]
              )
        -- The scope ended (it did not loop on the reading) and raised the recorded failure.
        case outcome of
          Left (ExceptionWithContext _ failure) → show failure `shouldSatisfy` containsText scopeText
          Right () → expectationFailure "the scope should have raised the failed retirement"
        -- The texture is not reported reclaimed: its charge is still held.
        readIORef seen >>= maybe (expectationFailure "the body never ran") (\nested → sessionNow nested `shouldReturn` 128)
      -- The owner whose request it was is told as cleanup evidence, as every cleanup failure is.
      show ownerFailure `shouldSatisfy` containsText expected

  it "unwinds the fixture when an example fails while a hook, a gate and a submission are held: nothing waits for what the failure left behind" $ do
    gate ← newGate
    submission ←
      timeout 60000000 . try @HUnitFailure $
        withSession ((config small layout) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}) $ \session _ runtime → do
          vm ← startVm session runtime "unwinding" OnArrival
          admitDriver session vm "i"
          started session vm "i" "k0" "a.png"
          readMVar (arrived gate)
          expectationFailure "injected while the decode hook holds the worker"
    holding ←
      timeout 60000000 . try @HUnitFailure $
        withSession (config small layout) $ \session _ runtime → do
          vm ← startVm session runtime "unwinding" OnArrival
          admitDriver session vm "i"
          setHoldSubmission (ssFake session) True
          started session vm "i" "k0" "a.png"
          awaitSubmitting (ssFake session) 1
          expectationFailure "injected while the backend's submission is held"
    (either (const True) (const False) <$> submission, either (const True) (const False) <$> holding) `shouldBe` (Just True, Just True)

  it "is not started over a pool whose workers are not the profile's: nothing is started and the failure names it" $
    withSession ((config small layout) {cfgPool = (1, 16)}) (\_ _ _ → pure ())
      `shouldThrow` \(TextureDefect why) → "the read pool has 1 workers, not the profile's 2" `Text.isInfixOf` why
