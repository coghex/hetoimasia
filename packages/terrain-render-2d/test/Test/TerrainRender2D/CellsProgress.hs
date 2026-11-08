-- | TRA-16: pending data, progressive preparation, demand and delivery
-- behaviour of the cell-quad planner. See "Test.TerrainRender2D.CellFixtures"
-- for the scenes; the demand reference is a brute-force enumeration of the
-- sprites that touch the viewport, written here with its own projection
-- arithmetic.
module Test.TerrainRender2D.CellsProgress (spec) where

import Control.Monad (forM_)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import qualified Data.Set as Set
import Hetoimasia.Math.Vector (V2 (..))
import Data.Ratio (denominator)
import Data.Word (Word32)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Terrain.Cell (Column (..), ZRange, mkZRange)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisValue)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.CellPick
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Shape (ViewFacing (..), allViewFacings)
import Hetoimasia.Terrain.Source
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Test.Hspec
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Fixtures (axis, factsOf, flatWorld, followCamera, setup, source, tileAt)

spec ∷ Spec
spec = describe "Cell planning delivery (TRA-16)" $ beforeAll (loadAssets 5) $ do
  pendingData
  reveals
  identities
  capacity
  progress
  demand
  summaries
  privacy
  refusals

zr ∷ Integer → Integer → ZRange
zr lo hi = either (error . show) id (mkZRange lo hi)

centrePixel ∷ CellPlan → TileCoord → (Int, Int)
centrePixel plan tile = case [q | q ← cellPlanQuads plan, quadCell q == Just tile] of
  q : _ → case quadTarget q of TargetRect l t _ _ → (floor (l + 48), floor (t + 32))
  [] → error ("no quad for " <> show tile)

-- What a quad is, in full: the same for two plans exactly when they draw alike.
fullView ∷ CellQuad → (PartKind, Maybe TileCoord, ColourRef, CellKey, Word32, TargetRect)
fullView q = (quadPart q, quadCell q, quadColour q, quadKey q, quadDepthKey q, quadTarget q)

withConfig ∷ (CellConfig → CellConfig) → Scene → Scene
withConfig f scene = scene {sceneConfig = f (sceneConfig scene)}

withLimits ∷ (CellLimits → CellLimits) → Scene → Scene
withLimits f = withConfig (\c → c {ccLimits = f (ccLimits c)})

-- ---------------------------------------------------------------------------

pair ∷ [OCell]
pair = [OCell 0 0 0 0 KnownAll, OCell 1 1 3 0 KnownAll]

pendingScene ∷ Knowledge → Availability → Scene
pendingScene = sceneFrom FaceSouth 3 0 0 (sourceOf pair)

pendingData ∷ SpecWith AssetSnapshot
pendingData = describe "pending information in front of and behind a hit" $ do
  let rear = tileAt 0 0 0
      front = tileAt 1 1 3
      pendingAt x y z = knowledgeOf 1 CellDiscovered [(x, y, z, CellPending)]
  it "returns loading, with no candidate, when retained knowledge not yet arrived could lie ahead of the hit" $ \assets → do
    let plan = planScene assets (pendingScene (pendingAt 1 1 3) AllKnown)
    cellPlanProgress plan `shouldBe` Settled
    length (cellPlanPending plan) `shouldBe` 1
    pickPixel plan (centrePixel plan rear) `shouldBe` CellPickLoading
  it "keeps a hit when the pending information is proved behind it" $ \assets → do
    let plan = planScene assets (pendingScene (pendingAt 0 0 0) AllKnown)
    fmap hitCell (hitOf (pickPixel plan (centrePixel plan front))) `shouldBe` Just front
  it "is a miss, not loading, away from every pending footprint" $ \assets → do
    let plan = planScene assets (pendingScene (pendingAt 1 1 3) AllKnown)
    pickPixel plan (4, 4) `shouldBe` CellPickNoHit
  it "is loading through a pending footprint when no quad covers the point at all" $ \assets → do
    let plan = planScene assets (sceneFrom FaceSouth 3 0 0 (sourceOf []) (pendingAt 0 0 3) AllKnown)
        (_, pendingFootprint) = (cellPlanQuads plan, cellPlanPending plan)
    cellPlanQuads plan `shouldBe` []
    length pendingFootprint `shouldBe` 1
    -- The pending cell's own canvas: roughly the viewport centre.
    pickPixel plan (160, 120) `shouldBe` CellPickLoading
  it "never fabricates air for unavailable terrain: it is pending, named in the demand, and drawn as nothing" $ \assets → do
    let everywhere = mkAvailability ([(ChunkKey cx cy, [zr (-2000) 2000]) | cx ← [-8 .. 8], cy ← [-8 .. 8], (cx, cy) /= (0, 0)] <> [(ChunkKey 0 0, [zr 0 3])])
        plan = planScene assets (pendingScene (knowledgeOf 1 CellDiscovered []) everywhere)
        wanted = [d | d ← demandChunks (cdVisible (cellPlanDemand plan)), demandChunk d == ChunkKey 0 0]
    [q | q ← cellPlanQuads plan, quadCell q == Just front] `shouldBe` []
    [any (\(a, b) → a <= 3 && 3 < b) (demandIntervals d) | d ← wanted] `shouldBe` [True]
    pickPixel plan (centrePixel plan rear) `shouldBe` CellPickLoading
  it "is loading everywhere in the viewport when nothing is available, never a miss" $ \assets → do
    let plan = planScene assets (pendingScene (knowledgeOf 1 CellDiscovered []) (mkAvailability []))
    cellPlanQuads plan `shouldBe` []
    cellPlanProgress plan `shouldBe` Settled
    [p | p ← stridePixels 9, pickPixel plan p /= CellPickLoading] `shouldBe` []
    length (demandChunks (cdVisible (cellPlanDemand plan))) `shouldSatisfy` (> 0)

