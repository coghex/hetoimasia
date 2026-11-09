-- | TRA-17: the terrain atlases, their region manifest and the generator's atlas modes, proved
-- independently of the packer that makes them.
--
-- The committed atlas PNGs under @samples/ecce-homo/content/textures/terrain-atlas/@ are decoded
-- with JuicyPixels (not the packer's own lookup), and each manifest rectangle is cropped and
-- compared byte for byte with the independently decoded source image it was extracted from, for
-- the three colour sources and all 46 catalog maps. A matching regenerated hash alone is never
-- the evidence of pixel correctness. Every packer example is stated by hand, and every
-- manifest negative control changes a copy of the committed text, never a committed file.
module Test.TerrainRender2D.Atlas (spec) where

import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Either (isLeft, isRight)
import Data.List (isInfixOf, sort)
import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), buildBinaryCoverage, checkNormalEncoding)
import Hetoimasia.Terrain.Atlas.Manifest
import Hetoimasia.Terrain.Atlas.Pack
import Hetoimasia.Terrain.MapGen.Atlas (atlasDirectoryRelative, atlasManifestName, colourAtlasFile, generateAtlases, normalAtlasFile)
import Hetoimasia.Terrain.MapGen.Cli (Outcome (..), runCli)
import Hetoimasia.Terrain.MapGen.Inputs (ColourArt (..), ReferenceMask (..), loadInputs, pinnedColourArt, referenceDirectory, referenceMasks, textureDirectory)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.TerrainRender2D.Art (findUpwards, loadFile, sha256Hex, texturesDirectory)

spec ∷ Spec
spec = describe "Atlas" $ do
  packerSpec
  committedSpec
  manifestSpec
  commandSpec

atlasDirectory ∷ FilePath
atlasDirectory = texturesDirectory </> "terrain-atlas"

-- ---------------------------------------------------------------------------
-- The packer

-- | A 96 x 64 canvas whose every texel is distinct and follows a stated rule: the texel at
-- (x, y) is (x, y, tag, 255 - tag) with x < 96 and y < 64, so a misplaced texel names itself.
canvas ∷ String → Int → Canvas
canvas name tag = Canvas name (ByteString.pack (concat [[fromIntegral x, fromIntegral y, fromIntegral tag, fromIntegral (255 - tag)] | y ← [0 .. 63 ∷ Int], x ← [0 .. 95 ∷ Int]]))

texelAt ∷ PackedAtlas → Int → Int → [Int]
texelAt atlas x y = [fromIntegral (ByteString.index (packedTexels atlas) (4 * (y * fromIntegral (packedWidth atlas) + x) + c)) | c ← [0 .. 3]]

