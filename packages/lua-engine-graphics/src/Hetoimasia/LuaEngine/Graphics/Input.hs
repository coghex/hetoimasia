{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The concrete presentation input of the Lua facade (TRA-6): one window's ordered input read by the Lua adapter as the
-- window's one logical consumer, and the instance-checked operations the CPU facade ("Hetoimasia.LuaEngine.Facade") is
-- injected with.
--
-- = What this is
--
-- The CPU facade owns every Lua-visible rule of @api.input.poll@ and @api.input.acknowledgeReset@ and imports no GLFW
-- module. It is handed 'InputServices', abstract operations, and this module is their composition over the window
-- integration's public interfaces and nothing else: the window's reader and admission control
-- ("Hetoimasia.GLFW.Input") and its observation snapshot, reached through the narrow 'WindowInput' the production port
-- yields ("Hetoimasia.LuaEngine.Graphics.Window.Host"), never through the scene target or a raw native handle.
--
-- = The source, so that the logic is testable without a producer
--
-- No public API outside the GLFW package can produce a GLFW input event or a reset token: both have private
-- representations, on purpose. The consumer is therefore written over a 'Source', a record of the transactions it needs, and
-- is polymorphic in the event and token types. 'glfwSource' is the production source over a 'WindowInput'; a test builds a
-- controlled one whose events are public 'Glfw.InputPayload' values and whose tokens are its own. The translation of a
-- payload to the facade's vocabulary ('translateEvent') is a thin function over the public payload types.
--
-- = A consumer
--
-- One 'Consumer' is the single logical consumer of one window incarnation's feed. It owns no thread and no queue: a poll is
-- one transaction that reads a bounded prefix of the feed, the disposition the read stopped on, the feed's epoch and the
-- window's observation, so they are one coherent boundary. A reset committed first supersedes its backlog (the feed answers
-- the reset, and nothing is read behind it); a batch taken in an earlier transaction belongs to the script, which may finish or
-- abandon its handlers before it acknowledges a later reset. Events of two epochs are never in one packet, because the
-- feed changes epoch in a transaction of its own.
--
-- == Reset tokens
--
-- A reset token a script sees is a capability whose key is @consumerId * 2^32 + sequence@: the consumer that issued it and
-- the order it was issued in. The consumer remembers one thing, the newest 'Glfw.ResetToken' it handed out and its sequence,
-- so polling a pending reset again answers the same sequence, and a newer reset replaces it. Authenticity and liveness are
-- the arithmetic of two numbers and the registry's live consumers: nothing remembers a reset that is over, no registry
-- grows with the history of resets, and a sequence is never issued twice by one consumer, so an old handle can never name a
-- newer reset. An older sequence acknowledges nothing and answers stale without touching the feed; the newest is handed to
-- the feed's own acknowledgement, which decides acknowledged, already acknowledged, stale or closed itself.
--
-- = The registry
--
-- One 'InputRegistry' belongs to one VM's graphics services. It holds, for each declared instance, at most one consumer: the
-- instance's single window slot admits at most one live window handle at a time, and a consumer for a later window
-- replaces (and ends) the one for an earlier. It is written in transactions only, by the instance's owner thread (a poll
-- registers its consumer, lazily) and by the declaring thread (declare and forget), and read by the capability liveness
-- check. Its size is bounded by the instances a VM may have; forgetting an instance removes its entry.
--
-- == When admission is enabled
--
-- A feed starts gated: the host drops input until the application's admission is enabled. The adapter enables it in the
-- transaction that registers the consumer, at the instance's /first successful poll/ of that window incarnation, so
-- admission is never open before the consumer is registered, and input produced before that first poll is gated and
-- dropped (it is not replayed). A window whose script never polls is never enabled, so it never overflows and the host
-- never owes a warning for it: no reset, no warning and no adapter-side queue. When the consumer ends (the instance is
-- forgotten, or a later window replaces its window) the adapter suspends admission in the transaction that removes it,
-- which makes the feed's reset of reason suspension, owes no warning, and stops a feed nobody reads from filling.
--
-- = Closure
--
-- Revoking a window or an instance never waits for an acknowledgement: forgetting an instance is one transaction that
-- removes its consumer and suspends admission, and the window's own retirement is the provider's, which never reads this
-- registry. The feed closing with its window is observed as a closed disposition by the next read.
module Hetoimasia.LuaEngine.Graphics.Input
  ( -- * The source of one window's input
    Source (..)
  , SourceRead (..)
  , SourceObservation (..)
  , SomeSource (..)
  , InputHost (..)
  , glfwSource
  , glfwInputHost

    -- * Translation
  , translateEvent
  , translateObservation

    -- * One consumer
  , Consumer
  , consumerId
  , consumerPoll
  , consumerAcknowledge
  , consumerIssued
  , consumerEnable
  , consumerEnd
  , newConsumer
  , tokenKey
  , tokenParts
  , InputDefect (..)

    -- * The registry and the services
  , InputRegistry
  , newInputRegistry
  , declareInput
  , forgetInput
  , InputReading (..)
  , inputReading
  , InputConfig (..)
  , inputServices
  ) where

