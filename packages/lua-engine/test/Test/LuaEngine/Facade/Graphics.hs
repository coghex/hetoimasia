{-# LANGUAGE OverloadedStrings #-}

-- | The graphics calls of the facade (LFE-21) over /gated, injected/ services: the CPU facade's own rules, on real Lua in
-- real instances of a real supervised owner, with the providers behind it faked and counted.
--
-- What this proves is the facade: who may call, in which role and phase, with what arguments, which errors are ordinary,
-- the two-value busy answer, the exact request records and the three release answers. A refused call must have asked
-- the providers for nothing, so the fake counts every check and every start it is given. The real providers, leases and
-- windows are the graphics adapter's suites; nothing here is evidence of them.
module Test.LuaEngine.Facade.Graphics (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank)
import Hetoimasia.LuaEngine.Request (M1Ask (..), M1Start (..), m1Ask, startM1)
import Hetoimasia.LuaEngine.Scene (sceneSchema)
import Hetoimasia.Scripting.Lua.Admission (Necessity (RequiredRequest))
import Hetoimasia.Scripting.Lua.Lease (Leases, Ownership (InstanceOwned), ReleaseAnswer (..), leaseCapabilityType, newLeases, releaseLease, withLeaseOr)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Provider
  ( Adoption (Adoption)
  , Completion
  , ProviderReply (ProviderResource)
  , ProviderWork (..)
  , RequestEndpoint (..)
  , RetirementState (ProviderComplete, ProviderPending)
  , Submission (..)
  , completeRequest
  )
import Hetoimasia.Scripting.Lua.Registration (capabilityType, stateOperation, withArgumentCheck)
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SNil, SRecord), Value (VCapability, VInteger, VNil, VRecord), capability)
import Hetoimasia.LuaEngine.Profile (ByteLimit (CopiedValueBytes, DataBytes, SceneInputBytes), Profile, fixedM1Profile)
import Numeric.Natural (Natural)
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (bytesOf)

-- | What the fake providers were asked and what they hold.
data Gfx = Gfx
  { gxCalls ∷ !(IORef [Text])
  , gxBusy ∷ !(IORef Bool)
  , gxHanded ∷ !(TVar [(Text, Completion, TVar RetirementState)])
  , gxIssued ∷ !(TVar (Map.Map Word64 Text))
  , gxInput ∷ !Inp
  , gxOptions ∷ !(IORef [TextureOptions])
    -- ^ The image options each started texture request reached the service with, oldest last.
  }

newGfx ∷ IO Gfx
newGfx = Gfx <$> newIORef [] <*> newIORef False <*> newTVarIO [] <*> newTVarIO Map.empty <*> newInp <*> newIORef []

-- | The injected ordered input port: a feed the example loads, with the disposition it is in, the observation a read
-- takes and the answers an acknowledgement is told to give. Every operation it is asked to do is logged, so a refused call
-- is shown to have asked it for nothing.
data Inp = Inp
  { inLog ∷ !(IORef [Text])
  , inFeed ∷ !(TVar Feed)
  , inObservation ∷ !(TVar InputObservation)
  , inAcks ∷ !(IORef [InputAck])
  , inRefuse ∷ !(IORef (Maybe Text))
  }

data Feed = Feed
  { feedQueue ∷ ![InputEventRecord]
  , feedMode ∷ !FeedMode
  , feedEpoch ∷ !Natural
  }

data FeedMode = FeedRunning | FeedReset | FeedPaused | FeedClosed
  deriving (Eq)

newInp ∷ IO Inp
newInp = Inp <$> newIORef [] <*> newTVarIO (Feed [] FeedRunning 3) <*> newTVarIO emptyObservation <*> newIORef [] <*> newIORef Nothing

emptyObservation ∷ InputObservation
emptyObservation = InputObservation 0 Nothing Nothing Nothing Nothing Nothing Nothing

inCalls ∷ Gfx → IO [Text]
inCalls = fmap reverse . readIORef . inLog . gxInput

noteIn ∷ Inp → Text → IO ()
noteIn inp entry = atomicModifyIORef' (inLog inp) (\held → (entry : held, ()))

-- | The token key every reset the fake shows is under.
fakeTokenKey ∷ Word64
fakeTokenKey = (1 * 4294967296) + 1

fakeInput ∷ Gfx → Leases → InputServices
fakeInput gx leases =
  InputServices
    { isTypes = [leaseCapabilityTypeFor]
    , isCheckPoll = \_ key → noteIn inp "check poll" >> windowOwned key
    , isPoll = \_ _ count → do
        noteIn inp ("poll " <> Text.pack (show count))
        refused ← readIORef (inRefuse inp)
        case refused of
          Just why → pure (PollRefused why)
          Nothing → atomically $ do
            feed ← readTVar (inFeed inp)
            observation ← readTVar (inObservation inp)
            let (taken, rest) = splitAt count (feedQueue feed)
                packet disposition events exhausted reset = Polled (InputPacket disposition (feedEpoch feed) events exhausted reset observation)
            case feedMode feed of
              FeedRunning → writeTVar (inFeed inp) feed {feedQueue = rest} >> pure (packet DispositionRunning taken (length taken < count) Nothing)
              FeedReset → pure (packet DispositionResetRequired [] True (Just (InputResetInfo ResetReasonOverflow (feedEpoch feed + 1) (Just fakeTokenKey))))
              FeedPaused → pure (packet DispositionPaused [] True (Just (InputResetInfo ResetReasonOverflow (feedEpoch feed + 1) Nothing)))
              FeedClosed → pure (packet DispositionClosed [] True Nothing)
    , isCheckAcknowledge = \_ key _ → noteIn inp "check ack" >> windowOwned key
    , isAcknowledge = \_ _ _ → do
        noteIn inp "ack"
        atomicModifyIORef' (inAcks inp) $ \case
          answer : more → (more, answer)
          [] → ([], AckAcknowledged)
    }
  where
    inp = gxInput gx
    leaseCapabilityTypeFor = capabilityType graphicsInputResetType (\key → pure (key == fakeTokenKey))
    windowOwned key = withLeaseOr leases key (\why → pure (Just why)) (\(_ ∷ Text) → pure Nothing)

calls ∷ Gfx → IO [Text]
calls = fmap reverse . readIORef . gxCalls

note ∷ Gfx → Text → IO ()
note gx entry = atomicModifyIORef' (gxCalls gx) (\held → (entry : held, ()))

-- | How many of the fake's calls began with this word.
countOf ∷ Gfx → Text → IO Int
countOf gx word = length . filter (Text.isPrefixOf word) <$> calls gx

injection ∷ Gfx → GraphicsInjection
injection = injectionOpt False