packerSpec ∷ Spec
packerSpec = describe "the packer" $ do
  it "copies a canvas byte for byte into a one-canvas atlas, which is the single-image region" $
    case packGrid 1 [canvas "a" 7] of
      Left why → expectationFailure (describePackError why)
      Right atlas → do
        (packedWidth atlas, packedHeight atlas) `shouldBe` (96, 64)
        packedTexels atlas `shouldBe` canvasTexels (canvas "a" 7)
        packedPlacements atlas `shouldBe` [Placed "a" 0 0]
  it "places canvases row by row at their grid rectangles, unaltered" $
    -- Five canvases over three columns: a b c on the first row, d e on the second, whose third
    -- grid cell is unused. The atlas is 3 * 96 wide and 2 * 64 tall.
    case packGrid 3 [canvas (show i) i | i ← [1 .. 5 ∷ Int]] of
      Left why → expectationFailure (describePackError why)
      Right atlas → do
        (packedWidth atlas, packedHeight atlas) `shouldBe` (288, 128)
        packedPlacements atlas
          `shouldBe` [Placed "1" 0 0, Placed "2" 96 0, Placed "3" 192 0, Placed "4" 0 64, Placed "5" 96 64]
        -- Canvas 4 is at (0, 64): its texel (5, 9) is the atlas texel (5, 73).
        texelAt atlas 5 73 `shouldBe` [5, 9, 4, 251]
        -- Canvas 5 is at (96, 64): its texel (95, 63) is the atlas texel (191, 127).
        texelAt atlas 191 127 `shouldBe` [95, 63, 5, 250]
        -- Canvas 2's first texel and canvas 3's last.
        texelAt atlas 96 0 `shouldBe` [0, 0, 2, 253]
        texelAt atlas 287 63 `shouldBe` [95, 63, 3, 252]
  it "leaves unused grid cells entirely zero, so unused pixels have zero alpha" $
    case packGrid 3 [canvas (show i) i | i ← [1 .. 5 ∷ Int]] of
      Left why → expectationFailure (describePackError why)
      Right atlas →
        forM_ [(x, y) | y ← [64, 100, 127], x ← [192, 200, 287]] $ \(x, y) →
          texelAt atlas x y `shouldBe` [0, 0, 0, 0]
  it "is deterministic: the same canvases give the same bytes and rectangles" $
    packGrid 3 [canvas (show i) i | i ← [1 .. 5 ∷ Int]] `shouldBe` packGrid 3 [canvas (show i) i | i ← [1 .. 5 ∷ Int]]
  it "refuses inputs it cannot pack, naming the canvas" $ do
    packGrid 0 [canvas "a" 1] `shouldBe` Left (PackBadColumns 0)
    packGrid 2 [] `shouldBe` Left PackNoCanvases
    packGrid 2 [Canvas "short" (ByteString.replicate 100 0)] `shouldBe` Left (PackBadCanvas "short" 100)
    packGrid 2 [canvas "a" 1, canvas "a" 2] `shouldBe` Left (PackDuplicate "a")
    packGrid 1 [canvas (show i) 0 | i ← [1 .. 257 ∷ Int]] `shouldBe` Left (PackTooManyCanvases 257)
  it "refuses an atlas beyond the bounded image limits" $
    -- 22 columns of 96 texels are 2112 wide, beyond 2048.
    packGrid 22 [canvas (show i) 0 | i ← [1 .. 22 ∷ Int]] `shouldBe` Left (PackTooLarge 2112 64)
  it "never rotates, trims or scales: an asymmetric canvas keeps its orientation" $
    case packGrid 2 [canvas "a" 1, canvas "b" 2] of
      Left why → expectationFailure (describePackError why)
      Right atlas → do
        -- Along b's top row the red channel counts 0..95 from the left: no mirroring.
        [texelAt atlas (96 + x) 0 !! 0 | x ← [0, 1, 95]] `shouldBe` [0, 1, 95]
        -- Down b's left column the green channel counts 0..63 from the top: no flipping.
        [texelAt atlas 96 y !! 1 | y ← [0, 1, 63]] `shouldBe` [0, 1, 63]

-- ---------------------------------------------------------------------------
-- The committed atlases

decodeAt ∷ FilePath → IO (Int, Int, ByteString.ByteString)
decodeAt relative = do
  bytes ← loadFile relative
  either (\why → expectationFailure (relative <> ": " <> why) >> pure (0, 0, ByteString.empty)) pure (decodeRgba bytes)

loadManifest ∷ IO AtlasManifest
loadManifest = do
  bytes ← loadFile (atlasDirectory </> "manifest.json")
  either (\problems → expectationFailure (unlines problems) >> fail "manifest") pure (parseManifest bytes)

-- | The texels of a rectangle of an image of the given width, row by row.
crop ∷ Int → ByteString.ByteString → (Int, Int, Int, Int) → ByteString.ByteString
crop width texels (x, y, w, h) = ByteString.concat [ByteString.take (4 * w) (ByteString.drop (4 * (j * width + x)) texels) | j ← [y .. y + h - 1]]

