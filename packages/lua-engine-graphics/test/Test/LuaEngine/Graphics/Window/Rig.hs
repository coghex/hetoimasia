-- | What the window examples share: a provider over the gated fake port inside the real composition, a stop
-- endpoint that counts, a fatal-fault sink, and the bound every example runs under.
--
-- An example ends however it ends with every hold of the fake opened, so a failing example fails instead of
-- waiting for what is right to wait for; the provider's scope then drains until every window has retired.
module Test.LuaEngine.Graphics.Window.Rig
  ( WRig (..)
  , withWRig
  , withWRigWrapped
  , swallowAdoption
  , mainStep
  , attachNow
  , readyCount
  , slotHeld
  , stopsNow
  , fatalsNow
  , awaitStops
  , awaitFatalCount
  , awaitProvider
  , awaitNoteCount
  , openAndReady
  , openAndSettle
  , raisesWindowDefect
  , eventCount
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (finally, try)
import Control.Monad (unless)
import qualified Data.Text as Text
import Data.Text (Text)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Fatal)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.Scripting.Lua.Provider (Completion (..), ProviderReply (..), ReplyAnswer (..), RequestEndpoint (..), Submission (..))
import Test.HUnit.Lang (assertFailure)
import Test.LuaEngine.Graphics.Rig (bounded)
import Test.LuaEngine.Graphics.Window.Fake
import Test.LuaEngine.Graphics.Windows

-- | An example's world.
data WRig = WRig
  { wrFake ∷ !Fake
  , wrComp ∷ !(WinComp ())
  , wrVm ∷ !(WinVm ())
  , wrStops ∷ !(TVar Int)
  , wrFatals ∷ !(TVar [Fatal])
  }

-- | Run an example over a provider with this many work records and these holds in place.
withWRig ∷ Int → [Hold] → (WRig → IO a) → IO a
withWRig = withWRigWrapped id

-- | The same with the window endpoint passed through a function (see 'swallowAdoption').
withWRigWrapped ∷ (RequestEndpoint → RequestEndpoint) → Int → [Hold] → (WRig → IO a) → IO a
withWRigWrapped wrap records holds body = do
  fake ← newFake (FakeConfig holds)
  stops ← newTVarIO 0
  fatals ← newTVarIO []
  let config = WindowConfig records (atomically (modifyTVar' stops (+ 1))) (\found → atomically (modifyTVar' fatals (found :)))
  bounded . withWinComp config (fakePort fake) $ \comp _ runtime → do
    vm ← startWinVmWith wrap comp runtime "window-vm"
    body (WRig fake comp vm stops fatals) `finally` releaseAll fake

-- | One bounded main-thread step.
mainStep ∷ WRig → IO ()
mainStep rig = windowMainStep (wcProvider (wrComp rig))

-- | Wait until the main thread has window work, then do it: what the owner loop does on its next turn.
attachNow ∷ WRig → IO ()
attachNow rig = do
  atomically (windowMainReady (wcProvider (wrComp rig)) >>= \ready → unless ready retry)
  mainStep rig

-- | How many times a script recorded a line containing this text.
readyCount ∷ WRig → Text → IO Int
readyCount rig needle = length . filter (Text.isInfixOf needle) <$> notes (wrComp rig)

-- | Whether the named instance's one window slot is occupied.
slotHeld ∷ WRig → Text → IO Bool
slotHeld rig name = ownerOf (wrVm rig) name >>= atomically . ownerSlotHeld

stopsNow ∷ WRig → IO Int
stopsNow = readTVarIO . wrStops

fatalsNow ∷ WRig → IO [Fatal]
fatalsNow = readTVarIO . wrFatals

awaitStops ∷ WRig → Int → IO ()
awaitStops rig wanted = atomically (readTVar (wrStops rig) >>= \n → unless (n >= wanted) retry)

awaitFatalCount ∷ WRig → Int → IO ()
awaitFatalCount rig wanted = atomically (readTVar (wrFatals rig) >>= \found → unless (length found >= wanted) retry)

awaitProvider ∷ WRig → (ProviderReading → Bool) → IO ()
awaitProvider rig wanted = atomically (providerReading (wcProvider (wrComp rig)) >>= \found → unless (wanted found) retry)

-- | Block until a script recorded this many lines containing the text.
awaitNoteCount ∷ WRig → Text → Int → IO ()
awaitNoteCount rig needle wanted = atomically $ do
  seen ← readTVar (wcLog (wrComp rig))
  unless (length (filter (Text.isInfixOf needle) seen) >= wanted) retry

-- | Open a window for the named instance and drive it through every stage to a taken success. Leaves
-- the holds as they were set by the caller, which must have opened the ones this passes through.
openAndReady ∷ WRig → Text → Text → IO ()
openAndReady rig name title = do
  commandOpen (wrComp rig) (wrVm rig) name "a" title (640, 480)
  _ ← awaitNoteContaining (wrComp rig) (name <> " start a started")
  attachNow rig
  command (wrComp rig) (wrVm rig) name "wait_take" "a"
  line ← awaitNoteContaining (wrComp rig) (name <> " wait_take a")
  unless (Text.isInfixOf "status=success" line) (fail ("expected a success, found " <> Text.unpack line))

-- | How many native operations were recorded that contain this text.
eventCount ∷ WRig → Text → IO Int
eventCount rig needle = length . filter (Text.isInfixOf needle) <$> events (wrFake rig)

-- | Open a window and drive it to a settled success without taking it: the request is waited on and its
-- result is left for the script to take or cancel.
openAndSettle ∷ WRig → Text → Text → IO ()
openAndSettle rig name title = do
  commandOpen (wrComp rig) (wrVm rig) name "a" title (640, 480)
  _ ← awaitNoteContaining (wrComp rig) (name <> " start a started")
  attachNow rig
  command (wrComp rig) (wrVm rig) name "wait" "a"
  _ ← awaitNoteContaining (wrComp rig) (name <> " wait a waited")
  pure ()

-- | Run an example whose scope is /expected/ to raise the provider's own defect at its exit, as it does when a
-- native release failed: only that exception is expected. An assertion failure inside the example, or any
-- other exception, is not caught and fails the example.
raisesWindowDefect ∷ IO a → IO ()
raisesWindowDefect action =
  try @WindowDefect action >>= \case
    Left _ → pure ()
    Right _ → assertFailure "the scope returned although a native release failed"

-- | An endpoint that accepts the window's resource reply and never forwards it to the host: the provider is told
-- the reply was accepted (so it holds an offered result), the host never builds the resource, and the example's
-- cancellation then settles the request with the provider's work already reported over. Every other reply is
-- forwarded.
swallowAdoption ∷ RequestEndpoint → RequestEndpoint
swallowAdoption endpoint =
  endpoint
    { endpointSubmit = \submission →
        endpointSubmit endpoint submission {submissionCompletion = Completion (swallowing (completeRequest (submissionCompletion submission)))}
    }
  where
    swallowing forward = \case
      ProviderResource {} → pure ReplyAdoption
      other → forward other