import Control.Concurrent.STM
  ( STM
  , TVar
  , atomically
  , newTVar
  , newTVarIO
  , readTVar
  , throwSTM
  , writeTVar
  )
import Control.Exception (Exception, mask_)
import Control.Monad (void)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Kind (Type)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Typeable (Typeable)
import Data.Word (Word32, Word64)
import GHC.Float (float2Double)
import qualified Hetoimasia.GLFW.Input as Glfw
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , ContentScale (..)
  , CursorPosition (..)
  , Extent (..)
  , WindowObservation
  , observedContentScale
  , observedCursorInside
  , observedCursorPosition
  , observedFocused
  , observedFramebufferExtent
  , observedLogicalExtent
  , observedRevision
  )
import Hetoimasia.LuaEngine.Facade
  ( InputAck (..)
  , InputBody (..)
  , InputButtonAction (..)
  , InputDisposition (..)
  , InputEventRecord (..)
  , InputKeyAction (..)
  , InputModifiers (..)
  , InputObservation (..)
  , InputPacket (..)
  , InputPoll (..)
  , InputResetInfo (..)
  , InputResetReason (..)
  , InputServices (..)
  , graphicsInputResetType
  )
import Hetoimasia.LuaEngine.Graphics.Window.Host (WindowInput (..))
import Hetoimasia.LuaEngine.Graphics.Window.Port (WindowToken)
import Hetoimasia.LuaEngine.Graphics.Window.Provider
  ( WindowResource (..)
  , WindowRole (PresentationRole)
  , ownerRole
  , ownerTaking
  , withWindowOr
  )
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Scripting.Lua.Registration (capabilityType)
import Numeric.Natural (Natural)

-- The source ------------------------------------------------------------------------------------------

-- | What one read of a window's feed found, in the event type @ev@ and the token type @tok@ of its source.
data SourceRead ev tok
  = ReadEvent ev
  | ReadReset tok
  | ReadPaused
  | ReadEmpty
  | ReadClosed

-- | A window's latest observation, in the public vocabulary of the window integration: each attribute is either observed or
-- unavailable, and the cursor is whatever the last callback recorded.
data SourceObservation = SourceObservation
  { soRevision ∷ !Natural
  , soFocused ∷ !(Attribute Bool)
  , soCursor ∷ !(Maybe CursorPosition)
  , soCursorInside ∷ !(Maybe Bool)
  , soLogical ∷ !(Attribute Extent)
  , soFramebuffer ∷ !(Attribute Extent)
  , soScale ∷ !(Attribute ContentScale)
  }

-- | The transactions a consumer needs of one window's feed, and nothing it could produce input or retire the window with.
data Source ev tok = Source
  { sourceRead ∷ STM (SourceRead ev tok)
  -- ^ Read without waiting, consuming one event when there is one.
  , sourceEvent ∷ ev → (Natural, Glfw.InputPayload)
  -- ^ An event's epoch and payload.
  , sourceResetOf ∷ tok → (Natural, Glfw.ResetReason)
  -- ^ The epoch a reset reserved and why it began.
  , sourceAcknowledge ∷ tok → STM (Either Glfw.InputMisuse Glfw.Acknowledgement)
  , sourceEpoch ∷ STM Natural
  -- ^ The epoch of the running generation, or of the last one that ran.
  , sourceLastReset ∷ STM (Maybe (Natural, Glfw.ResetReason))
  -- ^ The newest reset, if any began.
  , sourceClosed ∷ STM Bool
  , sourceObservation ∷ STM SourceObservation
  , sourceEnable ∷ STM ()
  -- ^ Open the application's input admission.
  , sourceSuspend ∷ STM ()
  -- ^ Close it again, through the feed's own reset when input was running.
  }

-- | A source of any event and token type.
data SomeSource = ∀ ev tok. Eq tok ⇒ SomeSource (Source ev tok)

