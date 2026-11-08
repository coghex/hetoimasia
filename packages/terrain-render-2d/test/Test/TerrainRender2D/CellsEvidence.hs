-- | TRA-16: the reproducible CPU evidence record.
--
-- This example renders, deterministically, the readings the issue asks to be
-- retained: expected and actual classifications over the fixed scenes, work and
-- count readings, and the source and asset identities. It uses no random seed:
-- every scene and every sample pixel is enumerated in "Test.TerrainRender2D.Cells".
-- When @HETOIMASIA_TRA16_EVIDENCE_DIR@ names a directory the text is written
-- there as @README.md@; otherwise nothing is written, so a routine run
-- exercises the rendering without touching the tree. The record is CPU
-- evidence only and does not discharge the device gate (Q-13) of TRA-17.
--
-- Reproduce with:
--
-- > HETOIMASIA_TRA16_EVIDENCE_DIR=<dir> HETOIMASIA_TRA16_COMMIT=<commit> \
-- >   cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests \
-- >     --test-options='--match "TRA-16 evidence record"'
module Test.TerrainRender2D.CellsEvidence (spec) where

import qualified Data.ByteString as ByteString
import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera (camRef)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Shape (ViewFacing (..), allViewFacings)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import Test.Hspec
import Test.TerrainRender2D.Art (loadFile, sha256Hex, texturesDirectory)
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Cells (AScene (..), agreementScenes, classify, collapse, decidable, productionClass, referenceFront)

spec ∷ Spec
spec = describe "TRA-16 evidence record" $ beforeAll (loadAssets 5) $
  it "renders the CPU evidence and, when asked, writes it to the named directory" $ \assets → do
    commit ← maybe "unpinned" id <$> lookupEnv "HETOIMASIA_TRA16_COMMIT"
    identities ← sourceIdentities
    let text = renderEvidence commit identities assets
    length (lines text) `shouldSatisfy` (> 60)
    destination ← lookupEnv "HETOIMASIA_TRA16_EVIDENCE_DIR"
    case destination of
      Nothing → pure ()
      Just directory → do
        createDirectoryIfMissing True directory
        writeFile (directory </> "README.md") text

-- The committed inputs the scenes are built from, by their hash.
sourceIdentities ∷ IO [(FilePath, String)]
sourceIdentities = mapM entry ["blanktexture.png", "loam.png", "granite.png", "facemap/manifest.json"]
  where
    entry name = do
      bytes ← loadFile (texturesDirectory </> name)
      pure (texturesDirectory </> name, sha256Hex bytes <> " (" <> show (ByteString.length bytes) <> " bytes)")