-- | The same, with the ordered input port injected when asked to.
injectionOpt ∷ Bool → Gfx → GraphicsInjection
injectionOpt withInput gx = GraphicsInjection $ \vm → do
  lending ← newLending
  leases ← newLeases lending 17
  pure
    GraphicsServices
      { gsLending = lending
      , gsLeases = leases
      , gsLeaseCapacity = 17
      , gsTypes = [leaseCapabilityType leases graphicsTextureType, leaseCapabilityType leases graphicsWindowType]
      , gsEndpoints = [endpointOf "texture" (SRecord [("width", SInteger), ("height", SInteger)]), endpointOf "window" SNil]
      , gsDeclare = \identity → note gx ("declare " <> identity)
      , gsForget = \identity → note gx ("forget " <> identity)
      , gsTextureCheck = \_ _ _ _ _ _ → note gx "check texture" >> pure Nothing
      , gsTextureStart = \_ _ _ options ctx → atomicModifyIORef' (gxOptions gx) (\held → (options : held, ())) >> start vm ctx "texture" (Just textureCompose)
      , gsWindowCheck = \_ _ _ _ _ _ → note gx "check window" >> pure Nothing
      , gsWindowStart = \_ _ _ _ ctx → start vm ctx "window" (Just windowCompose)
      , gsPublish = \name precondition →
          withArgumentCheck precondition $
            stateOperation name [SCapability graphicsWindowType, sceneSchema] [] $ \_ → note gx "publish" >> pure []
      , gsIssued = \identity key → atomically (modifyTVar' (gxIssued gx) (Map.insert key identity))
      , gsReleaseCheck = \identity key → do
          owner ← Map.lookup key <$> readTVarIO (gxIssued gx)
          case owner of
            Just other | other /= identity → pure (Just "the texture belongs to another instance")
            _ → withLeaseOr leases key (\why → pure (if Text.isInfixOf "another" why then Just why else Nothing)) (\(_ ∷ Text) → pure Nothing)
      , gsRelease = \key → do
          note gx "release"
          word <$> releaseLease leases key
      , gsInput = if withInput then Just (fakeInput gx leases) else Nothing
      }
  where
    word = \case
      Released → "done"
      Retiring → "retiring"
      AlreadyReleased → "already_released"
    endpointOf name schema =
      RequestEndpoint
        { endpointName = name
        , endpointResult = schema
        , endpointSubmit = \submission → do
            retirement ← atomically (newTVar ProviderPending)
            atomically (modifyTVar' (gxHanded gx) (<> [(name, submissionCompletion submission, retirement)]))
            -- A cancelled request's work is over at once, so that an example that fails unwinds instead of waiting for what
            -- would never come.
            pure ProviderWork {workCancel = note gx ("cancel " <> name) >> atomically (writeTVar retirement ProviderComplete), workRetirement = readTVar retirement}
        }
    start vm ctx name composed = do
      busy ← readIORef (gxBusy gx)
      if busy
        then note gx ("busy " <> name) >> pure (GraphicsStarted (M1Busy "a bank is full"))
        else do
          note gx ("start " <> name)
          started ←
            startM1
              (gvRequests vm)
              ((m1Ask RequiredRequest name) {askCodes = if name == "window" then ["window_error"] else ["not_found"], askLease = composed})
              ctx
              name
              []
              (pure ())
          pure (GraphicsStarted started)
    textureCompose = (InstanceOwned, \value key → case value of
      VRecord fields → VRecord (("texture", VCapability (capability graphicsTextureType key)) : fields)
      other → other)
    windowCompose = (InstanceOwned, \_ key → VCapability (capability graphicsWindowType key))

awaitHanded ∷ Gfx → Int → IO ()
awaitHanded gx wanted = atomically (readTVar (gxHanded gx) >>= \held → if length held >= wanted then pure () else retry)

-- | The provider answers the nth handed request.
handed ∷ Gfx → Int → IO (Text, Completion)
handed gx index = atomically $ do
  held ← readTVar (gxHanded gx)
  case drop index held of
    (name, completion, _) : _ → pure (name, completion)
    [] → retry

-- | The provider's work for the nth request is over as it answers, so that an example that fails after the answer unwinds.
finishOne ∷ Gfx → Int → IO ()
finishOne gx index = atomically $ do
  held ← readTVar (gxHanded gx)
  case drop index held of
    (_, _, retirement) : _ → writeTVar retirement ProviderComplete
    [] → pure ()

-- | The providers prove all their work over, so that an example's teardown does not wait for what is right to wait for.
finishAll ∷ Gfx → IO ()
finishAll gx = atomically $ do
  held ← readTVar (gxHanded gx)
  mapM_ (\(_, _, retirement) → writeTVar retirement ProviderComplete) held

answerTexture ∷ Gfx → Int → IO ()
answerTexture gx index = do
  (_, completion) ← handed gx index
  finishOne gx index
  void (completeRequest completion (ProviderResource (VRecord [("width", VInteger 4), ("height", VInteger 2)]) (Adoption (\_ → resource "texture"))))

answerWindow ∷ Gfx → Int → IO ()
answerWindow gx index = do
  (_, completion) ← handed gx index
  finishOne gx index
  void (completeRequest completion (ProviderResource VNil (Adoption (\_ → resource "window"))))

resource ∷ Text → Assembly Text
resource name = do
  _ ← acquirePart name (releaseRank 0) (pure ()) (\_ → pure ())
  pure name

files ∷ [(FilePath, ByteString)]
files = [("images/quad.png", "png")]

-- | A case: a label, the Lua expression run under @pcall@ and what it must have come to.
data Verdict = Refused [Text] | Accepted | Holds

data Case = Case Text Text Verdict

caseLua ∷ Case → Text
caseLua (Case label expression _) = "try(" <> Text.pack (show (Text.unpack label)) <> ", function() return " <> expression <> " end)"

checkCases ∷ [Case] → [Text] → Expectation
checkCases cases printed = mapM_ check cases
  where
    check (Case label _ verdict) = case [Text.drop (Text.length prefix) line | line ← printed, prefix `Text.isPrefixOf` line] of
      [seen] → case verdict of
        Accepted
          | "true" `Text.isPrefixOf` seen → pure ()
          | otherwise → expectationFailure (show label <> " must be accepted, but: " <> Text.unpack seen)
        -- A predicate: the call returned, and what it returned is true (not merely that nothing raised).
        Holds
          | "true ; true" `Text.isPrefixOf` seen → pure ()
          | otherwise → expectationFailure (show label <> " must hold, but: " <> Text.unpack seen)
        Refused reasons
          | "false ; " `Text.isPrefixOf` seen && all (`Text.isInfixOf` seen) reasons → pure ()
          | otherwise → expectationFailure (show label <> " must be refused with " <> show reasons <> ", but: " <> Text.unpack seen)
      other → expectationFailure ("the case " <> show label <> " printed " <> show (length other) <> " lines; printed: " <> show printed)
      where
        prefix = label <> " => "

-- | Run the cases in a hook of an instance of this role over a fresh fake, and check what it printed.
inInit ∷ Role → [Case] → (Gfx → Expectation) → Expectation
inInit role cases afterwards = do
  gx ← newGfx
  ( withOneGraphics (injection gx) role script {scInit = map caseLua cases} files $ \world _ _ _ → do
      outLines world >>= checkCases cases
      afterwards gx
      finishAll gx
    )
    `finally` finishAll gx

spec ∷ Spec
spec = describe "graphics calls" $ do
  it "refuses, as ordinary errors and before any provider is asked, every misshapen texture, window, publish and release call" $
    inInit
      Presentation
      [ Case "texture colon" "api.content:texture('images/quad.png')" (Refused ["content_texture"])
      , Case "texture no arguments" "api.content.texture()" (Refused ["expected 2 values, found 0"])
      , Case "texture extra argument" "api.content.texture('images/quad.png', nil, nil)" (Refused ["expected 2 values, found 3"])
      , Case "texture path number" "api.content.texture(42)" (Refused ["expected byte string"])
      , Case "texture options string" "api.content.texture('images/quad.png', 'x')" (Refused ["expected record"])
      , Case "texture tick offset 1" "api.content.texture('images/quad.png', {tick_offset = 1})" (Refused ["unknown field tick_offset"])
      , Case "texture tick offset" "api.content.texture('images/quad.png', {tick_offset = 2})" (Refused ["unknown field tick_offset"])
      , Case "texture unknown option" "api.content.texture('images/quad.png', {bogus = 1})" (Refused ["unknown field bogus"])
      , Case "texture optional string" "api.content.texture('images/quad.png', {optional = 'yes'})" (Refused ["expected boolean"])
      , Case "texture options metatable" "api.content.texture('images/quad.png', setmetatable({}, {__index = function() error('boom') end}))" (Refused ["metatable"])
      , Case "texture kind unknown" "api.content.texture('images/quad.png', {kind = 'video'})" (Refused ["kind must be"])
      , Case "texture kind case" "api.content.texture('images/quad.png', {kind = 'Data'})" (Refused ["kind must be"])
      , Case "texture kind number" "api.content.texture('images/quad.png', {kind = 1})" (Refused ["expected text"])
      , Case "texture coverage unknown" "api.content.texture('images/quad.png', {coverage = 'alpha'})" (Refused ["coverage must be"])
      , Case "texture coverage boolean" "api.content.texture('images/quad.png', {coverage = true})" (Refused ["expected text"])
      , Case "texture encoding unknown" "api.content.texture('images/quad.png', {kind = 'data', normal_encoding = 'bogus'})" (Refused ["normal_encoding must be"])
      , Case "texture encoding version" "api.content.texture('images/quad.png', {kind = 'data', normal_encoding = 'unit-normal-rgb-v2'})" (Refused ["normal_encoding must be"])
      , Case "texture encoding number" "api.content.texture('images/quad.png', {kind = 'data', normal_encoding = 5})" (Refused ["expected text"])
      , Case "texture encoding without kind" "api.content.texture('images/quad.png', {normal_encoding = 'unit-normal-rgb-v1'})" (Refused ["valid only with kind"])
      , Case "texture encoding with colour" "api.content.texture('images/quad.png', {kind = 'colour', normal_encoding = 'unit-normal-rgb-v1'})" (Refused ["valid only with kind"])
      , Case "texture encoding with nil kind" "api.content.texture('images/quad.png', {kind = nil, normal_encoding = 'unit-normal-rgb-v1'})" (Refused ["valid only with kind"])
      , Case "texture root number" "api.content.texture('images/quad.png', {root = 5})" (Refused ["expected text"])
      , Case "texture root not enabled" "api.content.texture('images/quad.png', {root = 'other'})" (Refused ["is not enabled"])
      , Case "texture root uppercase" "api.content.texture('images/quad.png', {root = 'Game'})" (Refused ["is not a content identifier"])
      , Case "texture path with dots" "api.content.texture('../quad.png')" (Refused ["not a content address"])
      , Case "texture path with a backslash" "api.content.texture('images\\\\quad.png')" (Refused ["not a content address"])
      , Case "window colon" "api.window:open({title = 't', width = 1, height = 1})" (Refused ["window_open"])
      , Case "window no arguments" "api.window.open()" (Refused ["expected 1 values, found 0"])
      , Case "window extra argument" "api.window.open({title = 't', width = 1, height = 1}, nil)" (Refused ["expected 1 values, found 2"])
      , Case "window not a table" "api.window.open('t')" (Refused ["expected record"])
      , Case "window missing width" "api.window.open({title = 't', height = 1})" (Refused ["width"])
      , Case "window extra field" "api.window.open({title = 't', width = 1, height = 1, x = 1})" (Refused ["unknown field x"])
      , Case "window float width" "api.window.open({title = 't', width = 1.0, height = 1})" (Refused ["a float where an integer is declared"])
      , Case "window numeric string height" "api.window.open({title = 't', width = 1, height = '1'})" (Refused ["expected integer"])
      , Case "window title number" "api.window.open({title = 5, width = 1, height = 1})" (Refused ["expected byte string"])
      , Case "window metatable" "api.window.open(setmetatable({title = 't', width = 1, height = 1}, {}))" (Refused ["metatable"])
      , Case "publish no arguments" "api.scene.publish()" (Refused ["expected 2 values, found 0"])
      , Case "publish colon" "api.scene:publish({}, {})" (Refused ["scene_publish"])
      , Case "publish not a window" "api.scene.publish({}, {clear = {r = 0, g = 0, b = 0}, sprites = {}})" (Refused ["expected capability"])
      , Case "release no arguments" "api.texture.release()" (Refused ["expected 1 values, found 0"])
      , Case "release colon" "api.texture:release(1)" (Refused ["texture_release"])
      , Case "release not a texture" "api.texture.release('x')" (Refused ["expected capability"])
      ]
      $ \gx → do
        -- Nothing a refused call did reached a provider: not a check, not a start.
        seen ← calls gx
        filter (\entry → any (`Text.isPrefixOf` entry) ["check", "start", "busy", "publish", "release"]) seen `shouldBe` []

  it "takes the image options of a texture request, parses them once, and starts each request with exactly the options asked for" $ do
    gx ← newGfx
    let cases =
          [ Case "default" "api.content.texture('images/quad.png')" Accepted
          , Case "colour" "api.content.texture('images/quad.png', {kind = 'colour'})" Accepted
          , Case "data" "api.content.texture('images/quad.png', {kind = 'data'})" Accepted
          , Case "coverage" "api.content.texture('images/quad.png', {coverage = 'binary'})" Accepted
          , Case "data coverage" "api.content.texture('images/quad.png', {kind = 'data', coverage = 'binary'})" Accepted
          , Case "encoding alone" "api.content.texture('images/quad.png', {kind = 'data', normal_encoding = 'unit-normal-rgb-v1'})" Accepted
          , Case "all" "api.content.texture('images/quad.png', {kind = 'data', coverage = 'binary', normal_encoding = 'unit-normal-rgb-v1', optional = true})" Accepted
          , Case "nil fields" "api.content.texture('images/quad.png', {kind = nil, coverage = nil, normal_encoding = nil})" Accepted
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = map caseLua cases} files $ \world _ _ _ → do
        outLines world >>= checkCases cases
        countOf gx "start texture" `shouldReturn` length cases
        reverse <$> readIORef (gxOptions gx)
          `shouldReturn` [ TextureOptions ImageColour False Nothing
                         , TextureOptions ImageColour False Nothing
                         , TextureOptions ImageData False Nothing
                         , TextureOptions ImageColour True Nothing
                         , TextureOptions ImageData True Nothing
                         , TextureOptions ImageData False (Just "unit-normal-rgb-v1")
                         , TextureOptions ImageData True (Just "unit-normal-rgb-v1")
                         , TextureOptions ImageColour False Nothing
                         ]
        finishAll gx
      )
      `finally` finishAll gx

  it "takes a valid texture and window call, nil and absent options alike, with false a value, and starts each once" $ do
    gx ← newGfx
    let cases =
          [ Case "texture bare" "api.content.texture('images/quad.png')" Accepted
          , Case "texture nil options" "api.content.texture('images/quad.png', nil)" Accepted
          , Case "texture empty options" "api.content.texture('images/quad.png', {})" Accepted
          , Case "texture nil fields" "api.content.texture('images/quad.png', {root = nil, optional = nil})" Accepted
          , Case "texture optional false" "api.content.texture('images/quad.png', {optional = false})" Accepted
          , Case "texture own root" "api.content.texture('images/quad.png', {root = 'modules-test', optional = true})" Accepted
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = map caseLua cases} files $ \world _ _ _ → do
        outLines world >>= checkCases cases
        countOf gx "start texture" `shouldReturn` length cases
        finishAll gx
      )
      `finally` finishAll gx

  it "refuses the logical role's graphics calls as ordinary errors before any provider is asked" $ do
    let cases =
          [ Case "logical texture" "api.content.texture('images/quad.png')" (Refused ["presentation role only"])
          , Case "logical window" "api.window.open({title = 't', width = 1, height = 1})" (Refused ["presentation role only"])
          , Case "logical release" "api.texture.release(1)" (Refused ["presentation role only"])
          ]
    inInit Gameplay cases $ \gx → do
      seen ← calls gx
      filter (\entry → any (`Text.isPrefixOf` entry) ["check", "start", "busy"]) seen `shouldBe` []

  it "answers a busy bank with exactly nil and the busy record, no handle and no start, and an explicit retry then succeeds once the bank has room" $ do
    gx ← newGfx
    writeIORef (gxBusy gx) True
    let cases =
          [ Case "busy texture" "(function() local r, e = api.content.texture('images/quad.png') return r == nil and e.code == 'busy' and type(e.message) == 'string' and select('#', api.content.texture('images/quad.png')) == 2 end)()" Holds
          , Case "busy window" "(function() local r, e = api.window.open({title = 't', width = 2, height = 2}) return r == nil and e.code == 'busy' end)()" Holds
          ]
        retrying =
          [ "if self.ran then return end"
          , "self.ran = true"
          , "local r, e = api.content.texture('images/quad.png')"
          , "print('retry', r ~= nil, e == nil)"
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = map caseLua cases, scUpdate = retrying} files $ \world _ _ _ → do
        outLines world >>= checkCases cases
        countOf gx "start" `shouldReturn` 0
        -- The bank has room again: Lua alone retries, on a later update, and the request is accepted and started once.
        writeIORef (gxBusy gx) False
        advanceClock world 2000000000
        pumpUntil world (elem "retry\ttrue\ttrue" <$> outLines world)
        countOf gx "start texture" `shouldReturn` 1
        finishAll gx
      )
      `finally` finishAll gx

  it "refuses another instance's facade and handle, and leaves a peer's graphics resources usable when one same-VM instance ends" $ do
    gx ← newGfx
    let live =
          [ Case "foreign facade window" "share.apis[1].window.open({title = 't', width = 1, height = 1})" (Refused ["belongs to another instance"])
          , Case "foreign handle, live" "api.texture.release(share.texs[1])" (Refused ["belongs to another instance"])
          ]
        retired =
          [ Case "foreign handle, retired" "api.texture.release(share.texs[1])" (Refused ["belongs to another instance"])
          , Case "own release" "api.texture.release(self.tex) == 'done'" Holds
          ]
        cases = live <> retired
        prelude = ["local share = import('lua/share.lua')"]
        initial = ["self.my = #share.apis + 1", "share.apis[self.my] = api", "self.t = api.content.texture('images/quad.png')"]
        updating =
          [ "if self.done then"
          , "  if share.ended and not self.said then self.said = true print('peer', api.texture.release(self.tex)) end"
          , "  return"
          , "end"
          , "if not self.tex then"
          , "  if not api.request.ready(self.t) then return end"
          , "  self.tex = api.request.take(self.t).value.texture"
          , "  share.texs[self.my] = self.tex"
          , "end"
          , "if self.my == 1 then"
          , -- the first instance releases its own texture once the second has tried the live one: it retires completely
            "  if share.b1 and not self.rel then self.rel = true print('a released', api.texture.release(self.tex)) share.a_done = true end"
          , "  return"
          , "end"
          , "if not share.texs[1] then return end"
          , "if not share.b1 then"
          , "  share.b1 = true"
          ]
            <> map (("  " <>) . caseLua) live
            <> [ "  return"
               , "end"
               , "if share.a_done then"
               , "  self.done = true"
               ]
            <> map (("  " <>) . caseLua) retired
            <> ["  print('b done')", "end"]
        shared = ("lua/share.lua", luaMain ["return {apis = {}, texs = {}}"])
    ( withWorld fixedM1Profile (Layout (("lua/main.lua", scriptSource script {scPrelude = prelude <> [], scInit = initial, scUpdate = updating, scShutdown = ["share.ended = true"]}) : shared : files)) $ \world _ runtime →
        withFvm world runtime ((presentationShape) {shGraphics = Just (injection gx)}) $ \fvm → do
          first ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          awaitHanded gx 2
          answerTexture gx 0
          answerTexture gx 1
          -- (the clock moves on with every look, so each instance's cadence comes round as often as it needs to)
          pumpUntil world (advanceClock world 1100000000 >> (elem "b done" <$> outLines world))
          outLines world >>= checkCases cases
          -- The first instance ends; the second's own texture is still its to use, and releasing it again is
          -- already_released, not an error about a lease that went with the peer.
          stopSpawned first
          _ ← settledOf first
          pumpUntil world (advanceClock world 1100000000 >> (elem "peer\talready_released" <$> outLines world))
          finishAll gx
      )
      `finally` finishAll gx

  it "delivers the exact texture and window records, with integer dimensions, and the release answers done then already_released" $ do
    gx ← newGfx
    let setup =
          [ "self.t = api.content.texture('images/quad.png')"
          , "self.w = api.window.open({title = 'Lua quad', width = 640, height = 480})"
          , "print('pending', api.request.take(self.t).status, api.request.take(self.w).status)"
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = setup, scUpdate = updateLua} files $ \world _ _ _ → do
      awaitHanded gx 2
      answerTexture gx 0
      answerWindow gx 1
      -- The presentation cadence is the injected clock's: move it past one period and let the owner look at it.
      advanceClock world 2000000000
      pumpUntil world (any (== "release\tdone\talready_released") <$> outLines world)
      outLines world >>= \printed → do
        printed `shouldSatisfy` any (== "pending\tpending\tpending")
        printed `shouldSatisfy` any (Text.isPrefixOf "result\tsuccess\tinteger\tinteger\t4\t2\twindow\tuserdata")
        printed `shouldSatisfy` any (== "release\tdone\talready_released")
        printed `shouldSatisfy` any (Text.isPrefixOf "consumed\tfalse\t")
        finishAll gx
      )
      `finally` finishAll gx

  it "refuses acquisition and publication once the session takes no new work, while release stays usable" $ do
    gx ← newGfx
    let setup =
          [ "self.t = api.content.texture('images/quad.png')"
          , "self.w = api.window.open({title = 't', width = 2, height = 2})"
          ]
        step =
          [ "if not self.got then"
          , "  if not (api.request.ready(self.t) and api.request.ready(self.w)) then return end"
          , "  self.tex = api.request.take(self.t).value.texture"
          , "  self.win = api.request.take(self.w).value"
          , "  self.got = true"
          , "  print('got')"
          , "  return"
          , "end"
          , "if self.cased then return end"
          , "self.cased = true"
          ]
            <> map caseLua stopped
            <> ["print('cased')"]
        stopped =
          [ Case "stopped texture" "api.content.texture('images/quad.png')" (Refused ["the session is stopping"])
          , Case "stopped window" "api.window.open({title = 't', width = 2, height = 2})" (Refused ["the session is stopping"])
          , Case "stopped publish" "api.scene.publish(self.win, {clear = {r = 0, g = 0, b = 0}, sprites = {}})" (Refused ["the session is stopping"])
          , Case "stopped release" "api.texture.release(self.tex) == 'done'" Holds
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = setup, scUpdate = step, scPrelude = []} files $ \world _ _ _ → do
        awaitHanded gx 2
        answerTexture gx 0
        answerWindow gx 1
        advanceClock world 2000000000
        pumpUntil world (elem "got" <$> outLines world)
        setAdmission world AdmissionStopping
        advanceClock world 2000000000
        pumpUntil world (elem "cased" <$> outLines world)
        outLines world >>= checkCases stopped
        countOf gx "start" `shouldReturn` 2
        countOf gx "publish" `shouldReturn` 0
        finishAll gx
      )
      `finally` finishAll gx

  it "refuses acquisition in shutdown as an ordinary error, before any provider is asked" $ do
    gx ← newGfx
    let cases =
          [ Case "shutdown texture" "api.content.texture('images/quad.png')" (Refused ["not available in shutdown"])
          , Case "shutdown window" "api.window.open({title = 't', width = 2, height = 2})" (Refused ["not available in shutdown"])
          ]
    ( withOneGraphics (injection gx) Presentation script {scShutdown = map caseLua cases} files $ \world _ _ spawned → do
        stopSpawned spawned
        _ ← settledOf spawned
        outLines world >>= checkCases cases
        countOf gx "start" `shouldReturn` 0
      )
      `finally` finishAll gx
  inputSpec
  where
    updateLua =
      [ "if self.done or not api.request.ready(self.t) or not api.request.ready(self.w) then return end"
      , "self.done = true"
      , "local t = api.request.take(self.t)"
      , "local w = api.request.take(self.w)"
      , "print('result', t.status, math.type(t.value.width), math.type(t.value.height), t.value.width, t.value.height, type(w.value) == 'userdata' and 'window' or type(w.value), type(w.value))"
      , "print('consumed', pcall(api.request.ready, self.t))"
      , "local first = api.texture.release(t.value.texture)"
      , "local second = api.texture.release(t.value.texture)"
      , "print('release', first, second)"
      ]

