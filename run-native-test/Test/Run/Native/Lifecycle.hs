{-# LANGUAGE OverloadedStrings #-}

-- | The identities and the completion evidence the two-instance cases correlate, read from the host's and the adapter's
-- own public records and retained as machine-readable lifecycle records (LFE-25, #540 requirements 4 and 6).
--
-- * /Texture identities/ are the ones the scene ledger holds for adopted scenes (@readingHeld@): a texture is the same
--   texture across time when the same identity is held, and a reload would show as a new one.
-- * /GPU obligations/ are the host's frame events. A window's attachments are the ones its frames name; each of its
--   submissions (@FrameSubmitted@) has a terminal @SubmissionCompleted@ and each of its presentations (@FramePresented@)
--   a @PresentationRetired@ when its resources may be disposed. 'outstanding' lists what has not.
--
-- A record states what was read where it was read; it never infers retirement from a count, a timeout or a capture.
module Test.Run.Native.Lifecycle
  ( heldTextures
  , Obligations (..)
  , obligationsOf
  , obligationsFrom
  , outstanding
  , awaitSettled
  , lifecycleRecord
  , writeLifecycle
  ) where

import Control.Concurrent.STM (atomically, readTVar, retry)
import Data.List (nub, (\\))
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW (FrameEvent (..))
import Hetoimasia.LuaEngine.Graphics.Scene (LedgerReading (..), ledgerReading)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.Runtime.GLFW (attachmentWindow)
import System.FilePath ((</>))
import Test.Run.Native.Env (Env (..))
import Test.Run.Native.Json
import Test.Run.Native.Observe (freshEvents, step)
import Test.Run.Native.Peers (Peers (..))

-- | The texture identities any adopted scene holds now.
heldTextures ∷ Peers → IO (Set Word64)
heldTextures peers = readingHeld <$> atomically (ledgerReading (graphicsLedger (peGraphics peers)))

-- | What one window's frames asked of the GPU, and what has finished, as the host's events show (shown, since the
-- identifier types are the native layer's; equality is on their text).
data Obligations = Obligations
  { obAttachments ∷ ![String]
  , obSubmitted ∷ ![String]
  , obCompleted ∷ ![String]
  , obPresented ∷ ![String]
  , obRetired ∷ ![String]
  }
  deriving (Eq, Show)

-- | The window's obligations among the events seen so far.
obligationsOf ∷ Peers → WindowId → IO Obligations
obligationsOf peers window = obligationsFrom window <$> freshEvents peers 0

-- | The same, over events already read (oldest first).
obligationsFrom ∷ WindowId → [FrameEvent] → Obligations
obligationsFrom window events =
  let named attachment = attachmentWindow attachment == window
      attachments = nub [show attachment | event ← events, Just attachment ← [attachmentOf event], named attachment]
      mine attachment = show attachment `elem` attachments
   in Obligations
        { obAttachments = attachments
        , obSubmitted = [show submission | FrameSubmitted attachment _ submission ← events, mine attachment]
        , obCompleted = [show submission | SubmissionCompleted submission ← events]
        , obPresented = [show presentation | FramePresented attachment _ presentation _ ← events, mine attachment]
        , obRetired = [show presentation | PresentationRetired presentation ← events]
        }
  where
    attachmentOf = \case
      FrameAcquired attachment _ _ → Just attachment
      FramePending attachment _ → Just attachment
      FrameSubmitted attachment _ _ → Just attachment
      FramePresentRequested attachment _ _ _ → Just attachment
      FramePresented attachment _ _ _ → Just attachment
      FrameAbandoned attachment _ _ → Just attachment
      _ → Nothing

-- | Wait, as an STM fact on the host's own events, until every submission and presentation this window made has completed
-- or retired. A window's frames stop when it ends, so this ends; it is bounded by 'step'.
awaitSettled ∷ Peers → WindowId → IO Obligations
awaitSettled peers window = step ("every GPU obligation of window " <> show window <> " to have finished") . atomically $ do
  (_, newestFirst) ← readTVar (peFrames peers)
  let ob = obligationsFrom window (reverse newestFirst)
  if outstanding ob == ([], []) then pure ob else retry

-- | Submissions with no completion and presentations with no retirement: what is still owed.
outstanding ∷ Obligations → ([String], [String])
outstanding ob = (obSubmitted ob \\ obCompleted ob, obPresented ob \\ obRetired ob)

-- | One window's lifecycle as a record.
lifecycleRecord ∷ Text → Obligations → Json
lifecycleRecord label ob =
  JObject
    [ ("window", JString label)
    , ("attachments", strings (obAttachments ob))
    , ("submissions", strings (obSubmitted ob))
    , ("submissions_completed", strings [s | s ← obSubmitted ob, s `elem` obCompleted ob])
    , ("presentations", strings (obPresented ob))
    , ("presentations_retired", strings [p | p ← obPresented ob, p `elem` obRetired ob])
    , ("submissions_outstanding", strings (fst (outstanding ob)))
    , ("presentations_outstanding", strings (snd (outstanding ob)))
    ]
  where
    strings = JArray . map (JString . Text.pack)

-- | Write a lifecycle record next to the captures: @lifecycle--NAME.json@ in the run's capture directory.
writeLifecycle ∷ Env → Text → [(Text, Json)] → IO ()
writeLifecycle env name fields =
  writeFile (envCaptureDir env </> "lifecycle--" <> Text.unpack name <> ".json") (render (JObject (("name", JString name) : fields)) <> "\n")