renderEvidence ∷ String → [(FilePath, String)] → AssetSnapshot → String
renderEvidence commit identities assets =
  unlines $
    [ "# TRA-16 CPU evidence: cell-quad planning and coverage picking"
    , ""
    , "**This is CPU evidence only.** It shows that the pure planner and picker agree with independent"
    , "references on fixed scenes. It does not show that a device rasterizer, depth test or sampler agrees;"
    , "TRA-17 owns that proof (Q-13), and a disagreement found there is a counterexample, not a reason to"
    , "change an order, threshold or rule here."
    , ""
    , "- Pinned to commit: `" <> commit <> "`"
    , "- Reproduce: `HETOIMASIA_TRA16_EVIDENCE_DIR=<dir> HETOIMASIA_TRA16_COMMIT=<commit> cabal test --project-file cabal.project.cpu hetoimasia-terrain-render-2d:terrain-render-2d-tests --test-show-details=direct --test-options='--match \"TRA-16 evidence record\"'`"
    , "- Seeds: none. Every scene, facing and sample pixel is enumerated in `packages/terrain-render-2d/test/Test/TerrainRender2D/Cells.hs`;"
    , "  the run is deterministic (Hspec's seed affects only example order)."
    , "- View: a 320 x 240 target at zoom 1, camera at the anchor column, manual cut as listed; the oracle"
    , "  samples the centre of every sixth pixel from offset (5, 3), keeping a pixel only where its answer is"
    , "  stable under a 1/32 render-pixel jitter (a pixel on a facet or mask edge is skipped, not guessed)."
    , ""
    , "## Source and asset identities"
    , ""
    , "| Input | SHA-256 |"
    , "| --- | --- |"
    ]
      <> ["| `" <> path <> "` | " <> hash <> " |" | (path, hash) ← identities]
      <> [ ""
         , "The asset snapshot used is version 5, built from the committed catalog (46 maps), the blank colour and"
         , "the loam (`stone`) and granite (`soil`) artwork above, each with texture version 5 and coverage version 5."
         , "Its identity is a fixed-size digest of those versions, taken once when the snapshot is built: `" <> show (assetIdentity assets) <> "`."
         , ""
         , "## Expected against actual classifications"
         , ""
         , "Per scene and facing: decidable sample pixels, then the oracle's answer against the reference traversal"
         , "(which sees fog) and the production pick (which does not distinguish fog from a miss). `none`, `fog`,"
         , "`known` count the oracle's frontmost classification. `reference mismatches` and `pick mismatches` are the"
         , "pixels where the traversal or the pick differs from it; the acceptance is that both are 0."
         , ""
         , "| Scene | Facing | Decidable | none | fog | known | reference mismatches | pick mismatches | Quads | Depth keys (min..max) |"
         , "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |"
         ]
      <> concat [sceneRow scene facing | scene ← agreementScenes, facing ← allViewFacings]
      <> [ ""
         , "## Work and count readings"
         , ""
         , "Limits are the defaults of `defaultCellLimits` unless stated (engineering defaults, not measured capacity)."
         , ""
         , "| Scene (South) | Columns | Levels evaluated | Instances | Pending spans | Distinct assets | Progress |"
         , "| --- | ---: | ---: | ---: | ---: | ---: | --- |"
         ]
      <> [workRow scene | scene ← agreementScenes]
      <> [ ""
         , "## Capacity pressure"
         , ""
         , "Scene: a mixed ramp, a full block, a mixed ramp (identity 12) and an undiscovered block (six quads)."
         , "`clInstances` is the instance limit. A column is admitted whole or left unresolved, so a mixed cell's fog and"
         , "known parts are never split; ranks are distinct and below the limit."
         , ""
         , "| clInstances | Quads | Progress | Known parts without their fog |"
         , "| ---: | ---: | --- | ---: |"
         ]
      <> [capacityRow limit | limit ← [0 .. 6 ∷ Int]]
      <> [""]
  where
    sceneRow scene facing =
      let plan = planScene assets (sceneOfAt facing (sceneAnchor scene) (sceneCut scene) (sceneCells scene))
          compared = decidable plan facing scene
          nearToFar = reverse (cellPlanQuads plan)
          count c = length [() | (_, o) ← compared, o == c]
          refBad = length [() | (p, o) ← compared, classify (referenceFront assets nearToFar p) /= o]
          pickBad = length [() | (p, o) ← compared, productionClass plan p /= collapse o]
          keys = map quadDepthKey (cellPlanQuads plan)
          range = if null keys then "-" else show (minimum keys) <> ".." <> show (maximum keys)
       in [ "| "
              <> intercalate " | " [sceneName scene, show facing, show (length compared), show (count ONothing), show (count OFog), show (length [() | (_, OKnown _) ← compared]), show refBad, show pickBad, show (length (cellPlanQuads plan)), range]
              <> " |"
          ]
    workRow scene =
      let plan = planScene assets (sceneOfAt FaceSouth (sceneAnchor scene) (sceneCut scene) (sceneCells scene))
          stats = cellPlanStats plan
       in "| "
            <> intercalate " | " [sceneName scene, show (cellStatColumns stats), show (cellStatLevels stats), show (cellStatInstances stats), show (cellStatPending stats), show (length (cellPlanAssets plan)), show (cellPlanProgress plan)]
            <> " |"
    capacityRow limit =
      let cells = [OCell 0 0 0 5 KnownSolid, OCell 3 0 0 0 KnownAll, OCell 0 3 0 12 KnownSolid, OCell 3 3 0 0 Undisc]
          scene = (sceneOf FaceSouth 0 cells)
          limited = scene {sceneConfig = (sceneConfig scene) {ccLimits = (ccLimits (sceneConfig scene)) {clInstances = limit}}}
          plan = planScene assets limited
          quads = cellPlanQuads plan
          fogKeys = Map.fromList [(cellOf q, ()) | q ← quads, quadPart q == PartFog]
          cellOf q = let CellKey a z x y _ = quadKey q in (a, z, x, y)
          orphans = length [() | q ← quads, quadPart q == PartKnown, cellOf q `Map.notMember` fogKeys]
       in "| " <> intercalate " | " [show limit, show (length quads), show (cellPlanProgress plan), show orphans] <> " |"
    _unused = camRef
