{-# LANGUAGE OverloadedStrings #-}

-- | @api.terrain.region@: one whole region's terrain and discovery copied to Lua at one pair of revisions.
--
-- A Lua copy is compared with the native regional snapshot of the same region at the same revisions, cell by cell through the
-- snapshot's own accessors: both sides make the same run-length digest of the dense arrays. What an example asserts is an outcome (the
-- values, the revisions the reply reports, the accounts the service keeps), never an order or a time. The windows of the borrow are
-- decided by what an example does at a causal gate: a request whose copy is made and whose staging has not happened, and one staged
-- and not yet offered to the arbitration. The balances are read from the service's own structures: its regional borrows, its snapshot
-- charges and its retained bank.
module Test.LuaEngine.Terrain.Region (spec) where

import Control.Concurrent.MVar (newEmptyMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (STM, atomically, check, readTVar)
import Control.Exception (evaluate, finally, onException)
import Control.Monad (forM_, void, when)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (group)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (CopiedValueElements, LuaIntegerMaximum, SceneSprites), Profile, ProfileSpec (specCounts), fixedM1Profile, profileSpec, validateProfile)
import Hetoimasia.LuaEngine.Terrain (TerrainHooks (hookAdmitted), noTerrainHooks, terrainCodesFor)
import Hetoimasia.Terrain.Cell (Cell (..), materialIdString)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, composeTile, mkLocalCoord, tileCoord)
import qualified Hetoimasia.Terrain.Discovery as D
import Hetoimasia.Terrain.Residency (LimitsSpec (..), Revision (..), mkLimits)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Testing (NativeOp (OpReadAt))
import Hetoimasia.Terrain.Shape (cornerMaskValue, shapeIdValue)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Test.Hspec
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Request.Profiles (counts)
import Test.LuaEngine.Terrain.Seam
import Test.LuaEngine.Terrain.Support
import Test.Support.Bounded (bounded)

-- The native side ---------------------------------------------------------------------------------------------

-- | The cells of a region in the order of the Lua index @1 + x + 16 * y + 256 * z@: x fastest, then y, then z.
tilesOf ∷ RegionCoord → [TileCoord]
tilesOf region = [either (error . show) id (mkLocalCoord x y z >>= composeTile region) | z ← [0 .. 31], y ← [0 .. 15], x ← [0 .. 15]]

-- | A run-length digest: each run of equal keys as @COUNTxKEY@.
runs ∷ [Text] → Text
runs keys = Text.unwords [Text.pack (show (length same)) <> "x" <> key | same@(key : _) ← group keys]

-- | What the Lua scripts print of a reply ('reportPrelude'), made from a native snapshot through its per-cell accessors.
nativeDigest ∷ RegionSnapshot → RegionCoord → Text
nativeDigest snapshot region =
  Text.unwords
    [ Text.pack (show content)
    , Text.pack (show knowledge)
    , "T"
    , part (regionTerrain snapshot region) [terrainKey (regionCell snapshot tile) | tile ← tilesOf region]
    , "K"
    , part (regionKnowledge snapshot region) [knowledgeKey (regionCellKnowledge snapshot tile) | tile ← tilesOf region]
    ]
  where
    Revision content = regionSnapshotContentRevision snapshot
    Revision knowledge = regionSnapshotKnowledgeRevision snapshot
    part available keys = case available of
      PartReady _ → Text.pack (show (length keys)) <> "[" <> runs keys <> "]"
      _ → "unavailablenil"
    terrainKey = \case
      PartReady Air → "air"
      PartReady (Solid material shape) → Text.pack (materialIdString material) <> ":" <> Text.pack (show (shapeIdValue shape))
      PartReady (CornerSolid material mask) → Text.pack (materialIdString material) <> ":c" <> Text.pack (show (cornerMaskValue mask))
      _ → "missing"
    knowledgeKey = \case
      PartReady (D.CellKnowledge solid hollow) → solidText solid <> "/" <> voidText hollow
      _ → "missing"
    solidText = \case D.NoSolid → "none"; D.SolidKnown → "known"; D.SolidUnknown → "unknown"
    voidText = \case D.NoVoidHere → "none"; D.VoidKnown → "known"; D.VoidUnknown → "unknown"

-- | An independent client of the service, attached to the arena a Lua instance opened as @main@, for the body.
withNative ∷ Rig → (Service → ArenaLease → IO a) → IO a
withNative rig body = do
  let svc = rgService rig
  client ← either (fail . show) pure =<< registerClient svc
  ( do
      attaching ← attachArena svc client (arenaName rig "modules-test" "main") >>= either (fail . show) pure
      lease ← await svc attaching >>= either (fail . show) pure
      body svc lease
    )
    `finally` endClient svc client

-- | The native digest of one region, read through a borrow released before it returns.
digestOfRegion ∷ Service → ArenaLease → RegionCoord → IO Text
digestOfRegion svc lease region =
  withRegionSnapshot
    svc
    lease
    [region]
    ( \case
        Right snapshot → evaluate (nativeDigest snapshot region)
        Left settlement → fail ("the native regional snapshot did not settle: " <> show settlement)
    )
    >>= either (fail . show) pure

-- | Wait until every request the service holds has settled and its owner has nothing left to do, so that a reading of the accounts is
-- not made in the middle of anyone's work.
quiescent ∷ Service → IO ()
quiescent svc =
  bounded (atomically ((&&) <$> (all censusSettled . censusRequests <$> inspectCensusSTM svc) <*> backedQuiescentSTM svc >>= check))
    `onException` do
      census ← atomically (inspectCensusSTM svc)
      putStrLn ("not quiescent: settled " <> show (map censusSettled (censusRequests census)))

-- | The retained bank's use, once the service is quiescent.
retainedUse ∷ Service → IO Word64
retainedUse svc = quiescent svc >> fst <$> atomically (inspectRetainedChargesSTM svc)

-- | The service holds nothing for a regional read: no borrow, no snapshot charge, no borrower, and the retained bank where it stood.
balancedAt ∷ Service → Word64 → IO ()
balancedAt svc baseline = do
  (charges, held, use, borrowers) ← holdings svc
  (charges, held, use, borrowers) `shouldBe` (0, 0, baseline, 0)