hitOf ∷ CellPickResult → Maybe CellHit
hitOf (CellPickHit h) = Just h
hitOf _ = Nothing

-- ---------------------------------------------------------------------------

reveals ∷ SpecWith AssetSnapshot
reveals = describe "reveal updates, offload and reload, and late knowledge" $ do
  let ramp = sourceOf [OCell 0 0 0 5 KnownAll]
      viewOf assets src revision state avail =
        let plan = planScene assets (sceneFrom FaceSouth 0 0 0 src (knowledgeOf revision CellDiscovered [(0, 0, 0, state)]) avail)
         in (plan, map fullView (cellPlanQuads plan))
      parts plan = [quadPart q | q ← cellPlanQuads plan]
  it "selects the ordinary map when a void is discovered, the terrain truth unchanged" $ \assets → do
    let (p1, _) = viewOf assets ramp 1 CellUndiscovered AllKnown
        (p2, _) = viewOf assets ramp 2 CellSolidKnown AllKnown
        (p3, _) = viewOf assets ramp 3 CellDiscovered AllKnown
    (parts p1, parts p2, parts p3) `shouldBe` ([PartFog], [PartFog, PartKnown], [PartOrdinary])
  it "follows two supplied reveal updates, each a new coherent plan" $ \assets → do
    let two = sourceOf [OCell 0 0 0 0 KnownAll, OCell 3 0 0 5 KnownAll]
        at revision a c = planScene assets (sceneFrom FaceSouth 0 0 0 two (knowledgeOf revision CellDiscovered [(0, 0, 0, a), (3, 0, 0, c)]) AllKnown)
        known p = [quadCell q | q ← cellPlanQuads p, quadPart q /= PartFog]
    map known [at 1 CellUndiscovered CellUndiscovered, at 2 CellDiscovered CellUndiscovered, at 3 CellDiscovered CellDiscovered]
      `shouldBe` [[], [Just (tileAt 0 0 0)], [Just (tileAt 0 0 0), Just (tileAt 3 0 0)]]
    cellIdentityKnowledge (cellPlanIdentity (at 3 CellDiscovered CellDiscovered)) `shouldBe` 3
  it "drops a discovered cell to pending, not air or fog, when its chunk is offloaded, and restores it identically on reload" $ \assets → do
    let offloaded = mkAvailability [(ChunkKey cx cy, [zr (-2000) 2000]) | cx ← [-8 .. 8], cy ← [-8 .. 8], (cx, cy) /= (0, 0)]
        (pLoaded, loaded) = viewOf assets ramp 1 CellDiscovered AllKnown
        (pOff, off) = viewOf assets ramp 1 CellDiscovered offloaded
        (_, reloaded) = viewOf assets ramp 1 CellDiscovered AllKnown
    length loaded `shouldBe` 1
    off `shouldBe` []
    any (\d → demandChunk d == ChunkKey 0 0) (demandChunks (cdVisible (cellPlanDemand pOff))) `shouldBe` True
    reloaded `shouldBe` loaded
    cellPlanProgress pLoaded `shouldBe` Settled
  it "keeps confirmed fog when terrain is offloaded: undiscovered display never reads the terrain" $ \assets → do
    let offloaded = mkAvailability [(ChunkKey cx cy, [zr (-2000) 2000]) | cx ← [-8 .. 8], cy ← [-8 .. 8], (cx, cy) /= (0, 0)]
        (_, loaded) = viewOf assets ramp 1 CellUndiscovered AllKnown
        (_, off) = viewOf assets ramp 1 CellUndiscovered offloaded
    length loaded `shouldBe` 1
    off `shouldBe` loaded
  it "turns late knowledge into loading, then fog or a hit, and never calls pending knowledge undiscovered" $ \assets → do
    let planFor state = planScene assets (sceneFrom FaceSouth 0 0 0 ramp (knowledgeOf 1 CellDiscovered [(0, 0, 0, state)]) AllKnown)
        waiting = planFor CellPending
        fogged = planFor CellUndiscovered
        known = planFor CellDiscovered
        centre = (160, 120 - 8)
    cellPlanQuads waiting `shouldBe` []
    [PartFog] `shouldBe` map quadPart (cellPlanQuads fogged)
    pickPixel waiting centre `shouldBe` CellPickLoading
    pickPixel fogged centre `shouldBe` CellPickNoHit
    fmap hitCell (hitOf (pickPixel known centre)) `shouldBe` Just (tileAt 0 0 0)

