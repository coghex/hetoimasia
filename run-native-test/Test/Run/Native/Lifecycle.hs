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
  , obligationsFrom
  , outstanding
  , Disposal (..)
  , disposalsSoFar
  , awaitDisposal
  , disposalRecord
  , disposalFollowedObligations
  , lifecycleRecord
  , writeLifecycle
  ) where

import Control.Concurrent.STM (atomically, readTVar, readTVarIO, retry)
import Data.List (nub, (\\))
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW (FrameEvent (..), VulkanHost (..))
import Hetoimasia.LuaEngine.Graphics.Scene (LedgerReading (..), ledgerReading)
import Hetoimasia.LuaEngine.Graphics.Texture (TextureGraphics (..))
import Hetoimasia.Runtime.GLFW (attachmentWindow, hostWindowIdentities)
import System.FilePath ((</>))
import Test.Run.Native.Env (Env (..))
import Test.Run.Native.Json
import Test.Run.Native.Observe (step)
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

-- | One window's disposal as the trace shows it: each native disposal call that ended its graphics (in order, up to and
-- including the destruction of its surface), with the position it took among the frame events and the obligations the
-- window's frames had among the events that came before that position.
data Disposal = Disposal
  { dsPoints ∷ ![(Text, Int, Obligations)]
  , dsSurfaceDestroyed ∷ !Bool
  , dsAttached ∷ !Bool
  -- ^ Whether the window's frames named an attachment at all (a window that never attached has no graphics to dispose).
  }

-- | How many native disposals have been seen: read before an instance is ended, so that its own are the ones after.
disposalsSoFar ∷ Peers → IO Int
disposalsSoFar peers = length <$> readTVarIO (peDisposals peers)

-- | Wait, as an STM fact, until the window has left the host, then read what the trace says about its disposal: the
-- disposals recorded after @before@ up to its surface's destruction, each with the window's obligations among the frame
-- events that preceded it. The read is of the order recorded as the calls happened, not of what completed afterwards.
awaitDisposal ∷ Peers → WindowId → Int → IO Disposal
awaitDisposal peers window before = step ("window " <> show window <> " to have left the host") . atomically $ do
  live ← hostWindowIdentities (vulkanWindowHost (peHost peers))
  if window `elem` live
    then retry
    else do
      recorded ← drop before <$> readTVar (peDisposals peers)
      (count, newestFirst) ← readTVar (peFrames peers)
      let ordered = reverse newestFirst
          dropped = count - length ordered
          before' index = take (max 0 (index - dropped)) ordered
          upToSurface = takeThrough ((== "vkDestroySurfaceKHR") . fst) recorded
          points = [(name, index, obligationsFrom window (before' index)) | (name, index) ← upToSurface]
          attached = not (null (obAttachments (obligationsFrom window ordered)))
      pure (Disposal points (any ((== "vkDestroySurfaceKHR") . fst) upToSurface) attached)
  where
    takeThrough keep = \case
      [] → []
      (x : rest) | keep x → [x]
                 | otherwise → x : takeThrough keep rest

-- | Every disposal of the window's graphics came after everything its frames had asked of the GPU had finished, and a
-- window whose frames attached had its surface destroyed. A window that never attached has nothing to dispose.
disposalFollowedObligations ∷ Disposal → Bool
disposalFollowedObligations disposal =
  all (\(_, _, ob) → outstanding ob == ([], [])) (dsPoints disposal)
    && (not (dsAttached disposal) || dsSurfaceDestroyed disposal)

-- | The disposal as a record: each call, its position in the frame events and the obligations before it.
disposalRecord ∷ Text → Disposal → Json
disposalRecord label disposal =
  JObject
    [ ("window", JString label)
    , ("attached", JBool (dsAttached disposal))
    , ("surface_destroyed", JBool (dsSurfaceDestroyed disposal))
    , ( "disposals_in_order"
      , JArray
          [ JObject [("call", JString name), ("after_frame_events", JNumber (fromIntegral index)), ("obligations_before", lifecycleRecord label ob)]
          | (name, index, ob) ← dsPoints disposal
          ]
      )
    ]

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
