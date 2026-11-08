-- | The pinned inputs of the generator (TRA-14): the unchanged colour artwork,
-- the imported blank, and the retained reference-only Synarchy masks.
--
-- Everything is read from the sample's own committed files and checked against
-- the SHA-256 recorded here, which are the values of the Synarchy revision
-- 'sourceRevision'. Nothing reads a sibling Synarchy checkout or the network.
-- The reference masks are legacy face-weight maps; they feed the original
-- comparison sheets only and are never resolved as @unit-normal-rgb-v1@ maps.
--
-- State, ownership and lifetime: none. A load reads files and returns values.
module Hetoimasia.Terrain.MapGen.Inputs
  ( sourceRevision
  , ColourArt (..)
  , pinnedColourArt
  , ReferenceMask (..)
  , referenceMasks
  , Inputs (..)
  , loadInputs
  , sha256Hex
  , textureDirectory
  , referenceDirectory
  ) where

import Control.Monad (forM)
import Crypto.Hash.SHA256 (hash)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Either (partitionEithers)
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Numeric (showHex)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | The Synarchy commit every pinned input comes from.
sourceRevision ∷ String
sourceRevision = "3777d437ea00e1302bf55162ad5693fee4879187"

-- | Lowercase hexadecimal SHA-256.
sha256Hex ∷ ByteString → String
sha256Hex = concatMap two . ByteString.unpack . hash
  where
    two byte = (if byte < 16 then "0" else "") <> showHex byte ""

-- | Where the colour artwork lives under the sample directory.
textureDirectory ∷ FilePath
textureDirectory = "content" </> "textures"

-- | Where the reference-only masks live under the sample directory.
referenceDirectory ∷ FilePath
referenceDirectory = "reference" </> "synarchy-3777d437" </> "facemap"

-- | An authored colour sheet imported byte for byte.
data ColourArt = ColourArt
  { artName ∷ !String
  , artFile ∷ !FilePath
  -- ^ Relative to 'textureDirectory'.
  , artSourcePath ∷ !String
  -- ^ The path in Synarchy at 'sourceRevision'.
  , artSha256 ∷ !String
  }
  deriving stock (Eq, Show)

-- | The loam and granite artwork kept from the baseline and the generic blank
-- the cover uses.
pinnedColourArt ∷ [ColourArt]
pinnedColourArt =
  [ ColourArt "loam" "loam.png" "assets/textures/world/loam/loam.png" "f449a06bc3aa76fdf56607c4e4d23ac1cc8c1a67245b8ae5b295dbff621105e1"
  , ColourArt "granite" "granite.png" "assets/textures/world/granite/granite.png" "776a28d3ee45f656ee8f024444c0f2529b4d176da455902e4ac9bfb329d79d1c"
  , ColourArt "blanktexture" "blanktexture.png" "assets/textures/utility/blanktexture.png" "c747223e0f788c942d1e8699735ac4a26a011599b6442c707b91c29f42f2f90e"
  ]

-- | A retained legacy face-weight mask: the Synarchy shape identity it is
-- selected for (at the South facing), its file, git blob and SHA-256.
data ReferenceMask = ReferenceMask
  { referenceShape ∷ !Int
  , referenceFile ∷ !FilePath
  , referenceBlob ∷ !String
  , referenceSha256 ∷ !String
  }
  deriving stock (Eq, Show)