-- Input (TRA-6) ------------------------------------------------------------------------------------------

-- | Lua helpers the input examples share: an event or a packet as one short line.
inputPrelude ∷ [Text]
inputPrelude =
  [ "local function flags(m) return (m.shift and 'S' or '-') .. (m.control and 'C' or '-') .. (m.alt and 'A' or '-') .. (m.super and 'U' or '-') .. (m.caps_lock and 'L' or '-') .. (m.num_lock and 'N' or '-') end"
  , "local function brief(e)"
  , "  local parts = {e.kind, tostring(e.epoch)}"
  , "  for _, k in ipairs({'code', 'scancode', 'action', 'codepoint', 'button', 'x', 'y', 'scroll_x', 'scroll_y', 'focused'}) do"
  , "    if e[k] ~= nil then parts[#parts + 1] = k .. '=' .. tostring(e[k]) end"
  , "  end"
  , "  if e.text ~= nil then parts[#parts + 1] = 'bytes=' .. table.concat({string.byte(e.text, 1, -1)}, ',') end"
  , "  if e.mods ~= nil then parts[#parts + 1] = 'mods=' .. flags(e.mods) end"
  , "  return table.concat(parts, ' ')"
  , "end"
  , "local function show_packet(tag, p)"
  , "  print(tag, p.disposition, p.epoch, p.exhausted, #p.events)"
  , "  for i, e in ipairs(p.events) do print(tag .. i, brief(e)) end"
  , "end"
  ]

