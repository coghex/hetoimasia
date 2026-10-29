-- | A window 'Port' the examples drive by hand: every native stage of a window (creation, attachment,
-- admission, graphics retirement, native destruction) is a hold the example opens when it chooses, queue
-- pressure and a genuine native close are injected, and every native operation is recorded.
--
-- Evidence from this fake is /injected/ evidence and says so: it proves the provider's ordering,
-- ownership and routing, never a window, a surface or a pixel. The real windows are the native suite's.
--
-- Nothing sleeps. A hold is a variable the provider's pump reads in the transaction that decides; opening
-- it (or changing any other fact) bumps a version, which the port's progress reading waits on.
module Test.LuaEngine.Graphics.Window.Fake
  ( -- * The fake
    Fake
  , FakeConfig (..)
  , defaultFakeConfig
  , newFake
  , fakePort

    -- * Holds and pressure
  , Hold (..)
  , hold
  , release
  , releaseAll
  , setCreateFull
  , setCloseFull

    -- * Scripting
  , scriptStanding
  , scriptAttach
  , scriptCreate
  , failNativeDisposal
  , failOwner
  , nativeClose
  , wakes

    -- * Reading
  , FakeReading (..)
  , readFake
  , awaitFake
  , events
  , awaitEvent
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Graphics.Window.Port
import Numeric.Natural (Natural)

-- | A stage of a window that the example can hold back.
data Hold
  = -- | A creation command's ticket does not settle.
    HoldCreate
  | -- | The main thread's handover answers that the owner is not ready.
    HoldAttach
  | -- | The owner has not yet answered for the attachment (still constructing).
    HoldAdmit
  | -- | Graphics use and the attachment do not retire.
    HoldGraphics
  | -- | The native window is not destroyed.
    HoldNative
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What the fake is configured to do.
data FakeConfig = FakeConfig
  { fcHolds ∷ ![Hold]
  }

defaultFakeConfig ∷ FakeConfig
defaultFakeConfig = FakeConfig []

data Win = Win
  { winClose ∷ !Natural
    -- ^ The newest genuine close request.
  , winClosing ∷ !Bool
  , winAttached ∷ !Bool
  , winNativeFails ∷ !Bool
  }

data FS = FS
  { fsHolds ∷ !(Set Hold)
  , fsCreateFull ∷ !Bool
  , fsCloseFull ∷ !Bool
  , fsNext ∷ !Word64
  , fsCreates ∷ !(Map Word64 (Text, Int, Int, Maybe WindowToken))
  , fsWindows ∷ !(Map Word64 Win)
  , fsEvents ∷ ![Text]
  , fsAttachScript ∷ ![AttachOutcome]
  , fsCreateScript ∷ ![CreateOutcome]
  , fsStanding ∷ !Standing
  , fsOwnerFailure ∷ !(Maybe Fatal)
  , fsVersion ∷ !Word64
  , fsWakes ∷ !Int
  }

newtype Fake = Fake (TVar FS)

newFake ∷ FakeConfig → IO Fake
newFake cfg = Fake <$> newTVarIO (FS (Set.fromList (fcHolds cfg)) False False 1 Map.empty Map.empty [] [] [] StandingUsable Nothing 0 0)

modify ∷ Fake → (FS → FS) → STM ()
modify (Fake var) change = readTVar var >>= \st → writeTVar var (change st) {fsVersion = fsVersion st + 1}

note ∷ Text → FS → FS
note line st = st {fsEvents = line : fsEvents st}

-- Holds and pressure -----------------------------------------------------------------------------------

hold ∷ Fake → Hold → IO ()
hold fake stage = atomically (modify fake (\st → st {fsHolds = Set.insert stage (fsHolds st)}))

release ∷ Fake → Hold → IO ()
release fake stage = atomically (modify fake (\st → st {fsHolds = Set.delete stage (fsHolds st)}))

releaseAll ∷ Fake → IO ()
releaseAll fake = mapM_ (release fake) [minBound .. maxBound]

setCreateFull ∷ Fake → Bool → IO ()
setCreateFull fake full = atomically (modify fake (\st → st {fsCreateFull = full}))

setCloseFull ∷ Fake → Bool → IO ()
setCloseFull fake full = atomically (modify fake (\st → st {fsCloseFull = full}))

-- Scripting --------------------------------------------------------------------------------------------

-- | What the owner answers for every attachment from now on.
scriptStanding ∷ Fake → Standing → IO ()
scriptStanding fake standing' = atomically (modify fake (\st → st {fsStanding = standing'}))

