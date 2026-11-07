{-# LANGUAGE OverloadedStrings #-}

-- | Real Lua polling a window's input through the production graphics injection (TRA-6): the CPU facade's bindings, the
-- real instance leases, the real window provider and the Lua input adapter, with the window's feed a /controlled model/
-- ("Test.LuaEngine.Graphics.InputFeed") and the windows the fake port's.
--
-- What this proves is the adapter's ownership and ordering: when admission is enabled, who may poll and acknowledge which
-- window, the reset protocol from the script's side (clear before acknowledging, nothing resumes without it), tokens that
-- name one reset and no other, closure that nothing waits behind, and bookkeeping that returns to its baseline. It is not
-- evidence of what a real window delivers: the feed is injected, and the real feed's own contract is the GLFW package's
-- suite. Nothing sleeps; an example knows what has happened from the lines the scripts printed and from transactions it
-- blocks in.
module Test.LuaEngine.Graphics.InputSession (spec) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (forM, unless, void)
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Hetoimasia.GLFW.Input as Glfw
import Hetoimasia.LuaEngine.Facade (forgetInstance)
import Hetoimasia.LuaEngine.Graphics.Input
import Hetoimasia.LuaEngine.Graphics.Window.Port (WindowToken)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (ProviderReading (..), providerReading)
import Hetoimasia.Scripting.Lua.Instance (waitInstance)
import Test.Hspec
import Test.LuaEngine.Graphics.InputFeed
import Test.LuaEngine.Graphics.PeersRig
import qualified Test.LuaEngine.Graphics.Window.Fake as WF

-- | Prepared feeds, handed to windows in the order their input is first reached, and every VM registry as it is made.
data Inputs = Inputs
  { inFeeds ∷ ![Feed]
  , inPrepared ∷ !(TVar [Feed])
  , inAssigned ∷ !(TVar (Map.Map WindowToken Feed))
  , inRegistries ∷ !(TVar [InputRegistry])
  }

newInputs ∷ Int → Int → IO Inputs
newInputs room count = do
  feeds ← forM [1 .. count] (const (newFeed room))
  Inputs feeds <$> newTVarIO feeds <*> newTVarIO Map.empty <*> newTVarIO []

inputsHost ∷ Inputs → InputHost
inputsHost inputs =
  InputHost
    { inputSource = \token → do
        assigned ← readTVar (inAssigned inputs)
        case Map.lookup token assigned of
          Just feed → pure (Just (SomeSource (feedSource feed)))
          Nothing → do
            prepared ← readTVar (inPrepared inputs)
            case prepared of
              [] → pure Nothing
              feed : rest → do
                writeTVar (inPrepared inputs) rest
                writeTVar (inAssigned inputs) (Map.insert token feed assigned)
                pure (Just (SomeSource (feedSource feed)))
    , inputObserve = \registry → atomically (modifyTVar' (inRegistries inputs) (<> [registry]))
    }

-- | The only registry the example's VM made.
theRegistry ∷ Inputs → IO InputRegistry
theRegistry inputs = atomically $ do
  found ← readTVar (inRegistries inputs)
  case found of
    registry : _ → pure registry
    [] → retry

reading ∷ Inputs → IO InputReading
reading inputs = theRegistry inputs >>= atomically . inputReading

-- | An instance that opens a window and runs this body of its update once the window is its own. Instances share one
-- export; a fixture lives in the prelude.
entry ∷ [Text] → [Text] → ByteString
entry prelude body =
  Text.encodeUtf8 . Text.unlines $
    ["local share = import('lua/share.lua')"]
      <> prelude
      <> [ "return {"
         , "  presentation = {"
         , "    every_seconds = 0.02,"
         , "    init = function(self, api)"
         , "      self.my = #share.apis + 1"
         , "      share.apis[self.my] = api"
         , "      self.w = api.window.open({title = 't', width = 64, height = 64})"
         , "    end,"
         , "    update = function(self, dt)"
         , "      local api = self.api"
         , "      if not self.win then"
         , "        if not api.request.ready(self.w) then return end"
         , "        self.win = api.request.take(self.w).value"
         , "        share.wins = share.wins or {}"
         , "        share.wins[self.my] = self.win"
         , "        print('window', self.my)"
         , "        return"
         , "      end"
         ]
      <> map ("      " <>) body
      <> ["    end", "  }", "}"]

-- | The authored consumer the contract asks for: it keeps held keys and a scroll accumulator derived from the events it
-- handled, clears them on a focus loss and before it acknowledges a reset, and acknowledges only when the example says so.
fixtureEntry ∷ ByteString
fixtureEntry =
  entry
    [ "local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end"
    , "local held, scroll = {}, 0"
    ]
    [ "local p = api.input.poll(self.win, 8)"
    , "if p.disposition == 'running' then"
    , "  for _, e in ipairs(p.events) do"
    , "    print('event', e.kind, e.epoch, e.code or e.codepoint or '', tostring(e.focused), tostring(e.action))"
    , "    if e.kind == 'key' and e.action == 'press' then held[e.code] = true"
    , "    elseif e.kind == 'key' and e.action == 'release' then held[e.code] = nil"
    , "    elseif e.kind == 'scroll' then scroll = scroll + e.scroll_y"
    , "    elseif e.kind == 'focus' and not e.focused then"
    , "      held = {}; scroll = 0"
    , "      print('cleared on focus loss', count(held), scroll)"
    , "    end"
    , "  end"
    , "elseif p.disposition == 'reset_required' then"
    , "  if not self.reset then self.reset = true print('reset', p.reset.reason, p.reset.epoch, count(held), scroll) end"
    , "  if api.session.status().stopping then"
    , "    held = {}; scroll = 0"
    , "    print('cleared', count(held), scroll)"
    , "    print('ack', api.input.acknowledgeReset(self.win, p.reset.token))"
    , "  end"
    , "elseif p.disposition == 'paused' then"
    , "  if not self.paused then self.paused = true print('paused', p.reset.epoch, p.reset.token == nil) end"
    , "end"
    ]

-- | A consumer that polls when the example says so, and does nothing else.
oneShotEntry ∷ ByteString
oneShotEntry =
  entry
    []
    [ "if not api.session.status().stopping then return end"
    , "local p = api.input.poll(self.win, 8)"
    , "if not self.first then self.first = true print('first', p.disposition, p.exhausted, #p.events) end"
    , "for _, e in ipairs(p.events) do print('event', e.kind, e.epoch, e.codepoint) end"
    ]

-- | An instance that opens a window and never touches its input.
silentEntry ∷ ByteString
silentEntry = entry [] []

key ∷ Int → Glfw.KeyAction → Glfw.InputPayload
key code action = Glfw.KeyInput (Glfw.KeyEvent code 0 action Glfw.noModifiers)

text ∷ Char → Glfw.InputPayload
text = Glfw.TextInput

-- | One character event for each character, in order.
texts ∷ Feed → String → STM ()
texts feed = mapM_ (produce feed . text)

signal ∷ Peers → IO ()
signal peers = atomically (writeTVar (peSignal peers) True)

awaitEnabled ∷ Feed → IO ()
awaitEnabled feed = atomically (feedAdmission feed >>= \admission → unless (admission == Enabled) retry)

-- | The instance ends and is forgotten, as the session does once it has seen the settlement; its window retires.
endInstance ∷ Peers → Spawned → IO ()
endInstance peers found = do
  stop peers found
  void (waitInstance (spTicket found))
  forgetInstance (peFacade peers) (spIdentity found)

awaitAcquisitions ∷ Peers → Int → IO ()
awaitAcquisitions peers wanted = atomically (providerReading (peProvider peers) >>= \found → unless (readingAcquisitions found == wanted) retry)

spec ∷ Spec
spec = describe "input through the production graphics injection" $ do
  it "enables a window's admission at the instance's first poll, registered first, gates what came before, and delivers what comes after" $ do
    inputs ← newInputs 4 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) oneShotEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      -- produced before the first poll: gated and dropped, not queued, not replayed; nothing was enabled or registered
      atomically (texts feed "ab")
      atomically ((,,) <$> feedGated feed <*> feedQueued feed <*> feedLog feed) `shouldReturn` (2, 0, [])
      atomically (feedAdmission feed) `shouldReturn` Awaiting
      reading inputs `shouldReturn` InputReading 1 0
      signal peers
      awaitLine peers "first\trunning\ttrue\t0"
      atomically (feedLog feed) `shouldReturn` ["enable"]
      reading inputs `shouldReturn` InputReading 1 1
      atomically (produce feed (text 'x'))
      awaitLine peers "event\ttext\t1\t120"
      endInstance peers first
      atomically (feedLog feed) `shouldReturn` ["enable", "suspend"]
      reading inputs `shouldReturn` InputReading 0 0
      awaitAcquisitions peers 0

  it "never enables an opted-in window nobody polls, so it never overflows, resets or owes a warning, and ends without a trace" $ do
    inputs ← newInputs 2 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) silentEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      atomically (texts feed (replicate 50 'z'))
      atomically ((,,,) <$> feedGated feed <*> feedQueued feed <*> feedPhase feed <*> feedAdmission feed) `shouldReturn` (50, 0, Running, Awaiting)
      reading inputs `shouldReturn` InputReading 1 0
      endInstance peers first
      atomically (feedLog feed) `shouldReturn` []
      reading inputs `shouldReturn` InputReading 0 0
      awaitAcquisitions peers 0

  it "runs the contract: the script clears its derived state before acknowledging, a feed nobody acknowledged stays paused, and the fresh epoch delivers only what is produced after the resume" $ do
    inputs ← newInputs 2 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) fixtureEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled feed
      atomically (produce feed (key 65 Glfw.KeyPressed) >> produce feed (Glfw.ScrollInput (Glfw.ScrollEvent 0 0.5)))
      awaitLine peers "event\tkey\t1\t65\tnil\tpress"
      awaitLine peers "event\tscroll\t1\t\tnil\tnil"
      -- overflow: the backlog is superseded by the reset, and the script's derived state still holds what it handled
      atomically (texts feed "abc")
      awaitLine peers "reset\toverflow\t2\t1\t0.5"
      atomically (feedPhase feed) `shouldReturn` ResetPending
      atomically (resumeFeed feed) `shouldReturn` False
      atomically (feedLog feed) `shouldReturn` ["enable"]
      signal peers
      awaitLine peers "cleared\t0\t0"
      awaitLine peers "ack\tacknowledged"
      awaitLine peers "paused\t2\ttrue"
      atomically (feedLog feed) `shouldReturn` ["enable", "ack 2"]
      -- acknowledged is not resumed: the script saw paused, and the owner resumes only when its own gates allow
      atomically (feedPhase feed) `shouldReturn` ResetAcknowledged
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (produce feed (key 66 Glfw.KeyPressed))
      awaitLine peers "event\tkey\t2\t66\tnil\tpress"
      printed ← readTVarIO (peOut peers)
      -- nothing the reset discarded was replayed to the script
      filter (Text.isPrefixOf "event\ttext") printed `shouldBe` []
      endInstance peers first
      reading inputs `shouldReturn` InputReading 0 0

  it "delivers a focus loss as an ordered event the script clears its state on, not as a reset and not with invented releases" $ do
    inputs ← newInputs 8 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) fixtureEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled feed
      atomically (produce feed (key 65 Glfw.KeyPressed) >> produce feed (Glfw.ScrollInput (Glfw.ScrollEvent 0 0.5)) >> produce feed (Glfw.FocusInput False))
      awaitLine peers "cleared on focus loss\t0\t0"
      awaitLine peers "event\tfocus\t1\t\tfalse\tnil"
      -- it was not a reset, and the feed never left its epoch
      atomically ((,) <$> feedPhase feed <*> feedEpoch feed) `shouldReturn` (Running, 1)
      -- what the window produces while unfocused is gated, and nothing synthesizes a release for the key that was held
      atomically (produce feed (key 65 Glfw.KeyReleased))
      atomically (feedGated feed) `shouldReturn` 1
      atomically (produce feed (Glfw.FocusInput True) >> produce feed (key 66 Glfw.KeyPressed))
      awaitLine peers "event\tkey\t1\t66\tnil\tpress"
      printed ← readTVarIO (peOut peers)
      filter (Text.isSuffixOf "release") printed `shouldBe` []
      endInstance peers first

  it "answers a token of an earlier reset stale, reaching nothing, and acknowledges only the newest reset with the newest token" $ do
    inputs ← newInputs 2 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) staleEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled feed
      atomically (texts feed "abc")
      awaitLine peers "ack1\tacknowledged"
      atomically (resumeFeed feed) `shouldReturn` True
      atomically (texts feed "def")
      awaitLine peers "distinct\ttrue\tfalse"
      awaitLine peers "stale\tstale"
      -- the old token acknowledged nothing: the feed was not asked, and the newer reset is still pending
      atomically (feedLog feed) `shouldReturn` ["enable", "ack 2"]
      atomically (feedPhase feed) `shouldReturn` ResetPending
      signal peers
      awaitLine peers "ack2\tacknowledged"
      atomically (feedLog feed) `shouldReturn` ["enable", "ack 2", "ack 3"]
      endInstance peers first

  it "answers closure before the acknowledgement, to the stale and the current token alike, and an instance that ends owing one strands nothing" $ do
    inputs ← newInputs 2 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) closureEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled feed
      atomically (texts feed "abc")
      awaitLine peers "reset"
      atomically (closeFeed feed)
      awaitLine peers "closed"
      signal peers
      awaitLine peers "ack\tclosed"
      endInstance peers first
      awaitAcquisitions peers 0
      reading inputs `shouldReturn` InputReading 0 0
    quiet ← newInputs 2 1
    let owing = inFeeds quiet !! 0
    withPeersInput (inputsHost quiet) closureEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled owing
      atomically (texts owing "abc")
      awaitLine peers "reset"
      -- the instance ends while the reset is pending and unacknowledged: its end and its window's retirement wait for nothing
      endInstance peers first
      awaitAcquisitions peers 0
      atomically (feedLog owing) `shouldReturn` ["enable", "suspend"]
      reading quiet `shouldReturn` InputReading 0 0

  it "acknowledges a reset while the host's command queue is full, which takes no command capacity, and the instance then ends as usual once the queue has room" $ do
    inputs ← newInputs 2 1
    let feed = inFeeds inputs !! 0
    withPeersInput (inputsHost inputs) fixtureEntry $ \peers → do
      first ← peAdmit peers
      awaitLine peers "window\t1"
      awaitEnabled feed
      atomically (texts feed "abc")
      awaitLine peers "reset\toverflow\t2\t0\t0"
      -- the host's bounded command queue refuses every close from here on
      WF.setCloseFull (peWindows peers) True
      signal peers
      -- the acknowledgement is one transaction on the reader: it needs no command or request capacity, and the feed is acknowledged
      awaitLine peers "ack\tacknowledged"
      atomically (feedLog feed) `shouldReturn` ["enable", "ack 2"]
      -- (a window's close waits for room in that queue, as it always did; that is the provider's, not the adapter's)
      WF.setCloseFull (peWindows peers) False
      endInstance peers first
      atomically (feedLog feed) `shouldReturn` ["enable", "ack 2", "suspend"]
      reading inputs `shouldReturn` InputReading 0 0
      awaitAcquisitions peers 0

  it "keeps two windows' feeds, epochs and tokens apart: a peer's token, window and facade are refused with nothing acknowledged or read, and ending one leaves the other's epoch and delivery alone" $ do
    inputs ← newInputs 2 2
    let one = inFeeds inputs !! 0
        two = inFeeds inputs !! 1
    withPeersInput (inputsHost inputs) peerEntry $ \peers → do
      first ← peAdmit peers
      second ← peAdmit peers
      awaitLine peers "window\t1"
      awaitLine peers "window\t2"
      awaitEnabled one
      awaitEnabled two
      atomically (texts one "abc")
      awaitLine peers "reset\t1\toverflow\t2"
      awaitLine peers "foreign\tfalse\ttrue\tfalse\tfalse\ttrue"
      -- the refused attempts reached no feed: neither acknowledged, and the peer's queue is where it was
      atomically (feedLog one) `shouldReturn` ["enable"]
      atomically (feedLog two) `shouldReturn` ["enable"]
      atomically ((,) <$> feedPhase one <*> feedPhase two) `shouldReturn` (ResetPending, Running)
      atomically (produce two (text 'q'))
      awaitLine peers "event\t2\ttext\t1\t113"
      signal peers
      awaitLine peers "ack\t1\tacknowledged"
      atomically (feedLog one) `shouldReturn` ["enable", "ack 2"]
      atomically (feedLog two) `shouldReturn` ["enable"]
      reading inputs `shouldReturn` InputReading 2 2
      -- the first instance ends: its consumer goes with it, and the second's feed, epoch and consumer are untouched
      endInstance peers first
      atomically (feedLog one) `shouldReturn` ["enable", "ack 2", "suspend"]
      atomically ((,,) <$> feedPhase two <*> feedEpoch two <*> feedLog two) `shouldReturn` (Running, 1, ["enable"])
      reading inputs `shouldReturn` InputReading 1 1
      atomically (produce two (text 'r'))
      awaitLine peers "event\t2\ttext\t1\t114"
      endInstance peers second
      atomically (feedLog two) `shouldReturn` ["enable", "suspend"]
      reading inputs `shouldReturn` InputReading 0 0
      awaitAcquisitions peers 0

staleEntry ∷ ByteString
staleEntry =
  entry
    []
    [ "local p = api.input.poll(self.win, 8)"
    , "if p.disposition == 'reset_required' then"
    , "  if p.reset.epoch == 2 and not self.t1 then"
    , "    self.t1 = p.reset.token"
    , "    print('ack1', api.input.acknowledgeReset(self.win, self.t1))"
    , "  elseif p.reset.epoch == 3 then"
    , "    if not self.t2 then"
    , "      self.t2 = p.reset.token"
    , "      print('distinct', self.t1 ~= self.t2, rawequal(self.t1, self.t2))"
    , "      print('stale', api.input.acknowledgeReset(self.win, self.t1))"
    , "    end"
    , "    if api.session.status().stopping and not self.done then self.done = true print('ack2', api.input.acknowledgeReset(self.win, self.t2)) end"
    , "  end"
    , "end"
    ]

closureEntry ∷ ByteString
closureEntry =
  entry
    []
    [ "local p = api.input.poll(self.win, 8)"
    , "if p.disposition == 'reset_required' then"
    , "  self.tok = p.reset.token"
    , "  if not self.said then self.said = true print('reset') end"
    , "elseif p.disposition == 'closed' then"
    , "  if not self.closed then self.closed = true print('closed') end"
    , "  if self.tok and api.session.status().stopping and not self.acked then"
    , "    self.acked = true"
    , "    print('ack', api.input.acknowledgeReset(self.win, self.tok))"
    , "  end"
    , "end"
    ]

peerEntry ∷ ByteString
peerEntry =
  entry
    []
    [ "if self.my == 2 and not share.polled1 then return end"
    , "local p = api.input.poll(self.win, 8)"
    , "if self.my == 1 then"
    , "  share.polled1 = true"
    , "  if p.disposition == 'reset_required' then"
    , "    share.tok = share.tok or p.reset.token"
    , "    if not self.said then self.said = true print('reset', 1, p.reset.reason, p.reset.epoch) end"
    , "    if api.session.status().stopping and not self.acked then self.acked = true print('ack', 1, api.input.acknowledgeReset(self.win, p.reset.token)) end"
    , "  end"
    , "else"
    , "  for _, e in ipairs(p.events) do print('event', 2, e.kind, e.epoch, e.codepoint) end"
    , "  if share.tok and not self.tried then"
    , "    self.tried = true"
    , "    local ok1, e1 = pcall(api.input.acknowledgeReset, self.win, share.tok)"
    , "    local ok2 = pcall(api.input.poll, share.wins[1], 1)"
    , "    local ok3, e3 = pcall(share.apis[1].input.poll, self.win, 1)"
    , "    print('foreign', ok1, tostring(e1):find('does not belong to this window', 1, true) ~= nil, ok2, ok3, tostring(e3):find('belongs to another instance', 1, true) ~= nil)"
    , "  end"
    , "end"
    ]