committedSpec ∷ Spec
committedSpec = describe "the committed atlases" $ do
  it "has the three colour regions and all 46 catalog maps, at the stated landmark rectangles" $ do
    manifest ← loadManifest
    map atlasName (manifestAtlases manifest) `shouldBe` ["colour", "normal"]
    let rectangle identity = (\(_, r) → (regionX r, regionY r, regionW r, regionH r)) <$> findRegion manifest identity
    -- Colour: loam, granite, blank side by side. Normal: eight maps to a row, in catalog order,
    -- the sixteen ordinary shapes first (shape.07 ends the first row, shape.08 starts the
    -- second) and then each nonflat shape's known and cover parts, 46 in all, the last at
    -- index 45: column 5 of row 5.
    rectangle "colour.loam" `shouldBe` Just (0, 0, 96, 64)
    rectangle "colour.granite" `shouldBe` Just (96, 0, 96, 64)
    rectangle "colour.blanktexture" `shouldBe` Just (192, 0, 96, 64)
    rectangle "shape.00" `shouldBe` Just (0, 0, 96, 64)
    rectangle "shape.07" `shouldBe` Just (672, 0, 96, 64)
    rectangle "shape.08" `shouldBe` Just (0, 64, 96, 64)
    rectangle "shape.15" `shouldBe` Just (672, 64, 96, 64)
    rectangle "mixed.01.known" `shouldBe` Just (0, 128, 96, 64)
    rectangle "mixed.15.fog" `shouldBe` Just (480, 320, 96, 64)
    [(atlasWidth a, atlasHeight a) | a ← manifestAtlases manifest] `shouldBe` [(288, 64), (768, 384)]
    map (length . atlasRegions) (manifestAtlases manifest) `shouldBe` [3, 46]
  it "recovers every source image's decoded RGBA exactly from its rectangle, independently of the packer" $ do
    manifest ← loadManifest
    forM_ (manifestAtlases manifest) $ \atlas → do
      (width, height, texels) ← decodeAt (atlasDirectory </> atlasFile atlas)
      (width, height) `shouldBe` (fromIntegral (atlasWidth atlas), fromIntegral (atlasHeight atlas))
      forM_ (atlasRegions atlas) $ \region → do
        source ← loadFile (regionSourcePath region)
        sha256Hex source `shouldBe` regionSourceSha256 region
        (sw, sh, sourceTexels) ← either (\why → expectationFailure why >> pure (0, 0, ByteString.empty)) pure (decodeRgba source)
        (sw, sh) `shouldBe` (96, 64)
        let rect = (fromIntegral (regionX region), fromIntegral (regionY region), 96, 64)
        if crop width texels rect == sourceTexels then pure () else expectationFailure (regionId region <> " is not its source's texels")
  it "records each atlas file's digest, and every texel outside every region is zero" $ do
    manifest ← loadManifest
    forM_ (manifestAtlases manifest) $ \atlas → do
      bytes ← loadFile (atlasDirectory </> atlasFile atlas)
      sha256Hex bytes `shouldBe` atlasSha256 atlas
      (width, height, texels) ← decodeAt (atlasDirectory </> atlasFile atlas)
      let inside x y = or [fromIntegral (regionX r) <= x && x < fromIntegral (regionX r) + 96 && fromIntegral (regionY r) <= y && y < fromIntegral (regionY r) + 64 | r ← atlasRegions atlas]
          stray = [(x, y) | y ← [0 .. height - 1], x ← [0 .. width - 1], not (inside x y), crop width texels (x, y, 1, 1) /= ByteString.replicate 4 0]
      stray `shouldBe` []
  it "has a normal atlas whose opaque texels all validate as unit-normal-rgb-v1, and binary coverage in both" $ do
    (cw, ch, colour) ← decodeAt (atlasDirectory </> "colour.png")
    (nw, nh, normal) ← decodeAt (atlasDirectory </> "normal.png")
    checkNormalEncoding UnitNormalRgbV1 (fromIntegral nw) (fromIntegral nh) normal `shouldBe` Right ()
    buildBinaryCoverage (fromIntegral nw) (fromIntegral nh) normal `shouldSatisfy` isRight
    buildBinaryCoverage (fromIntegral cw) (fromIntegral ch) colour `shouldSatisfy` isRight
  it "carries a layout identity that is the digest of its rectangles" $ do
    manifest ← loadManifest
    manifestLayout manifest `shouldBe` layoutIdentity (manifestAtlases manifest)
  it "changes the layout identity when one rectangle changes on the same parent" $ do
    manifest ← loadManifest
    let moved = [a {atlasRegions = [if regionId r == "shape.01" then r {regionX = regionX r + 1} else r | r ← atlasRegions a]} | a ← manifestAtlases manifest]
    layoutIdentity moved `shouldNotBe` layoutIdentity (manifestAtlases manifest)
  it "regenerates the same files the repository commits" $ do
    sample ← findUpwards "samples/ecce-homo"
    loaded ← loadInputs sample
    case loaded of
      Left problems → expectationFailure (unlines problems)
      Right inputs → case generateAtlases inputs of
        Left why → expectationFailure why
        Right files → do
          sort (map fst files) `shouldBe` sort [atlasManifestName, colourAtlasFile, normalAtlasFile]
          forM_ files $ \(name, bytes) → do
            committed ← loadFile (atlasDirectory </> name)
            (name, committed == bytes) `shouldBe` (name, True)
  it "states the committed directory beside, not inside, the facemap catalog" $
    atlasDirectoryRelative `shouldBe` (textureDirectory </> "terrain-atlas")