openWindow ∷ [Text]
openWindow = ["self.w = api.window.open({title = 't', width = 2, height = 2})"]

-- | The start of every update: take the window once it is there, and run the rest once.
takeWindow ∷ [Text]
takeWindow =
  [ "if not self.win then"
  , "  if not api.request.ready(self.w) then return end"
  , "  self.win = api.request.take(self.w).value"
  , "end"
  , "if self.ran then return end"
  , "self.ran = true"
  ]

-- | A presentation instance that opens a window, takes it and then runs this Lua once with @self.win@ the handle, ending
-- with the line @ran@; then the check, over the world and the instance.
runInputWith ∷ Profile → Gfx → [Text] → [Text] → (World → Spawned → IO ()) → IO ()
runInputWith profile gx body shutdown check =
  ( withWorld profile (Layout [("lua/main.lua", scriptSource found)]) $ \world _ runtime →
      withFvm world runtime (presentationShape {shGraphics = Just (injectionOpt True gx)}) $ \fvm → do
        spawned ← spawn world fvm "modules-test" mainPath
        awaitHanded gx 1
        answerWindow gx 0
        pumpUntil world (advanceClock world 2000000000 >> (elem "ran" <$> outLines world))
        check world spawned
        finishAll gx
  )
    `finally` finishAll gx
  where
    found = script {scPrelude = dumpPrelude <> inputPrelude, scInit = openWindow, scUpdate = takeWindow <> body <> ["print('ran')"], scShutdown = shutdown}

