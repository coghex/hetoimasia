-- | The terrain atlas region manifest: its checked, bounded representation (TRA-17).
--
-- Every terrain texture is an atlas: a small number of parent images per content family, each
-- holding logical 96 x 64 canvases at integer rectangles. The offline generator
-- (@terrain-mapgen --atlas-output@) writes one colour atlas (loam, granite, blank) and one
-- numeric normal atlas (the 46 catalog maps) and this manifest. Runtime packs nothing: it loads
-- the two parent images through the bounded decoder and reads this manifest for where each
-- logical identity lives.
--
-- == What the manifest records
--
-- For each parent atlas: its name, file, extent, image kind and profile, the SHA-256 of its file
-- and its regions. For each region: the logical identity, the integer rectangle and the path and
-- SHA-256 of the source image it was extracted from. A /layout identity/ digests the atlases'
-- names, extents and every identity with its rectangle, so a change to any rectangle, on the same
-- parent or not, is a change of layout.
--
-- == Checks
--
-- 'validateManifest' reports every problem it finds, naming the identity or file: a wrong schema,
-- a missing, duplicate or unexpected atlas or identity, a wrong kind or profile, a zero,
-- overflowing or out-of-bounds rectangle, a terrain region that is not 96 x 64, a region in the
-- wrong parent, overlapping rectangles, an atlas beyond the decoder's bounds and a layout
-- identity that differs from the one recomputed from the rectangles. 'parseManifest' reads the
-- bytes under fixed limits and then validates, so an accepted value is always valid.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Atlas.Manifest
  ( -- * Constants
    manifestSchema
  , logicalWidth
  , logicalHeight
  , maxManifestBytes
  , maxAtlases
  , maxRegionsPerAtlas
  , maxAtlasAxis
  , maxAtlasTexels
  , colourAtlasName
  , normalAtlasName
  , colourKind
  , colourProfile
  , dataKind
  , normalProfile
  , colourRegionId
  , normalRegionId
  , colourRegionIds
  , normalRegionIds

    -- * The manifest
  , RegionEntry (..)
  , AtlasEntry (..)
  , AtlasManifest (..)
  , layoutIdentity
  , layoutIdentityHex
  , regionRectangle
  , findRegion

    -- * Checks
  , ManifestProblem (..)
  , describeProblem
  , validateManifest
  , parseManifest
  ) where

import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.Char (ord)
import qualified Data.Map.Strict as Map
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.Region (ImageRegion, RegionRefusal, mkImageRegion, regionRefusalText)
import Hetoimasia.Terrain.Atlas.Internal.Json (JsonLimits (..), JsonValue (..), parseJsonBounded)
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapIdentifier)
import Numeric (readHex, showHex)

-- | The schema name the manifest states and a reader requires.
manifestSchema ∷ String
manifestSchema = "hetoimasia.terrain-atlas-manifest/1"

-- | The logical canvas every terrain region is, in texels.
logicalWidth, logicalHeight ∷ Word32
logicalWidth = 96
logicalHeight = 64

-- | The most bytes of manifest a reader looks at.
maxManifestBytes ∷ Int
maxManifestBytes = 262144

-- | The most parent atlases a manifest may list.
maxAtlases ∷ Int
maxAtlases = 8

-- | The most regions one atlas may list.
maxRegionsPerAtlas ∷ Int
maxRegionsPerAtlas = 256

-- | The bounded PNG decoder's limits on a parent image: texels per axis and in all.
maxAtlasAxis ∷ Word32
maxAtlasAxis = 2048

maxAtlasTexels ∷ Integer
maxAtlasTexels = 4194304

-- | The two parent atlases' names.
colourAtlasName, normalAtlasName ∷ String
colourAtlasName = "colour"
normalAtlasName = "normal"

-- | The image kind and profile the colour atlas is declared with: premultiplied sRGB colour.
colourKind, colourProfile ∷ String
colourKind = "colour"
colourProfile = "srgb-colour-premultiplied"

-- | The image kind and profile the normal atlas is declared with: raw linear data.
dataKind, normalProfile ∷ String
dataKind = "data"
normalProfile = "unit-normal-rgb-v1"

-- | The logical identity of a colour artwork by its name, e.g. @colour.loam@.
colourRegionId ∷ String → String
colourRegionId name = "colour." <> name