-- ---------------------------------------------------------------------------
-- The manifest's refusals

-- | The committed manifest text with one exact substring replaced, which must be present.
mutate ∷ [(String, String)] → IO ByteString.ByteString
mutate edits = do
  bytes ← loadFile (atlasDirectory </> "manifest.json")
  let go text (from, to) = case breakOn from text of
        Just (prefix, suffix) → prefix <> to <> drop (length from) suffix
        Nothing → error ("the committed manifest has no " <> show from)
  pure (Char8.pack (foldl go (Char8.unpack bytes) edits))
  where
    breakOn needle text = go' [] text
      where
        go' acc rest
          | needle `isPrefixOf'` rest = Just (reverse acc, rest)
          | otherwise = case rest of
              [] → Nothing
              c : cs → go' (c : acc) cs
    isPrefixOf' p s = take (length p) s == p

refuses ∷ [(String, String)] → String → Expectation
refuses edits expected = do
  bytes ← mutate edits
  case parseManifest bytes of
    Right _ → expectationFailure ("the manifest was accepted; expected a refusal mentioning " <> show expected)
    Left problems →
      if any (expected `isInfixOf`) problems
        then pure ()
        else expectationFailure ("expected a refusal mentioning " <> show expected <> ", got:\n" <> unlines problems)