runInput ∷ Gfx → [Text] → [Text] → (World → Spawned → IO ()) → IO ()
runInput = runInputWith fixedM1Profile

shiftMods, ctrlMods, noMods ∷ InputModifiers
shiftMods = InputModifiers True False False False False False
ctrlMods = InputModifiers False True False False False False
noMods = InputModifiers False False False False False False

-- | Every kind of event, in one epoch.
orderedEvents ∷ [InputEventRecord]
orderedEvents =
  map
    (InputEventRecord 3)
    [ BodyKey 65 30 KeyActionPress shiftMods
    , BodyKey 65 30 KeyActionRepeat shiftMods
    , BodyKey 65 30 KeyActionRelease noMods
    , BodyText 65
    , BodyText 233
    , BodyText 0xD800
    , BodyButton 0 ButtonActionPress (Just (10.5, -3.25)) ctrlMods
    , BodyButton 0 ButtonActionRelease Nothing noMods
    , BodyScroll (-1.5) 0.25
    , BodyFocus False
    , BodyFocus True
    ]

loadFeed ∷ Gfx → [InputEventRecord] → FeedMode → IO ()
loadFeed gx events mode = atomically (writeTVar (inFeed (gxInput gx)) (Feed events mode 3))

-- | What the feed still holds.
remaining ∷ Gfx → IO Int
remaining gx = length . feedQueue <$> readTVarIO (inFeed (gxInput gx))