-- | The logical identity of a catalog map, e.g. @shape.15@ or @mixed.03.fog@.
normalRegionId ∷ String → String
normalRegionId = id

-- | The colour artwork names the colour atlas holds, in packing order.
colourRegionIds ∷ [String]
colourRegionIds = map colourRegionId ["loam", "granite", "blanktexture"]

-- | The identities of the 46 catalog maps, in catalog (and packing) order.
normalRegionIds ∷ [String]
normalRegionIds = map (normalRegionId . mapIdentifier) catalogKeys

-- | One logical image's place in a parent atlas.
data RegionEntry = RegionEntry
  { regionId ∷ !String
  , regionX ∷ !Word32
  , regionY ∷ !Word32
  , regionW ∷ !Word32
  , regionH ∷ !Word32
  , regionSourcePath ∷ !String
  , regionSourceSha256 ∷ !String
  }
  deriving stock (Eq, Show)

-- | A parent image and the regions it holds.
data AtlasEntry = AtlasEntry
  { atlasName ∷ !String
  , atlasFile ∷ !String
  , atlasWidth ∷ !Word32
  , atlasHeight ∷ !Word32
  , atlasKind ∷ !String
  , atlasProfile ∷ !String
  , atlasSha256 ∷ !String
  , atlasRegions ∷ ![RegionEntry]
  }
  deriving stock (Eq, Show)

-- | A manifest: the recipe that made it, the layout identity it states and its atlases.
data AtlasManifest = AtlasManifest
  { manifestRecipe ∷ !String
  , manifestLayout ∷ !Word64
  , manifestAtlases ∷ ![AtlasEntry]
  }
  deriving stock (Eq, Show)

-- | The digest of the arrangement: every atlas's name and extent and every region's identity and
-- rectangle, in the order listed. FNV-1a over a canonical text, so any change of a rectangle,
-- extent, name or identity changes it; two independent 64-bit digests are not needed because a
-- stale identity here is a wrong answer, not an attack.
layoutIdentity ∷ [AtlasEntry] → Word64
layoutIdentity atlases = foldl' step 14695981039346656037 (map (fromIntegral . ord) text)
  where
    step h w = (h `xor` w) * 1099511628211
    text = concatMap atlasText atlases
    atlasText a = "A|" <> atlasName a <> "|" <> show (atlasWidth a) <> "|" <> show (atlasHeight a) <> "\n" <> concatMap regionText (atlasRegions a)
    regionText r =
      "R|" <> regionId r <> "|" <> show (regionX r) <> "|" <> show (regionY r) <> "|" <> show (regionW r) <> "|" <> show (regionH r) <> "\n"

-- | The layout identity as sixteen lowercase hexadecimal digits, the manifest's spelling.
layoutIdentityHex ∷ Word64 → String
layoutIdentityHex w = replicate (16 - length digits) '0' <> digits
  where
    digits = showHex w ""

-- | The checked rectangle of an entry, without a parent.
regionRectangle ∷ RegionEntry → Either RegionRefusal ImageRegion
regionRectangle r = mkImageRegion (regionX r) (regionY r) (regionW r) (regionH r)

-- | The atlas and entry of a logical identity, if the manifest has it. The first match wins, so a
-- valid manifest (which has no duplicate) is unambiguous.
findRegion ∷ AtlasManifest → String → Maybe (AtlasEntry, RegionEntry)
findRegion manifest identity =
  case [(a, r) | a ← manifestAtlases manifest, r ← atlasRegions a, regionId r == identity] of
    hit : _ → Just hit
    [] → Nothing

-- | A problem a manifest has.
data ManifestProblem
  = BadSchema !String
  | TooManyAtlases !Int
  | TooManyRegions !String !Int
  | MissingAtlas !String
  | DuplicateAtlas !String
  | UnexpectedAtlas !String
  | BadAtlasExtent !String !Word32 !Word32
  | WrongKind !String !String
  | WrongProfile !String !String
  | BadFileName !String !String
  | BadHash !String !String
  | DuplicateRegion !String
  | MissingRegion !String !String
  | UnexpectedRegion !String !String
  | -- | The identity belongs to the other atlas: its name, then the atlas that holds it.
    RegionInWrongParent !String !String
  | BadRectangle !String !RegionRefusal
  | WrongLogicalExtent !String !Word32 !Word32
  | RegionOutsideAtlas !String !String
  | RegionOverlap !String !String !String
  | LayoutMismatch !Word64 !Word64
  deriving stock (Eq, Show)