manifestSpec ∷ Spec
manifestSpec = describe "the manifest's checks" $ do
  it "accepts the committed manifest" $ do
    bytes ← loadFile (atlasDirectory </> "manifest.json")
    parseManifest bytes `shouldSatisfy` isRight
  it "refuses a missing identity" $ refuses [("{\"id\": \"shape.07\"", "{\"id\": \"shape.99\"")] "lacks identity shape.07"
  it "refuses an identity the atlas should not hold" $ refuses [("{\"id\": \"shape.07\"", "{\"id\": \"shape.99\"")] "unexpected identity \"shape.99\""
  it "refuses a duplicate identity" $ refuses [("{\"id\": \"shape.07\"", "{\"id\": \"shape.06\"")] "identity shape.06 is listed more than once"
  it "refuses a zero-width rectangle" $ refuses [("\"id\": \"shape.01\", \"x\": 96, \"y\": 0, \"width\": 96", "\"id\": \"shape.01\", \"x\": 96, \"y\": 0, \"width\": 0")] "needs a positive extent"
  it "refuses a negative coordinate rather than wrapping it" $ refuses [("\"id\": \"shape.01\", \"x\": 96", "\"id\": \"shape.01\", \"x\": -96")] "not an unsigned 32-bit integer"
  it "refuses a coordinate beyond 32 bits" $ refuses [("\"id\": \"shape.01\", \"x\": 96", "\"id\": \"shape.01\", \"x\": 4294967296")] "not an unsigned 32-bit integer"
  it "refuses a rectangle whose far edge overflows 32 bits" $ refuses [("\"id\": \"shape.01\", \"x\": 96", "\"id\": \"shape.01\", \"x\": 4294967295")] "overflows 32 bits"
  it "refuses a rectangle outside its atlas" $ refuses [("\"id\": \"shape.01\", \"x\": 96", "\"id\": \"shape.01\", \"x\": 700")] "lies outside atlas normal"
  it "refuses a terrain region that is not 96 x 64" $ refuses [("\"id\": \"shape.01\", \"x\": 96, \"y\": 0, \"width\": 96", "\"id\": \"shape.01\", \"x\": 96, \"y\": 0, \"width\": 95")] "is 95 x 64, not 96 x 64"
  it "refuses overlapping rectangles" $ refuses [("\"id\": \"shape.01\", \"x\": 96", "\"id\": \"shape.01\", \"x\": 48")] "shape.00 and shape.01 overlap in atlas normal"
  it "refuses the wrong image kind" $ refuses [("\"kind\": \"data\"", "\"kind\": \"colour\"")] "atlas normal has kind \"colour\""
  it "refuses the wrong profile" $ refuses [("\"profile\": \"unit-normal-rgb-v1\"", "\"profile\": \"srgb-colour-premultiplied\"")] "atlas normal has profile"
  it "refuses an identity in the wrong parent atlas" $ refuses [("\"id\": \"colour.blanktexture\"", "\"id\": \"shape.00\"")] "identity shape.00 is in atlas colour, which is not its parent"
  it "refuses an unexpected atlas" $ refuses [("\"name\": \"normal\"", "\"name\": \"extra\"")] "atlas \"extra\" is not one the manifest may hold"
  it "refuses a missing atlas" $ refuses [("\"name\": \"normal\"", "\"name\": \"extra\"")] "atlas normal is missing"
  it "refuses a stale layout identity on the same parent" $
    -- The rectangles are untouched but the stated identity is not the one they digest to.
    refuses [("\"layoutIdentity\": \"263cb64032502aa0\"", "\"layoutIdentity\": \"263cb64032502aa1\"")] "layout identity is 263cb64032502aa1"
  it "refuses a digest that is not lowercase hexadecimal of the right length" $ do
    refuses [("\"sha256\": \"96c53814636e77b5cc822b5ebe93acd945640c7502c0d2d02b4eb112601bc29f\"", "\"sha256\": \"96C5\"")] "is not 64 lowercase hexadecimal digits"
    refuses [("\"layoutIdentity\": \"263cb64032502aa0\"", "\"layoutIdentity\": \"263CB64032502AA0\"")] "is not 16 lowercase hexadecimal digits"
  it "refuses a wrong schema and an unknown key" $ do
    refuses [("hetoimasia.terrain-atlas-manifest/1", "hetoimasia.terrain-atlas-manifest/2")] "schema is"
    refuses [("\"recipe\":", "\"surprise\": 1,\n  \"recipe\":")] "unexpected key"
  it "refuses a file name that leaves the directory" $ refuses [("\"file\": \"normal.png\"", "\"file\": \"../normal.png\"")] "not a plain file name"
  it "refuses text that is not the bounded JSON subset" $ do
    parseManifest (Char8.pack "{") `shouldSatisfy` isLeft
    parseManifest (ByteString.replicate (maxManifestBytes + 1) 32) `shouldSatisfy` isLeft
    parseManifest (Char8.pack "{\"schema\": 1.5}") `shouldSatisfy` isLeft
    parseManifest (ByteString.pack [123, 200, 125]) `shouldSatisfy` isLeft
    bytes ← mutate []
    parseManifest (bytes <> Char8.pack "extra") `shouldSatisfy` isLeft
  it "bounds the work: too many regions or atlases are refused before any per-region walk" $ do
    manifest ← loadManifest
    let entryOf = head' (manifestAtlases manifest)
        many = [RegionEntry ("shape." <> show i) 0 0 96 64 "" (replicate 64 'a') | i ← [1 .. maxRegionsPerAtlas + 1]]
    validateManifest manifest {manifestAtlases = [entryOf {atlasRegions = many}]} `shouldBe` [TooManyRegions "colour" (maxRegionsPerAtlas + 1)]
    validateManifest manifest {manifestAtlases = replicate (maxAtlases + 1) entryOf} `shouldBe` [TooManyAtlases (maxAtlases + 1)]
  it "refuses an atlas beyond the decoder's per-axis limit" $
    refuses [("\"width\": 768", "\"width\": 4096")] "outside 1..2048 per axis"
  where
    head' (x : _) = x
    head' [] = error "no atlas"

-- ---------------------------------------------------------------------------
-- The generator's atlas modes

-- | A minimal sample directory holding only what the generator reads, copied from the
-- repository's own: the colour art and the sixteen reference masks.
withSample ∷ (FilePath → IO a) → IO a
withSample action = withSystemTempDirectory "tra17-sample" $ \directory → do
  sample ← findUpwards "samples/ecce-homo"
  forM_ [(textureDirectory </> artFile art) | art ← pinnedColourArt] $ \relative → copyInto sample directory relative
  forM_ [(referenceDirectory </> referenceFile mask) | mask ← referenceMasks] $ \relative → copyInto sample directory relative
  action directory
  where
    copyInto from to relative = do
      createDirectoryIfMissing True (takeDirectory (to </> relative))
      copyFile (from </> relative) (to </> relative)

