-- | The sprites sample's swap case (GRS-9): the atlas's handle is redirected
-- to a replacement texture in a surface-free session, with the scene's
-- instance data — which carries the handle, not the texture — unchanged
-- across the swap.
--
-- The case draws the sample's scene three times, each into its own 256×256
-- linear RGBA8 target, read back once its batch's completion is proved:
--
-- 1. /before/: a frame recorded and submitted before the swap, which samples
--    the atlas;
-- 2. /delayed/: a frame recorded before the swap and submitted after it. Its
--    recording binds the table, and then, before the batch is submitted, the
--    atlas's handle is swapped to 'swappedAtlasFixture' — whose upload has
--    completed, so the swap takes effect at once — and a texture is
--    registered, which must not take the atlas's slot: the delayed batch
--    still holds the version mapping it. The batch still samples the atlas;
-- 3. /after/: a frame recorded once the delayed batch has completed, which
--    samples the replacement.
--
-- Once the delayed batch has completed and the after frame has bound the
-- table, a second texture is registered, and must take the atlas's old slot:
-- the slot is reused only after the batch that held it completes. The before
-- and delayed captures are checked against the oracle over the original
-- fixtures, the after capture against the oracle with the replacement drawn
-- for the atlas ('evaluateProbesWith'). The PNGs and a JSON record of the
-- facts, the ordering and every probe are written into the directory.
--
-- A session holds one texture table, so the case runs in a session of its
-- own: the sample's executable runs it with @--evidence --swap@, and the
-- window integration's native suite runs it as @grs9-swap@.
module Hetoimasia.Sample.Sprites.Swap
  ( SwapEvidence (..)
  , SwapFacts (..)
  , runSwapEvidence
  , swapBeforePng
  , swapDelayedPng
  , swapAfterPng
  , swapRecordName
  , renderSwapRecord
  , swappedTextures
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word32)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Refusal (RefusedIllegal)
  , formatCode
  )
import Hetoimasia.GPU.Vulkan.Native.TextureTable
  ( LookupEntry (..)
  , SwapState (..)
  , TableView (..)
  , TextureHandle (..)
  , readSwapTicket
  )
import Hetoimasia.GPU.Vulkan.Native.Uploads (UploadRequest (..))
import Hetoimasia.Sample.Sprites
  ( Builders (..)
  , Made (..)
  , SceneTarget (..)
  , makeSprites
  , pipelineFor
  , recordScene
  , registerSprites
  , sceneInstanceBytes
  , spritesHandle
  , uploadRequests
  )
import Hetoimasia.Sample.Sprites.Evidence (Host (..))
import Hetoimasia.Sample.Sprites.Fixtures (Fixture (..), FixtureName (..), Rgba (..), fixture, swappedAtlasFixture, translucentFixture)
import Hetoimasia.Sample.Sprites.Oracle (Expectation (..), ProbeResult (..), evaluateProbesWith, probesPassed)
import Hetoimasia.Sample.Sprites.Png (encodePng)
import Hetoimasia.Sample.Sprites.Scene (Probe (..), targetBytes, targetSide)

-- | What the swap case found besides its captures.
data SwapFacts = SwapFacts
  { factsOldSlot ∷ !Word32
    -- ^ The atlas's slot before the swap.
  , factsNewSlot ∷ !Word32
    -- ^ The replacement's slot, which the handle resolves to after it.
  , factsSwapState ∷ !SwapState
    -- ^ Where the swap stood once the delayed batch completed.
  , factsRetiringDuringDelay ∷ ![Word32]
    -- ^ The retiring slots while the delayed batch, recorded and not yet
    -- submitted, held the version mapping the old slot.
  , factsSlotDuringDelay ∷ !Word32
    -- ^ The slot a texture registered then took.
  , factsSlotAfterCompletion ∷ !Word32
    -- ^ The slot a texture registered once the delayed batch completed took.
  , factsInstancesUnchanged ∷ !Bool
    -- ^ Whether the instance data the frames drew was the same bytes before
    -- and after the swap.
  , factsInstanceBytes ∷ !Int
  , factsOrder ∷ ![Text]
    -- ^ What happened, in order.
  }
  deriving (Show)