-- | A problem as one line that names the identity, atlas or file it is about.
describeProblem ∷ ManifestProblem → String
describeProblem = \case
  BadSchema found → "schema is " <> show found <> ", expected " <> show manifestSchema
  TooManyAtlases n → "the manifest lists " <> show n <> " atlases, more than " <> show maxAtlases
  TooManyRegions a n → "atlas " <> a <> " lists " <> show n <> " regions, more than " <> show maxRegionsPerAtlas
  MissingAtlas a → "atlas " <> a <> " is missing"
  DuplicateAtlas a → "atlas " <> a <> " is listed twice"
  UnexpectedAtlas a → "atlas " <> show a <> " is not one the manifest may hold"
  BadAtlasExtent a w h → "atlas " <> a <> " is " <> show w <> " x " <> show h <> ", outside 1.." <> show maxAtlasAxis <> " per axis and " <> show maxAtlasTexels <> " texels"
  WrongKind a k → "atlas " <> a <> " has kind " <> show k
  WrongProfile a p → "atlas " <> a <> " has profile " <> show p
  BadFileName a f → "atlas " <> a <> " names the file " <> show f <> ", which is not a plain file name"
  BadHash what h → what <> " has the digest " <> show h <> ", which is not 64 lowercase hexadecimal digits"
  DuplicateRegion i → "identity " <> i <> " is listed more than once"
  MissingRegion a i → "atlas " <> a <> " lacks identity " <> i
  UnexpectedRegion a i → "atlas " <> a <> " lists the unexpected identity " <> show i
  RegionInWrongParent i a → "identity " <> i <> " is in atlas " <> a <> ", which is not its parent"
  BadRectangle i why → "identity " <> i <> ": " <> regionRefusalText why
  WrongLogicalExtent i w h → "identity " <> i <> " is " <> show w <> " x " <> show h <> ", not " <> show logicalWidth <> " x " <> show logicalHeight
  RegionOutsideAtlas i a → "identity " <> i <> " lies outside atlas " <> a
  RegionOverlap a i j → "identities " <> i <> " and " <> j <> " overlap in atlas " <> a
  LayoutMismatch stated actual → "the layout identity is " <> layoutIdentityHex stated <> ", the rectangles give " <> layoutIdentityHex actual

-- | Every problem a manifest has, in a stable order. The counts are checked first and stop the
-- walk, so the work is bounded by the limits however large the value is.
validateManifest ∷ AtlasManifest → [ManifestProblem]
validateManifest manifest
  | length (take (maxAtlases + 1) atlases) > maxAtlases = [TooManyAtlases (length atlases)]
  | not (null oversized) = oversized
  | otherwise =
      concat
        [ atlasSetProblems
        , concatMap atlasProblems atlases
        , duplicateIdentities
        , [LayoutMismatch (manifestLayout manifest) actual | manifestLayout manifest /= actual]
        ]
  where
    atlases = manifestAtlases manifest
    actual = layoutIdentity atlases
    oversized = [TooManyRegions (atlasName a) (length (atlasRegions a)) | a ← atlases, length (take (maxRegionsPerAtlas + 1) (atlasRegions a)) > maxRegionsPerAtlas]
    names = map atlasName atlases
    atlasSetProblems =
      [DuplicateAtlas n | n ← uniqueSorted (duplicatesOf names)]
        <> [MissingAtlas n | n ← [colourAtlasName, normalAtlasName], n `notElem` names]
        <> [UnexpectedAtlas n | n ← names, n `notElem` [colourAtlasName, normalAtlasName]]
    allIds = concatMap (map regionId . atlasRegions) atlases
    duplicateIdentities = [DuplicateRegion i | i ← uniqueSorted (duplicatesOf allIds)]

uniqueSorted ∷ Ord a ⇒ [a] → [a]
uniqueSorted xs = Map.keys (Map.fromList [(x, ()) | x ← xs])