-- | The same without a baseline: a refused request charged nothing.
nothingHeld ∷ Service → IO ()
nothingHeld svc = do
  (charges, held, _, borrowers) ← holdings svc
  (charges, held, borrowers) `shouldBe` (0, 0, 0)

-- | The service's own accounts of regional reads: the borrows it holds, the snapshot charges in its retained bank, that bank's use, and
-- the borrowers its closure would wait for.
holdings ∷ Service → IO (Int, Int, Word64, Int)
holdings svc = do
  quiescent svc
  charges ← atomically (inspectRegionalSTM svc)
  (use, held) ← atomically (inspectRetainedChargesSTM svc)
  census ← atomically (inspectCensusSTM svc)
  pure (length charges, length held, use, fromIntegral (censusBorrows census))

-- The scripts -------------------------------------------------------------------------------------------------

-- | The Lua every region script shares: the report of a reply, which is the digest 'nativeDigest' makes, and whether the reply's shape
-- is exactly the contract's (its four fields, the two keys of a ready part, a terrain cell with exactly its air, material and one
-- discriminator, @shape@ for a side solid or @corner_mask@ for a corner solid, and a knowledge cell with exactly its two).
reportPrelude ∷ [Text]
reportPrelude =
  [ "local function nkeys(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end"
  , "local function rle(cells, key)"
  , "  local out, prev, n = {}, nil, 0"
  , "  for i = 1, #cells do"
  , "    local k = key(cells[i])"
  , "    if k == prev then n = n + 1 else"
  , "      if prev then out[#out + 1] = n .. 'x' .. prev end"
  , "      prev, n = k, 1"
  , "    end"
  , "  end"
  , "  if prev then out[#out + 1] = n .. 'x' .. prev end"
  , "  return table.concat(out, ' ')"
  , "end"
  , "local function tkey(c) if c.air then return 'air' end if c.corner_mask then return c.material .. ':c' .. c.corner_mask end return c.material .. ':' .. c.shape end"
  , "local function kkey(c) return c.solid .. '/' .. c.void end"
  , "local function part(p, key) if p.state == 'ready' then return #p.cells .. '[' .. rle(p.cells, key) .. ']' end return p.state .. tostring(p.cells) end"
  , "local function wellformed(v)"
  , "  if nkeys(v) ~= 4 then return false end"
  , "  for _, p in ipairs({ v.terrain, v.knowledge }) do"
  , "    if p.state == 'ready' then if nkeys(p) ~= 2 or #p.cells ~= 8192 then return false end"
  , "    elseif p.state ~= 'unavailable' or nkeys(p) ~= 1 then return false end"
  , "  end"
  , "  for _, c in ipairs(v.terrain.cells or {}) do if nkeys(c) ~= (c.air and 1 or 3) or (not c.air and (c.shape == nil) == (c.corner_mask == nil)) then return false end end"
  , "  for _, c in ipairs(v.knowledge.cells or {}) do if nkeys(c) ~= 2 then return false end end"
  , "  return true"
  , "end"
  , "local function report(v)"
  , "  return v.content_revision .. ' ' .. v.knowledge_revision .. ' T ' .. part(v.terrain, tkey) .. ' K ' .. part(v.knowledge, kkey) .. ' ' .. tostring(wellformed(v))"
  , "end"
  , "local R0 = {x = 0, y = 0, z = 0}"
  ]

-- | Stone up to a sky at level 8, a cave along X at level 5 beside a sloped slab whose empty side faces nothing the cave reaches (a known
-- solid over an unknown void, once the cave is opened to the sky by removing the shaft that 'shaftSteps' removes), and one floating shaped ore
-- cell at (3, 5, 9) in the sky, where a transposed axis of the dense array's index would show.
shapedPrelude ∷ [Text]
shapedPrelude =
  [ "local PATCHES = {}"
  , "for x = 1, 7 do PATCHES[#PATCHES + 1] = { x = x, y = 1, z_min = 5, z_max = 6, value = { air = true } } end"
  , "PATCHES[#PATCHES + 1] = { x = 4, y = 0, z_min = 5, z_max = 6, value = { material = 'slab', shape = 1 } }"
  , "PATCHES[#PATCHES + 1] = { x = 3, y = 5, z_min = 9, z_max = 10, value = { material = 'ore', shape = 3 } }"
  , "local SHAPED = { materials = { 'stone', 'slab', 'ore' }, layers = { { z_max = 8, material = 'stone', shape = 0 } }, patches = PATCHES }"
  ]

-- | The removal of the shaft from the cave to the sky: three edits, after which discovery knows the cave.
shaftSteps ∷ [Step]
shaftSteps = [Step ("shaft " <> Text.pack (show z)) ("return api.terrain.remove(A, {x = 0, y = 1, z = " <> Text.pack (show z) <> "})") "return tostring(v.changed)" | z ← [5 .. 7 ∷ Int]]

-- | The wait at which the example reads the native side, with the arena quiet.
quietStep ∷ Text → Step
quietStep name = Step name ("TEST_WAIT(" <> Text.pack (show (Text.unpack name)) <> ") return nil") "return ''"

-- | A region read of this label and region, reported by 'report'.
readStep ∷ Text → Text → Step
readStep label region = Step label ("return api.terrain.region(A, " <> region <> ")") "return report(v)"

-- | The line a read prints: its label, the status and the digest.
readLine ∷ Text → Text → Text
readLine label digest = label <> "\tsuccess\t" <> digest <> " true"

-- | The way each role moves its VM until a condition holds.
type Drive = World → Fvm → STM Bool → IO ()

roles ∷ [(String, Rig → VmShape, Drive)]
roles =
  [ ("presentation", presentationOver, \world _ → stepUntil world)
  , ("gameplay", gameplayOver, \_ fvm → tickUntil fvm)
  ]

-- | The example's side of a @TEST_WAIT(name)@: the script has reached it, the service is quiet, this is done, and the script goes on.
atWait ∷ Rig → (STM Bool → IO ()) → Text → IO a → IO a
atWait rig drive name action = do
  drive (elem ("entered " <> name) <$> readTVar (rgTrace rig))
  quiescent (rgService rig)
  made ← action
  signalRig rig name
  pure made