-- | How a composition reaches a window incarnation's source. The production host's is 'glfwInputHost'.
data InputHost = InputHost
  { inputSource ∷ WindowToken → STM (Maybe SomeSource)
  -- ^ The source of a window incarnation the host made and has not retired; 'Nothing' for any other.
  , inputObserve ∷ InputRegistry → IO ()
  -- ^ Told of each VM's registry as it is made: a test seam that lets an example read the bookkeeping back (in the way
  -- 'Hetoimasia.LuaEngine.Graphics.Scene.PublishHooks' lets one hold a publication). Production does nothing.
  }

-- | The production source over a window's one reader, admission control and observation.
glfwSource ∷ WindowInput → Source Glfw.InputEvent Glfw.ResetToken
glfwSource window =
  Source
    { sourceRead = fmap classify (Glfw.readInput reader)
    , sourceEvent = \event → (Glfw.epochNumber (Glfw.inputEpoch event), Glfw.inputPayload event)
    , sourceResetOf = \token → (Glfw.epochNumber (Glfw.resetEpoch token), Glfw.resetReason token)
    , sourceAcknowledge = Glfw.acknowledgeReset reader
    , sourceEpoch = Glfw.epochNumber . Glfw.statisticsEpoch <$> Glfw.inputStatistics reader
    , sourceLastReset = fmap (\summary → (Glfw.epochNumber (Glfw.summaryEpoch summary), Glfw.summaryReason summary)) . Glfw.statisticsLastReset <$> Glfw.inputStatistics reader
    , sourceClosed = (== Glfw.InputFeedClosed) . Glfw.statisticsPhase <$> Glfw.inputStatistics reader
    , sourceObservation = observe <$> windowInputObservation window
    , sourceEnable = void (Glfw.enableInput control)
    , sourceSuspend = void (Glfw.suspendInput control)
    }
  where
    reader = windowInputReader window
    control = windowInputControl window
    classify = \case
      Glfw.InputDelivered event → ReadEvent event
      Glfw.InputResetRequired token → ReadReset token
      Glfw.InputPaused → ReadPaused
      Glfw.InputEmpty → ReadEmpty
      Glfw.InputClosed → ReadClosed

observe ∷ WindowObservation → SourceObservation
observe found =
  SourceObservation
    { soRevision = observedRevision found
    , soFocused = observedFocused found
    , soCursor = observedCursorPosition found
    , soCursorInside = observedCursorInside found
    , soLogical = observedLogicalExtent found
    , soFramebuffer = observedFramebufferExtent found
    , soScale = observedContentScale found
    }

-- | The production host's source lookup, over the port's input lookup.
glfwInputHost ∷ (WindowToken → STM (Maybe WindowInput)) → InputHost
glfwInputHost lookupInput = InputHost (\token → fmap (SomeSource . glfwSource) <$> lookupInput token) (\_ → pure ())

-- Translation -----------------------------------------------------------------------------------------

-- | An event of the source, in the facade's vocabulary. Key code and platform scancode stay separate, press, repeat and
-- release stay distinct, a button keeps its captured cursor and modifiers, a scroll keeps both signed fractional offsets and
-- no modifiers (the source captured none), and a character keeps its exact code point.
translateEvent ∷ (Natural, Glfw.InputPayload) → InputEventRecord
translateEvent (epoch, payload) = InputEventRecord epoch $ case payload of
  Glfw.KeyInput key → BodyKey (Glfw.keyCode key) (Glfw.keyScancode key) (keyAction (Glfw.keyAction key)) (modifiers (Glfw.keyModifiers key))
  Glfw.TextInput character → BodyText (fromEnum character)
  Glfw.ButtonInput button →
    BodyButton
      (Glfw.buttonNumber button)
      (buttonAction (Glfw.buttonAction button))
      ((\(CursorPosition x y) → (x, y)) <$> Glfw.buttonCursor button)
      (modifiers (Glfw.buttonModifiers button))
  Glfw.ScrollInput scroll → BodyScroll (Glfw.scrollX scroll) (Glfw.scrollY scroll)
  Glfw.FocusInput focused → BodyFocus focused
  where
    keyAction = \case
      Glfw.KeyPressed → KeyActionPress
      Glfw.KeyRepeated → KeyActionRepeat
      Glfw.KeyReleased → KeyActionRelease
    buttonAction = \case
      Glfw.ButtonPressed → ButtonActionPress
      Glfw.ButtonReleased → ButtonActionRelease
    modifiers found =
      InputModifiers
        { modShift = Glfw.modifierShift found
        , modControl = Glfw.modifierControl found
        , modAlt = Glfw.modifierAlt found
        , modSuper = Glfw.modifierSuper found
        , modCapsLock = Glfw.modifierCapsLock found
        , modNumLock = Glfw.modifierNumLock found
        }