-- | What one swap case run found.
data SwapEvidence = SwapEvidence
  { swapPassed ∷ !Bool
  , swapFailure ∷ !(Maybe Text)
    -- ^ Why the run stopped before checking everything, if it did.
  , swapBc7 ∷ !(Maybe Bool)
  , swapFacts ∷ !(Maybe SwapFacts)
  , swapBefore ∷ ![ProbeResult]
  , swapDelayed ∷ ![ProbeResult]
  , swapAfter ∷ ![ProbeResult]
  , swapPngs ∷ ![FilePath]
  , swapRecord ∷ !FilePath
  }

swapBeforePng, swapDelayedPng, swapAfterPng, swapRecordName ∷ FilePath
swapBeforePng = "swap-before.png"
swapDelayedPng = "swap-delayed.png"
swapAfterPng = "swap-after.png"
swapRecordName = "swap-probes.json"

-- | The textures the after frame draws: the replacement for the atlas, the
-- other fixtures as they were.
swappedTextures ∷ FixtureName → Fixture
swappedTextures = \case
  Atlas → swappedAtlasFixture
  other → fixture other

-- | What the run captured: the BC7 status, the three readbacks and the facts.
data Captured = Captured !Bool !ByteString !ByteString !ByteString !SwapFacts

-- | Run the swap case over a host, writing its PNGs and record into this
-- directory, which is made if missing and never deleted.
runSwapEvidence ∷ Host → FilePath → IO SwapEvidence
runSwapEvidence Host {hostAct = actOn, hostRecord = recordOn, hostUpload = upload, hostAwait = awaitBatch, hostReadTable = readTable, hostRead = readBytes} directory = do
  createDirectoryIfMissing True directory
  outcome ← evidence
  let recordPath = directory </> swapRecordName
  case outcome of
    Left (failure, bc7) → do
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderSwapRecord (Just failure) bc7 Nothing [] [] []))
      pure (SwapEvidence False (Just failure) bc7 Nothing [] [] [] [] recordPath)
    Right (Captured bc7 before delayed after facts) → do
      let short = [(name, ByteString.length bytes) | (name, bytes) ← [("before", before), ("delayed", delayed), ("after", after)], ByteString.length bytes /= fromIntegral targetBytes]
          failure = case short of
            [] → Nothing
            _ → Just ("short readbacks: " <> tshow short)
          checkedBefore = evaluateProbesWith fixture bc7 before
          checkedDelayed = evaluateProbesWith fixture bc7 delayed
          checkedAfter = evaluateProbesWith swappedTextures bc7 after
          paths = [directory </> name | name ← [swapBeforePng, swapDelayedPng, swapAfterPng]]
          passed =
            failure == Nothing
              && all probesPassed [checkedBefore, checkedDelayed, checkedAfter]
              && factsHold facts
      mapM_ (\(path, bytes) → ByteString.writeFile path (encodePng targetSide targetSide bytes)) (zip paths [before, delayed, after])
      ByteString.writeFile recordPath (Text.encodeUtf8 (renderSwapRecord failure (Just bc7) (Just facts) checkedBefore checkedDelayed checkedAfter))
      pure (SwapEvidence passed failure (Just bc7) (Just facts) checkedBefore checkedDelayed checkedAfter paths recordPath)
  where
    evidence = do
      madeAnswer ← actOn "making the ring, the table, the textures, the targets and the layout" $ \builders → do
        made ← makeSprites builders
        targets ← traverse (const (buildImage builders (ImageDescription ColorTarget Rgba8Linear side side 1))) [1 ∷ Int .. 3]
        readbacks ← traverse (const (buildReadback builders targetBytes)) [1 ∷ Int .. 3]
        replacement ← buildImage builders (ImageDescription TextureImage Rgba8Linear (fixtureWidth swappedAtlasFixture) (fixtureHeight swappedAtlasFixture) 1)
        extras ← traverse (const (buildImage builders (ImageDescription TextureImage Rgba8Linear 2 2 1))) [1 ∷ Int .. 2]
        pure $ do
          made' ← made
          targets' ← sequence targets
          readbacks' ← sequence readbacks
          replacement' ← replacement
          extras' ← sequence extras
          case (targets', readbacks', extras') of
            ([t0, t1, t2], [r0, r1, r2], [during, later]) → Right (made', (t0, r0), (t1, r1), (t2, r2), replacement', during, later)
            _ → Left (RefusedIllegal "the swap case's targets, readbacks and textures were not all made")
      case madeAnswer of
        Left failure → pure (Left (failure, Nothing))
        Right (made, (t0, r0), (t1, r1), (t2, r2), replacement, during, later) → do
          let bc7 = Map.size (madeTextures made) == 3
              stop failure = pure (Left (failure, Just bc7))
          uploads ←
            traverse
              upload
              ( uploadRequests made
                  <> [ UploadImage replacement [fixtureBytes swappedAtlasFixture]
                     , UploadImage during [fixtureBytes translucentFixture]
                     , UploadImage later [fixtureBytes translucentFixture]
                     ]
              )
          case sequence uploads of
            Left failure → stop ("an upload did not complete: " <> failure)
            Right _ →
              awaitPlaceholder (200 ∷ Int) >>= \case
                Left failure → stop failure
                Right () → do
                  held ← newIORef Nothing
                  order ← newIORef []
                  let noting what = modifyOrder order what
                  -- 1. The frame before the swap.
                  beforeTicket ← recordOn "registering the textures and recording the frame before the swap" $ \builders →
                    registerSprites builders made >>= \case
                      Left refusal → pure (Left refusal)
                      Right sprites → do
                        writeIORef held (Just sprites)
                        fmap (\pipeline → recordScene sprites pipeline (Offscreen t0 r0)) <$> pipelineFor builders sprites (formatCode Rgba8Linear)
                  sprites' ← readIORef held
                  case (beforeTicket, sprites' >>= \sprites → (,) sprites <$> spritesHandle Atlas sprites) of
                    (Left failure, _) → stop failure
                    (Right _, Nothing) → stop "the atlas was not registered"
                    (Right beforeBatch, Just (sprites, atlas)) →
                      andThen (awaitBatch beforeBatch) stop ("the frame before the swap did not complete: " <>) $ \() → do
                        noting "the frame before the swap completed"
                        andThen (readBytes r0) stop ("the frame before the swap was not read: " <>) $ \before →
                          andThen readTable stop id $ \beforeView → do
                            let instancesBefore = sceneInstanceBytes sprites
                                oldSlot = slotOf atlas beforeView
                            delayedState ← newIORef Nothing
                            -- 2. The delayed frame: recorded, then the swap
                            -- and a registration, then submitted.
                            delayedTicket ← recordOn "recording a frame, then swapping the atlas and registering a texture before the frame is submitted" $ \builders →
                              fmap
                                ( \pipeline recorder →
                                    recordScene sprites pipeline (Offscreen t1 r1) recorder >>= \case
                                      Left refusal → pure (Left refusal)
                                      Right () →
                                        swapImage builders atlas replacement >>= \case
                                          Left refusal → pure (Left refusal)
                                          Right ticket →
                                            registerImage builders during >>= \case
                                              Left refusal → pure (Left refusal)
                                              Right duringHandle → do
                                                view ← inspectTable builders
                                                Right () <$ writeIORef delayedState (Just (ticket, duringHandle, view))
                                )
                                <$> pipelineFor builders sprites (formatCode Rgba8Linear)
                            noting "recorded the delayed frame, which bound the table; then swapped the atlas's handle and registered a texture; then submitted the frame"
                            delayedHeld ← readIORef delayedState
                            case (delayedTicket, delayedHeld) of
                              (Left failure, _) → stop failure
                              (Right _, Nothing) → stop "the delayed frame's swap was not made"
                              (Right delayedBatch, Just (swapTicket, duringHandle, duringView)) →
                                andThen (awaitBatch delayedBatch) stop ("the delayed frame did not complete: " <>) $ \() → do
                                  noting "the delayed frame completed"
                                  swapState ← atomically (readSwapTicket swapTicket)
                                  andThen (readBytes r1) stop ("the delayed frame was not read: " <>) $ \delayed → do
                                    -- 3. The frame after the swap.
                                    afterTicket ← recordOn "recording the frame after the swap" $ \builders →
                                      fmap (\pipeline → recordScene sprites pipeline (Offscreen t2 r2)) <$> pipelineFor builders sprites (formatCode Rgba8Linear)
                                    andThen' afterTicket stop $ \afterBatch →
                                      andThen (awaitBatch afterBatch) stop ("the frame after the swap did not complete: " <>) $ \() → do
                                        noting "the frame after the swap completed"
                                        andThen (readBytes r2) stop ("the frame after the swap was not read: " <>) $ \after →
                                          andThen (actOn "registering a texture once the delayed frame completed" (\builders → registerImage builders later)) stop id $ \laterHandle → do
                                            noting "registered a texture once the delayed frame completed"
                                            andThen readTable stop id $ \finalView → do
                                              steps ← reverse <$> readIORef order
                                              let instancesAfter = sceneInstanceBytes sprites
                                                  facts =
                                                    SwapFacts
                                                      { factsOldSlot = oldSlot
                                                      , factsNewSlot = slotOf atlas finalView
                                                      , factsSwapState = swapState
                                                      , factsRetiringDuringDelay = maybe [] tableViewRetiring duringView
                                                      , factsSlotDuringDelay = slotOf duringHandle finalView
                                                      , factsSlotAfterCompletion = slotOf laterHandle finalView
                                                      , factsInstancesUnchanged = instancesBefore == instancesAfter
                                                      , factsInstanceBytes = ByteString.length instancesAfter
                                                      , factsOrder = steps
                                                      }
                                              pure (Right (Captured bc7 before delayed after facts))
    side = fromIntegral targetSide
    -- The slot a version published now would resolve the handle to.
    slotOf handle = \case
      Just view → case Map.lookup (handleIndex handle) (tableViewMapping view) of
        Just entry | entryGeneration entry == handleGeneration handle → entrySlot entry
        _ → 0
      Nothing → 0
    awaitPlaceholder remaining =
      readTable >>= \case
        Left failure → pure (Left failure)
        Right (Just view) | tableViewPlaceholderWritten view → pure (Right ())
        Right _
          | remaining <= 0 → pure (Left "the texture table's placeholder was not written within ten seconds")
          | otherwise → threadDelay 50000 >> awaitPlaceholder (remaining - 1)

-- | Continue with an action's answer, or stop with its failure, prefixed.
andThen ∷ IO (Either Text a) → (Text → IO b) → (Text → Text) → (a → IO b) → IO b
andThen action stop' prefix continue =
  action >>= \case
    Left failure → stop' (prefix failure)
    Right value → continue value

-- | Continue with an answer already in hand, or stop with its failure.
andThen' ∷ Either Text a → (Text → IO b) → (a → IO b) → IO b
andThen' answer stop' continue = either stop' continue answer

modifyOrder ∷ IORef [Text] → Text → IO ()
modifyOrder order what = readIORef order >>= writeIORef order . (what :)

-- | Whether the facts show the swap as GRS-9 requires: published by the time
-- the delayed batch completed; the old slot retiring, and not reused, while
-- that batch held it; reused once it completed; the replacement in a slot of
-- its own; the instance data unchanged.
factsHold ∷ SwapFacts → Bool
factsHold facts =
  factsSwapState facts == SwapPublished
    && factsOldSlot facts `elem` factsRetiringDuringDelay facts
    && factsSlotDuringDelay facts `notElem` [0, factsOldSlot facts]
    && factsSlotAfterCompletion facts == factsOldSlot facts
    && factsNewSlot facts `notElem` [0, factsOldSlot facts]
    && factsOldSlot facts /= 0
    && factsInstancesUnchanged facts

-- | The swap case's record: a JSON document of the facts, the ordering, and
-- every probe of each capture.
renderSwapRecord ∷ Maybe Text → Maybe Bool → Maybe SwapFacts → [ProbeResult] → [ProbeResult] → [ProbeResult] → Text
renderSwapRecord failure bc7 facts before delayed after =
  Text.pack . (<> "\n") $
    object
      [ ("target", object [("width", show targetSide), ("height", show targetSide), ("format", str "R8G8B8A8_UNORM"), ("clear", rgba (Rgba 0 0 0 0))])
      , ("replacement", object [("for", str "Atlas"), ("format", str (show (fixtureFormat swappedAtlasFixture))), ("width", show (fixtureWidth swappedAtlasFixture)), ("height", show (fixtureHeight swappedAtlasFixture))])
      , ("bc7", object [("supported", maybe "null" bool bc7), ("exercised", maybe "false" bool bc7)])
      , ("failure", maybe "null" (str . Text.unpack) failure)
      , ("facts", maybe "null" factsRecord facts)
      , ("before", probesRecord before)
      , ("delayed", probesRecord delayed)
      , ("after", probesRecord after)
      , ("passed", bool (failure == Nothing && maybe False factsHold facts && all probesPassed [before, delayed, after]))
      ]
  where
    factsRecord held =
      object
        [ ("old_slot", show (factsOldSlot held))
        , ("new_slot", show (factsNewSlot held))
        , ("swap_state", str (show (factsSwapState held)))
        , ("retiring_during_delay", list (map show (factsRetiringDuringDelay held)))
        , ("slot_registered_during_delay", show (factsSlotDuringDelay held))
        , ("slot_registered_after_completion", show (factsSlotAfterCompletion held))
        , ("instances_unchanged", bool (factsInstancesUnchanged held))
        , ("instance_bytes", show (factsInstanceBytes held))
        , ("order", list (map (str . Text.unpack) (factsOrder held)))
        ]
    probesRecord results =
      list
        [ object
            [ ("name", str (Text.unpack (probeName (resultProbe result))))
            , ("x", show (fst (probePixel (resultProbe result))))
            , ("y", show (snd (probePixel (resultProbe result))))
            , ("expected", rgba (expectedRgba (resultExpected result)))
            , ("observed", rgba (resultObserved result))
            , ("tolerance", show (expectedTolerance (resultExpected result)))
            , ("passed", bool (resultPassed result))
            ]
        | result ← results
        ]
    object ∷ [(String, String)] → String
    object fields = "{" <> intercalate ", " [str key <> ": " <> value | (key, value) ← fields] <> "}"
    list ∷ [String] → String
    list items = "[" <> intercalate ", " items <> "]"
    str ∷ String → String
    str value = "\"" <> concatMap escape value <> "\""
    escape ∷ Char → String
    escape = \case
      '"' → "\\\""
      '\\' → "\\\\"
      c
        | c < ' ' → let digits = showHex (fromEnum c) "" in "\\u" <> replicate (4 - length digits) '0' <> digits
        | otherwise → [c]
    bool ∷ Bool → String
    bool value = if value then "true" else "false"
    rgba ∷ Rgba → String
    rgba (Rgba r g b a) = list (map show [r, g, b, a])

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