-- | A script, run as one instance in a VM of this shape over the rig, for the body.
withScript ∷ Rig → Profile → (Rig → VmShape) → Script → (World → Fvm → IO a) → IO a
withScript rig profile over steps body =
  withWorld profile (Layout [("lua/main.lua", scriptSource steps)]) $ \world _ runtime →
    withFvm world runtime (over rig) $ \fvm → do
      _ ← spawn world fvm "modules-test" mainPath
      body world fvm

-- | A script whose one purpose is to print a line, and when it has, @done@.
finished ∷ World → IO [Text]
finished world = do
  stepUntil world (elem "done" <$> outLinesSTM world)
  outLines world

-- The examples ------------------------------------------------------------------------------------------------

spec ∷ Spec
spec = describe "Lua regional read" $ do
  copySpec
  cornerSpec
  unavailableSpec
  limitsSpec
  refusalSpec
  ownershipSpec
  balanceSpec
  windowSpec
  ceilingSpec
  retirementSpec
  admissionSpec

-- | The copy itself: a fresh record equal to the native snapshot, at the revisions it reports, in either role.
copySpec ∷ Spec
copySpec =
  forM_ roles $ \(role, over, drive) →
    it ("copies one region to a fresh record that equals the native snapshot at the same revisions, before and after an edit, from a " <> role <> " instance") $
      withRig $ \rig → do
        let steps =
              stepsScript
                "SHAPED"
                (reportPrelude <> shapedPrelude)
                ( shaftSteps
                    <> [ quietStep "quiet"
                       , Step
                           "region0"
                           "return api.terrain.region(A, R0)"
                           "local o = v.terrain.cells[1 + 3 + 16 * 5 + 256 * 9] return report(v) .. ' ' .. o.material .. ':' .. o.shape .. ' ' .. tostring(v.terrain.cells[1 + 4 + 16 * 5 + 256 * 9].air)"
                       , readStep "region below" "{x = -1, y = 0, z = -1}"
                       , Step "edit" "return api.terrain.remove(A, {x = 3, y = 1, z = 0})" "return tostring(v.changed)"
                       , quietStep "edited"
                       , readStep "region edited" "R0"
                       ]
                )
        withScript rig fixedM1Profile over steps $ \world fvm → do
          let go = drive world fvm
          (origin, below) ← atWait rig go "quiet" $
            withNative rig $ \svc lease → (,) <$> digestOfRegion svc lease (RegionCoord 0 0 0) <*> digestOfRegion svc lease (RegionCoord (-1) 0 (-1))
          edited ← atWait rig go "edited" $ withNative rig $ \svc lease → digestOfRegion svc lease (RegionCoord 0 0 0)
          printed ← go (elem "done" <$> outLinesSTM world) >> outLines world
          -- the ore cell at local (3, 5, 9) is element 1 + 3 + 16 * 5 + 256 * 9 of the dense array and its neighbour is air
          printed `shouldContain` [readLine "region0" origin <> " ore:3 true"]
          printed `shouldContain` [readLine "region below" below]
          printed `shouldContain` [readLine "region edited" edited]
          -- the edit is in the copy that follows it: another version
          edited `shouldNotBe` origin
          -- the ramp is a known solid over an unknown void in what Lua read, as it is in the native snapshots
          [origin, edited] `shouldSatisfy` all ("known/unknown" `Text.isInfixOf`)

-- | Side and corner solids authored from Haskell (the Lua input form is another slice): a corner slope, a side slope, a corner full block,
-- a side full block and an authored corner zero side by side at level 5, and a stack at (3, 6) that alternates side and corner full blocks.
cornerSource ∷ SourceSpec
cornerSource =
  SourceSpec
    ["stone", "slab"]
    [LayerSpec Nothing (Just 8) "stone" 0]
    ( [ PatchSpec 3 5 5 6 (SpecCorner "slab" 9)
      , PatchSpec 4 5 5 6 (SpecSolid "slab" 3)
      , PatchSpec 5 5 5 6 (SpecCorner "slab" 15)
      , PatchSpec 6 5 5 6 (SpecSolid "slab" 0)
      , PatchSpec 7 5 5 6 (SpecCorner "slab" 0)
      ]
        <> [PatchSpec 3 6 z (z + 1) c | (z, c) ← zip [5 ..] [SpecSolid "slab" 0, SpecCorner "slab" 15, SpecSolid "slab" 15, SpecCorner "slab" 15]]
    )

-- | A corner solid replies with @material@ and @corner_mask@ and no @shape@, a side solid with @material@ and @shape@ and no
-- @corner_mask@, and air with neither, on a cell, a column, a surface and a region read alike; the region copy equals the native snapshot's.
cornerSpec ∷ Spec
cornerSpec =
  it "replies with corner_mask for a corner solid and shape for a side solid, on cell, column, surface and region reads, equal to the native snapshot" $
    withRig $ \rig → do
      let svc = rgService rig
          cellStep ∷ Text → Int → Int → Int → Step
          cellStep label x y z = Step label ("return api.terrain.cell(A, {x = " <> n x <> ", y = " <> n y <> ", z = " <> n z <> "})") "return ctext(v)"
          n = Text.pack . show
          steps =
            stepsScript "nil" (reportPrelude <> cornerPrelude) (
              [ cellStep "corner slope" 3 5 5
              , cellStep "side slope" 4 5 5
              , cellStep "corner block" 5 5 5
              , cellStep "side block" 6 5 5
              , cellStep "corner zero" 7 5 5
              , Step "column" "return api.terrain.column(A, {x = 3, y = 6, z_min = 4, z_max = 10})" "return runtext(v)"
              , Step "surface" "return api.terrain.surface(A, {x = 3, y = 6})" "return stext(v)"
              , Step "surface of a side column" "return api.terrain.surface(A, {x = 4, y = 5})" "return stext(v)"
              , readStep "region" "R0"
              ])
      withHostedArena rig cornerSource steps $ \world creator → do
        printed ← finished world
        native ← digestOfRegion svc creator (RegionCoord 0 0 0)
        let line label text = label <> "\tsuccess\t" <> text
        printed `shouldContain` [line "corner slope" "false slab nil 9 4"]
        printed `shouldContain` [line "side slope" "false slab 3 nil 4"]
        printed `shouldContain` [line "corner block" "false slab nil 15 4"]
        printed `shouldContain` [line "side block" "false slab 0 nil 4"]
        printed `shouldContain` [line "corner zero" "true nil nil nil 2"]
        -- side 0, corner 15, side 15 and corner 15 again are four runs, never joined
        printed
          `shouldContain` [ line
                              "column"
                              "4:5:false:stone:0:nil:5 5:6:false:slab:0:nil:5 6:7:false:slab:nil:15:5 7:8:false:slab:15:nil:5 8:9:false:slab:nil:15:5 9:10:true:nil:nil:nil:3"
                          ]
        printed `shouldContain` [line "surface" "true 8 slab nil 15 5"]
        -- a column that tops out at the stone layer reports its side identity 0, not a corner mask
        printed `shouldContain` [line "surface of a side column" "true 7 stone 0 nil 5"]
        -- the region copy equals what the native snapshot holds, a corner solid keyed by its mask
        printed `shouldContain` [readLine "region" native]
        native `shouldSatisfy` ("xslab:c9" `Text.isInfixOf`)
        native `shouldSatisfy` ("xslab:c15" `Text.isInfixOf`)
        native `shouldSatisfy` ("xslab:3" `Text.isInfixOf`)