inputSpec ∷ Spec
inputSpec = describe "input calls" $ do
  it "polls a synthetic ordered sequence as a prefix and then the remainder, with exact payloads, order and epoch, and no false empty" $ do
    gx ← newGfx
    loadFeed gx orderedEvents FeedRunning
    runInput
      gx
      [ "show_packet('a', api.input.poll(self.win, 4))"
      , "show_packet('b', api.input.poll(self.win, 4))"
      , "show_packet('c', api.input.poll(self.win, 4))"
      ]
      []
      $ \world _ → do
        outLines world
          >>= ( `shouldBe`
                  [ "a\trunning\t3\tfalse\t4"
                  , "a1\tkey 3 code=65 scancode=30 action=press mods=S-----"
                  , "a2\tkey 3 code=65 scancode=30 action=repeat mods=S-----"
                  , "a3\tkey 3 code=65 scancode=30 action=release mods=------"
                  , "a4\ttext 3 codepoint=65 bytes=65"
                  , "b\trunning\t3\tfalse\t4"
                  , "b1\ttext 3 codepoint=233 bytes=195,169"
                  , -- a surrogate has no UTF-8 text: the exact code point, and no substitute character
                    "b2\ttext 3 codepoint=55296"
                  , "b3\tbutton 3 action=press button=0 x=10.5 y=-3.25 mods=-C----"
                  , "b4\tbutton 3 action=release button=0 mods=------"
                  , "c\trunning\t3\ttrue\t3"
                  , "c1\tscroll 3 scroll_x=-1.5 scroll_y=0.25"
                  , "c2\tfocus 3 focused=false"
                  , "c3\tfocus 3 focused=true"
                  , "ran"
                  ]
              )
        inCalls gx `shouldReturn` ["check poll", "poll 4", "check poll", "poll 4", "check poll", "poll 4"]
        remaining gx `shouldReturn` 0

  it "carries 128 events in one packet, then the rest, under the fixed profile" $ do
    gx ← newGfx
    loadFeed gx (replicate 130 (InputEventRecord 3 (BodyButton 7 ButtonActionRelease (Just (1.5, 2.5)) (InputModifiers True True True True True True)))) FeedRunning
    runInput gx ["local a = api.input.poll(self.win, 128)", "local b = api.input.poll(self.win, 128)", "print(#a.events, a.exhausted, #b.events, b.exhausted)"] [] $ \world _ →
      outLines world >>= (`shouldBe` ["128\tfalse\t2\ttrue", "ran"])

  it "reports the observation of the same read: latest cursor and focus, logical and framebuffer extents and the content scale" $ do
    gx ← newGfx
    atomically (writeTVar (inObservation (gxInput gx)) (InputObservation 7 (Just False) (Just (-2.5, 100.75)) (Just False) (Just (800, 600)) (Just (1600, 1200)) (Just (2.0, 1.5))))
    runInput gx ["print(dump(api.input.poll(self.win, 1).observation))"] [] $ \world _ →
      outLines world
        >>= ( `shouldBe`
                [ "{cursor={x=-2.5,y=100.75},cursor_inside=false,focused=false,framebuffer={height=1200,width=1600},logical={height=600,width=800},revision=7,scale={x=2.0,y=1.5}}"
                , "ran"
                ]
            )

  it "leaves an unavailable attribute absent rather than zero, and keeps a zero drawable extent" $ do
    gx ← newGfx
    atomically (writeTVar (inObservation (gxInput gx)) (InputObservation 8 Nothing Nothing Nothing Nothing (Just (0, 0)) Nothing))
    runInput gx ["print(dump(api.input.poll(self.win, 1).observation))"] [] $ \world _ →
      outLines world >>= (`shouldBe` ["{framebuffer={height=0,width=0},revision=8}", "ran"])

  it "shows a reset's reason, reserved epoch and token, a paused feed's reset without a token, and a closed feed" $ do
    gx ← newGfx
    loadFeed gx [] FeedReset
    runInput gx ["local p = api.input.poll(self.win, 1)", "print(p.disposition, p.epoch, p.exhausted, #p.events, p.reset.reason, p.reset.epoch, type(p.reset.token))", "local q = api.input.poll(self.win, 1)", "print(rawequal(p.reset.token, q.reset.token), p.reset.token == q.reset.token)"] [] $ \world _ →
      outLines world >>= (`shouldBe` ["reset_required\t3\ttrue\t0\toverflow\t4\tuserdata", "false\ttrue", "ran"])
    paused ← newGfx
    loadFeed paused [] FeedPaused
    runInput paused ["local p = api.input.poll(self.win, 1)", "print(p.disposition, p.reset.reason, p.reset.epoch, p.reset.token == nil, #p.events)"] [] $ \world _ →
      outLines world >>= (`shouldBe` ["paused\toverflow\t4\ttrue\t0", "ran"])
    closed ← newGfx
    loadFeed closed [] FeedClosed
    runInput closed ["local p = api.input.poll(self.win, 1)", "print(p.disposition, p.reset == nil, #p.events, p.exhausted)"] [] $ \world _ →
      outLines world >>= (`shouldBe` ["closed\ttrue\t0\ttrue", "ran"])

  it "refuses every misshapen or out-of-range call as an ordinary error before a single event is read or acknowledged" $ do
    gx ← newGfx
    loadFeed gx orderedEvents FeedRunning
    let cases =
          [ Case "poll colon" "api.input:poll(self.win, 1)" (Refused ["input_poll"])
          , Case "poll no arguments" "api.input.poll()" (Refused ["expected 2 values, found 0"])
          , Case "poll one argument" "api.input.poll(self.win)" (Refused ["expected 2 values, found 1"])
          , Case "poll extra argument" "api.input.poll(self.win, 1, nil)" (Refused ["expected 2 values, found 3"])
          , Case "poll explicit nil count" "api.input.poll(self.win, nil)" (Refused ["expected integer"])
          , Case "poll integral float" "api.input.poll(self.win, 3.0)" (Refused ["a float where an integer is declared"])
          , Case "poll float" "api.input.poll(self.win, 1.5)" (Refused ["a float where an integer is declared"])
          , Case "poll numeric string" "api.input.poll(self.win, '3')" (Refused ["expected integer"])
          , Case "poll zero" "api.input.poll(self.win, 0)" (Refused ["from 1 to 128"])
          , Case "poll negative" "api.input.poll(self.win, -1)" (Refused ["from 1 to 128"])
          , Case "poll 129" "api.input.poll(self.win, 129)" (Refused ["from 1 to 128"])
          , Case "poll huge" "api.input.poll(self.win, math.maxinteger)" (Refused ["from 1 to 128"])
          , Case "poll nil window" "api.input.poll(nil, 1)" (Refused ["expected capability"])
          , Case "poll number window" "api.input.poll(7, 1)" (Refused ["expected capability"])
          , Case "poll table window" "api.input.poll({}, 1)" (Refused ["expected capability"])
          , Case "poll extra options" "api.input.poll(self.win, 1, {})" (Refused ["expected 2 values, found 3"])
          , Case "ack colon" "api.input:acknowledgeReset(self.win, self.win)" (Refused ["input_acknowledge_reset"])
          , Case "ack no arguments" "api.input.acknowledgeReset()" (Refused ["expected 2 values, found 0"])
          , Case "ack one argument" "api.input.acknowledgeReset(self.win)" (Refused ["expected 2 values, found 1"])
          , Case "ack integer token" "api.input.acknowledgeReset(self.win, 1)" (Refused ["expected capability"])
          , Case "ack string token" "api.input.acknowledgeReset(self.win, 'x')" (Refused ["expected capability"])
          , Case "ack window as token" "api.input.acknowledgeReset(self.win, self.win)" (Refused [])
          ]
    runInput gx (map caseLua cases) [] $ \world _ → do
      outLines world >>= checkCases cases
      -- nothing was asked of the port, and the feed holds every event it held
      inCalls gx `shouldReturn` []
      remaining gx `shouldReturn` length orderedEvents

  it "takes one valid poll and reads exactly once after its own check" $ do
    gx ← newGfx
    loadFeed gx orderedEvents FeedRunning
    runInput gx (map caseLua [Case "valid" "api.input.poll(self.win, 1)" Accepted]) [] $ \world _ → do
      outLines world >>= checkCases [Case "valid" "" Accepted]
      inCalls gx `shouldReturn` ["check poll", "poll 1"]
      remaining gx `shouldReturn` (length orderedEvents - 1)

  it "turns a refusal that lands after the check into an ordinary error, having read nothing" $ do
    gx ← newGfx
    loadFeed gx orderedEvents FeedRunning
    writeIORef (inRefuse (gxInput gx)) (Just "the instance has ended")
    runInput gx (map caseLua [Case "late" "api.input.poll(self.win, 2)" (Refused ["the instance has ended"])] <> ["print(select('#', pcall(api.input.poll, self.win, 2)))"]) [] $ \world _ → do
      outLines world >>= \printed → printed `shouldSatisfy` (\ls → any (Text.isInfixOf "the instance has ended") ls)
      remaining gx `shouldReturn` length orderedEvents

  it "refuses polling in shutdown and to the logical role, and acknowledging to the logical role, and asks the port for nothing" $ do
    gx ← newGfx
    loadFeed gx [] FeedReset
    let shutdownCases =
          [ Case "shutdown poll" "api.input.poll(self.win, 1)" (Refused ["not available in shutdown"])
          , Case "shutdown ack" "api.input.acknowledgeReset(self.win, self.token) == 'acknowledged'" Holds
          ]
    runInput gx ["self.token = api.input.poll(self.win, 1).reset.token"] (map caseLua shutdownCases) $ \world spawned → do
      stopSpawned spawned
      _ ← settledOf spawned
      outLines world >>= checkCases shutdownCases
      -- the poll before the shutdown and the acknowledgement in it are the only reads
      inCalls gx `shouldReturn` ["check poll", "poll 1", "check ack", "ack"]
    logical ← newGfx
    let logicalCases =
          [ Case "logical poll" "api.input.poll(nil, 1)" (Refused ["presentation role only"])
          , Case "logical ack" "api.input.acknowledgeReset(nil, nil)" (Refused ["presentation role only"])
          ]
    ( withOneGraphics (injectionOpt True logical) Gameplay script {scInit = map caseLua logicalCases} [] $ \world _ _ _ → do
        outLines world >>= checkCases logicalCases
        inCalls logical `shouldReturn` []
        finishAll logical
      )
      `finally` finishAll logical

  it "refuses polling once the session takes no new work, while acknowledgement stays usable" $ do
    gx ← newGfx
    loadFeed gx [] FeedReset
    let stopped =
          [ Case "stopping poll" "api.input.poll(self.win, 1)" (Refused ["the session is stopping"])
          , Case "stopping ack" "api.input.acknowledgeReset(self.win, self.token) == 'acknowledged'" Holds
          ]
        update =
          takeWindow'
            <> ["if not self.got then self.got = true self.token = api.input.poll(self.win, 1).reset.token print('got') return end", "if self.cased then return end", "self.cased = true"]
            <> map caseLua stopped
            <> ["print('cased')"]
        takeWindow' =
          [ "if not self.win then"
          , "  if not api.request.ready(self.w) then return end"
          , "  self.win = api.request.take(self.w).value"
          , "end"
          ]
    ( withOneGraphics (injectionOpt True gx) Presentation script {scPrelude = dumpPrelude <> inputPrelude, scInit = openWindow, scUpdate = update} [] $ \world _ _ _ → do
        awaitHanded gx 1
        answerWindow gx 0
        pumpUntil world (advanceClock world 2000000000 >> (elem "got" <$> outLines world))
        setAdmission world AdmissionStopping
        pumpUntil world (advanceClock world 2000000000 >> (elem "cased" <$> outLines world))
        outLines world >>= checkCases stopped
        inCalls gx `shouldReturn` ["check poll", "poll 1", "check ack", "ack"]
        finishAll gx
      )
      `finally` finishAll gx

  it "answers each acknowledgement outcome as a word, and refuses a late-found refusal as an ordinary error" $ do
    gx ← newGfx
    loadFeed gx [] FeedReset
    writeIORef (inAcks (gxInput gx)) [AckAcknowledged, AckAlready, AckStale, AckClosed, AckRefused "the reset token does not belong to this window"]
    runInput
      gx
      [ "local p = api.input.poll(self.win, 1)"
      , "for i = 1, 5 do print('ack', i, pcall(api.input.acknowledgeReset, self.win, p.reset.token)) end"
      ]
      []
      $ \world _ → do
        printed ← outLines world
        take 4 printed
          `shouldBe` ["ack\t1\ttrue\tacknowledged", "ack\t2\ttrue\talready_acknowledged", "ack\t3\ttrue\tstale", "ack\t4\ttrue\tclosed"]
        printed !! 4 `shouldSatisfy` (\line → "ack\t5\tfalse\t" `Text.isPrefixOf` line && "does not belong to this window" `Text.isInfixOf` line)

  it "installs api.input with exactly poll and acknowledgeReset in both roles when injected, and nothing when not" $ do
    gx <- newGfx
    let probe =
          [ "local names = {}"
          , "for k in pairs(api.input or {}) do names[#names + 1] = k end"
          , "table.sort(names)"
          , "print('layout', api.role, api.input ~= nil, table.concat(names, ','), type(api.input and api.input.poll), type(api.input and api.input.acknowledgeReset))"
          ]
    withOneGraphics (injectionOpt True gx) Presentation script {scInit = probe} [] (\world _ _ _ → outLines world >>= (`shouldBe` ["layout\tpresentation\ttrue\tacknowledgeReset,poll\tfunction\tfunction"]) >> finishAll gx)
      `finally` finishAll gx
    gx' ← newGfx
    withOneGraphics (injectionOpt True gx') Gameplay script {scInit = probe} [] (\world _ _ _ → outLines world >>= (`shouldBe` ["layout\tgameplay\ttrue\tacknowledgeReset,poll\tfunction\tfunction"]) >> finishAll gx')
      `finally` finishAll gx'
    gx'' ← newGfx
    withOneGraphics (injection gx'') Presentation script {scInit = probe} [] (\world _ _ _ → outLines world >>= (`shouldBe` ["layout\tpresentation\tfalse\t\tnil\tnil"]) >> finishAll gx'')
      `finally` finishAll gx''
    withOne Presentation fixedM1Profile script {scInit = probe} (\world _ _ _ → outLines world >>= (`shouldBe` ["layout\tpresentation\tfalse\t\tnil\tnil"]))

  it "refuses a facade a module kept when its top level reaches for input, and another instance's captured facade" $ do
    gx ← newGfx
    let shared = ("lua/share.lua", luaMain ["return {apis = {}}"])
        late =
          ( "lua/late.lua"
          , luaMain $
              tryPrelude
                <> [ "local share = import('lua/share.lua')"
                   , "local api = share.apis[1]"
                   , "try('late poll', function() return api.input.poll(share.win, 1) end)"
                   , "try('late ack', function() return api.input.acknowledgeReset(share.win, share.win) end)"
                   , "return {}"
                   ]
          )
        mainSource =
          scriptSource
            script
              { scPrelude = ["local share = import('lua/share.lua')"]
              , scInit = ["share.apis[#share.apis + 1] = api", "if #share.apis == 1 then api.content.module('lua/late.lua') end"]
              , scUpdate =
                  [ "if self.ran or #share.apis < 2 then return end self.ran = true"
                  , "if api.instance_id ~= share.apis[2].instance_id then return end"
                  , "try('foreign facade poll', function() return share.apis[1].input.poll(nil, 1) end)"
                  , "try('foreign facade ack', function() return share.apis[1].input.acknowledgeReset(nil, nil) end)"
                  , "print('ran')"
                  ]
              }
    ( withWorld fixedM1Profile (Layout [("lua/main.lua", mainSource), shared, late]) $ \world _ runtime →
        withFvm world runtime (presentationShape {shGraphics = Just (injectionOpt True gx)}) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntil world (advanceClock world 2000000000 >> (elem "ran" <$> outLines world))
          printed ← outLines world
          let named prefix = [line | line ← printed, prefix `Text.isPrefixOf` line]
          named "late poll => " `shouldSatisfy` all (\line → "false ; " `Text.isPrefixOf` Text.drop 13 line || "services are not available while a module is evaluated" `Text.isInfixOf` line)
          length (named "late ") `shouldBe` 2
          named "late " `shouldSatisfy` all ("services are not available while a module is evaluated" `Text.isInfixOf`)
          length (named "foreign facade") `shouldBe` 2
          named "foreign facade" `shouldSatisfy` all ("belongs to another instance" `Text.isInfixOf`)
          inCalls gx `shouldReturn` []
          finishAll gx
      )
      `finally` finishAll gx

  it "bounds a poll by what the copied-value limits carry: the largest count that fits is delivered whole, and one more is refused before any read" $ do
    gx ← newGfx
    loadFeed gx (replicate 130 (InputEventRecord 3 (BodyButton 7 ButtonActionRelease (Just (1.5, 2.5)) (InputModifiers True True True True True True)))) FeedRunning
    runInputWith
      (bytesOf [(CopiedValueBytes, 24000), (DataBytes, 64), (SceneInputBytes, 64)])
      gx
      [ "local n, why = 128, nil"
      , "while n >= 1 do"
      , "  local ok, result = pcall(api.input.poll, self.win, n)"
      , "  if ok then print('fits', n, #result.events) break end"
      , "  why = result"
      , "  n = n - 1"
      , "end"
      , "print('refused above', tostring(why):find('copied-value limits', 1, true) ~= nil, tostring(why):find('max_events ' .. (n + 1), 1, true) ~= nil)"
      ]
      []
      $ \world _ → do
        printed ← outLines world
        let fitted = [(read (Text.unpack a), read (Text.unpack b)) | line ← printed, ["fits", a, b] ← [Text.splitOn "\t" line]] ∷ [(Int, Int)]
        case fitted of
          [(n, delivered)] → do
            n `shouldSatisfy` (\count → count >= 1 && count < 128)
            delivered `shouldBe` n
            remaining gx `shouldReturn` (130 - n)
            -- only the accepted poll reached the port
            inCalls gx `shouldReturn` ["check poll", "poll " <> Text.pack (show n)]
          other → expectationFailure ("a poll must fit once: " <> show other <> " in " <> show printed)
        printed `shouldSatisfy` elem "refused above\ttrue\ttrue"

  it "fails the owner as the host's defect, never an empty poll, when the provider's data cannot be a Lua integer or a finite number" $ do
    let failing events expected = do
          gx ← newGfx
          loadFeed gx events FeedRunning
          (failures, _) ←
            fatalWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource script {scInit = openWindow, scUpdate = takeWindow <> ["api.input.poll(self.win, 1)", "print('survived')"]})]) $ \world control runtime →
              withFvm world runtime (presentationShape {shGraphics = Just (injectionOpt True gx)}) $ \fvm → do
                _ ← admitOnly world fvm "modules-test" mainPath
                awaitHanded gx 1
                answerWindow gx 0
                pumpUntil world (advanceClock world 2000000000 >> (not . null <$> failuresSeen world))
                void (awaitEnded control fvm)
                  `finally` finishAll gx
          failures `shouldSatisfy` any (\(EngineFailure why) → expected `Text.isInfixOf` why)
          -- the batch was taken: it is not replayed and not hidden behind an empty poll
          remaining gx `shouldReturn` 0
    failing [InputEventRecord (2 ^ (63 ∷ Int)) (BodyFocus True)] "Lua integer ceiling"
    failing [InputEventRecord 3 (BodyScroll (1 / 0) 0)] "not a finite number"
