{-# LANGUAGE OverloadedStrings #-}

-- | An arena the host published to one content root ('terrainInjectionWithArena'): an instance of that root takes its own attachment to
-- it with @api.terrain.attach_host()@, whatever name the host opened it under, and reads, edits and releases it like any attachment.
-- The host's creator lease stays the host's, with its native view; the arena closes with the last of those, however much Lua is attached.
--
-- Every example runs real Lua instances over the production service ('withRig'), through the injection the facade composes with
-- 'terrainInjectionWithArena'. The windows (host closure before and after the lease is issued, the adoption) are held by gates and
-- hooks; nothing sleeps. What is asserted is outcomes and resource balances, never an order the design does not promise.
module Test.LuaEngine.Terrain.HostPublished (spec) where

import Control.Exception (finally)
import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.Identity (rootKey)
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Terrain
import Hetoimasia.Terrain.Cell (Cell (..), materialIdString, mkColumn, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Coordinate (axisValue, decomposeTile, mkLocalCoord, tileCoord)
import Hetoimasia.Terrain.Query (Occupied (..), Run (..))
import Hetoimasia.Terrain.Residency (RegionDemand (..), Revision (..), coverageTile)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Control.Concurrent.STM (atomically, retry)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Scripting.Lua.Provider (RequestEndpoint (endpointName))
import Control.Monad (when)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Terrain.Support

-- The host ----------------------------------------------------------------------------------------------------

-- | The host's side of a published arena: its client and creator lease, with the native view that demands it.
data Host = Host
  { hostClient ∷ !Client
  , hostLease ∷ !ArenaLease
  , hostInjection ∷ !TerrainInjection
  }

soilOverStoneSpec ∷ SourceSpec
soilOverStoneSpec =
  SourceSpec
    { specMaterials = ["soil", "stone"]
    , specLayers =
        [ LayerSpec {layerMin = Nothing, layerMax = Just (-3), layerMaterial = "stone", layerShape = 0}
        , LayerSpec {layerMin = Just (-3), layerMax = Just 1, layerMaterial = "soil", layerShape = 0}
        ]
    , specPatches = []
    }

-- | The host opens an arena under a name of its own and publishes it to this content root: the injection a session is composed with.
publish ∷ Rig → Text → IO Host
publish rig root = do
  let service = rgService rig
  Right client ← registerClient service
  Right opening ← openArena service client "host/native" soilOverStoneSpec
  Right lease ← await service opening
  key ← either (\refused → fail ("root key refused: " <> show refused)) pure (rootKey (BC.pack (Text.unpack root)))
  injection ← terrainInjectionWithArena (rgFacade rig) key lease >>= either (\refused → fail ("the publication was refused: " <> show refused)) pure
  pure (Host client lease injection)

presentationWith, gameplayWith ∷ Rig → TerrainInjection → VmShape
presentationWith rig injection = (presentationOver rig) {shTerrain = Just (injection, rgSession rig)}
gameplayWith rig injection = (gameplayOver rig) {shTerrain = Just (injection, rgSession rig)}

-- | The native client's reading of the arena through its own lease, in the digests the scripts print.
nativeDigests ∷ Service → ArenaLease → IO [Text]
nativeDigests service lease = do
  Right reading ← cellAt service lease (tileAt 0 0 0)
  Right cell ← await service reading
  Right ranging ← columnAt service lease column range
  Right col ← await service ranging
  Right surfacing ← surfaceAt service lease column
  Right surf ← await service surfacing
  Right status ← arenaStatus service lease
  pure
    [ revisionText (cellRevision cell) <> " " <> materialOf (cellValue cell)
    , revisionText (columnRevision col) <> " " <> Text.intercalate "," [runText r | r ← columnAnswerRuns col]
    , revisionText (surfaceRevision surf) <> " " <> maybe "empty" (\(Occupied level material _) → Text.pack (show (axisValue level)) <> " " <> Text.pack (materialIdString material)) (surfaceTop surf)
    , revisionText (statusContentRevision status) <> " " <> revisionText (statusKnowledgeRevision status)
    ]
  where
    tileAt x y z = either (error . show) id (tileCoord x y z)
    column = either (error . show) id (mkColumn 0 0)
    range = either (error . show) id (mkZRange (-4) 2)
    revisionText (Revision w) = Text.pack (show w)
    materialOf = \case
      Air → "air"
      Solid material _ → Text.pack (materialIdString material)
    runText (Run zs cell) = Text.pack (show (toInteger (zRangeLo zs))) <> ":" <> Text.pack (show (toInteger (zRangeHi zs))) <> ":" <> materialOf cell

-- | Wait, bounded, until the arena's discovery is idle: the removal's content commit is the awaited request's, but the knowledge it
-- discovers is committed after, by the owner, and a status read before it is a different reading from one after.
awaitDiscoveryIdle ∷ Service → ArenaLease → IO ()
awaitDiscoveryIdle service lease =
  bounded . atomically $
    arenaStatusSTM service lease >>= \case
      Right status | statusDiscovery status == DiscoveryIdle → pure ()
      _ → retry

-- | The native client's demand through its creator lease and its own view: one cell of the arena's first region.
demandsNatively ∷ Service → Host → IO ()
demandsNatively service host = do
  Right view ← openView service (hostClient host)
  let (region, _) = decomposeTile (either (error . show) id (tileCoord 0 0 0))
      coverage = either (error . show) coverageTile (mkLocalCoord 0 0 0)
  Right _ ← setViewDemand service view (hostLease host) [RegionDemand region coverage]
  Right () ← clearViewDemand service view
  closeView service view

-- The scripts -------------------------------------------------------------------------------------------------

-- | An instance that attaches to the host's arena and then runs each step, as 'stepsScript' does for an arena it opens itself: the
-- label, the status and the text the show function makes of the value (or the failure's code) are printed at each settlement, and
-- @done@ after the last.
hostSteps ∷ [Step] → Script
hostSteps list =
  script
    { scPrelude =
        terrainPrelude
          <> ["local STEPS = {"]
          <> [ "  { " <> Text.pack (show (Text.unpack (stLabel step))) <> ", function(A, api) " <> stStart step <> " end, function(v) " <> stShow step <> " end },"
             | step ← list
             ]
          <> ["}", "local label, show, i = nil, nil, 0"]
    , scInit = ["self.s = 0", "self.q = api.terrain.attach_host()"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    print('attach', t.status, t.error and t.error.code)"
        , "    self.q = nil"
        , "    if t.status == 'success' then self.arena = t.value self.s = 1 else print('done') self.s = 2 end"
        , "  end"
        , "elseif self.s == 1 then"
        , "  if self.q then"
        , "    local t = settle(api, self.q)"
        , "    if t then"
        , "      if t.status == 'success' then print(label, t.status, show(t.value)) else print(label, t.status, t.error and t.error.code) end"
        , "      self.q = nil"
        , "    end"
        , "  end"
        , "  if not self.q then"
        , "    i = i + 1"
        , "    local step = STEPS[i]"
        , "    if step then label = step[1] show = step[3] self.q = step[2](self.arena, api)"
        , "    else print('done') self.s = 2 end"
        , "  end"
        , "end"
        ]
    }

-- | The four stock reads of cell, column, surface and status, each printing the digest 'nativeDigests' makes of the native client's.
readsLabelled ∷ Text → [Step]
readsLabelled suffix =
  [ Step ("cell" <> suffix) "return api.terrain.cell(A, {x = 0, y = 0, z = 0})" "return v.revision .. ' ' .. (v.air and 'air' or v.material)"
  , Step ("column" <> suffix) "return api.terrain.column(A, {x = 0, y = 0, z_min = -4, z_max = 2})" runs
  , Step ("surface" <> suffix) "return api.terrain.surface(A, {x = 0, y = 0})" "return v.revision .. ' ' .. (v.occupied and (v.z .. ' ' .. v.material) or 'empty')"
  , Step ("status" <> suffix) "return api.terrain.status(A)" "return v.content_revision .. ' ' .. v.knowledge_revision"
  ]
  where
    runs = "local o = {} for _, r in ipairs(v.runs) do o[#o + 1] = r.z_min .. ':' .. r.z_max .. ':' .. (r.air and 'air' or r.material) end return v.revision .. ' ' .. table.concat(o, ',')"

-- | The reads before and after the host's native edit, the instance held between them until the example says the edit is done.
agreeing ∷ Script
agreeing = hostSteps (readsLabelled "0" <> [Step "wait" "TEST_WAIT('edited')" "return ''"] <> readsLabelled "1")

-- | The labelled lines a run of 'readsLabelled' prints for these native digests.
linesFor ∷ Text → [Text] → [Text]
linesFor suffix digests = [label <> suffix <> "\tsuccess\t" <> digest | (label, digest) ← zip ["cell", "column", "surface", "status"] digests]

-- Examples ----------------------------------------------------------------------------------------------------

spec ∷ Spec
spec = describe "host-published arena" $ do
  it "reads the host's arena through the stock calls, agreeing with the native client across the native edit, while native demand succeeds" $
    withRig $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource agreeing)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` signalRig rig "edited") $ do
          _ ← spawn world fvm "modules-test" mainPath
          awaitDiscoveryIdle service (hostLease host)
          nativeBefore ← nativeDigests service (hostLease host)
          demandsNatively service host
          untilPrinted world "status0\tsuccess\t0 0"
          -- the native client edits through its own creator lease
          Right removing ← removeAt service (hostLease host) (either (error . show) id (tileCoord 0 0 0)) Nothing
          void (either (\settled → fail ("the native removal settled " <> show settled)) pure =<< await service removing)
          awaitDiscoveryIdle service (hostLease host)
          nativeAfter ← nativeDigests service (hostLease host)
          demandsNatively service host
          signalRig rig "edited"
          untilPrinted world "done"
          printed ← outLines world
          printed `shouldBe` (["attach\tsuccess\tnil"] <> linesFor "0" nativeBefore <> linesFor "1" nativeAfter <> ["done"])
          -- the edit is visible, and the two reads are of one arena at two revisions
          nativeBefore `shouldNotBe` nativeAfter
          limitHeld service "leases" `shouldReturn` 2

  it "attaches from either role, to the arena whatever name the host opened it under" $
    withRig $ \rig → do
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime → do
        withFvm world runtime (gameplayWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          tickUntil fvm (elem "done" <$> outLinesSTM world)
        nativeBefore ← nativeDigests (rgService rig) (hostLease host)
        gameplay ← outLines world
        gameplay `shouldBe` (["attach\tsuccess\tnil"] <> linesFor "0" nativeBefore <> ["done"])
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          stepUntil world (elem "done" <$> outLinesSTM world)
          nativeBefore ← nativeDigests (rgService rig) (hostLease host)
          presented ← outLines world
          presented `shouldBe` (["attach\tsuccess\tnil"] <> linesFor "0" nativeBefore <> ["done"])

  it "removes through its attachment, refuses storage growth and retry, releases only its own interest, and releases again harmlessly" $
    withRig $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource authority)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "alive"
          printed ← outLines world
          printed
            `shouldBe` [ "attach\tsuccess\tnil"
                       , "remove\tsuccess\t1"
                       , "grow => false ; hetoimasia_engine.terrain_grow_storage: only the arena's creator lease may grow its storage"
                       , "retry => false ; hetoimasia_engine.terrain_retry_storage: only the arena's creator lease may retry its storage"
                       , "release\tdone"
                       , "again\talready_released"
                       , "alive"
                       ]
          -- the removal through the attachment is the native client's to read; the attachment's release left the arena and the host's lease
          [cell, _, _, _] ← nativeDigests service (hostLease host)
          cell `shouldBe` "1 air"
          limitHeld service "arenas" `shouldReturn` 1
          limitHeld service "leases" `shouldReturn` 1

  it "gives its attachment back when the instance ends, leaving the host's lease and arena" $
    withRig $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          spawned ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          limitHeld service "leases" `shouldReturn` 2
          stopSpawned spawned
          failure ← settledFailure spawned
          failure `shouldSatisfy` (== Nothing) . fmap (const ())
      limitHeld service "leases" `shouldReturn` 1
      [cell, _, _, _] ← nativeDigests service (hostLease host)
      cell `shouldBe` "0 soil"

  it "settles not_found for a session composed with the plain injection, and for an instance of another content root" $
    withRig $ \rig → do
      host ← publish rig "published-root"
      let runWith shape = withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
            withFvm world runtime shape $ \fvm → do
              clientsBefore ← limitHeld (rgService rig) "clients"
              _ ← spawn world fvm "modules-test" mainPath
              stepUntil world (elem "done" <$> outLinesSTM world)
              -- the instance's own client and nothing more: no attach client was made for a request with nothing to reach
              limitHeld (rgService rig) "clients" `shouldReturn` clientsBefore + 1
              outLines world
      -- the plain injection of the same facade
      plain ← runWith (presentationOver rig)
      plain `shouldBe` ["attach\tfailure\tnot_found", "done"]
      -- the injection published to another root: this instance is in an unpublished root
      elsewhere ← runWith (presentationWith rig (hostInjection host))
      elsewhere `shouldBe` ["attach\tfailure\tnot_found", "done"]
      -- nothing was reserved by either, and the host's arena is untouched
      limitHeld (rgService rig) "leases" `shouldReturn` 1

  it "settles not_found for a grant that expired, and a reused name cannot redirect it" $
    withRig $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      -- an attachment taken while the grant stood, held across the host's closure and the reuse of the name
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource staleAfterReuse)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` signalRig rig "closed") $ do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "attached"
          -- the host closes the arena by releasing its last creator lease, and opens the same name again: a new incarnation
          Right () ← releaseLease service (hostLease host)
          Right reopening ← openArena service (hostClient host) "host/native" soilOverStoneSpec
          Right _ ← await service reopening
          signalRig rig "closed"
          untilPrinted world "done"
          printed ← outLines world
          printed
            `shouldBe` [ "attached"
                       , -- the old handle is the closed incarnation's: not the replacement's
                         "old cell\tfailure\tarena_closed"
                       , -- the grant names the old incarnation: the reused name finds nothing to attach to
                         "again\tfailure\tnot_found"
                       , "done"
                       ]

  it "settles not_found when the host closes the arena after admission and before the lease is issued, and holds nothing" $ do
    gate ← newGate
    disarmGate gate
    let probe = gatedProbe (\p → case p of PointBeforeCommit _ → True; _ → False) gate
    withRigProbe defaultConfigForRaces probe $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` openGate gate) $ do
          armGate gate
          _ ← spawn world fvm "modules-test" mainPath
          -- the request is admitted and its commit held: the host closes the arena, and the commit finds no grant to issue from
          pumpUntilReached world gate
          Right () ← releaseLease service (hostLease host)
          openGate gate
          untilPrinted world "done"
          outLines world >>= (`shouldBe` ["attach\tfailure\tnot_found", "done"])
          limitHeld service "leases" `shouldReturn` 0

  it "settles not_found when the host closes the arena before the request is admitted, and holds nothing" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookSubmitting = holdAt gate} $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` openGate gate) $ do
          _ ← admitOnly world fvm "modules-test" mainPath
          pumpUntilReached world gate
          Right () ← releaseLease service (hostLease host)
          openGate gate
          untilPrinted world "done"
          outLines world >>= (`shouldBe` ["attach\tfailure\tnot_found", "done"])
          limitHeld service "leases" `shouldReturn` 0

  it "settles arena_closed, and publishes no lease, when the host closes the arena after the attachment was issued and before it was published" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdAt gate} $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` openGate gate) $ do
          _ ← spawn world fvm "modules-test" mainPath
          pumpUntilReached world gate
          Right () ← releaseLease service (hostLease host)
          openGate gate
          untilPrinted world "done"
          outLines world >>= (`shouldBe` ["attach\tfailure\tarena_closed", "done"])
          -- the offered lease was released and the creator's lease is gone: no lease is left
          limitHeld service "leases" `shouldReturn` 0

  it "releases the lease an attachment built when its instance stops between the build and the settlement, leaving the host's lease" $ do
    gate ← newGate
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookAdopted = holdAt gate} $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → (`finally` openGate gate) $ do
          spawned ← admitOnly world fvm "modules-test" mainPath
          pumpUntilReached world gate
          stopSpawned spawned
          openGate gate
          failure ← settledFailure spawned
          failure `shouldSatisfy` (== Nothing) . fmap (const ())
          limitHeld service "arenas" `shouldReturn` 1
          limitHeld service "leases" `shouldReturn` 1
      [cell, _, _, _] ← nativeDigests service (hostLease host)
      cell `shouldBe` "0 soil"

  it "answers busy when the service's lease bank is full, reserves nothing, and attaches once a lease is free" $
    withRigConfig defaultConfig {configMaxLeases = 2} $ \rig → do
      let service = rgService rig
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource pressed)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          outLines world >>= (`shouldBe` ["first\tsuccess", "second\ttrue\tbusy", "released\tdone", "third\tsuccess", "done"])
          limitHeld service "leases" `shouldReturn` 2
          -- the attachment is the instance's own client's: the host's and the instance's are all that is held
          limitHeld service "clients" `shouldReturn` 2

  it "answers a service that closed between the host's precheck and the hand-off of an unpublished attach as the closed-service refusal, with nothing reserved" $ do
    gate ← newGate
    armed ← newIORef False
    let holdFirst = do
          go ← atomicModifyIORef' armed (\a → (False, a))
          when go (holdAt gate)
    withRigHooks defaultConfigForRaces noProbeForRaces noTerrainHooks {hookSubmitting = holdFirst} $ \rig →
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource closesBeforeHandOff)]) $ \world _ runtime →
        -- the plain injection publishes nothing: the request would settle not_found at the hand-off
        withFvm world runtime (presentationOver rig) $ \fvm → (`finally` openGate gate) $ do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "ready"
          writeIORef armed True
          pumpUntilReached world gate
          closeService (rgService rig)
          openGate gate
          untilPrinted world "done"
          -- an ordinary error that names the closure, not a request settled not_found
          outLines world >>= (`shouldContain` ["call\tfalse\ttrue"])
          limitHeld (rgService rig) "leases" `shouldReturn` 0
          inspectInvariants (rgService rig) `shouldReturn` []

  it "refuses attach_host as an ordinary error for a provider that declares no host attachment, without calling it, and leaves its named attach alone" $
    withRig $ \rig → do
      host ← publish rig "modules-test"
      asked ← newIORef ([] ∷ [Text])
      -- a provider as the original constructor gave it: the adapter's services without the host attachment endpoint, whose named-attach
      -- callbacks enforce the whole name bound (a name is nonempty and at most 128 characters) and record every name they are asked for
      let noted name = atomicModifyIORef' asked (\seen → (name : seen, ()))
          bounded' name = Text.null name || Text.length name > 128
          original = TerrainInjection
            { tiLeaseCapacity = tiLeaseCapacity (hostInjection host)
            , injectTerrain = \vm → do
                services ← injectTerrain (hostInjection host) vm
                pure
                  services
                    { tsEndpoints = filter ((/= terrainHostAttachEndpoint) . endpointName) (tsEndpoints services)
                    , tsAttachCheck = \identity root name owner values → do
                        noted name
                        if bounded' name then pure (Just "an arena name is out of bounds") else tsAttachCheck services identity root name owner values
                    , tsAttachStart = \identity root name ctx → do
                        noted name
                        tsAttachStart services identity root name ctx
                    }
            }
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource namedAndHost)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig original) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          stepUntil world (elem "done" <$> outLinesSTM world)
          printed ← outLines world
          printed `shouldSatisfy` any (Text.isPrefixOf "host => false ; ")
          printed `shouldSatisfy` any (Text.isInfixOf "publishes no arena")
          -- the named attach reached the provider's callbacks (the check and the start), the host attach never did
          names ← readIORef asked
          names `shouldBe` ["nothing", "nothing"]
          limitHeld (rgService rig) "leases" `shouldReturn` 1

  it "attaches with the service's client bank full: the instance's own client issues the attachment" $
    withRigConfig defaultConfig {configMaxClients = 2} $ \rig → do
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource (hostSteps (readsLabelled "0")))]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          stepUntil world (elem "done" <$> outLinesSTM world)
          digests ← nativeDigests (rgService rig) (hostLease host)
          printed ← outLines world
          -- the host's client and the instance's fill the bank, and the grant is still live and the lease bank has room
          printed `shouldBe` (["attach\tsuccess\tnil"] <> linesFor "0" digests <> ["done"])
          limitHeld (rgService rig) "clients" `shouldReturn` 2
          limitHeld (rgService rig) "leases" `shouldReturn` 2

  it "refuses an argument as an ordinary error, before anything is reserved" $
    withRig $ \rig → do
      host ← publish rig "modules-test"
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource arguments)]) $ \world _ runtime →
        withFvm world runtime (presentationWith rig (hostInjection host)) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          untilPrinted world "done"
          printed ← outLines world
          forM_ ["extra => false ; ", "name => false ; "] $ \prefix →
            printed `shouldSatisfy` any (Text.isPrefixOf prefix)
          limitHeld (rgService rig) "leases" `shouldReturn` 1

  it "refuses a lease that is not a live creator lease of the facade's service when the host publishes it, and acquires nothing" $
    withRig $ \rig → do
      let service = rgService rig
      Right client ← registerClient service
      Right opening ← openArena service client "host/native" soilOverStoneSpec
      Right creator ← await service opening
      other ← registerClient service >>= either (\refused → fail (show refused)) pure
      Right attaching ← attachArena service other "host/native"
      Right attached ← await service attaching
      key ← either (\refused → fail (show refused)) pure (rootKey "modules-test")
      let refusal lease = either Just (const Nothing) <$> terrainInjectionWithArena (rgFacade rig) key lease
      -- an attachment is not a creator lease
      refusal attached `shouldReturn` Just RefusedAuthority
      -- a live creator lease is accepted, and borrowing it takes no lease of its own
      refusal creator `shouldReturn` Nothing
      limitHeld service "leases" `shouldReturn` 2
      -- a released one is not live
      Right () ← releaseLease service creator
      refusal creator `shouldReturn` Just RefusedAuthority
      -- and a lease of another service is not this service's authority
      withRig $ \foreignRig → do
        Right foreignClient ← registerClient (rgService foreignRig)
        Right foreignOpening ← openArena (rgService foreignRig) foreignClient "host/native" soilOverStoneSpec
        Right foreignLease ← await (rgService foreignRig) foreignOpening
        refusal foreignLease `shouldReturn` Just RefusedAuthority

-- | An instance that calls @attach_host@ once the example says to (it is ready), and says whether the call raised a closed-service error.
closesBeforeHandOff ∷ Script
closesBeforeHandOff =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0"]
    , scUpdate =
        [ "if self.s == 0 then print('ready') self.s = 1"
        , "elseif self.s == 1 then"
        , "  local ok, e = pcall(api.terrain.attach_host)"
        , "  print('call', ok, string.find(tostring(e), 'closed', 1, true) ~= nil)"
        , "  print('done') self.s = 2"
        , "end"
        ]
    }

-- | An instance that removes through its attachment, tries the creator's calls, and releases twice.
authority ∷ Script
authority =
  hostSteps
    [ Step "remove" "return api.terrain.remove(A, {x = 0, y = 0, z = 0})" "return v.revision"
    , Step "grow" "try('grow', api.terrain.grow_storage, A, 134217728)" "return ''"
    , Step "retry" "try('retry', api.terrain.retry_storage, A)" "return ''"
    , Step "release" "print('release', api.terrain.release(A))" "return ''"
    , Step "again" "print('again', api.terrain.release(A))" "return ''"
    , Step "alive" "print('alive')" "return ''"
    ]

-- | An instance that attaches, closes nothing, and attaches again after the host has closed the arena and reused its name.
staleAfterReuse ∷ Script
staleAfterReuse =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.attach_host()"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then self.arena = t.value print('attached') TEST_WAIT('closed') self.q = api.terrain.cell(self.arena, {x = 0, y = 0, z = 0}) self.s = 1 end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('old cell', t.status, t.error and t.error.code) self.q = api.terrain.attach_host() self.s = 2 end"
        , "elseif self.s == 2 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('again', t.status, t.error and t.error.code) print('done') self.s = 3 end"
        , "end"
        ]
    }

-- | An instance that holds an attachment, is refused a second as busy while the lease bank is full, and attaches again after releasing.
pressed ∷ Script
pressed =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "self.q = api.terrain.attach_host()"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then"
        , "    self.arena = t.value print('first', t.status)"
        , "    local r, e = api.terrain.attach_host()"
        , "    print('second', r == nil, e and e.code)"
        , "    print('released', api.terrain.release(self.arena))"
        , "    self.q = api.terrain.attach_host() self.s = 1"
        , "  end"
        , "elseif self.s == 1 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('third', t.status) print('done') self.s = 2 end"
        , "end"
        ]
    }

-- | An instance that calls @attach_host@ (refused) and then a named attach of a name nothing holds (a request that settles not_found).
namedAndHost ∷ Script
namedAndHost =
  script
    { scPrelude = terrainPrelude
    , scInit = ["self.s = 0", "try('host', api.terrain.attach_host)", "self.q = api.terrain.attach('nothing')"]
    , scUpdate =
        [ "if self.s == 0 then"
        , "  local t = settle(api, self.q)"
        , "  if t then print('named', t.status, t.error and t.error.code) print('done') self.s = 1 end"
        , "end"
        ]
    }

-- | An instance that calls @attach_host@ with arguments.
arguments ∷ Script
arguments =
  script
    { scPrelude = terrainPrelude
    , scInit = ["try('extra', api.terrain.attach_host, 1)", "try('name', api.terrain.attach_host, 'main')", "print('done')"]
    , scUpdate = []
    }