-- ---------------------------------------------------------------------------

identities ∷ SpecWith AssetSnapshot
identities = describe "plan identity" $ do
  let base = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]
  it "rejects a stale camera, knowledge, asset, metrics and configuration identity, and a mixed version set" $ \assets → do
    newerAssets ← loadAssets 6
    let plan = planScene assets base
        askWith other = pickCells plan (CellPickQuery (cellPlanIdentity other) (V2 160.5 100.5))
        variants =
          [ ("camera revision", planScene assets base {sceneCamera = either (error . show) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (Pan 0.5 0) (sceneCamera base))})
          , ("knowledge revision", planScene assets base {sceneKnowledge = knowledgeOf 2 CellDiscovered [(0, 0, 0, CellDiscovered)]})
          , ("asset versions", planScene newerAssets base)
          , ("target metrics", planScene assets base {sceneSetup = (setup 640 480)})
          , ("configuration", planScene assets (withConfig (\c → c {ccDepth = 100}) base))
          ]
    forM_ variants $ \(name, other) → (name, askWith other) `shouldBe` (name, Left CellPickStale)
    pickCells plan (CellPickQuery (cellPlanIdentity plan) (V2 160.5 100.5)) `shouldSatisfy` isRight'
    cellIdentityKnowledge (cellPlanIdentity plan) `shouldBe` 1
  it "refuses a request whose versions differ from the facts'" $ \assets → do
    let inputs = inputsOf assets base
        request = inputsRequest inputs
        mixed = inputs {inputsRequest = request {crVersions = Versions 1 1 2}}
    planCells mixed `shouldSatisfy` (\r → case r of Left (CellMixedVersions _ _) → True; _ → False)

isRight' ∷ Either a b → Bool
isRight' (Right _) = True
isRight' _ = False

-- ---------------------------------------------------------------------------