-- | The sixteen masks Synarchy's @World.Render.Textures.getTileFaceMapTexture@
-- selects: identity 0 the flat @isoface@, the rest @isoface_slope_*@.
referenceMasks ∷ [ReferenceMask]
referenceMasks =
  [ ReferenceMask 0 "isoface.png" "a4a5c0585c66513083034a4891b742134b674e9c" "60fe5a0584255d8088eebdfbc20e39aa5ba18af7564f99a91a02dcf02ebfc5fe"
  , ReferenceMask 1 "isoface_slope_n.png" "effc21564c7a653605dcbafca23ce7bc560e262d" "1e0d2e7e559a004821d3b02150ed650ebfa6360fd77648164010efb9fb3c6310"
  , ReferenceMask 2 "isoface_slope_e.png" "5ed533b4d9467fa3b371a4cb489a87844fa64611" "b63967d34e447e487a504ddf97b723d4c4f7cd642b1a319f44fe88eb55ab2c1d"
  , ReferenceMask 3 "isoface_slope_ne.png" "d2fa0656f8c1ed277ca4a155b7adadf81856a049" "320310fb5d93f26f63b7dcf5afcf8646dc3824c818e1e3ed5e99ad0ca3570192"
  , ReferenceMask 4 "isoface_slope_s.png" "708fbd56d624dd44a5b5fe6cd3e23c2c8dea66ed" "d35c5ba917286f12143bcf872372dc80fd269e9fe5d988b87ceff449ae178b01"
  , ReferenceMask 5 "isoface_slope_ns.png" "51456f8a31fddbf4d6b9bb12267625638e0c53d7" "d0e7fb355b743851d755be6d838f8a67d4a2152608928cadf1929bda13d8ae07"
  , ReferenceMask 6 "isoface_slope_es.png" "87307362412726f8f9090d5b1a26ff1210dea901" "712b6709a6c1a5ed4ffc30e5f92f7750c003293a85ca5a1df0b8ec78845a44ea"
  , ReferenceMask 7 "isoface_slope_nes.png" "ff3e46062421bae13bb84429a62d450d265e45a3" "d365d6685cc810ca2a5322be04b9b5a029da552f974387081dbbc37d7d30ef82"
  , ReferenceMask 8 "isoface_slope_w.png" "ca32254f1e5d5236e4f888b96ddec789d10701d0" "278e8bcafbf0d4faf6ee6932c579507570e3e41d9dab364f7b630928c22b1668"
  , ReferenceMask 9 "isoface_slope_nw.png" "038d24596344ac3d526c64dbed77f21a1edde0cb" "4e7ab264ac94df0cfd3639b2d26fd3184f677e91d4bb9b49a083d6875dcf741b"
  , ReferenceMask 10 "isoface_slope_ew.png" "eaf29e314251b2970136ad47d9bc05efb81f559d" "ed3b977fc349d2d66debbc15f63fd9e55503c328169547b76f9f93b5254ef653"
  , ReferenceMask 11 "isoface_slope_new.png" "4066ee35d1d4e224970dcb509bc4b8a4caf2a0d6" "0f35475c441804a8d95c7b4bd0b31ed0019f2826caa9a8620398e8f535308dcd"
  , ReferenceMask 12 "isoface_slope_sw.png" "9ed0e0631f03df2b02052a6c119f370797c0065f" "9cceb34ba8aed3433e6ef7672aa6110efdfec0afbf154d40272913b12ef5908a"
  , ReferenceMask 13 "isoface_slope_nsw.png" "6a8cca207f9d77309733aa8089a4b6f0fe295f52" "5e42db15a4f4f214507ef5845c8b47c82a6d26465cdd4a5be47088daa4512ed2"
  , ReferenceMask 14 "isoface_slope_esw.png" "3253a6885d20604cccd6889737bfcec35c9fa24d" "fa9bf95a40dbcc6526d7b57934957c5cff52d2d1c42a8aba4efeca4663b2719d"
  , ReferenceMask 15 "isoface_slope_nesw.png" "2bec0d312710cb5aaa6e3d01998a90cf9c272122" "c5be1edd139438eebe7faf41864e56cf74152263224d39c19f41c2e70f92a749"
  ]

-- | The checked inputs: each file's bytes and decoded RGBA8 canvas.
data Inputs = Inputs
  { inputColour ∷ [(ColourArt, ByteString, ByteString)]
  -- ^ The art, its file bytes and its 96 × 64 RGBA8 texels.
  , inputReference ∷ [(ReferenceMask, ByteString, ByteString)]
  -- ^ The mask, its file bytes and its 96 × 64 RGBA8 texels.
  }

-- | Read and verify every input under the sample directory. A missing file, a
-- hash other than the pinned one or a canvas that is not 96 × 64 RGBA8 is
-- reported by path; nothing is repaired.
loadInputs ∷ FilePath → IO (Either [String] Inputs)
loadInputs sample = do
  colour ← forM pinnedColourArt $ \art →
    load (sample </> textureDirectory </> artFile art) (artSha256 art) (\bytes texels → (art, bytes, texels))
  reference ← forM referenceMasks $ \mask →
    load (sample </> referenceDirectory </> referenceFile mask) (referenceSha256 mask) (\bytes texels → (mask, bytes, texels))
  let (colourBad, colourGood) = partitionEithers colour
      (referenceBad, referenceGood) = partitionEithers reference
  pure $ case colourBad <> referenceBad of
    [] → Right (Inputs colourGood referenceGood)
    bad → Left bad
  where
    load path expected build = do
      present ← tryRead path
      pure $ case present of
        Nothing → Left ("missing input: " <> path)
        Just bytes
          | sha256Hex bytes /= expected → Left ("input " <> path <> " has SHA-256 " <> sha256Hex bytes <> ", expected " <> expected)
          | otherwise → case decodeRgba bytes of
              Left why → Left ("input " <> path <> " is not an RGBA8 PNG: " <> why)
              Right (96, 64, texels) → Right (build bytes texels)
              Right (w, h, _) → Left ("input " <> path <> " is " <> show w <> "x" <> show h <> ", expected 96x64")
    tryRead path = do
      exists ← doesFileExist path
      if exists then Just <$> ByteString.readFile path else pure Nothing