-- | The observation in the facade's vocabulary: an attribute the platform could not provide is absent, never zero or a
-- guessed scale. A scale's single-precision components widen exactly. Whether a value is representable and finite is the
-- facade's to decide when it shapes the packet.
translateObservation ∷ SourceObservation → InputObservation
translateObservation found =
  InputObservation
    { observationRevision = soRevision found
    , observationFocused = observed (soFocused found)
    , observationCursor = (\(CursorPosition x y) → (x, y)) <$> soCursor found
    , observationCursorInside = soCursorInside found
    , observationLogical = (\(Extent w h) → (w, h)) <$> observed (soLogical found)
    , observationFramebuffer = (\(Extent w h) → (w, h)) <$> observed (soFramebuffer found)
    , observationScale = (\(ContentScale x y) → (float2Double x, float2Double y)) <$> observed (soScale found)
    }
  where
    observed = \case
      Observed value → Just value
      Unavailable → Nothing

-- A consumer ------------------------------------------------------------------------------------------

-- | A fault of the consumer's own bookkeeping, or of what the feed answered: a defect, never a script's mistake.
newtype InputDefect = InputDefect Text
  deriving (Eq, Show)

instance Exception InputDefect

-- | The key of a reset token: the consumer that issued it and the order it was issued in.
tokenKey ∷ Word32 → Word32 → Word64
tokenKey consumer order = (fromIntegral consumer `shiftL` 32) .|. fromIntegral order

-- | The consumer and the order a token key was made from.
tokenParts ∷ Word64 → (Word32, Word32)
tokenParts key = (fromIntegral (key `shiftR` 32), fromIntegral (key .&. 0xFFFFFFFF))

-- | The single logical consumer of one window incarnation's feed.
data Consumer = Consumer
  { consumerId ∷ !Word32
  , consumerPoll ∷ Int → STM InputPacket
  -- ^ Read at most this many events, atomically with the disposition, the epoch and the observation.
  , consumerAcknowledge ∷ Word32 → STM InputAck
  -- ^ Acknowledge by the order a token was issued in.
  , consumerIssued ∷ STM Word32
  -- ^ How many tokens this consumer has issued: every order from one to this is a token it made.
  , consumerEnable ∷ STM ()
  , consumerEnd ∷ STM ()
  }

-- | A consumer over a source. Remembers one reset token at a time, the newest it handed out.
newConsumer ∷ ∀ ev tok. Eq tok ⇒ Word32 → Source ev tok → STM Consumer
newConsumer identity source = do
  held ← newTVar (Nothing ∷ Maybe (Word32, tok))
  issued ← newTVar (0 ∷ Word32)
  let -- The reset token to hand a script: the same order while the same reset is pending, a new one for a newer reset.
      issue token = do
        current ← readTVar held
        case current of
          Just (order, old) | old == token → pure order
          _ → do
            count ← readTVar issued
            if count == maxBound
              then throwSTM (InputDefect "a consumer issued every reset token it can")
              else do
                writeTVar issued (count + 1)
                writeTVar held (Just (count + 1, token))
                pure (count + 1)

      collect ∷ Int → [InputEventRecord] → STM ([InputEventRecord], Maybe (SourceRead ev tok))
      collect remaining found
        | remaining <= 0 = pure (reverse found, Nothing)
        | otherwise =
            sourceRead source >>= \case
              ReadEvent event → collect (remaining - 1) (translateEvent (sourceEvent source event) : found)
              other → pure (reverse found, Just other)

      poll limit = do
        (events, stopped) ← collect limit []
        epoch ← sourceEpoch source
        observation ← translateObservation <$> sourceObservation source
        (disposition, exhausted, reset) ← case stopped of
          -- The bound was reached: the poll did not look past it, so it does not say the feed is empty.
          Nothing → pure (DispositionRunning, False, Nothing)
          Just ReadEmpty → pure (DispositionRunning, True, Nothing)
          Just (ReadReset token) → do
            order ← issue token
            let (reserved, why) = sourceResetOf source token
            pure (DispositionResetRequired, True, Just (InputResetInfo (reasonOf why) reserved (Just (tokenKey identity order))))
          Just ReadPaused → do
            latest ← sourceLastReset source
            pure (DispositionPaused, True, (\(reserved, why) → InputResetInfo (reasonOf why) reserved Nothing) <$> latest)
          Just ReadClosed → pure (DispositionClosed, True, Nothing)
          Just (ReadEvent _) → throwSTM (InputDefect "a read that stopped on an event")
        pure
          InputPacket
            { packetDisposition = disposition
            , packetEpoch = epoch
            , packetEvents = events
            , packetExhausted = exhausted
            , packetReset = reset
            , packetObservation = observation
            }

      acknowledge order = do
        count ← readTVar issued
        current ← readTVar held
        closed ← sourceClosed source
        case current of
          _ | order == 0 || order > count → pure (AckRefused "the reset token was not issued by this window's input")
          -- An older token never reaches the feed: it can acknowledge nothing, and closure still wins.
          _ | order < count → pure (if closed then AckClosed else AckStale)
          Just (_, token) →
            sourceAcknowledge source token >>= \case
              Left misuse → throwSTM (InputDefect ("the feed refused a token this consumer issued: " <> Text.pack (show misuse)))
              Right Glfw.Acknowledged → pure AckAcknowledged
              Right Glfw.AlreadyAcknowledged → pure AckAlready
              Right Glfw.StaleAcknowledgement → pure AckStale
              Right Glfw.AcknowledgementClosed → pure AckClosed
          Nothing → pure (AckRefused "the reset token was not issued by this window's input")
  pure
    Consumer
      { consumerId = identity
      , consumerPoll = poll
      , consumerAcknowledge = acknowledge
      , consumerIssued = readTVar issued
      , consumerEnable = sourceEnable source
      , consumerEnd = sourceSuspend source
      }
  where
    reasonOf = \case
      Glfw.InputOverflowed → ResetReasonOverflow
      Glfw.AdmissionSuspended → ResetReasonSuspension