capacity ∷ SpecWith AssetSnapshot
capacity = describe "capacity and atomic admission" $ do
  let cells = [OCell 0 0 0 5 KnownSolid, OCell 3 0 0 0 KnownAll, OCell 0 3 0 12 KnownSolid, OCell 3 3 0 0 Undisc]
      scene = sceneOf FaceSouth 0 cells
      sibling q = let CellKey a z x y _ = quadKey q in (a, z, x, y)
  it "never splits a mixed cell's parts under one-instance and one-key pressure, and ranks them distinctly below the limit" $ \assets → do
    let full = planScene assets scene
        total = length (cellPlanQuads full)
    total `shouldBe` 6
    forM_ [0 .. total] $ \limit → do
      let plan = planScene assets (withLimits (\l → l {clInstances = limit}) scene)
          quads = cellPlanQuads plan
          knownCells = Set.fromList [sibling q | q ← quads, quadPart q == PartKnown]
          fogCells = Set.fromList [sibling q | q ← quads, quadPart q == PartFog]
      length quads `shouldSatisfy` (<= limit)
      -- Every mixed cell admitted has both of its parts.
      (Set.toList (knownCells `Set.difference` fogCells)) `shouldBe` []
      sort (map quadDepthKey quads) `shouldBe` map fromIntegral [0 .. length quads - 1]
      (cellPlanProgress plan == Settled) `shouldBe` (limit >= total)
    cellPlanProgress (planScene assets (withLimits (\l → l {clInstances = total - 1}) scene)) `shouldBe` Halted HaltInstances
    map quadDepthKey (cellPlanQuads full) `shouldBe` map fromIntegral [0 .. total - 1]
  it "leaves a halted plan's remainder unresolved, so a pick through it is loading, not a miss" $ \assets → do
    let plan = planScene assets (withLimits (\l → l {clInstances = 1}) scene)
    cellPlanProgress plan `shouldBe` Halted HaltInstances
    (isNothing (cellPlanUnresolved plan)) `shouldBe` False
    pickPixel plan (160, 112) `shouldBe` CellPickLoading
  it "accepts the whole 24-bit key space as a limit without allocating it, and refuses one key more" $ \assets → do
    let atLimit = planScene assets (withLimits (\l → l {clInstances = 2 ^ (24 ∷ Int)}) scene)
    cellPlanProgress atLimit `shouldBe` Settled
    planSceneWith assets (withLimits (\l → l {clInstances = 2 ^ (24 ∷ Int) + 1}) scene) `shouldSatisfy` (\r → case r of Left CellInvalidConfig → True; _ → False)

-- ---------------------------------------------------------------------------