commandSpec ∷ Spec
commandSpec = describe "terrain-mapgen --atlas-output and --check-atlases" $ do
  it "checks the committed atlases against a regeneration" $ do
    outcome ← runCli ["--check-atlases"]
    (outcomeExit outcome, outcomeErr outcome) `shouldBe` (0, [])
  it "writes a directory that checks clean, and writes only the three derivative files" $
    withSample $ \sample → withSystemTempDirectory "tra17-out" $ \out → do
      written ← runCli ["--atlas-output", out, "--sample", sample]
      outcomeExit written `shouldBe` 0
      forM_ [atlasManifestName, colourAtlasFile, normalAtlasFile] $ \name → doesFileExist (out </> name) >>= (`shouldBe` True)
      checked ← runCli ["--check-atlases", "--atlas-dir", out, "--sample", sample]
      (outcomeExit checked, outcomeErr checked) `shouldBe` (0, [])
  it "writes the same bytes twice" $
    withSample $ \sample → withSystemTempDirectory "tra17-a" $ \first → withSystemTempDirectory "tra17-b" $ \second → do
      _ ← runCli ["--atlas-output", first, "--sample", sample]
      _ ← runCli ["--atlas-output", second, "--sample", sample]
      forM_ [atlasManifestName, colourAtlasFile, normalAtlasFile] $ \name → do
        a ← ByteString.readFile (first </> name)
        b ← ByteString.readFile (second </> name)
        (name, a == b) `shouldBe` (name, True)
  it "fails, naming each affected file, on a changed, missing or unexpected file, and never writes there" $
    withSample $ \sample → withSystemTempDirectory "tra17-bad" $ \out → do
      _ ← runCli ["--atlas-output", out, "--sample", sample]
      ByteString.appendFile (out </> colourAtlasFile) (ByteString.pack [0])
      removeFile (out </> atlasManifestName)
      ByteString.writeFile (out </> "extra.txt") (Char8.pack "x")
      outcome ← runCli ["--check-atlases", "--atlas-dir", out, "--sample", sample]
      outcomeExit outcome `shouldBe` 1
      let text = unlines (outcomeErr outcome)
      forM_ ["changed: colour.png", "missing: manifest.json", "unexpected: extra.txt"] $ \needle →
        if needle `isInfixOf` text then pure () else expectationFailure (needle <> " not in:\n" <> text)
      -- Read-only: the check left the three files exactly as it found them.
      doesFileExist (out </> atlasManifestName) >>= (`shouldBe` False)
      ByteString.length <$> ByteString.readFile (out </> "extra.txt") >>= (`shouldBe` 1)
  it "resolves the default atlas directory under the selected sample" $
    withSample $ \sample → do
      absent ← runCli ["--check-atlases", "--sample", sample]
      outcomeExit absent `shouldBe` 1
      let target = sample </> textureDirectory </> "terrain-atlas"
      written ← runCli ["--atlas-output", target, "--sample", sample]
      outcomeExit written `shouldBe` 0
      present ← runCli ["--check-atlases", "--sample", sample]
      outcomeExit present `shouldBe` 0
  it "keeps --check on the facemap catalog, which the atlas directory does not disturb" $ do
    outcome ← runCli ["--check"]
    (outcomeExit outcome, outcomeErr outcome) `shouldBe` (0, [])
  it "accepts exactly one mode, with the usage status 2" $ do
    forM_
      [ ["--atlas-output", "x", "--check-atlases"]
      , ["--check-atlases", "--check"]
      , ["--atlas-output"]
      , ["--atlas-dir"]
      , ["--output", "x", "--atlas-output", "y"]
      ]
      $ \arguments → outcomeExit <$> runCli arguments >>= (`shouldBe` 2)
  it "reports the generated inventory with the written file count" $
    withSample $ \sample → withSystemTempDirectory "tra17-inv" $ \out → do
      outcome ← runCli ["--atlas-output", out, "--sample", sample]
      length (outcomeOut outcome) `shouldBe` 4
      outcomeOut outcome `shouldSatisfy` (any ("wrote 3 files" `isInfixOf`))
