-- | The triangle's pipeline cache over stand-in builders: numbered layouts and
-- pipelines, a journal of every construction asked for, and a pipeline build
-- that refuses a chosen number of times before it succeeds.
module Test.Sample.Triangle.Pipelines (spec) where

import Control.Monad (replicateM)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Word (Word32)

import Hetoimasia.GPU.Vulkan.Native.Recording (Refusal (..))
import Hetoimasia.Sample.Triangle.Pipelines (Builders (..), newPipelines, pipelineFor, pipelineFormats)
import Test.Hspec

-- | One construction the builders were asked for, in order.
data Construction
  = BuiltLayout !Int
  | RefusedLayout
  | BuiltPipeline !Int !Int !Word32
    -- ^ The pipeline, the layout it was built over, and its color format.
  | RefusedPipeline !Int !Word32
    -- ^ The layout the refused pipeline would have been built over, and its
    -- color format.
  deriving (Eq, Show)

-- | Stand-in builders whose layout build refuses @layoutRefusals@ times and
-- whose pipeline build refuses @pipelineRefusals@ times, each with its own
-- refusal, before they succeed. Layouts and pipelines are numbered from 1 in
-- the order they are built. The builders offer no release, as the host's do
-- not through 'Builders'.
standIn ∷ [Refusal] → [Refusal] → IO (Builders Int Int, IO [Construction])
standIn layoutRefusals pipelineRefusals = do
  journal ← newIORef []
  layoutsLeft ← newIORef layoutRefusals
  pipelinesLeft ← newIORef pipelineRefusals
  layouts ← newIORef (0 ∷ Int)
  pipelines ← newIORef (0 ∷ Int)
  let note entry = atomicModifyIORef' journal (\entries → (entry : entries, ()))
      next counter = atomicModifyIORef' counter (\n → (n + 1, n + 1))
      builders =
        Builders
          { buildLayout =
              pop layoutsLeft >>= \case
                Just refusal → Left refusal <$ note RefusedLayout
                Nothing → do
                  layout ← next layouts
                  Right layout <$ note (BuiltLayout layout)
          , buildPipeline = \layout _ wanted →
              pop pipelinesLeft >>= \case
                Just refusal → Left refusal <$ note (RefusedPipeline layout wanted)
                Nothing → do
                  pipeline ← next pipelines
                  Right pipeline <$ note (BuiltPipeline pipeline layout wanted)
          }
  pure (builders, reverse <$> readIORef journal)

pop ∷ IORef [a] → IO (Maybe a)
pop ref = atomicModifyIORef' ref $ \case
  [] → ([], Nothing)
  x : rest → (rest, Just x)

layoutsBuilt ∷ [Construction] → Int
layoutsBuilt entries = length [() | BuiltLayout _ ← entries]

format ∷ Word32
format = 44

otherFormat ∷ Word32
otherFormat = 50

-- | Three refusals of the kinds a recurring refusal takes: transient, and a
-- construction that raised.
refusals ∷ [Refusal]
refusals = [RefusedDiagnosticPending, RefusedConstructionFailed "stand-in", RefusedDiagnosticPending]

spec ∷ Spec
spec = describe "Triangle pipelines" $ do
  it "builds a format's layout once while its pipeline is refused, and releases none" $ do
    (builders, journal) ← standIn [] refusals
    pipelines ← newPipelines
    answers ← replicateM (length refusals) (pipelineFor pipelines builders format)
    -- Each refusal is answered as it was, so the frame is skipped.
    answers `shouldBe` map Left refusals
    pipelineFormats pipelines `shouldReturn` []
    success ← pipelineFor pipelines builders format
    success `shouldBe` Right 1
    pipelineFormats pipelines `shouldReturn` [format]
    entries ← journal
    -- One layout, built once and handed to every attempt; the builders offer
    -- no release, so every layout built is still the one held.
    entries
      `shouldBe` [BuiltLayout 1]
        <> map (const (RefusedPipeline 1 format)) refusals
        <> [BuiltPipeline 1 1 format]
    layoutsBuilt entries `shouldBe` 1

  it "reuses a built pipeline for every later frame of its format" $ do
    (builders, journal) ← standIn [] refusals
    pipelines ← newPipelines
    _ ← replicateM (length refusals + 1) (pipelineFor pipelines builders format)
    settled ← journal
    later ← replicateM 3 (pipelineFor pipelines builders format)
    later `shouldBe` replicate 3 (Right 1)
    journal `shouldReturn` settled

  it "holds nothing when the layout is refused, and builds it on a later frame" $ do
    (builders, journal) ← standIn [RefusedDiagnosticPending] []
    pipelines ← newPipelines
    pipelineFor pipelines builders format `shouldReturn` Left RefusedDiagnosticPending
    pipelineFormats pipelines `shouldReturn` []
    pipelineFor pipelines builders format `shouldReturn` Right 1
    journal `shouldReturn` [RefusedLayout, BuiltLayout 1, BuiltPipeline 1 1 format]

  it "holds one layout and one pipeline per color format" $ do
    (builders, journal) ← standIn [] [RefusedDiagnosticPending]
    pipelines ← newPipelines
    pipelineFor pipelines builders format `shouldReturn` Left RefusedDiagnosticPending
    pipelineFor pipelines builders otherFormat `shouldReturn` Right 1
    pipelineFormats pipelines `shouldReturn` [otherFormat]
    pipelineFor pipelines builders format `shouldReturn` Right 2
    pipelineFormats pipelines `shouldReturn` [format, otherFormat]
    journal
      `shouldReturn` [ BuiltLayout 1
                     , RefusedPipeline 1 format
                     , BuiltLayout 2
                     , BuiltPipeline 1 2 otherFormat
                     , BuiltPipeline 2 1 format
                     ]
