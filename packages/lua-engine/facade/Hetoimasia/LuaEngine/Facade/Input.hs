{-# LANGUAGE OverloadedStrings #-}

-- | @api.input.poll@ and @api.input.acknowledgeReset@: the ordered window input of the M1 presentation facade (TRA-6),
-- bound over the narrow operations a composition injects ('InputServices').
--
-- = What this module decides, and what it leaves to the window integration
--
-- Everything a script can get wrong is decided here, before any input is read, as an ordinary Lua error: the caller (an
-- instance of this facade, never a module's top level and never another instance's captured facade), its role (the
-- presentation role alone), its phase, the session's admission, the arity and types of the arguments (the host's own
-- rules, with no authored metamethod run), @max_events@'s range, and whether the largest packet @max_events@ allows fits
-- the copied-value limits. Only then is the injected check asked for the window's own facts (the handle is the calling
-- instance's live window). The read itself is the injected operation's, atomic with the feed's disposition and the
-- window's observation; this module shapes the packet it answers.
--
-- = The two calls
--
-- * @poll(window, max_events)@: init or update work while the session's admission is open. @max_events@ is a Lua integer
--   from 1 to 128, and no more than the copied-value limits can carry ('pollCapacity'); anything else (a float, an integral
--   float included, a numeric string, 0, 129) is refused before a single event is consumed.
-- * @acknowledgeReset(window, token)@: a cleanup/control operation, allowed in any finite hook of the owning presentation
--   instance (shutdown included) while its authority remains valid. It never reads the session's admission, so it cannot be
--   refused for a stop and cannot reopen anything.
--
-- = The packet
--
-- > { disposition = "running" | "reset_required" | "paused" | "closed"
-- > , epoch       = INTEGER            -- the epoch of the running generation, or of the last one that ran
-- > , exhausted   = BOOLEAN            -- true only when the read observed the end of the feed; false when it stopped at the bound
-- > , events      = { EVENT, ... }     -- an ordered prefix, at most max_events
-- > , reset       = { reason = "overflow" | "suspended", epoch = INTEGER, token = HANDLE | nil } | nil
-- > , observation = { revision = INTEGER, focused = BOOLEAN | nil, cursor = {x=,y=} | nil, cursor_inside = BOOLEAN | nil
-- >                 , logical = {width=,height=} | nil, framebuffer = {width=,height=} | nil, scale = {x=,y=} | nil } }
--
-- An EVENT always has @kind@ and @epoch@, and then:
--
-- > kind = "key"    : code, scancode, action = "press" | "repeat" | "release", mods
-- > kind = "text"   : codepoint = INTEGER (exact; a surrogate included), text = STRING | nil (nil unless a Unicode scalar value)
-- > kind = "button" : button, action = "press" | "release", x, y (the cursor captured for the event, nil when none), mods
-- > kind = "scroll" : scroll_x, scroll_y (floats; no modifiers, because the source captured none)
-- > kind = "focus"  : focused = BOOLEAN
--
-- @mods@ is @{shift=, control=, alt=, super=, caps_lock=, num_lock=}@, six booleans. Every number is exact: an epoch, a
-- revision or an extent is never passed through a float, and one that no Lua integer holds is the host's defect, not a
-- value ('failEngine'). A float that is not finite is the same. An attribute the platform could not provide is absent, never zero.
--
-- = After the read
--
-- A packet that cannot be delivered once the batch has been taken (a defect of the provider's data) is the engine's
-- failure and ends the owner as one; it is never an empty poll. The prevalidation in the check exists so that no ordinary
-- size or shape refusal can reach that point.
module Hetoimasia.LuaEngine.Facade.Input
  ( inputBindings
  , pollMaximum
  , pollCapacity
  , packetSchema
  , packetValue
  , worstPacketBytes
  ) where

import Control.Monad (when)
import qualified Data.ByteString as ByteString
import Data.Char (chr)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller (Caller (..), Stage (..), requireInstance, whoIsCalling)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , Precondition
  , asynchronousNativeRequestIn
  , refuseOrdinarily
  , withArgumentCheck
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Value
  ( Schema (..)
  , Value (..)
  , ValueLimits
  , capability
  , capabilityKey
  , limitBytes
  , limitDepth
  , limitElements
  )
import Numeric.Natural (Natural)

-- | The most events one poll may ask for: the approved host profile's cap.
pollMaximum ∷ Int
pollMaximum = 128

-- | The two bindings of the hidden namespace: @input_poll@ and @input_acknowledge_reset@. The initial chunk wraps each
-- in the facade's own closure. The limits are the ones every result of the owner is held to.
inputBindings ∷ Facade → InputServices → ValueLimits → [Binding]
inputBindings facade services limits =
  [ withPrecondition pollRule $
      withArgumentCheck pollCheck $
        asynchronousNativeRequestIn "input_poll" [SCapability graphicsWindowType, SInteger] [packetSchema] pollAct
  , withPrecondition ackRule $
      withArgumentCheck ackCheck $
        asynchronousNativeRequestIn "input_acknowledge_reset" [SCapability graphicsWindowType, SCapability graphicsInputResetType] [SText] ackAct
  ]
  where
    capacity = pollCapacity facade limits
    identityOf = recordId . callerRecord

    -- Who may poll, and when: a presentation instance's init or update, while the session takes new work. The session's
    -- admission is read last, so a role or phase refusal never depends on it.
    pollRule ∷ Precondition
    pollRule owner = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller
          | recordRole (callerRecord caller) /= Presentation → pure (refuseText "input polling is available to the presentation role only")
          | callerStage caller == StageEnding → pure (refuseText "input polling is not available in shutdown")
          | otherwise →
              endpointAdmission (fcEndpoints facade) >>= \case
                AdmissionStopping → pure (refuseText "the session is stopping: input is no longer polled")
                AdmissionClosed → pure (refuseText "the session is closed: input is no longer polled")
                AdmissionOpen → pure Nothing

    -- Acknowledgement is control work: any finite hook of a presentation instance, shutdown included, and never gated on
    -- the session's admission.
    ackRule ∷ Precondition
    ackRule owner = do
      calling ← whoIsCalling facade owner
      pure $ case requireInstance calling of
        Left why → refuseText why
        Right caller
          | recordRole (callerRecord caller) /= Presentation → refuseText "reset acknowledgement is available to the presentation role only"
          | otherwise → Nothing

    pollCheck ∷ ArgumentCheck
    pollCheck owner values = case values of
      [VCapability window, VInteger count]
        | count < 1 || count > fromIntegral pollMaximum → pure (refuseText ("max_events must be an integer from 1 to " <> showText pollMaximum))
        | fromIntegral count > capacity →
            pure (refuseText ("max_events " <> showText count <> " exceeds the " <> showText capacity <> " events this session's copied-value limits can carry in one packet"))
        | otherwise →
            callerOf owner >>= \case
              Left why → pure (refuseText why)
              Right caller → fmap (clipText 200) <$> isCheckPoll services (identityOf caller) (capabilityKey window)
      _ → pure (refuseText "polling takes a window and max_events")

    ackCheck ∷ ArgumentCheck
    ackCheck owner values = case values of
      [VCapability window, VCapability token] →
        callerOf owner >>= \case
          Left why → pure (refuseText why)
          Right caller → fmap (clipText 200) <$> isCheckAcknowledge services (identityOf caller) (capabilityKey window) (capabilityKey token)
      _ → pure (refuseText "acknowledging takes a window and a reset token")

    callerOf owner = requireInstance <$> whoIsCalling facade owner

    pollAct context values = do
      calling ← callingIn facade context
      case (requireInstance calling, values) of
        (Right caller, [VCapability window, VInteger count]) →
          isPoll services (identityOf caller) (capabilityKey window) (fromIntegral count) >>= \case
            PollRefused why → refuseOrdinarily (clipText 200 why)
            -- The batch is taken. What cannot be shaped now is a defect of the data, and fails the owner; it is never
            -- turned into an empty poll.
            Polled packet → case packetValue facade packet of
              Left why → failEngine facade ("an input packet could not be delivered: " <> why)
              Right shaped → pure [shaped]
        _ → failEngine facade "input was polled with no instance running"

    ackAct context values = do
      calling ← callingIn facade context
      case (requireInstance calling, values) of
        (Right caller, [VCapability window, VCapability token]) →
          isAcknowledge services (identityOf caller) (capabilityKey window) (capabilityKey token) >>= \case
            AckRefused why → refuseOrdinarily (clipText 200 why)
            AckAcknowledged → pure [VText "acknowledged"]
            AckAlready → pure [VText "already_acknowledged"]
            AckStale → pure [VText "stale"]
            AckClosed → pure [VText "closed"]
        _ → failEngine facade "a reset was acknowledged with no instance running"

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show

-- The schema -----------------------------------------------------------------------------------------

modifiersSchema ∷ Schema
modifiersSchema =
  SRecord [(name, SBoolean) | name ← modifierNames]

modifierNames ∷ [Text]
modifierNames = ["shift", "control", "alt", "super", "caps_lock", "num_lock"]

pairSchema ∷ (Text, Schema) → (Text, Schema) → Schema
pairSchema first second = SRecord [first, second]

eventSchema ∷ Schema
eventSchema =
  SRecord
    [ ("kind", SText)
    , ("epoch", SInteger)
    , ("code", SOptional SInteger)
    , ("scancode", SOptional SInteger)
    , ("action", SOptional SText)
    , ("mods", SOptional modifiersSchema)
    , ("codepoint", SOptional SInteger)
    , ("text", SOptional SText)
    , ("button", SOptional SInteger)
    , ("x", SOptional SFloat)
    , ("y", SOptional SFloat)
    , ("scroll_x", SOptional SFloat)
    , ("scroll_y", SOptional SFloat)
    , ("focused", SOptional SBoolean)
    ]

-- | The exact record a poll answers.
packetSchema ∷ Schema
packetSchema =
  SRecord
    [ ("disposition", SText)
    , ("epoch", SInteger)
    , ("exhausted", SBoolean)
    , ("events", SList eventSchema)
    , ("reset", SOptional (SRecord [("reason", SText), ("epoch", SInteger), ("token", SOptional (SCapability graphicsInputResetType))]))
    , ( "observation"
      , SRecord
          [ ("revision", SInteger)
          , ("focused", SOptional SBoolean)
          , ("cursor", SOptional (pairSchema ("x", SFloat) ("y", SFloat)))
          , ("cursor_inside", SOptional SBoolean)
          , ("logical", SOptional (pairSchema ("width", SInteger) ("height", SInteger)))
          , ("framebuffer", SOptional (pairSchema ("width", SInteger) ("height", SInteger)))
          , ("scale", SOptional (pairSchema ("x", SFloat) ("y", SFloat)))
          ]
      )
    ]

-- The packet's value ---------------------------------------------------------------------------------

-- | The Lua value of a packet, or why the provider's data is a defect: an integer no Lua integer holds, a float that is
-- not finite. Pure; the check's worst-case measure and the action's answer are the same function.
packetValue ∷ Facade → InputPacket → Either Text Value
packetValue facade packet = do
  epoch ← natural "epoch" (packetEpoch packet)
  events ← traverse eventValue (packetEvents packet)
  reset ← traverse resetValue (packetReset packet)
  observation ← observationValue (packetObservation packet)
  Right . VRecord $
    [ ("disposition", VText (dispositionWord (packetDisposition packet)))
    , ("epoch", epoch)
    , ("exhausted", VBoolean (packetExhausted packet))
    , ("events", VList events)
    ]
      <> [("reset", found) | Just found ← [reset]]
      <> [("observation", observation)]
  where
    ceiling' = limitIntegerMaximum (fcLimits facade)

    natural ∷ Text → Natural → Either Text Value
    natural what n
      | n <= fromIntegral ceiling' = Right (VInteger (fromIntegral n))
      | otherwise = Left (what <> " " <> showText n <> " is beyond the Lua integer ceiling")

    int ∷ Text → Int → Either Text Value
    int what n
      | toInteger n <= toInteger ceiling' = Right (VInteger (fromIntegral n))
      | otherwise = Left (what <> " " <> showText n <> " is beyond the Lua integer ceiling")

    float ∷ Text → Double → Either Text Value
    float what d
      | isNaN d || isInfinite d = Left (what <> " is not a finite number")
      | otherwise = Right (VFloat d)

    floats ∷ Text → (Double, Double) → Either Text Value
    floats what (x, y) = do
      vx ← float (what <> ".x") x
      vy ← float (what <> ".y") y
      Right (VRecord [("x", vx), ("y", vy)])

    extent ∷ Text → (Int, Int) → Either Text Value
    extent what (w, h) = do
      when (w < 0 || h < 0) (Left (what <> " is negative"))
      vw ← int (what <> ".width") w
      vh ← int (what <> ".height") h
      Right (VRecord [("width", vw), ("height", vh)])

    modsValue ∷ InputModifiers → Value
    modsValue m =
      VRecord
        [ ("shift", VBoolean (modShift m))
        , ("control", VBoolean (modControl m))
        , ("alt", VBoolean (modAlt m))
        , ("super", VBoolean (modSuper m))
        , ("caps_lock", VBoolean (modCapsLock m))
        , ("num_lock", VBoolean (modNumLock m))
        ]

    eventValue ∷ InputEventRecord → Either Text Value
    eventValue event = do
      epoch ← natural "event epoch" (eventEpoch event)
      let header kind = [("kind", VText kind), ("epoch", epoch)]
      case eventBody event of
        BodyKey code scancode action mods → do
          vc ← int "key code" code
          vs ← int "scancode" scancode
          Right . VRecord $ header "key" <> [("code", vc), ("scancode", vs), ("action", VText (keyWord action)), ("mods", modsValue mods)]
        BodyText point → do
          vp ← int "code point" point
          let scalar = point >= 0 && point <= 0x10FFFF && not (point >= 0xD800 && point <= 0xDFFF)
          Right . VRecord $ header "text" <> [("codepoint", vp)] <> [("text", VText (Text.singleton (chr point))) | scalar]
        BodyButton button action cursor mods → do
          vb ← int "button" button
          at ← traverse (\(x, y) → (,) <$> float "button x" x <*> float "button y" y) cursor
          Right . VRecord $
            header "button"
              <> [("button", vb), ("action", VText (buttonWord action)), ("mods", modsValue mods)]
              <> concat [[("x", x), ("y", y)] | Just (x, y) ← [at]]
        BodyScroll x y → do
          vx ← float "scroll x" x
          vy ← float "scroll y" y
          Right . VRecord $ header "scroll" <> [("scroll_x", vx), ("scroll_y", vy)]
        BodyFocus focused → Right . VRecord $ header "focus" <> [("focused", VBoolean focused)]

    resetValue ∷ InputResetInfo → Either Text Value
    resetValue found = do
      epoch ← natural "reset epoch" (resetEpoch found)
      Right . VRecord $
        [ ("reason", VText (resetWord (resetReason found)))
        , ("epoch", epoch)
        ]
          <> [("token", VCapability (capability graphicsInputResetType key)) | Just key ← [resetTokenKey found]]

    observationValue ∷ InputObservation → Either Text Value
    observationValue found = do
      revision ← natural "observation revision" (observationRevision found)
      cursor ← traverse (floats "cursor") (observationCursor found)
      logical ← traverse (extent "logical extent") (observationLogical found)
      framebuffer ← traverse (extent "framebuffer extent") (observationFramebuffer found)
      scale ← traverse (floats "content scale") (observationScale found)
      Right . VRecord $
        [("revision", revision)]
          <> [("focused", VBoolean focused) | Just focused ← [observationFocused found]]
          <> [("cursor", value) | Just value ← [cursor]]
          <> [("cursor_inside", VBoolean inside) | Just inside ← [observationCursorInside found]]
          <> [("logical", value) | Just value ← [logical]]
          <> [("framebuffer", value) | Just value ← [framebuffer]]
          <> [("scale", value) | Just value ← [scale]]

dispositionWord ∷ InputDisposition → Text
dispositionWord = \case
  DispositionRunning → "running"
  DispositionResetRequired → "reset_required"
  DispositionPaused → "paused"
  DispositionClosed → "closed"

keyWord ∷ InputKeyAction → Text
keyWord = \case
  KeyActionPress → "press"
  KeyActionRepeat → "repeat"
  KeyActionRelease → "release"

buttonWord ∷ InputButtonAction → Text
buttonWord = \case
  ButtonActionPress → "press"
  ButtonActionRelease → "release"

resetWord ∷ InputResetReason → Text
resetWord = \case
  ResetReasonOverflow → "overflow"
  ResetReasonSuspension → "suspended"

-- The capacity ---------------------------------------------------------------------------------------

-- | The most events one poll can carry under these copied-value limits: the largest count, up to 'pollMaximum', for which
-- the packet of that many of the widest events, with the widest envelope, still fits the limits' bytes, depth and
-- elements. Zero when not even one event fits, which refuses every poll before it reads. Computed with the host's
-- documented measure (1 byte for nil and a boolean, 9 for a number, 5 and the length for a string, 21 for a capability, 5
-- and every key and value for a table), so it is never below what the host will count.
pollCapacity ∷ Facade → ValueLimits → Int
pollCapacity facade limits = fromMaybe 0 (lookupFitting [pollMaximum, pollMaximum - 1 .. 1])
  where
    lookupFitting [] = Nothing
    lookupFitting (n : rest)
      | fits (worstPacket facade n) = Just n
      | otherwise = lookupFitting rest
    fits value =
      let (bytes, depth, elements) = measure value
       in bytes <= limitBytes limits && depth <= limitDepth limits && elements <= limitElements limits

-- | The bytes of the widest packet of this many events, by the same measure: what the tests compare against a real poll.
worstPacketBytes ∷ Facade → Int → Int
worstPacketBytes facade n = let (bytes, _, _) = measure (worstPacket facade n) in bytes

-- | The widest packet of @n@ events: the largest event kind repeated, the longest disposition word, a reset with a token and
-- every observation attribute present.
worstPacket ∷ Facade → Int → Value
worstPacket facade n =
  either (const (VRecord [])) id . packetValue facade $
    InputPacket
      { packetDisposition = DispositionResetRequired
      , packetEpoch = 1
      , packetEvents = replicate n widest
      , packetExhausted = True
      , packetReset = Just (InputResetInfo ResetReasonSuspension 1 (Just 1))
      , packetObservation = InputObservation 1 (Just True) (Just (1, 1)) (Just True) (Just (1, 1)) (Just (1, 1)) (Just (1, 1))
      }
  where
    mods = InputModifiers True True True True True True
    candidates =
      [ InputEventRecord 1 (BodyKey 1 1 KeyActionRelease mods)
      , InputEventRecord 1 (BodyText 0x10FFFF)
      , InputEventRecord 1 (BodyButton 1 ButtonActionRelease (Just (1, 1)) mods)
      , InputEventRecord 1 (BodyScroll 1 1)
      , InputEventRecord 1 (BodyFocus True)
      ]
    widest = snd (foldr1 wider [(bytesOf candidate, candidate) | candidate ← candidates])
    wider a b = if fst a >= fst b then a else b
    bytesOf candidate = either (const 0) (\value → let (bytes, _, _) = measure value in bytes) (eventOnly candidate)
    eventOnly candidate = packetValue facade (InputPacket DispositionRunning 1 [candidate] False Nothing (InputObservation 0 Nothing Nothing Nothing Nothing Nothing Nothing))

-- | The documented size of a copied value: its bytes, its depth and its element count.
measure ∷ Value → (Int, Int, Int)
measure = \case
  VBytes bytes → (5 + ByteString.length bytes, 0, 1)
  VText text → (5 + ByteString.length (Text.encodeUtf8 text), 0, 1)
  VCapability _ → (21, 0, 1)
  VList items → table [(9, item) | item ← items]
  VRecord entries → table [(5 + ByteString.length (Text.encodeUtf8 name), item) | (name, item) ← entries, item /= VNil]
  VNil → (1, 0, 1)
  VBoolean _ → (1, 0, 1)
  VExportTable {} → (9, 0, 1)
  _ → (9, 0, 1)
  where
    table entries =
      let measured = [(keySize + bytes, depth, elements) | (keySize, item) ← entries, let (bytes, depth, elements) = measure item]
       in (5 + sum [bytes | (bytes, _, _) ← measured], 1 + maximum (0 : [depth | (_, depth, _) ← measured]), 1 + sum [elements | (_, _, elements) ← measured])