-- The registry ----------------------------------------------------------------------------------------

data Entry = Entry
  { entryWindow ∷ !WindowToken
  , entryConsumer ∷ !Consumer
  }

-- | One VM's input bookkeeping: for each declared instance, its consumer when it has one, and the next consumer number.
data InputRegistry = InputRegistry
  { registrySlots ∷ !(TVar (Map Text (Maybe Entry)))
  , registryNext ∷ !(TVar Word32)
  }

newInputRegistry ∷ IO InputRegistry
newInputRegistry = InputRegistry <$> newTVarIO Map.empty <*> newTVarIO 0

-- | An instance was declared: it may now register a consumer.
declareInput ∷ InputRegistry → Text → IO ()
declareInput registry identity = atomically $ do
  slots ← readTVar (registrySlots registry)
  writeTVar (registrySlots registry) (Map.insertWith (\_ old → old) identity Nothing slots)

-- | An instance was forgotten: its consumer ends and its entry goes, in one transaction. Admission is suspended, which owes
-- no warning, and nothing waits for an acknowledgement.
forgetInput ∷ InputRegistry → Text → IO ()
forgetInput registry identity = atomically $ do
  slots ← readTVar (registrySlots registry)
  case Map.lookup identity slots of
    Nothing → pure ()
    Just entry → do
      mapM_ (consumerEnd . entryConsumer) entry
      writeTVar (registrySlots registry) (Map.delete identity slots)

-- | What the registry holds now: the counts it must return to when every instance has been forgotten.
data InputReading = InputReading
  { readingInstances ∷ !Int
  , readingConsumers ∷ !Int
  }
  deriving (Eq, Show)

inputReading ∷ InputRegistry → STM InputReading
inputReading registry = do
  slots ← readTVar (registrySlots registry)
  pure (InputReading (Map.size slots) (length [() | Just _ ← Map.elems slots]))

-- | What the services are composed from beyond the VM's own leases.
data InputConfig = InputConfig
  { icHost ∷ !InputHost
  , icTakesWork ∷ STM Bool
  -- ^ Whether the session still takes new work for this role, read in the transaction that decides to read input.
  }