progress ∷ SpecWith AssetSnapshot
progress = describe "bounded, resumable preparation" $ do
  let cells = [OCell x y 0 (fromInteger ((x + y) `mod` 16)) KnownAll | x ← [0 .. 5], y ← [0 .. 5]]
      scene = sceneOf FaceSouth 0 cells
      tiny = withLimits (\l → l {clStepCandidates = 3, clStepLevels = 40}) scene
      stepsOf inputs prep acc = case cellPrepProgress prep of
        Working → case stepCells inputs prep of
          Right next → stepsOf inputs next (next : acc)
          Left e → error (show e)
        _ → reverse (prep : acc)
  it "does bounded work per step and settles on the same plan as one unbounded pass" $ \assets → do
    let inputs = inputsOf assets tiny
        start = either (error . show) id (startCells inputs)
        trail = stepsOf inputs start [start]
        columnsAfter p = cellStatColumns (cellPlanStats (either (error . show) id (cellPlanOf inputs p)))
        deltas = zipWith (-) (map columnsAfter (drop 1 trail)) (map columnsAfter trail)
    length trail `shouldSatisfy` (> 10)
    deltas `shouldSatisfy` all (<= 3)
    cellPrepProgress (last trail) `shouldBe` Settled
    let settled = either (error . show) id (cellPlanOf inputs (last trail))
        once = planScene assets scene
    map fullView (cellPlanQuads settled) `shouldBe` map fullView (cellPlanQuads once)
    cellPlanDemand settled `shouldBe` cellPlanDemand once
    cellPlanUnresolved settled `shouldSatisfy` isNothing
  it "publishes a coherent partial plan whose unprocessed area is loading and whose near rows come first" $ \assets → do
    let inputs = inputsOf assets tiny
        start = either (error . show) id (startCells inputs)
        partial = foldl (\p _ → either (error . show) id (stepCells inputs p)) start [1 :: Int, 2]
        plan = either (error . show) id (cellPlanOf inputs partial)
        once = planScene assets scene
    cellPlanProgress plan `shouldBe` Working
    length (cellPlanQuads plan) `shouldSatisfy` (< length (cellPlanQuads once))
    (cellPlanUnresolved plan == Nothing) `shouldBe` False
    -- Everything it did draw is a prefix-consistent subset of the final plan's cells.
    Set.fromList [quadCell q | q ← cellPlanQuads plan] `shouldSatisfy` (`Set.isSubsetOf` Set.fromList [quadCell q | q ← cellPlanQuads once])
    -- A point in the unprocessed area is loading, not a miss.
    [p | p ← stridePixels 7, pickPixel plan p == CellPickLoading] `shouldSatisfy` (not . null)
    cdPrefetch (cellPlanDemand plan) `shouldBe` emptyDemand
  it "refuses to resume work or to publish under a replaced camera, knowledge or assets" $ \assets → do
    newerAssets ← loadAssets 6
    let inputs = inputsOf assets tiny
        start = either (error . show) id (startCells inputs)
        moved = tiny {sceneCamera = either (error . show) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (Pan 1 0) (sceneCamera tiny))}
        relearned = tiny {sceneKnowledge = knowledgeOf 2 CellDiscovered []}
        stale = \r → case r of Left CellStaleContinuation → True; _ → False
    stepCells (inputsOf assets moved) start `shouldSatisfy` stale
    stepCells (inputsOf assets relearned) start `shouldSatisfy` stale
    stepCells (inputsOf newerAssets tiny) start `shouldSatisfy` stale
    cellPlanOf (inputsOf assets moved) start `shouldSatisfy` isStale
  it "withholds prefetch until the visible work is settled, and then never takes visible capacity" $ \assets → do
    let ready = mkAvailability [(ChunkKey cx cy, [zr (-2000) 2000]) | cx ← [-1 .. 0], cy ← [-1 .. 0]]
        flat = sceneFrom FaceSouth 0 0 0 flatWorld (knowledgeOf 1 CellDiscovered []) ready
        plan = planScene assets flat
        visibleKeys = map demandChunk (demandChunks (cdVisible (cellPlanDemand plan)))
        prefetchKeys = map demandChunk (demandChunks (cdPrefetch (cellPlanDemand plan)))
    cellPlanProgress plan `shouldBe` Settled
    prefetchKeys `shouldSatisfy` (not . null)
    Set.fromList visibleKeys `shouldSatisfy` Set.disjoint (Set.fromList prefetchKeys)
    -- A partial plan of the same scene has no prefetch yet, though the settled one has.
    let tinyFlat = withLimits (\l → l {clStepCandidates = 3}) flat
        inputs = inputsOf assets tinyFlat
        start = either (error . show) id (startCells inputs)
        partial = foldl (\p _ → either (error . show) id (stepCells inputs p)) start [1 :: Int, 2]
        partialPlan = either (error . show) id (cellPlanOf inputs partial)
    cellPlanProgress partialPlan `shouldBe` Working
    cdPrefetch (cellPlanDemand partialPlan) `shouldBe` emptyDemand
    -- With room for the visible chunks only, prefetch is cut, not the visible demand.
    let tightLimit = length visibleKeys
        tight = planScene assets (withLimits (\l → l {clDemandChunks = tightLimit}) flat)
    map demandChunk (demandChunks (cdVisible (cellPlanDemand tight))) `shouldBe` visibleKeys
    cdPrefetch (cellPlanDemand tight) `shouldBe` emptyDemand
  where
    isStale r = case r of Left CellStaleContinuation → True; _ → False

-- ---------------------------------------------------------------------------

-- The sprites that touch the viewport, by brute force in the view frame, with
-- their own projection arithmetic: world cells of the band whose full 96 x 64
-- canvas overlaps the visible render-world rectangle with positive area.
requiredCells ∷ ViewFacing → (Int, Int) → Float → CameraState → [(Integer, Integer, Integer)]
requiredCells facing (w, h) zoom camera =
  [ (ax + wx, ay + wy, z)
  | v ← [-vMax .. vMax]
  , u ← [-uMax .. uMax]
  , even (u + v)
  , let rx = (u + v) `div` 2
  , let ry = (v - u) `div` 2
  , let (wx, wy) = turn ((4 - turnsOf facing) `mod` 4) (rx, ry)
  , z ← [clip - 250 .. clip]
  , let ox = 48 * (rx - ry)
  , let oy = 24 * (rx + ry - 1) - 16 * (z - ref)
  , fromInteger ox - 48 < halfW && fromInteger ox + 48 > negate halfW
  , fromInteger oy - 16 < halfH && fromInteger oy + 48 > negate halfH
  ]
  where
    halfW = fromIntegral w / (2 * toRational zoom) ∷ Rational
    halfH = fromIntegral h / (2 * toRational zoom) ∷ Rational
    ref = camRef camera
    clip = toInteger (axisValue (camClip camera))
    ax = toInteger (axisValue (camAnchorX camera))
    ay = toInteger (axisValue (camAnchorY camera))
    uMax = ceiling ((halfW + 96) / 48) + 1 ∷ Integer
    vMax = ceiling ((halfH + 16 * 260 + 100) / 24) ∷ Integer