-- | A script that attaches the arena the host created, named @shared@, instead of opening one of its own.
attachShared ∷ Script → Script
attachShared steps = steps {scInit = ["self.s = 0", "self.q = api.terrain.attach('shared')"]}

-- | A Lua instance attached to an arena the host opened from a Haskell source, for the body, which is given the host's own lease on it.
-- The corner form is authored natively here, as a Haskell source; "Test.LuaEngine.Terrain.Corners" authors it from Lua.
withHostedArena ∷ Rig → SourceSpec → Script → (World → ArenaLease → IO a) → IO a
withHostedArena rig source steps body = do
  let svc = rgService rig
  client ← registerClient svc >>= either (fail . show) pure
  ( do
      opening ← openArena svc client (arenaName rig "modules-test" "shared") source >>= either (fail . show) pure
      creator ← await svc opening >>= either (fail . show) pure
      withScript rig fixedM1Profile presentationOver (attachShared steps) (\world _ → body world creator)
    )
    `finally` endClient svc client

-- | The Lua that reads a corner reply: the discriminators a record carries, and its keys.
cornerPrelude ∷ [Text]
cornerPrelude =
  [ "local function ctext(c) return tostring(c.air) .. ' ' .. tostring(c.material) .. ' ' .. tostring(c.shape) .. ' ' .. tostring(c.corner_mask) .. ' ' .. nkeys(c) end"
  , "local function runtext(v)"
  , "  local out = {}"
  , "  for _, r in ipairs(v.runs) do"
  , "    out[#out + 1] = r.z_min .. ':' .. r.z_max .. ':' .. tostring(r.air) .. ':' .. tostring(r.material) .. ':' .. tostring(r.shape) .. ':' .. tostring(r.corner_mask) .. ':' .. nkeys(r)"
  , "  end"
  , "  return table.concat(out, ' ')"
  , "end"
  , "local function stext(v) return tostring(v.occupied) .. ' ' .. tostring(v.z) .. ' ' .. tostring(v.material) .. ' ' .. tostring(v.shape) .. ' ' .. tostring(v.corner_mask) .. ' ' .. nkeys(v) end"
  ]

-- | A failed page makes unavailable each part that needed it, independently of the other, in the copy as in the native snapshot.
unavailableSpec ∷ Spec
unavailableSpec =
  it "reports the knowledge unavailable beside a ready terrain when a page only it needed fails, as the native snapshot does, and both ready once the page reads again" $ do
    faults ← newFaults
    seen ← newIORef []
    withRigPort defaultConfig noProbe noTerrainHooks (seamPort faults) $ \rig → do
      let -- one removal in each of the 64 columns beside the region: the knowledge of the region reads their runs and its terrain does not
          ring ∷ [(Int, Int)]
          ring = [(-1, y) | y ← [0 .. 15]] <> [(16, y) | y ← [0 .. 15]] <> [(x, -1) | x ← [0 .. 15]] <> [(x, 16) | x ← [0 .. 15]]
          removals = [Step ("remove " <> Text.pack (show (x, y))) ("return api.terrain.remove(A, {x = " <> Text.pack (show x) <> ", y = " <> Text.pack (show y) <> ", z = 0})") "return ''" | (x, y) ← ring]
          steps =
            stepsScript
              "SHAPED"
              (reportPrelude <> shapedPrelude)
              ( removals
                  <> shaftSteps
                  <> [ quietStep "quiet"
                     , Step "faulted" "TEST_WAIT('fault') return api.terrain.region(A, R0)" "return report(v)"
                     , Step "healed" "TEST_WAIT('heal') return api.terrain.region(A, R0)" "return report(v)"
                     ]
              )
          pagesRead svc lease region = do
            earlier ← length <$> nativeOps faults
            _ ← digestOfRegion svc lease region
            ops ← drop earlier <$> nativeOps faults
            pure (Set.fromList [offset | OpReadAt offset _ ← ops])
          unavailable key digest = (key <> " unavailablenil") `Text.isInfixOf` digest
          failing page = addRule faults (-1) (\case OpReadAt offset _ → offset == page; _ → False) (FailWith 5)
      withScript rig fixedM1Profile presentationOver steps $ \world _ → do
        let go = stepUntil world
        -- the pages the region's build reads, and what failing each of them alone makes of the native snapshot's two parts
        outcomes ← atWait rig go "quiet" $ withNative rig $ \svc lease → do
          pages ← pagesRead svc lease (RegionCoord 0 0 0)
          pages `shouldSatisfy` (not . Set.null)
          forM_ (Set.toList pages) $ \page → do
            clearRules faults
            failing page
            digest ← digestOfRegion svc lease (RegionCoord 0 0 0)
            clearRules faults
            modifyIORef' seen ((page, (unavailable "T" digest, unavailable "K" digest)) :)
          readIORef seen
        -- the parts are independent: a page only the knowledge needed leaves the terrain ready and the knowledge unavailable
        page ← case [candidate | (candidate, (False, True)) ← outcomes] of
          found : _ → pure found
          [] → fail ("no page of the region's build leaves the terrain ready and the knowledge unavailable: " <> show outcomes)
        faulted ← atWait rig go "fault" $ do
          failing page
          withNative rig $ \svc lease → digestOfRegion svc lease (RegionCoord 0 0 0)
        healed ← atWait rig go "heal" $ do
          clearRules faults
          withNative rig $ \svc lease → digestOfRegion svc lease (RegionCoord 0 0 0)
        printed ← go (elem "done" <$> outLinesSTM world) >> outLines world
        printed `shouldContain` [readLine "faulted" faulted]
        printed `shouldContain` [readLine "healed" healed]
        -- the fault made something unavailable and the page that reads again made nothing so
        "unavailable" `Text.isInfixOf` faulted `shouldBe` True
        "unavailable" `Text.isInfixOf` healed `shouldBe` False
        -- the ready terrain part is the native snapshot's, cell for cell, beside the unavailable knowledge (the digests above carry both)
        (unavailable "T" faulted, unavailable "K" faulted) `shouldBe` (False, True)