-- | The facade's input operations of one VM, over its leases, its registry and the host's sources.
inputServices ∷ ∀ (target ∷ Type). Typeable target ⇒ InputConfig → Leases → InputRegistry → InputServices
inputServices config leases registry =
  InputServices
    { isTypes = [capabilityType graphicsInputResetType tokenLive]
    , isCheckPoll = checkPoll
    , isPoll = poll
    , isCheckAcknowledge = checkAcknowledge
    , isAcknowledge = acknowledge
    }
  where
    clip = Text.take 200

    -- A token key is live while its consumer is a registered one and the order is one it issued.
    tokenLive key = atomically $ do
      let (consumer, order) = tokenParts key
      slots ← readTVar (registrySlots registry)
      let issuedOf = [consumerIssued (entryConsumer entry) | Just entry ← Map.elems slots, consumerId (entryConsumer entry) == consumer]
      case issuedOf of
        found : _ → (\count → order >= 1 && order <= count) <$> found
        [] → pure False

    -- The facts a poll of this window by this instance rests on, read without consuming anything.
    availability identity resource = do
      taking ← ownerTaking (resourceOwner resource)
      session ← icTakesWork config
      slots ← readTVar (registrySlots registry)
      let token = resourceToken resource
          current = Map.lookup identity slots
      available ← case current of
        Nothing → pure (Left "the instance has ended")
        Just (Just entry) | entryWindow entry == token → pure (Right ())
        Just _ → maybe (Left "the window has retired") (const (Right ())) <$> inputSource (icHost config) token
      pure $ case () of
        _
          | ownerRole (resourceOwner resource) /= PresentationRole → Just "input is presentation-instance work"
          | not taking → Just "the instance has ended"
          | not session → Just "the session is stopping: input is no longer polled"
          | Left why ← available → Just why
          | otherwise → Nothing

    checkPoll identity windowKey =
      withWindowOr @target leases windowKey (pure . Just . clip) $ \resource →
        atomically (availability identity resource)

    -- Register the instance's consumer for this window incarnation and open admission, in one transaction: admission is
    -- never open before the consumer is registered, and an instance that ended meanwhile registers nothing.
    ensure identity token = mask_ . atomically $ do
      slots ← readTVar (registrySlots registry)
      case Map.lookup identity slots of
        Nothing → pure (Left "the instance has ended")
        Just (Just entry) | entryWindow entry == token → pure (Right (entryConsumer entry))
        Just earlier →
          inputSource (icHost config) token >>= \case
            Nothing → pure (Left "the window has retired")
            Just (SomeSource source) → do
              count ← readTVar (registryNext registry)
              if count == maxBound
                then throwSTM (InputDefect "a VM registered every input consumer it can")
                else do
                  writeTVar (registryNext registry) (count + 1)
                  consumer ← newConsumer (count + 1) source
                  -- The consumer of an earlier window of this instance ends here, so one instance never holds two.
                  mapM_ (consumerEnd . entryConsumer) earlier
                  writeTVar (registrySlots registry) (Map.insert identity (Just (Entry token consumer)) slots)
                  consumerEnable consumer
                  pure (Right consumer)

    poll identity windowKey limit =
      withWindowOr @target leases windowKey (pure . PollRefused . clip) $ \resource →
        ensure identity (resourceToken resource) >>= \case
          Left why → pure (PollRefused why)
          Right consumer → atomically $ do
            -- The authority and the read are one transaction: nothing that ends can land between them.
            refusal ← availability identity resource
            slots ← readTVar (registrySlots registry)
            let registered = case Map.lookup identity slots of
                  Just (Just entry) → entryWindow entry == resourceToken resource && consumerId (entryConsumer entry) == consumerId consumer
                  _ → False
            case refusal of
              Just why → pure (PollRefused why)
              Nothing
                | not registered → pure (PollRefused "the window's input has ended")
                | otherwise → Polled <$> consumerPoll consumer limit

    -- The consumer this instance holds for this window, if the token key names it.
    owned identity token key = do
      slots ← readTVar (registrySlots registry)
      pure $ case Map.lookup identity slots of
        Just (Just entry)
          | entryWindow entry == token
          , consumerId (entryConsumer entry) == fst (tokenParts key) → Just (entryConsumer entry)
        _ → Nothing

    checkAcknowledge identity windowKey key =
      withWindowOr @target leases windowKey (pure . Just . clip) $ \resource →
        atomically $
          if ownerRole (resourceOwner resource) /= PresentationRole
            then pure (Just "input is presentation-instance work")
            else
              owned identity (resourceToken resource) key <&> \case
                Nothing → Just "the reset token does not belong to this window"
                Just _ → Nothing

    acknowledge identity windowKey key =
      withWindowOr @target leases windowKey (pure . AckRefused . clip) $ \resource →
        atomically $
          owned identity (resourceToken resource) key >>= \case
            Nothing → pure (AckRefused "the reset token does not belong to this window")
            Just consumer → consumerAcknowledge consumer (snd (tokenParts key))

    (<&>) = flip fmap