chunkOfCell ∷ (Integer, Integer, Integer) → (ChunkKey, Integer)
chunkOfCell (x, y, z) = (ChunkKey (fromInteger (x `div` 16)) (fromInteger (y `div` 16)), z)

covered ∷ Demand → (ChunkKey, Integer) → Bool
covered wanted (key, z) = or [a <= z && z < b | d ← demandChunks wanted, demandChunk d == key, (a, b) ← demandIntervals d]

demand ∷ SpecWith AssetSnapshot
demand = describe "viewport-driven demand" $ do
  let configs =
        [ ("wide, zoom 1, cut 0", (320, 240), 1 ∷ Float, 0 ∷ Integer)
        , ("portrait, zoom 1, cut 0", (240, 320), 1, 0)
        , ("wide, zoom 1, cut 40", (320, 240), 1, 40)
        , ("wide, the minimum zoom", (320, 240), 0.125, 0)
        , ("portrait, the maximum zoom", (240, 320), 8, 0)
        ]
  forM_ configs $ \(name, (w, h), zoom, cut) → forM_ allViewFacings $ \facing →
    it ("requests every sprite the viewport can show, including the lower distant background: " <> name <> ", " <> show facing) $ \assets → do
      let camera0' = camera0 facing 0 0 cut
          camera = either (error . show) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (SetZoom zoom) camera0')
          scene = (sceneFrom facing cut 0 0 (sourceOf []) (knowledgeOf 1 CellDiscovered []) (mkAvailability []))
            {sceneCamera = camera, sceneSetup = setup w h}
          plan = planScene assets scene
          needed = map chunkOfCell (requiredCells facing (w, h) zoom camera)
          radius2 = Set.fromList [ChunkKey cx cy | cx ← [-2 .. 2], cy ← [-2 .. 2]]
          outside = [n | n@(key, _) ← needed, key `Set.notMember` radius2]
      cellPlanProgress plan `shouldBe` Settled
      [n | n ← needed, not (covered (cdVisible (cellPlanDemand plan)) n)] `shouldBe` []
      -- A radius-two loader would have omitted background the viewport shows.
      outside `shouldSatisfy` (not . null)
      cdTruncated (cellPlanDemand plan) `shouldBe` False
  it "treats a long chunk-spanning demand within explicit bounds, naming the rest as truncated rather than complete" $ \assets → do
    let scene = withLimits (\l → l {clDemandChunks = 2}) (sceneFrom FaceSouth 0 0 0 (sourceOf []) (knowledgeOf 1 CellDiscovered []) (mkAvailability []))
        plan = planScene assets scene
    length (demandChunks (cdVisible (cellPlanDemand plan))) `shouldSatisfy` (<= 2)
    cdTruncated (cellPlanDemand plan) `shouldBe` True
  it "follows the surface in follow mode and still requests the background" $ \assets → do
    let facts = factsOf flatWorld
        camera = followCamera facts 0 0
        scene = (sceneFrom FaceSouth 0 0 0 (sourceOf []) (knowledgeOf 1 CellDiscovered []) (mkAvailability [])) {sceneCamera = camera}
        plan = planScene assets scene
        needed = map chunkOfCell (requiredCells FaceSouth (320, 240) 1 camera)
    [n | n ← needed, not (covered (cdVisible (cellPlanDemand plan)) n)] `shouldBe` []

-- ---------------------------------------------------------------------------

