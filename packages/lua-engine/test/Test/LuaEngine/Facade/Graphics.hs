{-# LANGUAGE OverloadedStrings #-}

-- | The graphics calls of the facade (LFE-21) over /gated, injected/ services: the CPU facade's own rules, on real Lua in
-- real instances of a real supervised owner, with the providers behind it faked and counted.
--
-- What this proves is the facade: who may call, in which role and phase, with what arguments, which errors are ordinary,
-- the two-value busy answer, the exact request records and the three release answers. A refused call must have asked
-- the providers for nothing, so the fake counts every check and every start it is given. The real providers, leases and
-- windows are the graphics adapter's suites; nothing here is evidence of them.
module Test.LuaEngine.Facade.Graphics (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVar, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (Assembly, acquirePart, releaseRank)
import Hetoimasia.LuaEngine.Request (M1Ask (..), M1Start (..), m1Ask, startM1)
import Hetoimasia.LuaEngine.Scene (sceneSchema)
import Hetoimasia.Scripting.Lua.Admission (Necessity (RequiredRequest))
import Hetoimasia.Scripting.Lua.Lease (Ownership (InstanceOwned), ReleaseAnswer (..), leaseCapabilityType, newLeases, releaseLease)
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
import Hetoimasia.Scripting.Lua.Registration (stateOperation, withArgumentCheck)
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SNil, SRecord), Value (VCapability, VInteger, VNil, VRecord), capability)
import Test.Hspec
import Test.LuaEngine.Facade.Support

-- | What the fake providers were asked and what they hold.
data Gfx = Gfx
  { gxCalls ∷ !(IORef [Text])
  , gxBusy ∷ !(IORef Bool)
  , gxHanded ∷ !(TVar [(Text, Completion, TVar RetirementState)])
  }

newGfx ∷ IO Gfx
newGfx = Gfx <$> newIORef [] <*> newIORef False <*> newTVarIO []

calls ∷ Gfx → IO [Text]
calls = fmap reverse . readIORef . gxCalls

note ∷ Gfx → Text → IO ()
note gx entry = atomicModifyIORef' (gxCalls gx) (\held → (entry : held, ()))

-- | How many of the fake's calls began with this word.
countOf ∷ Gfx → Text → IO Int
countOf gx word = length . filter (Text.isPrefixOf word) <$> calls gx

injection ∷ Gfx → GraphicsInjection
injection gx = GraphicsInjection $ \vm → do
  lending ← newLending
  leases ← newLeases lending 17
  pure
    GraphicsServices
      { gsLending = lending
      , gsLeases = leases
      , gsTypes = [leaseCapabilityType leases graphicsTextureType, leaseCapabilityType leases graphicsWindowType]
      , gsEndpoints = [endpointOf "texture" (SRecord [("width", SInteger), ("height", SInteger)]), endpointOf "window" SNil]
      , gsDeclare = \identity → note gx ("declare " <> identity)
      , gsForget = \identity → note gx ("forget " <> identity)
      , gsTextureCheck = \_ _ _ _ _ → note gx "check texture" >> pure Nothing
      , gsTextureStart = \_ _ _ ctx → start vm ctx "texture" (Just textureCompose)
      , gsWindowCheck = \_ _ _ _ _ _ → note gx "check window" >> pure Nothing
      , gsWindowStart = \_ _ _ _ ctx → start vm ctx "window" (Just windowCompose)
      , gsPublish = \name precondition →
          withArgumentCheck precondition $
            stateOperation name [SCapability graphicsWindowType, sceneSchema] [] $ \_ → note gx "publish" >> pure []
      , gsRelease = \key → do
          note gx "release"
          word <$> releaseLease leases key
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

-- | The provider answers the nth handed request.
handed ∷ Gfx → Int → IO (Text, Completion)
handed gx index = atomically $ do
  held ← readTVar (gxHanded gx)
  case drop index held of
    (name, completion, _) : _ → pure (name, completion)
    [] → retry

-- | The providers prove all their work over, so that an example's teardown does not wait for what is right to wait for.
finishAll ∷ Gfx → IO ()
finishAll gx = atomically $ do
  held ← readTVar (gxHanded gx)
  mapM_ (\(_, _, retirement) → writeTVar retirement ProviderComplete) held

answerTexture ∷ Gfx → Int → IO ()
answerTexture gx index = do
  (_, completion) ← handed gx index
  void (completeRequest completion (ProviderResource (VRecord [("width", VInteger 4), ("height", VInteger 2)]) (Adoption (\_ → resource "texture"))))

answerWindow ∷ Gfx → Int → IO ()
answerWindow gx index = do
  (_, completion) ← handed gx index
  void (completeRequest completion (ProviderResource VNil (Adoption (\_ → resource "window"))))

resource ∷ Text → Assembly Text
resource name = do
  _ ← acquirePart name (releaseRank 0) (pure ()) (\_ → pure ())
  pure name

files ∷ [(FilePath, ByteString)]
files = [("images/quad.png", "png")]

-- | A case: a label, the Lua expression run under @pcall@ and what it must have come to.
data Verdict = Refused [Text] | Accepted

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

  it "answers a busy bank with exactly nil and the busy record, no handle and no start, and an explicit retry then succeeds" $ do
    gx ← newGfx
    writeIORef (gxBusy gx) True
    let cases =
          [ Case "busy texture" "(function() local r, e = api.content.texture('images/quad.png') return r == nil and e.code == 'busy' and type(e.message) == 'string' and select('#', api.content.texture('images/quad.png')) == 2 end)()" Accepted
          , Case "busy window" "(function() local r, e = api.window.open({title = 't', width = 2, height = 2}) return r == nil and e.code == 'busy' end)()" Accepted
          ]
    ( withOneGraphics (injection gx) Presentation script {scInit = map caseLua cases} files $ \world _ _ _ → do
        outLines world >>= checkCases cases
        countOf gx "start" `shouldReturn` 0
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
          , Case "stopped release" "api.texture.release(self.tex) == 'done'" Accepted
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
  where
    awaitHanded gx wanted = atomically (readTVar (gxHanded gx) >>= \held → if length held >= wanted then pure () else retry)
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
