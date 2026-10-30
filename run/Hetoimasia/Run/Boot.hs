-- | Preparing the game folder of @hetoimasia run@: the anchored root, the whole-folder inventory and the boot
-- checkpoint, all before any authored Lua (LFE-22 requirement 3, P-60, P-71).
--
-- = Order
--
-- 1. 'Hetoimasia.Content.withContentRoot' opens the selected folder once; the root is the session's and every
--    later read is anchored to it. Its resolved identity is reported (@content root resolved@, on stderr
--    through the logger) so the launch target is reviewable. The folder is never opened again by its
--    launch pathname.
-- 2. @hetoimasia.json@ is read through the root, within the manifest limit, and parsed by the strict format-1
--    parser: the manifest's @id@ is the content identity the inventory is keyed by (the folder's name never
--    is).
-- 3. The whole folder is scanned into an inventory under the fixed profile's numbers. Hidden and unused files
--    are scanned too.
-- 4. The manifest bytes parsed in step 2 must be the bytes the scan pinned ('checkManifestPinned'), and the
--    boot checkpoint ('bootCheckpointFrom') then parses the pinned bytes again and validates every declared
--    entry, an overridden common entry included, as an inventoried regular file. A manifest that changed
--    between the read and the scan, or between the scan and the checkpoint, is a refusal, never a quiet
--    substitution.
--
-- Steps 2 to 4 start no VM, worker, window or Lua, parse and compile no Lua, and are the whole of the
-- pre-init path-level validation. Evaluating the selected entries and validating the behaviors happen in the
-- session, which exits 1 without running either @init@ when they fail.
--
-- = Stop
--
-- A first SIGINT or SIGTERM during steps 2 to 4 abandons them ('BootStopped'): the work runs on a thread of
-- its own, is cancelled, and is joined before the root closes, so the scan never runs under a closed root.
-- Nothing in this module installs a handler or exits.
--
-- = Ownership
--
-- The 'Prepared' value is borrowed for the continuation only: the root closes when the continuation returns, on
-- every way out. The inventory and the checkpoint are immutable data over that root.
module Hetoimasia.Run.Boot
  ( Prepared (..)
  , BootEnd (..)
  , BootHooks (..)
  , noBootHooks
  , withPrepared
  , withPreparedWith
  , abortable
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM
  ( STM
  , atomically
  , check
  , newEmptyTMVarIO
  , orElse
  , putTMVar
  , readTMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ExceptionWithContext (ExceptionWithContext)
  , Exception
  , SomeAsyncException
  , SomeException
  , catch
  , displayException
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , toException
  , try
  , tryWithContext
  )
import Control.Monad (void)
import Hetoimasia.Foundation.Resource (cleanupFailuresInContext)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Content
  ( ContentFailure
  , ContentLimits
  , ContentRoot
  , RootReport (..)
  , NativeIdentity
  , nativeName
  , readChunk
  , rootReport
  , withContentRoot
  , withFile
  , limitReadChunk
  )
import Hetoimasia.Content.Identity (rootKey)
import Hetoimasia.Content.Inventory (Inventory, scanInventory)
import Hetoimasia.Foundation.Log (Component, Logger, logInfo, unsafeComponent)
import Hetoimasia.LuaEngine.Boot
  ( Checkpoint
  , ContentConfiguration (..)
  , bootCheckpointFrom
  , checkManifestPinned
  , contentConfiguration
  )
import Hetoimasia.LuaEngine.Manifest (Manifest (..), contentIdText, parseManifestWith)
import Hetoimasia.LuaEngine.Profile (ByteLimit (ManifestBytes), Bytes (Bytes), Profile, bytesLimit)
import Hetoimasia.Run.Output (reportText)
import Hetoimasia.Run.Settle (combine, diagnostic, rememberingInterruption)

-- | The folder, prepared: borrowed by the continuation.
data Prepared = Prepared
  { preparedProfile ∷ !Profile
  , preparedRoot ∷ !ContentRoot
  , preparedInventory ∷ !Inventory
  , preparedCheckpoint ∷ !Checkpoint
  , preparedContentId ∷ !Text
  }

-- | How preparation ended without a session to run.
data BootEnd
  = -- | The root, the manifest, the scan or an entry was refused: the one-line reason (bounded and escaped).
    BootRefused !Text
  | -- | A stop was requested first.
    BootStopped
  deriving (Eq, Show)

component ∷ Component
component = unsafeComponent "run"

-- | The suite's one seam: a step run between the manifest's first read and the scan, which is how an example
-- changes @hetoimasia.json@ in exactly that window. Production runs none ('noBootHooks').
newtype BootHooks = BootHooks
  { hookAfterManifestRead ∷ IO ()
  }

noBootHooks ∷ BootHooks
noBootHooks = BootHooks (pure ())

-- | Prepare the folder and run the continuation over it. The continuation's own result, and what it throws,
-- pass through untouched; only the preparation's refusals and a stop become a 'BootEnd'.
withPrepared ∷ Logger → Profile → STM Bool → FilePath → (Prepared → IO a) → IO (Either BootEnd a)
withPrepared = withPreparedWith noBootHooks

-- | 'withPrepared' with the suite's seam.
withPreparedWith ∷ BootHooks → Logger → Profile → STM Bool → FilePath → (Prepared → IO a) → IO (Either BootEnd a)
withPreparedWith hooks logger profile stop path continuation = case contentConfiguration profile of
  Left refusal → pure (Left (BootRefused (reportText ("the profile cannot configure the content layer: " <> Text.pack (show refusal)))))
  Right configuration → do
    -- Only a failure of /opening/ the root is a refusal: once the continuation has begun, what it raises is its own
    -- (the session's, a cleanup's) and passes through untouched.
    began ← newIORef False
    let refused ∷ ContentFailure → IO (Either BootEnd a)
        refused failure =
          readIORef began >>= \started →
            if started
              then throwIO failure
              else pure (Left (BootRefused (reportText ("the root could not be opened: " <> Text.pack (displayException failure)))))
        opened =
          withContentRoot (configContentLimits configuration) path $ \root → do
            reportRoot logger (rootReport root)
            preparation ← abortable stop (prepare configuration root)
            case preparation of
              Nothing → pure (Left BootStopped)
              Just (Left reason) → pure (Left (BootRefused (reportText reason)))
              Just (Right (inventory, checkpoint, contentId)) → do
                writeIORef began True
                Right <$> continuation (Prepared profile root inventory checkpoint contentId)
    opened `catch` refused
  where
    prepare configuration root = do
      read' ← readManifest profile (configContentLimits configuration) root
      case read' of
        Left reason → pure (Left reason)
        Right bytes → case parseManifestWith profile bytes of
          Left refusal → pure (Left ("hetoimasia.json was refused: " <> Text.pack (show refusal)))
          Right manifest → do
            hookAfterManifestRead hooks
            let contentId = contentIdText (manifestId manifest)
            case rootKey (Text.encodeUtf8 contentId) of
              Left refusal → pure (Left ("the content identity was refused: " <> Text.pack (show refusal)))
              Right key →
                scanInventory (configInventoryLimits configuration) key root >>= \case
                  Left failure → pure (Left ("the folder was refused: " <> Text.pack (show failure)))
                  Right inventory → case checkManifestPinned inventory manifest of
                    Left refusal → pure (Left ("hetoimasia.json changed while the folder was scanned: " <> Text.pack (show refusal)))
                    Right () →
                      bootCheckpointFrom profile root inventory >>= \case
                        Left refusal → pure (Left ("the folder cannot boot: " <> Text.pack (show refusal)))
                        Right checkpoint → pure (Right (inventory, checkpoint, contentId))

-- | The one startup line that names the launch target: the selection as typed, the pathname the operating
-- system reported for the directory actually opened, and the directory's identity. The pathname is a
-- diagnostic that can be stale; the identity is what names the directory.
reportRoot ∷ Logger → RootReport → IO ()
reportRoot logger report =
  diagnostic $ logInfo
    logger
    component
    "content root resolved"
    [ ("selected", bytesText (reportSelection report))
    , ("resolved", maybe "unknown" bytesText (reportResolved report))
    , ("identity", identityText (reportIdentity report))
    ]
  where
    bytesText = reportText . Text.decodeUtf8Lenient
    identityText ∷ NativeIdentity → Text
    identityText = Text.pack . show

-- | The bytes of @hetoimasia.json@ read through the root, or why they could not be. At most one byte past the
-- manifest limit is read: the parser refuses an oversized document by name.
readManifest ∷ Profile → ContentLimits → ContentRoot → IO (Either Text ByteString)
readManifest profile limits root = case nativeName "hetoimasia.json" of
  Left refusal → pure (Left ("the manifest name was refused: " <> Text.pack (show refusal)))
  Right name → do
    outcome ← try (withFile root [name] (go []))
    pure $ case outcome of
      Left failure → Left ("hetoimasia.json could not be read: " <> Text.pack (displayException (failure ∷ ContentFailure)))
      Right bytes → Right bytes
  where
    Bytes limit = bytesLimit profile ManifestBytes
    ceiling' = fromIntegral limit + 1 ∷ Int
    chunk = max 1 (limitReadChunk limits)
    go acc reader = do
      let held = sum (map ByteString.length acc)
      if held >= ceiling'
        then pure (ByteString.concat (reverse acc))
        else do
          next ← readChunk reader (min chunk (ceiling' - held))
          if ByteString.null next then pure (ByteString.concat (reverse acc)) else go (next : acc) reader

-- | Run an action on a thread of its own and wait for it in STM beside a stop request.
--
-- * When the action ends first its result, or its failure with the context it carries, is the caller's.
-- * When the stop arrives first the action is cancelled and /joined/, so whatever it borrowed has unwound before
--   this returns. The child's terminal outcome is then read: a clean expected cancellation is 'Nothing'; a
--   result it had produced anyway stands; and any other failure, a synchronous one or a cleanup failure
--   retained beside the cancellation, is raised with its context, because a failed cleanup is a failure of
--   the run and not an orderly stop.
-- * When the /caller/ is cancelled instead (in the wait, or while it is sending its cancellation), the child is
--   still cancelled and joined first, and the child's evidence (a failed cleanup, a failure of its own) is
--   retained beside the caller's cancellation, which is then raised: the cancellation is never lost and never
--   hides what the child's cleanup raised.
-- * Delivering the cancellation is itself an interruptible operation, so a cancellation of the caller is
--   remembered across the sending and the join together and raised only after the child has actually ended.
--   The wait is never made uninterruptible.
abortable ∷ ∀ a. STM Bool → IO a → IO (Maybe a)
abortable stop action = mask $ \restore → do
  done ← newEmptyTMVarIO
  child ← forkIO (tryWithContext (restore action) >>= \result → atomically (putTMVar done (result ∷ Either (ExceptionWithContext SomeException) a)))
  let ended = atomically (readTMVar done)
      -- Send the cancellation and wait for the child to end, remembering an interruption of the caller meanwhile.
      stopChild = rememberingInterruption (killThread child >> void ended)
      -- What the child's end adds to a failure that is already being raised: nothing for a clean cancellation.
      evidence outcome = [("the preparation worker", failure) | Left failure ← [outcome], not (expectedCancellation failure)]
  waited ← tryWithContext @SomeException (restore (atomically ((Right <$> readTMVar done) `orElse` (Left <$> (stop >>= check)))))
  case waited of
    Right (Right outcome) → either rethrowIO (pure . Just) outcome
    Right (Left ()) → do
      interruption ← stopChild
      outcome ← ended
      case interruption of
        Just interrupted → rethrowIO =<< combine interrupted (evidence outcome)
        Nothing → case outcome of
          Right result → pure (Just result)
          Left failure
            | expectedCancellation failure → pure Nothing
            | otherwise → rethrowIO (asFailure failure)
    Left callerFailure → do
      interruption <- stopChild
      outcome ← ended
      rethrowIO =<< combine callerFailure (evidence outcome <> [("a further interruption while stopping the preparation worker", interrupted) | Just interrupted ← [interruption]])
  where
    -- Only the bare cancellation we sent, with no cleanup failure retained beside it.
    expectedCancellation (ExceptionWithContext context failure) =
      (fromException failure ∷ Maybe AsyncException) == Just ThreadKilled && null (cleanupFailuresInContext context)
    -- The child's cancellation is asynchronous by type, but its cleanup having failed is a failure of this run: it
    -- is raised as an ordinary exception, with the child's context (and so its cleanup evidence) kept.
    asFailure (ExceptionWithContext context failure)
      | Just (_ ∷ SomeAsyncException) ← fromException failure = ExceptionWithContext context (toException (CancelledUncleanly (Text.pack (displayException failure))))
      | otherwise = ExceptionWithContext context failure

-- | The preparation was cancelled by a stop and its cleanup then failed.
newtype CancelledUncleanly = CancelledUncleanly Text
  deriving (Show)

instance Exception CancelledUncleanly where
  displayException (CancelledUncleanly why) = "the preparation was stopped and its cleanup failed: " <> Text.unpack why