-- | The next main-thread handover answers, one for each call, then the default.
scriptAttach ∷ Fake → [AttachOutcome] → IO ()
scriptAttach fake outcomes = atomically (modify fake (\st → st {fsAttachScript = outcomes}))

-- | The next creation settlements other than the default success, one for each created window.
scriptCreate ∷ Fake → [CreateOutcome] → IO ()
scriptCreate fake outcomes = atomically (modify fake (\st → st {fsCreateScript = outcomes}))

-- | The next native destruction fails (once the window is closing and its graphics retired).
failNativeDisposal ∷ Fake → IO ()
failNativeDisposal fake = atomically (modify fake (\st → st {fsWindows = Map.map (\win → win {winNativeFails = True}) (fsWindows st)}))

failOwner ∷ Fake → Fatal → IO ()
failOwner fake found = atomically (modify fake (\st → st {fsOwnerFailure = Just found}))

-- | A genuine native close request for the window the nth creation made (one-based, in creation order):
-- the window's own latched request, numbered in increasing order. Only this produces one.
nativeClose ∷ Fake → Int → IO ()
nativeClose fake nth = atomically $ modify fake $ \st →
  case drop (nth - 1) (Map.toAscList (fsWindows st)) of
    (key, win) : _ → note ("native close request w" <> tshow key) st {fsWindows = Map.insert key win {winClose = winClose win + 1} (fsWindows st)}
    [] → st

wakes ∷ Fake → IO Int
wakes (Fake var) = fsWakes <$> readTVarIO var

-- The port ---------------------------------------------------------------------------------------------