summaries ∷ SpecWith AssetSnapshot
summaries = describe "compressed summaries and bounded scratch" $ do
  forM_ [("a deep discovered solid", CellDiscovered), ("a deep undiscovered span", CellUndiscovered)] $ \(name, state) →
    it ("evaluates " <> name <> " by its runs, never a dense prism") $ \assets → do
      let scene = sceneFrom FaceSouth 0 0 0 flatWorld (knowledgeOf 1 state []) AllKnown
          plan = planScene assets scene
          stats = cellPlanStats plan
          dense = cellStatColumns stats * 251
      cellPlanProgress plan `shouldBe` Settled
      cellStatColumns stats `shouldSatisfy` (> 100)
      cellStatLevels stats `shouldSatisfy` (< dense `div` 20)
      cellStatInstances stats `shouldSatisfy` (<= 3 * cellStatColumns stats)
  it "handles a cut thousands of levels above all terrain without examining them" $ \assets → do
    let scene = sceneFrom FaceSouth (2 ^ (50 ∷ Int)) 0 0 flatWorld (knowledgeOf 1 CellDiscovered []) AllKnown
        plan = planScene assets scene
    cellPlanQuads plan `shouldBe` []
    cellStatLevels (cellPlanStats plan) `shouldSatisfy` (< 100000)

-- ---------------------------------------------------------------------------