-- | The worst-case region on the stock profile, and a profile too tight for it.
limitsSpec ∷ Spec
limitsSpec = do
  it "carries a worst-case region on the stock profile: every cell a solid of the longest material and the greatest shape" $
    withRig $ \rig → do
      let steps =
            stepsScript
              "FULL"
              (reportPrelude <> ["local BIG = string.rep('m', 64)", "local FULL = { materials = { BIG }, layers = { { material = BIG, shape = 15 } } }"])
              [quietStep "quiet", readStep "region" "R0"]
      withScript rig fixedM1Profile presentationOver steps $ \world _ → do
        let go = stepUntil world
        native ← atWait rig go "quiet" $ withNative rig $ \svc lease → digestOfRegion svc lease (RegionCoord 0 0 0)
        printed ← go (elem "done" <$> outLinesSTM world) >> outLines world
        printed `shouldContain` [readLine "region" native]
        -- all 8,192 cells of the terrain part are the one solid
        native `shouldSatisfy` Text.isInfixOf ("T 8192[8192x" <> Text.replicate 64 "m" <> ":15]")
  it "carries a worst-case corner region on the stock profile: every cell a corner solid of the longest material, whose longer discriminator name admission judged" $
    withRig $ \rig → do
      let big = replicate 64 'm'
          steps = stepsScript "nil" reportPrelude [readStep "region" "R0"]
      withHostedArena rig (SourceSpec [big] [CornerLayerSpec Nothing Nothing big 15] []) steps $ \world creator → do
        printed ← finished world
        native ← digestOfRegion (rgService rig) creator (RegionCoord 0 0 0)
        printed `shouldContain` [readLine "region" native]
        native `shouldSatisfy` Text.isInfixOf ("T 8192[8192x" <> Text.replicate 64 "m" <> ":c15]")
  it "refuses a region before admission, as an ordinary error that takes no request place, on a profile whose copied-value limits cannot carry the worst reply" $
    withRig $ \rig → do
      let checks =
            script
              { scPrelude = terrainPrelude
              , scInit = ["self.open = api.terrain.open('main', DEF)"]
              , scUpdate =
                  [ "if not self.ran then"
                  , "  local t = settle(api, self.open)"
                  , "  if t then"
                  , "    self.ran = true"
                  , "    local A = t.value"
                  , "    " <> caseLua (Case "region" "api.terrain.region(A, {x = 0, y = 0, z = 0})" (Refused ["copied-value limits cannot carry"]))
                  , "    " <> caseLua (Case "cell" "api.terrain.cell(A, {x = 0, y = 0, z = 0})" Accepted)
                  , "    for i = 1, 20 do pcall(api.terrain.region, A, {x = 0, y = 0, z = 0}) end"
                  , "    local taken = 0"
                  , "    for i = 1, 16 do if api.terrain.cell(A, {x = i, y = 0, z = 0}) ~= nil then taken = taken + 1 end end"
                  , "    print('places after the refusals', taken)"
                  , "    print('done')"
                  , "  end"
                  , "end"
                  ]
              }
      withScript rig tightProfile presentationOver checks $ \world _ → do
        printed ← finished world
        checkCases [Case "region" "" (Refused ["copied-value limits cannot carry"]), Case "cell" "" Accepted] printed
        -- the cell read of the case holds one place; the twenty refusals held none
        printed `shouldContain` ["places after the refusals\t15"]
        nothingHeld (rgService rig)

-- | The stock profile with a copied-value element limit under the worst region's 57,355.
tightProfile ∷ Profile
tightProfile = either (error . ("the tight profile is invalid: " <>) . show) id (validateProfile base {specCounts = tighter})
  where
    base = profileSpec fixedM1Profile
    tighter limit = case limit of
      CopiedValueElements → Count 50000
      SceneSprites → Count 512
      _ → specCounts base limit