fakePort ∷ Fake → Port ()
fakePort fake@(Fake var) =
  Port
    { portIssueCreate = \title width height → atomically $ do
        st ← readTVar var
        if fsCreateFull st
          then pure CreateQueueFull
          else do
            modify fake (note ("issue create " <> title <> " " <> tshow width <> "x" <> tshow height) . \now → now {fsNext = fsNext now + 1, fsCreates = Map.insert (fsNext st) (title, width, height, Nothing) (fsCreates now)})
            pure (CreateIssued (CreateToken (fsNext st)))
    , portCreateOutcome = \(CreateToken number) → do
        st ← readTVar var
        case Map.lookup number (fsCreates st) of
          Nothing → pure (Just (CreateFatal (Fatal "unknown creation")))
          Just (title, width, height, made)
            | Set.member HoldCreate (fsHolds st) → pure Nothing
            | Just token ← made → pure (Just (Created token))
            | otherwise → case fsCreateScript st of
                scripted : rest | not (isCreated scripted) → do
                  modify fake (\now → now {fsCreateScript = rest})
                  pure (Just scripted)
                _ → do
                  let token = WindowToken (fsNext st)
                  modify fake $
                    note ("created w" <> tshow (fsNext st))
                      . ( \now →
                            now
                              { fsNext = fsNext now + 1
                              , fsCreates = Map.insert number (title, width, height, Just token) (fsCreates now)
                              , fsWindows = Map.insert (fsNext st) (Win 0 False False False) (fsWindows now)
                              }
                        )
                  pure (Just (Created token))
    , portAttach = \(WindowToken key) → atomically $ do
        st ← readTVar var
        if Set.member HoldAttach (fsHolds st)
          then pure AttachRootsPending
          else case fsAttachScript st of
            scripted : rest → do
              modify fake (note ("attach w" <> tshow key) . \now → now {fsAttachScript = rest, fsWindows = Map.adjust (\win → win {winAttached = True}) key (fsWindows now)})
              pure scripted
            [] → do
              modify fake (note ("attach w" <> tshow key) . \now → now {fsWindows = Map.adjust (\win → win {winAttached = True}) key (fsWindows now)})
              pure AttachAnnounced
    , portStanding = \(WindowToken key) → do
        st ← readTVar var
        pure $ case Map.lookup key (fsWindows st) of
          Nothing → StandingEnded
          Just win
            | not (winAttached win) → StandingPending
            | Set.member HoldAdmit (fsHolds st) → StandingPending
            | winClosing win, fsStanding st == StandingUsable → StandingEnded
            | otherwise → fsStanding st
    , portCloseRequest = \(WindowToken key) → maybe 0 winClose . Map.lookup key . fsWindows <$> readTVar var
    , portBeginClose = \(WindowToken key) → atomically $ do
        st ← readTVar var
        if fsCloseFull st
          then pure CloseQueueFull
          else case Map.lookup key (fsWindows st) of
            Nothing → pure CloseGone
            Just win
              | winClosing win → pure CloseBegun
              | otherwise → do
                  modify fake (note ("close w" <> tshow key) . \now → now {fsWindows = Map.insert key win {winClosing = True} (fsWindows now)})
                  pure CloseBegun
    , portRetirement = \(WindowToken key) → do
        st ← readTVar var
        pure $ case Map.lookup key (fsWindows st) of
          Nothing → Retirement GraphicsRetired NativeDisposed
          Just win
            | not (winClosing win) → Retirement GraphicsInUse NativePending
            | otherwise →
                let graphicsDone = not (winAttached win) || not (Set.member HoldGraphics (fsHolds st))
                    graphics = if graphicsDone then GraphicsRetired else GraphicsInUse
                    native
                      | not graphicsDone || Set.member HoldNative (fsHolds st) = NativePending
                      | winNativeFails win = NativeDisposalFailed (Fatal "the native window's release failed")
                      | otherwise = NativeDisposed
                 in Retirement graphics native
    , portTarget = \(WindowToken key) → do
        st ← readTVar var
        pure $ case Map.lookup key (fsWindows st) of
          Just win | winAttached win, not (winClosing win), fsStanding st == StandingUsable, not (Set.member HoldAdmit (fsHolds st)) → Just ()
          _ → Nothing
    , portOwnerFailure = fsOwnerFailure <$> readTVar var
    , portProgress = do
        before ← fsVersion <$> readTVar var
        pure $ do
          now ← fsVersion <$> readTVar var
          when (now == before) retry
    , portWakeMain = atomically (modify fake (\st → st {fsWakes = fsWakes st + 1}))
    }
  where
    isCreated = \case
      Created _ → True
      _ → False

-- Reading ----------------------------------------------------------------------------------------------

-- | What the fake holds.
data FakeReading = FakeReading
  { readingCreates ∷ !Int
  , readingWindows ∷ !Int
  , readingClosing ∷ !Int
  , readingAttached ∷ !Int
  }
  deriving (Eq, Show)

readFake ∷ Fake → STM FakeReading
readFake (Fake var) = do
  st ← readTVar var
  let wins = Map.elems (fsWindows st)
  pure (FakeReading (Map.size (fsCreates st)) (length wins) (length (filter winClosing wins)) (length (filter winAttached wins)))

awaitFake ∷ Fake → (FakeReading → Bool) → IO ()
awaitFake fake wanted = atomically (readFake fake >>= \found → unless (wanted found) retry)

-- | The native operations recorded, oldest first.
events ∷ Fake → IO [Text]
events (Fake var) = reverse . fsEvents <$> readTVarIO var

-- | Block until an operation containing this text was recorded.
awaitEvent ∷ Fake → Text → IO ()
awaitEvent (Fake var) needle = atomically $ do
  seen ← fsEvents <$> readTVar var
  unless (any (Text.isInfixOf needle) seen) retry

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