privacy ∷ SpecWith AssetSnapshot
privacy = describe "fog hides the terrain behind it" $ do
  let fogged = [(x, y, z, CellUndiscovered) | x ← [0 .. 2], y ← [0 .. 2], z ← [0 .. 1]]
      truths =
        [ ("air", sourceOf [])
        , ("full stone", sourceOf [OCell x y z 0 KnownAll | x ← [0 .. 2], y ← [0 .. 2], z ← [0 .. 1]])
        , ("ramps of another material", sourceOf [OCell x y z (fromInteger ((x * 3 + y + z) `mod` 15 + 1)) KnownAll | x ← [0 .. 2], y ← [0 .. 2], z ← [0 .. 1]])
        ]
      planFor assets truth = planScene assets (sceneFrom FaceSouth 1 0 0 truth (knowledgeOf 1 CellDiscovered fogged) AllKnown)
  it "draws identical fog and gives identical picks for every hidden alternative" $ \assets → do
    let plans = [(name, planFor assets truth) | (name, truth) ← truths]
        views = [map fullView (cellPlanQuads p) | (_, p) ← plans]
        picks = [[pickPixel p px | px ← stridePixels 5] | (_, p) ← plans]
    length (head' views) `shouldSatisfy` (> 5)
    views `shouldBe` replicate 3 (head' views)
    picks `shouldBe` replicate 3 (head' picks)
    [q | (_, p) ← plans, q ← cellPlanQuads p, quadPart q /= PartFog] `shouldBe` []
  it "holds no coordinate, material or shape in a fog quad" $ \assets → do
    let plan = planFor assets (snd (truths !! 1))
    [(quadCell q, quadMaterial q, quadColour q) | q ← cellPlanQuads plan, quadPart q == PartFog]
      `shouldSatisfy` all (\(c, m, col) → c == Nothing && m == Nothing && col == ColourBlank)
  it "stops a pick at fog even where a known cell lies behind it, and lets a known cell in front of fog be picked" $ \assets → do
    let behind = tileAt 0 0 0
        scene = sceneOf FaceSouth 3 [OCell 0 0 0 0 KnownAll, OCell 1 1 3 0 Undisc]
        plan = planScene assets scene
        reversedScene = sceneOf FaceSouth 3 [OCell 0 0 0 0 Undisc, OCell 1 1 3 0 KnownAll]
        reversed = planScene assets reversedScene
    pickPixel plan (centrePixel plan behind `seq` centrePixelOfFog plan) `shouldBe` CellPickNoHit
    fmap hitCell (hitOf (pickPixel reversed (centrePixel reversed (tileAt 1 1 3)))) `shouldBe` Just (tileAt 1 1 3)
  it "does not depend on the order the source or knowledge are enumerated in" $ \assets → do
    let cells = [OCell x y z (fromInteger ((x + 2 * y + z) `mod` 16)) KnownAll | x ← [0 .. 3], y ← [0 .. 3], z ← [0 .. 2]]
        viewIn order = map fullView (cellPlanQuads (planScene assets (sceneOf FaceWest 2 order)))
    viewIn (reverse cells) `shouldBe` viewIn cells
    viewIn (rotate 17 cells) `shouldBe` viewIn cells
  where
    head' (x : _) = x
    head' [] = error "empty"
    rotate n xs = drop n xs <> take n xs
    centrePixelOfFog plan = case [q | q ← cellPlanQuads plan, quadPart q == PartFog] of
      q : _ → case quadTarget q of TargetRect l t _ _ → (floor (l + 48), floor (t + 32))
      [] → error "no fog"

-- ---------------------------------------------------------------------------

refusals ∷ SpecWith AssetSnapshot
refusals = describe "explicit refusals" $ do
  let base = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]
  it "refuses a solid known where the terrain holds air" $ \assets →
    planSceneWith assets (sceneFrom FaceSouth 0 0 0 (sourceOf []) (knowledgeOf 1 CellDiscovered [(0, 0, 0, CellSolidKnown)]) AllKnown)
      `shouldSatisfy` (\r → case r of Left (CellInconsistentKnowledge _ _) → True; _ → False)
  it "refuses a material whose colour is not in the adopted assets" $ \assets → do
    let ore = source SourceSpec {specMaterials = ["ore"], specLayers = [], specPatches = [PatchSpec 0 0 0 1 (SpecSolid "ore" 0)]}
    planSceneWith assets (sceneFrom FaceSouth 0 0 0 ore (knowledgeOf 1 CellDiscovered []) AllKnown)
      `shouldSatisfy` (\r → case r of Left (CellMissingMaterialColour _) → True; _ → False)
  it "refuses an unusable configuration and a snap view that would crack the quads" $ \assets → do
    forM_ [withConfig (\c → c {ccDepth = 251}), withConfig (\c → c {ccDepth = -1}), withConfig (\c → c {ccMargin = -1}), withLimits (\l → l {clColumns = -1})] $ \f →
      planSceneWith assets (f base) `shouldSatisfy` (\r → case r of Left CellInvalidConfig → True; _ → False)
    let snapping = base {sceneSetup = (sceneSetup base) {setupSettings = (setupSettings (sceneSetup base)) {settingPixelSnap = True}}, sceneCamera = either (error . show) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (SetZoom 1.01) (sceneCamera base))}
    planSceneWith assets snapping `shouldSatisfy` (\r → case r of Left (CellPixelSnapUnsupported _) → True; _ → False)
  it "refuses a view that cannot be built: a non-finite viewport" $ \assets →
    planSceneWith assets base {sceneSetup = (sceneSetup base) {setupViewport = Viewport (V2 (0 / 0) 0) (V2 10 10)}}
      `shouldSatisfy` (\r → case r of Left (CellInvalidView _) → True; _ → False)
  it "places quads on whole pixels under snapping at zooms that are whole multiples of 1/8" $ \assets →
    forM_ [2, 0.5, 1.125] $ \zoom → do
      let snapped = base {sceneSetup = (sceneSetup base) {setupSettings = (setupSettings (sceneSetup base)) {settingPixelSnap = True}}, sceneCamera = either (error . show) stepCamera (applyCommand defaultCameraConfig (factsOf flatWorld) (SetZoom zoom) (sceneCamera base))}
          plan = planScene assets snapped
      [ (denominator l, denominator t) | q ← cellPlanQuads plan, let TargetRect l t _ _ = quadTarget q ] `shouldBe` [(1, 1)]
  it "omits a hidden cell only on a valid coverage proof: a colour with a hole proves nothing" $ \assets → do
    holey ← loadAssetsWith 5 [(AssetColour (ColourMaterial stoneId), planeFromFormula (\x y → not (x == 48 && y == 30)))]
    let block = sceneOf FaceSouth 2 [OCell x y z 0 KnownAll | x ← [0 .. 2], y ← [0 .. 2], z ← [0 .. 2]]
        tiles p = Set.fromList [t | q ← cellPlanQuads p, Just t ← [quadCell q]]
    colourCoversHexagon assets (ColourMaterial stoneId) `shouldBe` True
    colourCoversHexagon holey (ColourMaterial stoneId) `shouldBe` False
    tiles (planScene assets block) `shouldSatisfy` (not . Set.member (tileAt 1 1 1))
    tiles (planScene holey block) `shouldSatisfy` Set.member (tileAt 1 1 1)
  where
    _unused = (axis, Column, Map.empty ∷ Map.Map Int Int, Viewport)