-- | What a script may hand the call, and what the service's own configuration refuses before any bank is asked.
refusalSpec ∷ Spec
refusalSpec = do
  it "declares the arena's closure as the only expected failure of the kind, and no storage code: an unreadable page is an unavailable part" $
    terrainCodesFor "terrain_region" `shouldBe` ["arena_closed"]
  it "refuses every bad address, shape and released handle as an ordinary error before admission, and takes no request place" $
    withRig $ \rig → do
      let cases =
            [ Case "colon call" "api.terrain:region(A, R0)" (Refused ["terrain_region"])
            , Case "no arguments" "api.terrain.region()" (Refused ["expected 2 values, found 0"])
            , Case "one argument" "api.terrain.region(A)" (Refused ["expected 2 values, found 1"])
            , Case "three arguments" "api.terrain.region(A, R0, nil)" (Refused ["expected 2 values, found 3"])
            , Case "handle a string" "api.terrain.region('x', R0)" (Refused ["expected capability"])
            , Case "region a number" "api.terrain.region(A, 5)" (Refused ["expected record"])
            , Case "region without z" "api.terrain.region(A, {x = 0, y = 0})" (Refused ["z"])
            , Case "region with an extra field" "api.terrain.region(A, {x = 0, y = 0, z = 0, w = 1})" (Refused ["w"])
            , Case "x a float" "api.terrain.region(A, {x = 0.0, y = 0, z = 0})" (Refused ["a float where an integer is declared"])
            , Case "y a string" "api.terrain.region(A, {x = 0, y = '0', z = 0})" (Refused ["expected integer"])
            , Case "x above the last region" "api.terrain.region(A, {x = 1 << 58, y = 0, z = 0})" (Refused ["x is outside the supported region indices"])
            , Case "x below the first region" "api.terrain.region(A, {x = -(1 << 58) - 1, y = 0, z = 0})" (Refused ["x is outside the supported region indices"])
            , Case "y above the last region" "api.terrain.region(A, {x = 0, y = 1 << 58, z = 0})" (Refused ["y is outside the supported region indices"])
            , Case "z above the last region" "api.terrain.region(A, {x = 0, y = 0, z = 1 << 57})" (Refused ["z is outside the supported region indices"])
            , Case "z below the first region" "api.terrain.region(A, {x = 0, y = 0, z = -(1 << 57) - 1})" (Refused ["z is outside the supported region indices"])
            , Case "a released handle" "api.terrain.region(G, R0)" (Refused ["handle that has ended"])
            ]
          checks =
            script
              { scPrelude = terrainPrelude <> ["local A, G, R0 = nil, nil, {x = 0, y = 0, z = 0}"]
              , scInit = ["self.open = api.terrain.open('main', DEF)", "self.gone = api.terrain.open('gone', DEF)"]
              , scUpdate =
                  [ "if not self.ran then"
                  , "  self.a = self.a or settle(api, self.open)"
                  , "  self.g = self.g or settle(api, self.gone)"
                  , "  if self.a and self.g then"
                  , "    self.ran = true"
                  , "    A, G = self.a.value, self.g.value"
                  , "    api.terrain.release(G)"
                  ]
                    <> map (("    " <>) . caseLua) cases
                    <> [ "    local taken = 0"
                       , "    for i = 1, 16 do if api.terrain.cell(A, {x = i, y = 0, z = 0}) ~= nil then taken = taken + 1 end end"
                       , "    print('places after the refusals', taken)"
                       , "    print('done')"
                       , "  end"
                       , "end"
                       ]
              }
      withScript rig fixedM1Profile presentationOver checks $ \world _ → do
        printed ← finished world
        checkCases cases printed
        printed `shouldContain` ["places after the refusals\t16"]
        nothingHeld (rgService rig)
  mapM_
    (\(label, config, reason) → it ("refuses every region as an ordinary error, never as busy, from a service " <> label) $ withRigConfig config $ \rig → refusedBy rig reason)
    [ ("whose extent is not a whole region", tightRigConfig, "extent is not a whole region")
    , ("whose hold admits no region", holdless, "hold admits no region")
    ]
  it "answers nil and busy, with a place, a lease and a charge left to nobody, when the retained bank cannot make the reservation" $
    withRigConfig defaultConfig {configRetainedBytes = 600000} $ \rig → do
      let checks =
            script
              { scPrelude = terrainPrelude
              , scInit = ["self.open = api.terrain.open('main', DEF)"]
              , scUpdate =
                  [ "if not self.ran then"
                  , "  local t = settle(api, self.open)"
                  , "  if t then"
                  , "    self.ran = true"
                  , "    local n = select('#', api.terrain.region(t.value, {x = 0, y = 0, z = 0}))"
                  , "    local r, e = api.terrain.region(t.value, {x = 0, y = 0, z = 0})"
                  , "    print('busy', n, r == nil, e.code, type(e.message))"
                  , "    local taken = 0"
                  , "    for i = 1, 16 do if api.terrain.cell(t.value, {x = i, y = 0, z = 0}) ~= nil then taken = taken + 1 end end"
                  , "    print('places after the refusals', taken)"
                  , "    print('done')"
                  , "  end"
                  , "end"
                  ]
              }
      withScript rig fixedM1Profile presentationOver checks $ \world _ → do
        printed ← finished world
        printed `shouldContain` ["busy\t2\ttrue\tbusy\tstring", "places after the refusals\t16"]
        nothingHeld (rgService rig)
  where
    refusedBy rig reason = do
      let cases = [Case "region" "api.terrain.region(A, {x = 0, y = 0, z = 0})" (Refused [reason])]
          checks =
            script
              { scPrelude = terrainPrelude <> ["local A"]
              , scInit = ["self.open = api.terrain.open('main', DEF)"]
              , scUpdate =
                  [ "if not self.ran then"
                  , "  local t = settle(api, self.open)"
                  , "  if t then"
                  , "    self.ran = true"
                  , "    A = t.value"
                  ]
                    <> map (("    " <>) . caseLua) cases
                    <> ["    print('done')", "  end", "end"]
              }
      withScript rig fixedM1Profile presentationOver checks $ \world _ → do
        printed ← finished world
        checkCases cases printed
        nothingHeld (rgService rig)