duplicatesOf ∷ Ord a ⇒ [a] → [a]
duplicatesOf xs = [k | (k, n) ← Map.toList (Map.fromListWith (+) [(x, 1 ∷ Int) | x ← xs]), n > 1]

-- The checks of one atlas and its regions.
atlasProblems ∷ AtlasEntry → [ManifestProblem]
atlasProblems atlas =
  extent
    <> profile
    <> file
    <> hash
    <> identities
    <> concatMap regionProblems regions
    <> overlaps
  where
    name = atlasName atlas
    regions = atlasRegions atlas
    w = atlasWidth atlas
    h = atlasHeight atlas
    extent =
      [ BadAtlasExtent name w h
      | w == 0 || h == 0 || w > maxAtlasAxis || h > maxAtlasAxis || toInteger w * toInteger h > maxAtlasTexels
      ]
    (wantKind, wantProfile, wantIds, otherIds) = case name of
      n
        | n == colourAtlasName → (Just colourKind, Just colourProfile, colourRegionIds, normalRegionIds)
        | n == normalAtlasName → (Just dataKind, Just normalProfile, normalRegionIds, colourRegionIds)
      _ → (Nothing, Nothing, [], [])
    profile =
      [WrongKind name (atlasKind atlas) | Just k ← [wantKind], k /= atlasKind atlas]
        <> [WrongProfile name (atlasProfile atlas) | Just p ← [wantProfile], p /= atlasProfile atlas]
    file = [BadFileName name f | let f = atlasFile atlas, null f || any (`elem` ['/', '\\']) f || f == "." || f == ".."]
    hash = [BadHash ("atlas " <> name) (atlasSha256 atlas) | not (isSha (atlasSha256 atlas))]
    ids = map regionId regions
    identities
      | null wantIds = []
      | otherwise =
          [MissingRegion name i | i ← wantIds, i `notElem` ids]
            <> [ if i `elem` otherIds then RegionInWrongParent i name else UnexpectedRegion name i
               | i ← ids
               , i `notElem` wantIds
               ]
    regionProblems r =
      [BadHash ("the source of " <> regionId r) (regionSourceSha256 r) | not (isSha (regionSourceSha256 r))]
        <> case regionRectangle r of
          Left why → [BadRectangle (regionId r) why]
          Right _ →
            [WrongLogicalExtent (regionId r) (regionW r) (regionH r) | regionW r /= logicalWidth || regionH r /= logicalHeight]
              <> [RegionOutsideAtlas (regionId r) name | far (regionX r) (regionW r) > toInteger w || far (regionY r) (regionH r) > toInteger h]
    far origin extent' = toInteger origin + toInteger extent'
    overlaps =
      [ RegionOverlap name (regionId a) (regionId b)
      | (index, a) ← zip [0 ∷ Int ..] regions
      , b ← drop (index + 1) regions
      , valid a
      , valid b
      , intersects a b
      ]
    valid r = either (const False) (const True) (regionRectangle r)
    intersects a b =
      toInteger (regionX a) < far (regionX b) (regionW b)
        && toInteger (regionX b) < far (regionX a) (regionW a)
        && toInteger (regionY a) < far (regionY b) (regionH b)
        && toInteger (regionY b) < far (regionY a) (regionH a)

isSha ∷ String → Bool
isSha s = length s == 64 && all (`elem` lowerHex) s

lowerHex ∷ String
lowerHex = "0123456789abcdef"

-- Parsing -------------------------------------------------------------------------------------------------

-- | Read a manifest: bounded text, then every check of 'validateManifest'. The result is a valid
-- manifest or the problems, one line each.
parseManifest ∷ ByteString → Either [String] AtlasManifest
parseManifest bytes = do
  json ← either (\why → Left ["manifest: " <> why]) Right (parseJsonBounded (JsonLimits maxManifestBytes 6 (4 * maxAtlases * maxRegionsPerAtlas + 64)) bytes)
  manifest ← either (\why → Left ["manifest: " <> why]) Right (decode json)
  case validateManifest manifest of
    [] → Right manifest
    problems → Left (map describeProblem problems)

