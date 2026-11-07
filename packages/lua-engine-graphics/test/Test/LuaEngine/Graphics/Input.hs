{-# LANGUAGE OverloadedStrings #-}

-- | The Lua input adapter ("Hetoimasia.LuaEngine.Graphics.Input") over a /controlled/ feed (TRA-6): the translation of a
-- source's payloads and observation to the facade's vocabulary, and the one consumer's bounded, atomic reads, reset tokens
-- and acknowledgements.
--
-- The feed here is "Test.LuaEngine.Graphics.InputFeed", a model an example drives by hand, because no public API outside the
-- GLFW package can produce a GLFW input event or a reset token. Everything below is evidence of the adapter's behavior over
-- a feed that follows the documented contract, and of nothing a window delivers; the session-level examples that put real
-- Lua over the real lease and provider are in "Test.LuaEngine.Graphics.InputSession", and what a real window delivers is the
-- native suite's.
module Test.LuaEngine.Graphics.Input (spec) where

import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVarIO, retry, writeTVar)
import Control.Monad (forM_, unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Word (Word64)
import GHC.Float (float2Double)
import qualified Hetoimasia.GLFW.Input as Glfw
import Hetoimasia.GLFW.Window (Attribute (..), ContentScale (..), CursorPosition (..), Extent (..))
import Hetoimasia.LuaEngine.Facade
import Hetoimasia.LuaEngine.Graphics.Input
import Test.Hspec
import Test.LuaEngine.Graphics.InputFeed
import Test.LuaEngine.Graphics.Rig (bounded)
import Test.Support.Owned (withOwnedThread)

text ∷ Char → Glfw.InputPayload
text = Glfw.TextInput

-- | One character event for each character, in order.
texts ∷ Feed → String → STM ()
texts feed = mapM_ (produce feed . text)

key ∷ Int → Glfw.KeyAction → Glfw.InputPayload
key code action = Glfw.KeyInput (Glfw.KeyEvent code 0 action Glfw.noModifiers)

-- | A feed with this much room, a consumer registered for it and admission enabled: what the adapter does at a first poll.
withConsumer ∷ Int → (Feed → Consumer → IO a) → IO a
withConsumer room body = do
  feed ← newFeed room
  consumer ← atomically (newConsumer 7 (feedSource feed))
  atomically (consumerEnable consumer)
  body feed consumer

poll ∷ Consumer → Int → IO InputPacket
poll consumer count = atomically (consumerPoll consumer count)

ack ∷ Consumer → Int → IO InputAck
ack consumer order = atomically (consumerAcknowledge consumer (fromIntegral order))

epochsOf ∷ InputPacket → [Integer]
epochsOf = map (fromIntegral . eventEpoch) . packetEvents

bodiesOf ∷ InputPacket → [InputBody]
bodiesOf = map eventBody . packetEvents

tokenOf ∷ InputPacket → Maybe Word64
tokenOf packet = packetReset packet >>= resetTokenKey

-- | A single-precision value that is not exact in decimal, read at run time so that no constant folding decides the example.
oneTenth ∷ Float
oneTenth = read "1.1"
{-# NOINLINE oneTenth #-}

spec ∷ Spec
spec = describe "input adapter over a controlled feed" $ do
  translationSpec
  consumerSpec

translationSpec ∷ Spec
translationSpec = describe "translation" $ do
  it "keeps key code and scancode apart, press, repeat and release distinct, and every one of the six modifier flags" $ do
    let flags =
          [ Glfw.noModifiers {Glfw.modifierShift = True}
          , Glfw.noModifiers {Glfw.modifierControl = True}
          , Glfw.noModifiers {Glfw.modifierAlt = True}
          , Glfw.noModifiers {Glfw.modifierSuper = True}
          , Glfw.noModifiers {Glfw.modifierCapsLock = True}
          , Glfw.noModifiers {Glfw.modifierNumLock = True}
          ]
        wanted =
          [ InputModifiers True False False False False False
          , InputModifiers False True False False False False
          , InputModifiers False False True False False False
          , InputModifiers False False False True False False
          , InputModifiers False False False False True False
          , InputModifiers False False False False False True
          ]
    [translateEvent (9, Glfw.KeyInput (Glfw.KeyEvent 65 30 Glfw.KeyPressed modifiers)) | modifiers ← flags]
      `shouldBe` [InputEventRecord 9 (BodyKey 65 30 KeyActionPress mods) | mods ← wanted]
    [bodyOf (translateEvent (1, Glfw.KeyInput (Glfw.KeyEvent (-1) 7 action Glfw.noModifiers))) | action ← [Glfw.KeyPressed, Glfw.KeyRepeated, Glfw.KeyReleased]]
      `shouldBe` [BodyKey (-1) 7 KeyActionPress none, BodyKey (-1) 7 KeyActionRepeat none, BodyKey (-1) 7 KeyActionRelease none]

  it "keeps a Unicode character by its exact code point, a surrogate and the last scalar included" $
    map (bodyOf . translateEvent . (,) 1 . text) ['A', '\xE9', '\x1F600', '\xD800', '\xDFFF', '\x10FFFF']
      `shouldBe` map BodyText [65, 233, 0x1F600, 0xD800, 0xDFFF, 0x10FFFF]

  it "keeps a button's captured cursor and modifiers, whether or not it had a cursor, and both signed fractional scroll offsets without modifiers" $ do
    bodyOf (translateEvent (2, Glfw.ButtonInput (Glfw.ButtonEvent 1 Glfw.ButtonPressed (Just (CursorPosition 0.1 (-300.75))) Glfw.noModifiers {Glfw.modifierControl = True})))
      `shouldBe` BodyButton 1 ButtonActionPress (Just (0.1, -300.75)) none {modControl = True}
    bodyOf (translateEvent (2, Glfw.ButtonInput (Glfw.ButtonEvent 0 Glfw.ButtonReleased Nothing Glfw.noModifiers)))
      `shouldBe` BodyButton 0 ButtonActionRelease Nothing none
    bodyOf (translateEvent (2, Glfw.ScrollInput (Glfw.ScrollEvent (-2.5) 0.125))) `shouldBe` BodyScroll (-2.5) 0.125
    bodyOf (translateEvent (2, Glfw.FocusInput False)) `shouldBe` BodyFocus False

  it "reports each observed attribute and leaves each unavailable one absent, widens a scale exactly, and keeps a zero drawable extent" $ do
    translateObservation (SourceObservation 5 (Observed True) (Just (CursorPosition 1.5 (-2))) (Just False) (Observed (Extent 800 600)) (Observed (Extent 0 0)) (Observed (ContentScale oneTenth 2)))
      `shouldBe` InputObservation 5 (Just True) (Just (1.5, -2)) (Just False) (Just (800, 600)) (Just (0, 0)) (Just (float2Double oneTenth, 2))
    -- not 1.1 as a double: a single-precision value widens exactly and is never rounded again
    fmap fst (observationScale (translateObservation (SourceObservation 0 Unavailable Nothing Nothing Unavailable Unavailable (Observed (ContentScale oneTenth 1)))))
      `shouldNotBe` Just (1.1 ∷ Double)
    translateObservation (SourceObservation 3 Unavailable Nothing Nothing Unavailable Unavailable Unavailable)
      `shouldBe` InputObservation 3 Nothing Nothing Nothing Nothing Nothing Nothing

  it "makes a token key of the consumer and the order it was issued in, and takes it apart again, at the edges of both" $ do
    mapM_ (\(consumer, order) → tokenParts (tokenKey consumer order) `shouldBe` (consumer, order)) [(1, 1), (maxBound, maxBound), (1, maxBound), (maxBound, 1)]
    tokenKey 1 1 `shouldNotBe` tokenKey 2 1
    tokenKey 1 1 `shouldNotBe` tokenKey 1 2
  where
    none = InputModifiers False False False False False False
    bodyOf = eventBody

consumerSpec ∷ Spec
consumerSpec = describe "one consumer" $ do
  it "stops at its bound without claiming the feed empty, and says empty only when it saw the end" $
    withConsumer 10 $ \feed consumer → do
      atomically (texts feed "abcde")
      first ← poll consumer 3
      (map eventBody (packetEvents first), packetExhausted first, packetEpoch first) `shouldBe` (map (BodyText . fromEnum) "abc", False, 1)
      second ← poll consumer 3
      (map eventBody (packetEvents second), packetExhausted second) `shouldBe` (map (BodyText . fromEnum) "de", True)
      -- exactly the bound again: the queue is now empty, but this poll did not look past its bound
      atomically (texts feed "xyz")
      third ← poll consumer 3
      (length (packetEvents third), packetExhausted third) `shouldBe` (3, False)
      fourth ← poll consumer 3
      (length (packetEvents fourth), packetExhausted fourth, packetDisposition fourth) `shouldBe` (0, True, DispositionRunning)

  it "delivers each event once, in order, with its epoch, however the polls divide the feed" $
    withConsumer 100 $ \feed consumer → do
      atomically (texts feed ['a' .. 'z'])
      packets ← mapM (poll consumer) [1, 5, 2, 100]
      concatMap bodiesOf packets `shouldBe` map (BodyText . fromEnum) ['a' .. 'z']
      concatMap epochsOf packets `shouldBe` replicate 26 1

  it "gates input produced before readiness, and delivers what is produced once the consumer has enabled admission" $ do
    feed ← newFeed 10
    atomically (texts feed "ab")
    atomically ((,) <$> feedGated feed <*> feedQueued feed) `shouldReturn` (2, 0)
    consumer ← atomically (newConsumer 7 (feedSource feed))
    atomically (feedLog feed) `shouldReturn` []
    atomically (consumerEnable consumer)
    atomically (feedAdmission feed) `shouldReturn` Enabled
    atomically (produce feed (text 'c'))
    packet ← poll consumer 4
    bodiesOf packet `shouldBe` [BodyText (fromEnum 'c')]
    atomically (feedLog feed) `shouldReturn` ["enable"]

  it "answers a pending reset in place of the backlog, the same token on every poll, with no history growing, and acknowledges only on request" $
    withConsumer 2 $ \feed consumer → do
      atomically (texts feed "abc")
      first ← poll consumer 8
      (packetDisposition first, packetEvents first, packetExhausted first) `shouldBe` (DispositionResetRequired, [], True)
      fmap (\reset → (resetReason reset, resetEpoch reset)) (packetReset first) `shouldBe` Just (ResetReasonOverflow, 2)
      tokenOf first `shouldBe` Just (tokenKey 7 1)
      repeated ← mapM (const (poll consumer 8)) [1 .. 50 ∷ Int]
      map tokenOf repeated `shouldBe` replicate 50 (tokenOf first)
      atomically (consumerIssued consumer) `shouldReturn` 1
      -- polling acknowledged nothing, and a feed nobody acknowledges stays paused
      atomically (feedLog feed) `shouldReturn` ["enable"]
      atomically (resumeFeed feed) `shouldReturn` False
      atomically (feedPhase feed) `shouldReturn` ResetPending

  it "acknowledges the exact reset, repeats idempotently, and shows an acknowledged feed as paused until the owner resumes it, never as running or empty" $
    withConsumer 2 $ \feed consumer → do
      atomically (texts feed "abc")
      _ ← poll consumer 8
      ack consumer 1 `shouldReturn` AckAcknowledged
      ack consumer 1 `shouldReturn` AckAlready
      paused ← poll consumer 8
      (packetDisposition paused, packetEvents paused, packetExhausted paused) `shouldBe` (DispositionPaused, [], True)
      fmap (\reset → (resetReason reset, resetEpoch reset, resetTokenKey reset)) (packetReset paused) `shouldBe` Just (ResetReasonOverflow, 2, Nothing)
      -- what is produced while paused is suppressed and never replayed
      atomically (produce feed (text 'x'))
      atomically (feedSuppressed feed) `shouldReturn` 1
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (produce feed (text 'y'))
      resumed ← poll consumer 8
      (packetDisposition resumed, packetEpoch resumed, bodiesOf resumed, epochsOf resumed) `shouldBe` (DispositionRunning, 2, [BodyText (fromEnum 'y')], [2])

  it "refuses the resume of an acknowledged reset until the window is focused and admission is open, and a focus loss is an event and not a reset" $
    withConsumer 4 $ \feed consumer → do
      atomically (produce feed (text 'a') >> produce feed (Glfw.FocusInput False))
      packet ← poll consumer 8
      bodiesOf packet `shouldBe` [BodyText (fromEnum 'a'), BodyFocus False]
      packetDisposition packet `shouldBe` DispositionRunning
      atomically (feedPhase feed) `shouldReturn` Running
      -- gated while unfocused, and nothing was invented for what was held
      atomically (produce feed (key 65 Glfw.KeyReleased))
      poll consumer 8 >>= (`shouldBe` []) . packetEvents
      atomically (produce feed (Glfw.FocusInput True) >> produce feed (key 65 Glfw.KeyPressed))
      poll consumer 8 >>= (`shouldBe` [BodyFocus True, BodyKey 65 0 KeyActionPress (InputModifiers False False False False False False)]) . bodiesOf

  it "does not turn a key held across a reset into a new press, or invent its release" $
    withConsumer 2 $ \feed consumer → do
      atomically (produce feed (key 65 Glfw.KeyPressed))
      held ← poll consumer 8
      length (packetEvents held) `shouldBe` 1
      atomically (texts feed "xyz")
      reset ← poll consumer 8
      packetDisposition reset `shouldBe` DispositionResetRequired
      ack consumer 1 `shouldReturn` AckAcknowledged
      atomically (resumeFeed feed) `shouldReturn` True
      -- the key is still physically down: its repeat and its release are not in the new epoch, and nothing pairs them
      atomically (produce feed (key 65 Glfw.KeyRepeated) >> produce feed (key 65 Glfw.KeyReleased))
      poll consumer 8 >>= (`shouldBe` []) . packetEvents
      atomically (produce feed (key 65 Glfw.KeyPressed))
      poll consumer 8 >>= (`shouldBe` 1) . length . packetEvents

  it "gives a newer reset a newer token, answers an older token stale without touching the feed, and refuses a token it never issued" $
    withConsumer 2 $ \feed consumer → do
      atomically (texts feed "abc")
      first ← poll consumer 8
      ack consumer 1 `shouldReturn` AckAcknowledged
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (texts feed "def")
      second ← poll consumer 8
      tokenOf second `shouldBe` Just (tokenKey 7 2)
      tokenOf second `shouldNotBe` tokenOf first
      fmap resetEpoch (packetReset second) `shouldBe` Just 3
      atomically (consumerIssued consumer) `shouldReturn` 2
      logged ← atomically (feedLog feed)
      ack consumer 1 `shouldReturn` AckStale
      -- the old token reached nothing: the feed was not asked, and the newer reset is still pending
      atomically (feedLog feed) `shouldReturn` logged
      atomically (feedPhase feed) `shouldReturn` ResetPending
      ack consumer 2 `shouldReturn` AckAcknowledged
      ack consumer 0 >>= (`shouldSatisfy` isRefused)
      ack consumer 3 >>= (`shouldSatisfy` isRefused)

  it "lets closure win over every acknowledgement and every read, the current token and an older one alike, without waiting for any" $
    withConsumer 2 $ \feed consumer → do
      atomically (texts feed "abc")
      _ ← poll consumer 8
      ack consumer 1 `shouldReturn` AckAcknowledged
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (texts feed "def")
      _ ← poll consumer 8
      atomically (closeFeed feed)
      closed ← poll consumer 8
      (packetDisposition closed, packetEvents closed, packetExhausted closed, packetReset closed) `shouldBe` (DispositionClosed, [], True, Nothing)
      ack consumer 2 `shouldReturn` AckClosed
      ack consumer 1 `shouldReturn` AckClosed

  it "reads a reset that was committed first instead of its backlog, and a batch it already took whole, and never mixes epochs" $ do
    -- the poll first: the batch is the consumer's, whole and of the old epoch, and the reset is the next poll's
    withConsumer 3 $ \feed consumer → do
      atomically (texts feed "ab")
      batch ← poll consumer 8
      epochsOf batch `shouldBe` [1, 1]
      atomically (texts feed "cdef")
      next ← poll consumer 8
      (packetDisposition next, packetEvents next) `shouldBe` (DispositionResetRequired, [])
    -- the reset first: its backlog is gone, and nothing of the old epoch is in the poll
    withConsumer 3 $ \feed consumer → do
      atomically (texts feed "abcd")
      batch ← poll consumer 8
      (packetDisposition batch, packetEvents batch) `shouldBe` (DispositionResetRequired, [])
      ack consumer 1 `shouldReturn` AckAcknowledged
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (produce feed (text 'z'))
      fresh ← poll consumer 8
      epochsOf fresh `shouldBe` [2]

  it "never mixes epochs, repeats an event or reorders one when a producer overflows the feed and the owner resumes it while the consumer polls and acknowledges (a concurrent run)" $
    bounded $ do
      feed ← newFeed 3
      consumer ← atomically (newConsumer 7 (feedSource feed))
      atomically (consumerEnable consumer)
      done ← newTVarIO False
      delivered ← newIORef (0 ∷ Int)
      resets ← newIORef (0 ∷ Int)
      let rounds = 400 ∷ Int
          -- the producer is the window's owner. A round starts only once the consumer has drained the last one and no reset still
          -- awaits its acknowledgement (it waits on the feed's own state, not on a clock). An ordinary round resumes what the
          -- consumer acknowledged and produces two numbered events, each in a transaction of its own, so a poll can land between
          -- them; every tenth round produces five in one transaction, which overflows the three-event feed whatever the consumer does.
          producer = do
            forM_ [1 .. rounds] $ \r → do
              atomically $ do
                phase ← feedPhase feed
                queued ← feedQueued feed
                when (phase == ResetPending || queued > 0) retry
              let event k = produce feed (key (r * 10 + k) Glfw.KeyPressed)
              if r `mod` 10 == 0
                then atomically (resumeFeed feed >> mapM_ event [1 .. 5])
                else forM_ [1, 2] $ \k → atomically (resumeFeed feed >> event k)
            atomically (writeTVar done True)
          consume lastCode = do
            -- whether the producer had finished before this poll: the poll that follows has then seen everything it produced
            finished ← readTVarIO done
            packet ← poll consumer 4
            let codes = [code | InputEventRecord _ (BodyKey code _ _ _) ← packetEvents packet]
            -- every event of a packet is of the packet's one epoch, and the codes only ever rise: nothing repeats or reorders
            map eventEpoch (packetEvents packet) `shouldBe` replicate (length codes) (packetEpoch packet)
            and (zipWith (<) (lastCode : codes) codes) `shouldBe` True
            case packetReset packet >>= resetTokenKey of
              Just token → do
                ack consumer (fromIntegral (snd (tokenParts token))) >>= (`shouldSatisfy` (`elem` [AckAcknowledged, AckAlready]))
                modifyIORef' resets (+ 1)
              Nothing → pure ()
            modifyIORef' delivered (+ length codes)
            queued ← atomically (feedQueued feed)
            -- done once the producer had finished before this poll, nothing is queued and no reset still awaits its acknowledgement
            -- (the owner is gone, so an acknowledged feed stays paused: that is the end of the run, not a stall)
            unless (finished && queued == 0 && packetDisposition packet /= DispositionResetRequired) (consume (maximum (lastCode : codes)))
      withOwnedThread producer $ \_ terminated → do
        consume 0
        terminated
      -- every ordinary round's two events were delivered exactly once, and every tenth round's overflow was seen once and acknowledged
      readIORef delivered >>= (`shouldBe` 2 * (rounds - rounds `div` 10))
      readIORef resets >>= (`shouldBe` rounds `div` 10)

  it "suspends admission when the consumer ends, which begins a reset that owes no acknowledgement to anyone" $
    withConsumer 4 $ \feed consumer → do
      atomically (consumerEnd consumer)
      atomically ((,) <$> feedAdmission feed <*> feedPhase feed) `shouldReturn` (Suspended, ResetPending)
      atomically (feedLog feed) `shouldReturn` ["enable", "suspend"]
  where
    isRefused = \case
      AckRefused _ → True
      _ → False