-- | The service's own limits with a hold that admits no region.
holdless ∷ Config
holdless = defaultConfig {configLimits = either (error . ("the hold-less limits are invalid: " <>) . show) id (mkLimits spec')}
  where
    spec' =
      LimitsSpec
        { specResidentBytes = 256 * 1024 * 1024
        , specEditBytes = 64 * 1024 * 1024
        , specStagingBytes = 128 * 1024 * 1024
        , specLoadJobs = 128
        , specQueuedCommands = 256
        , specPinsPerView = 2
        , specAgingQuanta = 8
        , specQueryRegions = 257
        , specExtentX = 16
        , specExtentY = 16
        , specExtentZ = 32
        , specHoldRegions = 0
        , specCameraRegions = 16384
        }

-- | A peer's arena handle is refused as an ordinary error, whatever it names.
ownershipSpec ∷ Spec
ownershipSpec =
  it "refuses another instance's arena handle as an ordinary error before admission" $
    withRig $ \rig → do
      let peers =
            script
              { scPrelude = terrainPrelude <> ["SHARED = {}"]
              , scInit = ["self.s = 0", "if api.instance_id == 'inst-1' then self.q = api.terrain.open('shared', DEF) end"]
              , scUpdate =
                  [ "if api.instance_id == 'inst-1' then"
                  , "  if self.s == 0 then local t = settle(api, self.q) if t then SHARED.arena = t.value self.s = 1 end end"
                  , "else"
                  , "  if SHARED.arena and self.s == 0 then"
                  , "    try('foreign region', api.terrain.region, SHARED.arena, {x = 0, y = 0, z = 0})"
                  , "    print('done') self.s = 1"
                  , "  end"
                  , "end"
                  ]
              }
      withWorld fixedM1Profile (Layout [("lua/main.lua", scriptSource peers)]) $ \world _ runtime →
        withFvm world runtime (presentationOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          _ ← spawn world fvm "modules-test" mainPath
          printed ← finished world
          printed `shouldContain` ["foreign region => false ; hetoimasia_engine.terrain_region: the arena belongs to another instance"]
          nothingHeld (rgService rig)

-- | What the service keeps for a copy that succeeded and is not taken, and what a copy that was taken outlives.
balanceSpec ∷ Spec
balanceSpec =
  it "gives the borrow back when the request settles, before Lua takes the result, and the taken copy stays coherent through an edit and the arena's closure" $
    withRig $ \rig → do
      let steps =
            stepsScript
              "SHAPED"
              (reportPrelude <> shapedPrelude)
              [ quietStep "quiet"
              , Step "issue" "V.r = api.terrain.region(A, R0) api.request.wait(V.r) TEST_WAIT('settled') return nil" "return ''"
              , Step "edit" "return api.terrain.remove(A, {x = 3, y = 1, z = 0})" "return tostring(v.changed)"
              , Step "close" "print('release', api.terrain.release(A)) return nil" "return ''"
              , Step "taken" "return V.r" "return report(v)"
              ]
      withScript rig fixedM1Profile presentationOver steps $ \world _ → do
        let go = stepUntil world
            svc = rgService rig
        baseline ← atWait rig go "quiet" (retainedUse svc)
        -- the request has settled and nobody has taken its result: the borrow is already given back, with its charge
        expected ← atWait rig go "settled" $ do
          balancedAt svc baseline
          withNative rig $ \_ lease → digestOfRegion svc lease (RegionCoord 0 0 0)
        printed ← go (elem "done" <$> outLinesSTM world) >> outLines world
        -- the copy is the version it was read at, whatever was committed or closed since
        printed `shouldContain` [readLine "taken" expected]
        printed `shouldContain` ["release\tdone"]
        (length <$> atomically (inspectRegionalSTM svc)) `shouldReturn` 0

-- | The two windows of a borrow, each ended by a script's cancel and by its arena's closure: the copy made and the answer not staged,
-- and the answer staged and not offered to the arbitration.
windowSpec ∷ Spec
windowSpec =
  forM_ [("its copy is made and the answer is not staged", \case PointPrepared _ → True; _ → False), ("its answer is staged and not offered to the arbitration", \case PointBeforeCommit _ → True; _ → False)] $ \(window, selects) →
    forM_ [("cancels the request", "print('cancel', api.request.cancel(self.r))"), ("releases the arena", "print('release', api.terrain.release(self.arena))")] $ \(action, act) →
      it ("settles once and gives every charge back when the script " <> action <> " while " <> window) $ do
        gate ← newGate
        disarmGate gate
        withRigProbe defaultConfig (gatedProbe selects gate) $ \rig → do
          let held =
                script
                  { scPrelude = terrainPrelude
                  , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
                  , scUpdate =
                      [ "if self.s == 0 then"
                      , "  local t = settle(api, self.q)"
                      , "  if t then self.arena = t.value print('opened') self.s = 1 end"
                      , "elseif self.s == 1 then"
                      , "  TEST_WAIT('go')"
                      , "  self.r = api.terrain.region(self.arena, {x = 0, y = 0, z = 0})"
                      , "  print('issued') self.s = 2"
                      , "elseif self.s == 2 then"
                      , "  " <> act
                      , "  print('acted') self.s = 3"
                      , "elseif self.s == 3 then"
                      , "  local t = settle(api, self.r)"
                      , "  if t then print('taken', t.status) print('done') self.s = 4 end"
                      , "end"
                      ]
                  }
              svc = rgService rig
          withScript rig fixedM1Profile presentationOver held $ \world _ → (`finally` openGate gate) $ do
            untilPrinted world "opened"
            baseline ← retainedUse svc
            armGate gate
            signalRig rig "go"
            untilPrinted world "issued"
            awaitReached gate
            -- the owner is held: the borrow is the request's, charged beyond the bank's baseline
            charges ← atomically (inspectRegionalSTM svc)
            length charges `shouldBe` 1
            untilPrinted world "acted"
            openGate gate
            untilPrinted world "done"
            printed ← outLines world
            -- one terminal outcome, and not a success: the script ended the request first
            [line | line ← printed, "taken\t" `Text.isPrefixOf` line] `shouldSatisfy` \taken → length taken == 1 && taken /= ["taken\tsuccess"]
            -- a borrow whose request ended while its copy was made is released at the owner's safe point: wait for that release, then read
            bounded (atomically (inspectRegionalSTM svc >>= check . null))
            balancedAt svc baseline

-- | A copy staged at the revision ceiling settles with its pinned revisions after the arena has moved past it: the revisions that count
-- are the snapshot's, never the live arena's.
ceilingSpec ∷ Spec
ceilingSpec =
  it "settles a copy staged at the profile's integer ceiling when the arena has advanced past the ceiling before its tick, with the revisions of the copy" $ do
    prepared ← newEmptyMVar
    answers ← newIORef (0 ∷ Int)
    let -- the open's answer is the first the Lua endpoints prepare and the region's the second
        probe = Probe $ \point → case point of
          PointPrepared _ → do
            n ← atomicModifyIORef' answers (\seen → (seen + 1, seen + 1))
            when (n == 2) (void (tryPutMVar prepared ()))
          _ → pure ()
        reader =
          script
            { scPrelude = terrainPrelude <> reportPrelude
            , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)"]
            , scUpdate =
                [ "if self.s == 0 then"
                , "  local t = settle(api, self.q)"
                , "  if t then self.r = api.terrain.region(t.value, R0) print('issued') self.s = 1 end"
                , "elseif self.s == 1 then"
                , "  local t = settle(api, self.r)"
                , "  if t then print('region', t.status, t.status == 'success' and report(t.value) or t.error.code) print('done') self.s = 2 end"
                , "end"
                ]
            }
    withRigProbe defaultConfig {configFirstRevision = 40} probe $ \rig →
      withWorld (counts [(LuaIntegerMaximum, 40)]) (Layout [("lua/main.lua", scriptSource reader)]) $ \world _ runtime →
        withFvm world runtime (gameplayOver rig) $ \fvm → do
          _ ← spawn world fvm "modules-test" mainPath
          tickUntil fvm (elem "issued" <$> outLinesSTM world)
          -- the copy has been made at revision 40, the ceiling; the arena then moves to 41, which no Lua integer of this VM holds
          bounded (takeMVar prepared)
          withNative rig $ \svc lease → do
            removal ← removeAt svc lease (either (error . show) id (tileCoord 0 0 0)) Nothing >>= either (fail . show) pure
            _ ← await svc removal >>= either (fail . show) pure
            pure ()
          tickUntil fvm (elem "done" <$> outLinesSTM world)
          printed ← outLines world
          [line | line ← printed, "region\tsuccess\t40 " `Text.isPrefixOf` line] `shouldSatisfy` (not . null)

-- | A request that ended while its copy was made keeps its place until the service has released its borrow.
retirementSpec ∷ Spec
retirementSpec =
  it "keeps the place of a cancelled and taken request charged until the service has released its borrow, and gives it back after" $ do
    gate ← newGate
    disarmGate gate
    withRigProbe defaultConfig (gatedProbe (\case PointPrepared _ → True; _ → False) gate) $ \rig → do
      let held =
            script
              { scPrelude = terrainPrelude
              , scInit = ["self.s = 0", "self.q = api.terrain.open('main', DEF)", "self.cells = {}"]
              , scUpdate =
                  [ "if self.s == 0 then"
                  , "  local t = settle(api, self.q)"
                  , "  if t then self.arena = t.value print('opened') self.s = 1 end"
                  , "elseif self.s == 1 then"
                  , "  TEST_WAIT('go')"
                  , "  self.r = api.terrain.region(self.arena, {x = 0, y = 0, z = 0})"
                  , "  print('issued') self.s = 2"
                  , "elseif self.s == 2 then"
                  , "  api.request.cancel(self.r)"
                  , "  print('taken', api.request.take(self.r).status)"
                  , "  local accepted = 0"
                  , "  for i = 1, 16 do"
                  , "    local r = api.terrain.cell(self.arena, {x = i, y = 0, z = 0})"
                  , "    if r ~= nil then accepted = accepted + 1 self.cells[accepted] = r end"
                  , "  end"
                  , "  print('accepted while the borrow is held', accepted)"
                  , "  for _, r in ipairs(self.cells) do api.request.cancel(r) end"
                  , "  print('done') self.s = 3"
                  , "end"
                  ]
              }
          svc = rgService rig
      withScript rig fixedM1Profile presentationOver held $ \world _ → (`finally` openGate gate) $ do
        untilPrinted world "opened"
        baseline ← retainedUse svc
        armGate gate
        signalRig rig "go"
        untilPrinted world "issued"
        awaitReached gate
        untilPrinted world "done"
        printed ← outLines world
        -- the cancelled request's place is not given back while the owner still holds the borrow: one of the sixteen is taken
        printed `shouldContain` ["accepted while the borrow is held\t15"]
        openGate gate
        bounded (atomically (inspectRegionalSTM svc >>= check . null))
        balancedAt svc baseline

-- | The window between the service's admission of a regional request and the host's record of it: the arena closes there, while the
-- service's gather still holds the borrow, and the request is failed and taken before the host can ask about its borrow.
admissionSpec ∷ Spec
admissionSpec =
  it "keeps the place of a regional request that the arena's closure failed before the host recorded it, until the service has released its borrow" $ do
    admitted ← newGate
    owner ← newGate
    disarmGate admitted
    disarmGate owner
    withRigHooks defaultConfig (gatedProbe (\case PointPrepared _ → True; _ → False) owner) noTerrainHooks {hookAdmitted = holdAt admitted} $ \rig → do
      let svc = rgService rig
          attached =
            script
              { scPrelude = terrainPrelude
              , scInit = ["self.s = 0", "self.q = api.terrain.attach('shared')", "self.cells = {}"]
              , scUpdate =
                  [ "if self.s == 0 then"
                  , "  local t = settle(api, self.q)"
                  , "  if t then self.arena = t.value print('attached') self.s = 1 end"
                  , "elseif self.s == 1 then"
                  , "  TEST_WAIT('go')"
                  , "  self.r = api.terrain.region(self.arena, {x = 0, y = 0, z = 0})"
                  , "  print('issued') self.s = 2"
                  , "elseif self.s == 2 then"
                  , "  local t = settle(api, self.r)"
                  , "  if t then"
                  , "    print('taken', t.status, t.error and t.error.code)"
                  , "    local accepted = 0"
                  , "    for i = 1, 16 do"
                  , "      local r = api.terrain.cell(self.arena, {x = i, y = 0, z = 0})"
                  , "      if r ~= nil then accepted = accepted + 1 self.cells[accepted] = r end"
                  , "    end"
                  , "    print('accepted while the borrow is held', accepted)"
                  , "    for _, r in ipairs(self.cells) do api.request.cancel(r) end"
                  , "    print('done') self.s = 3"
                  , "  end"
                  , "end"
                  ]
              }
      -- the host creates the arena, whose creator lease is what closes it; the Lua instance attaches
      client ← registerClient svc >>= either (fail . show) pure
      opening ← openArena svc client (arenaName rig "modules-test" "shared") (SourceSpec ["soil"] [LayerSpec Nothing (Just 10) "soil" 0] []) >>= either (fail . show) pure
      creator ← await svc opening >>= either (fail . show) pure
      withScript rig fixedM1Profile presentationOver attached $ \world _ → (`finally` (openGate admitted >> openGate owner)) $ do
        untilPrinted world "attached"
        stepUntil world (elem "entered go" <$> readTVar (rgTrace rig))
        armGate admitted
        armGate owner
        signalRig rig "go"
        -- the service's gather has built the copy and is held; the host has not recorded the request
        awaitReached owner
        releaseLease svc creator >>= either (fail . show) pure
        openGate admitted
        untilPrinted world "done"
        printed ← outLines world
        printed `shouldContain` ["taken\tfailure\tarena_closed", "accepted while the borrow is held\t15"]
        openGate owner
        bounded (atomically (inspectRegionalSTM svc >>= check . null))
        nothingHeld svc