decode ∷ JsonValue → Either String AtlasManifest
decode root = do
  top ← members "the document" ["schema", "recipe", "logical", "layoutIdentity", "atlases"] root
  schema ← str "schema" =<< get top "schema"
  if schema /= manifestSchema then Left (describeProblem (BadSchema schema)) else Right ()
  recipe ← str "recipe" =<< get top "recipe"
  logical ← members "logical" ["width", "height"] =<< get top "logical"
  lw ← word "logical.width" =<< get logical "width"
  lh ← word "logical.height" =<< get logical "height"
  if (lw, lh) /= (logicalWidth, logicalHeight) then Left ("logical is " <> show lw <> " x " <> show lh) else Right ()
  layoutText ← str "layoutIdentity" =<< get top "layoutIdentity"
  layout ← hex64 layoutText
  atlasValues ← array "atlases" =<< get top "atlases"
  if length (take (maxAtlases + 1) atlasValues) > maxAtlases then Left (describeProblem (TooManyAtlases (length atlasValues))) else Right ()
  atlases ← mapM atlas atlasValues
  Right (AtlasManifest recipe layout atlases)
  where
    atlas v = do
      m ← members "an atlas" ["name", "file", "width", "height", "kind", "profile", "coverage", "sha256", "regions"] v
      name ← str "name" =<< get m "name"
      file ← str "file" =<< get m "file"
      w ← word (name <> ".width") =<< get m "width"
      h ← word (name <> ".height") =<< get m "height"
      kind ← str "kind" =<< get m "kind"
      profile ← str "profile" =<< get m "profile"
      coverage ← str "coverage" =<< get m "coverage"
      if coverage /= "binary" then Left ("atlas " <> name <> " has coverage " <> show coverage) else Right ()
      sha ← str "sha256" =<< get m "sha256"
      regionValues ← array "regions" =<< get m "regions"
      if length (take (maxRegionsPerAtlas + 1) regionValues) > maxRegionsPerAtlas then Left (describeProblem (TooManyRegions name (length regionValues))) else Right ()
      regions ← mapM region regionValues
      Right (AtlasEntry name file w h kind profile sha regions)
    region v = do
      m ← members "a region" ["id", "x", "y", "width", "height", "sourcePath", "sourceSha256"] v
      i ← str "id" =<< get m "id"
      x ← word (i <> ".x") =<< get m "x"
      y ← word (i <> ".y") =<< get m "y"
      w ← word (i <> ".width") =<< get m "width"
      h ← word (i <> ".height") =<< get m "height"
      path ← str "sourcePath" =<< get m "sourcePath"
      sha ← str "sourceSha256" =<< get m "sourceSha256"
      Right (RegionEntry i x y w h path sha)

-- The members of an object, which must be exactly the expected keys.
members ∷ String → [String] → JsonValue → Either String (Map.Map String JsonValue)
members what expected (JsonObject fields)
  | length keys /= length (uniqueSorted keys) = Left (what <> " repeats a key")
  | not (null extra) = Left (what <> " has the unexpected key " <> show (head' extra))
  | not (null absent) = Left (what <> " lacks the key " <> show (head' absent))
  | otherwise = Right (Map.fromList fields)
  where
    keys = map fst fields
    extra = filter (`notElem` expected) keys
    absent = filter (`notElem` keys) expected
    head' (x : _) = x
    head' [] = ""
members what _ _ = Left (what <> " is not an object")

get ∷ Map.Map String JsonValue → String → Either String JsonValue
get m key = maybe (Left ("missing " <> key)) Right (Map.lookup key m)

str ∷ String → JsonValue → Either String String
str _ (JsonString s) = Right s
str what _ = Left (what <> " is not a string")

array ∷ String → JsonValue → Either String [JsonValue]
array _ (JsonArray items) = Right items
array what _ = Left (what <> " is not an array")

-- A number that must fit 32 unsigned bits: a negative or larger value is refused, never wrapped.
word ∷ String → JsonValue → Either String Word32
word what (JsonInteger n)
  | n < 0 || n > toInteger (maxBound ∷ Word32) = Left (what <> " is " <> show n <> ", not an unsigned 32-bit integer")
  | otherwise = Right (fromInteger n)
word what _ = Left (what <> " is not an integer")

hex64 ∷ String → Either String Word64
hex64 s
  | length s == 16 && all (`elem` lowerHex) s, [(n, "")] ← readHex s = Right n
  | otherwise = Left ("layoutIdentity " <> show s <> " is not 16 lowercase hexadecimal digits")
