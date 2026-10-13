-- | Examples proving what the package boundary shows a client: a validated
-- snapshot and a validated layer cannot be built or rewritten from outside the
-- validation module, an offscreen target reference cannot be built or taken
-- apart through its public module, a retained chunk's reference and a built chunk
-- cannot be forged either, a material reference cannot be built or rewritten
-- from the public module (R2D-11), and the backend-facing target, chunk-reference
-- and material modules and the documented validate-then-encode route do work.
--
-- Each compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @hetoimasia-math@,
-- @hetoimasia-render-api@ and @hetoimasia-render-2d@ and hiding everything
-- else. A rejected client must be refused for the diagnostic that names its
-- cause, so a missing package or an absent compiler can never pass for the
-- boundary holding. The accepted clients are the environment control: they show
-- the harness compiles against these packages at all.
module Test.Render.TwoD.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Validated value and target opacity across the package boundary" $ do
  rejected "a client that names the validated snapshot's constructor" snapshotConstructor "GHC-10237" "ValidSnapshot"
  rejected "a client that names the validated layer's constructor" layerConstructor "GHC-10237" "ValidLayer"
  rejected "a client that rewrites a validated layer by record update" layerRecordUpdate "GHC-22385" "validLayerContents"
  rejected "a client that names the offscreen target reference's constructor" targetConstructor "GHC-10237" "TargetRef"
  rejected "a client that reads the target reference's index through the public module" targetReader "GHC-61689" "targetRefIndex"
  rejected "a client that builds a target reference through the public module" targetBuilder "GHC-61689" "targetRef"
  rejected "a client that names the view mapping's constructor" mappingConstructor "GHC-10237" "ViewMapping"
  rejected "a client that names the chunk reference's constructor" chunkRefConstructor "GHC-10237" "ChunkRef"
  rejected "a client that reads the chunk reference's index through the public module" chunkRefReader "GHC-61689" "chunkRefIndex"
  rejected "a client that builds a chunk reference through the public module" chunkRefBuilder "GHC-61689" "chunkRef"
  rejected "a client that names the built chunk's constructor" chunkConstructor "GHC-10237" "Chunk"
  rejected "a client that rewrites a built chunk by record update" chunkRecordUpdate "GHC-22385" "chunkKind"
  rejected "a client that names the material reference's constructor" materialConstructor "GHC-10237" "MaterialRef"
  rejected "a client that reads the material reference's identity through the public module" materialIdentityReader "GHC-61689" "materialRefIdentity"
  rejected "a client that rewrites a fact of a material reference by record update" materialRecordUpdate "GHC-22385" "materialRefFacts"
  rejected "a client that builds a material reference through the public module" materialBuilder "GHC-61689" "materialRef"
  accepted "a client that validates a candidate and encodes its layers" validateAndEncode
  accepted "a client that reads a material reference's facts and names the default material" readMaterial
  acceptedWith
    ["base", "bytestring", "containers", "hetoimasia-math", "hetoimasia-render-api", "hetoimasia-render-2d"]
    "a client that builds a material reference through the backend-facing module, names it in an instance and validates the snapshot"
    backendMaterial
  accepted "a client that builds a view mapping and converts a cursor position" buildMapping
  accepted "a client that builds and reads a target reference through the backend-facing module" backendTarget
  accepted "a client that builds and reads a chunk reference through the backend-facing module" backendChunkRef
  accepted "a client that builds a chunk, lists it in a layer and validates the snapshot against it" buildAndList

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient =
  withPackageClient
    ["base", "hetoimasia-math", "hetoimasia-render-api", "hetoimasia-render-2d"]
    "Client.hs"

rejected ∷ String → String → String → String → Spec
rejected name source code mention =
  it ("rejects " <> name) $
    withClient source $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome code
      clientOutput outcome `shouldContain` mention

accepted ∷ String → String → Spec
accepted = acceptedWith ["base", "hetoimasia-math", "hetoimasia-render-api", "hetoimasia-render-2d"]

-- | An accepted client that may name more packages than the usual four.
acceptedWith ∷ [String] → String → String → Spec
acceptedWith packages name source =
  it ("accepts " <> name) $
    withPackageClient packages "Client.hs" source $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

snapshotConstructor ∷ String
snapshotConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Snapshot)"
    , "import Hetoimasia.Render.TwoD.Validation (ValidSnapshot (ValidSnapshot))"
    , ""
    , "forged ∷ Snapshot → ValidSnapshot"
    , "forged snapshot = ValidSnapshot snapshot []"
    ]

layerConstructor ∷ String
layerConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Layer)"
    , "import Hetoimasia.Render.TwoD.Validation (Location (AtLayer), ValidLayer (ValidLayer))"
    , ""
    , "forged ∷ Layer → ValidLayer"
    , "forged layer = ValidLayer (AtLayer 0 0 0) layer"
    ]

layerRecordUpdate ∷ String
layerRecordUpdate =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Snapshot (Layer)"
    , "import Hetoimasia.Render.TwoD.Validation (ValidLayer, validLayerContents)"
    , ""
    , "rewritten ∷ ValidLayer → Layer → ValidLayer"
    , "rewritten valid layer = valid { validLayerContents = layer }"
    ]

targetConstructor ∷ String
targetConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Target (TargetRef (TargetRef))"
    , ""
    , "forged ∷ TargetRef"
    , "forged = TargetRef 1 1"
    ]

targetReader ∷ String
targetReader =
  unlines
    [ "module Client (index) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Target (TargetRef, targetRefIndex)"
    , ""
    , "index ∷ TargetRef → Word32"
    , "index = targetRefIndex"
    ]

targetBuilder ∷ String
targetBuilder =
  unlines
    [ "module Client (made) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Target (TargetRef, targetRef)"
    , ""
    , "made ∷ TargetRef"
    , "made = targetRef 1 1"
    ]

-- | What game code does with the package: build a candidate, validate it, and
-- encode each layer of the result.
validateAndEncode ∷ String
validateAndEncode =
  unlines
    [ "module Client (frame) where"
    , ""
    , "import Hetoimasia.Math.Affine2 (identity)"
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , "import Hetoimasia.Render.TwoD.Encoding (encodeLayer)"
    , "import Hetoimasia.Render.TwoD.Material (defaultMaterial)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot"
    , "import Hetoimasia.Render.TwoD.Validation (validLayers, validateSnapshot)"
    , ""
    , "-- The result is unit: the encoded buffers are forced, then dropped, because"
    , "-- their type belongs to a package this client deliberately does not expose."
    , "frame ∷ TextureHandle → ()"
    , "frame texture = either (const ()) (foldr seq () . map encodeLayer . validLayers) (validateSnapshot snapshot)"
    , "  where"
    , "    snapshot = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [view]]"
    , "    view = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 640 480)) defaultViewSettings [] [layer]"
    , "    layer = UiLayer [Instance identity (UvRect 0 0 1 1) texture 0 (Tint 255 255 255 255) SamplerDefault False False 0 0 defaultMaterial]"
    ]

backendTarget ∷ String
backendTarget =
  unlines
    [ "module Client (issued, numbers) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Target (TargetRef)"
    , "import Hetoimasia.Render.TwoD.Target.Backend (targetRef, targetRefGeneration, targetRefIndex)"
    , ""
    , "issued ∷ Word32 → Word32 → TargetRef"
    , "issued = targetRef"
    , ""
    , "numbers ∷ TargetRef → (Word32, Word32)"
    , "numbers reference = (targetRefIndex reference, targetRefGeneration reference)"
    ]

chunkRefConstructor ∷ String
chunkRefConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Chunk (ChunkRef (ChunkRef))"
    , ""
    , "forged ∷ ChunkRef"
    , "forged = ChunkRef 1 1"
    ]

chunkRefReader ∷ String
chunkRefReader =
  unlines
    [ "module Client (index) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Chunk (ChunkRef, chunkRefIndex)"
    , ""
    , "index ∷ ChunkRef → Word32"
    , "index = chunkRefIndex"
    ]

chunkRefBuilder ∷ String
chunkRefBuilder =
  unlines
    [ "module Client (made) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Chunk (ChunkRef, chunkRef)"
    , ""
    , "made ∷ ChunkRef"
    , "made = chunkRef 1 1"
    ]

chunkConstructor ∷ String
chunkConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Chunk (Chunk (Chunk))"
    , ""
    , "forged ∷ Chunk → Chunk"
    , "forged held = Chunk held"
    ]

chunkRecordUpdate ∷ String
chunkRecordUpdate =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Chunk (Chunk, ChunkKind, chunkKind)"
    , ""
    , "rewritten ∷ Chunk → ChunkKind → Chunk"
    , "rewritten held kind = held { chunkKind = kind }"
    ]

backendChunkRef ∷ String
backendChunkRef =
  unlines
    [ "module Client (issued, numbers) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.TwoD.Chunk (ChunkRef)"
    , "import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef, chunkRefGeneration, chunkRefIndex)"
    , ""
    , "issued ∷ Word32 → Word32 → ChunkRef"
    , "issued = chunkRef"
    , ""
    , "numbers ∷ ChunkRef → (Word32, Word32)"
    , "numbers reference = (chunkRefIndex reference, chunkRefGeneration reference)"
    ]

-- | What a backend's client does: build a chunk, list it in a layer and validate
-- the snapshot against the chunks it holds.
buildAndList ∷ String
buildAndList =
  unlines
    [ "module Client (frame) where"
    , ""
    , "import Hetoimasia.Math.Affine2 (identity)"
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , "import Hetoimasia.Render.TwoD.Chunk"
    , "import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)"
    , "import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)"
    , "import Hetoimasia.Render.TwoD.Material (defaultMaterial)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot"
    , "import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)"
    , ""
    , "frame ∷ TextureHandle → Bool"
    , "frame texture = case buildChunk noCutoutMarks ChunkUi DeriveBounds [candidate] of"
    , "  Left _ → False"
    , "  Right built → either (const False) (const True) (validateSnapshotWith (chunksFrom [(reference, built)]) snapshot)"
    , "  where"
    , "    reference = chunkRef 1 1"
    , "    candidate = Instance identity (UvRect 0 0 1 1) texture 0 (Tint 255 255 255 255) SamplerDefault False False 0 0 defaultMaterial"
    , "    snapshot = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [view]]"
    , "    view = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 640 480)) defaultViewSettings [] [UiLayerWith [reference] []]"
    ]

mappingConstructor ∷ String
mappingConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Mapping (ViewMapping (ViewMapping))"
    , ""
    , "forged ∷ ViewMapping"
    , "forged = ViewMapping undefined undefined undefined undefined undefined undefined"
    ]

-- | What game code does with the mapping: build it from the window's metrics
-- and a view, and turn a cursor position into a world point.
buildMapping ∷ String
buildMapping =
  unlines
    [ "module Client (pick) where"
    , ""
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.TwoD.Mapping (viewMapping, windowToWorld)"
    , "import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot (Camera (..), View (..), Viewport (..))"
    , ""
    , "pick ∷ V2 → Maybe V2"
    , "pick cursor = viewMapping metrics view >>= \\mapping → windowToWorld mapping cursor"
    , "  where"
    , "    metrics = TargetMetrics (PixelExtent 640 480) (PixelExtent 1280 960) 2 2"
    , "    view = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 1280 960)) defaultViewSettings [] []"
    ]

materialConstructor ∷ String
materialConstructor =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRef (MaterialRef), RecordLayout (..))"
    , ""
    , "forged ∷ MaterialRef"
    , "forged = MaterialRef 1 (MaterialFacts True (RecordLayout 0 0) 0)"
    ]

materialIdentityReader ∷ String
materialIdentityReader =
  unlines
    [ "module Client (identity) where"
    , ""
    , "import Data.Word (Word64)"
    , "import Hetoimasia.Render.TwoD.Material (MaterialRef, materialRefIdentity)"
    , ""
    , "identity ∷ MaterialRef → Word64"
    , "identity = materialRefIdentity"
    ]

materialRecordUpdate ∷ String
materialRecordUpdate =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Material (MaterialFacts, MaterialRef)"
    , ""
    , "rewritten ∷ MaterialRef → MaterialFacts → MaterialRef"
    , "rewritten reference facts = reference {materialRefFacts = facts}"
    ]

materialBuilder ∷ String
materialBuilder =
  unlines
    [ "module Client (made) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Material (MaterialFacts (..), MaterialRef, RecordLayout (..), materialRef)"
    , ""
    , "made ∷ MaterialRef"
    , "made = materialRef 1 (MaterialFacts True (RecordLayout 0 0) 0)"
    ]

-- | What game code does with a reference: compare it, show it and read its facts.
readMaterial ∷ String
readMaterial =
  unlines
    [ "module Client (summary) where"
    , ""
    , "import Hetoimasia.Render.TwoD.Material"
    , ""
    , "summary ∷ MaterialRef → (Bool, RecordLayout, Word, Bool, String)"
    , "summary reference ="
    , "  ( materialCutoutCapable reference"
    , "  , materialRecordLayout reference"
    , "  , fromIntegral (materialPushBytes reference)"
    , "  , reference == defaultMaterial"
    , "  , show (materialFacts reference)"
    , "  )"
    ]

-- | What a backend, or a test standing in for one, does: build a reference with
-- its facts, name it in an instance and validate a snapshot holding that
-- instance, with the records and the push block its view holds for it.
backendMaterial ∷ String
backendMaterial =
  unlines
    [ "module Client (frame) where"
    , ""
    , "import qualified Data.ByteString as ByteString"
    , "import qualified Data.Map.Strict as Map"
    , "import Hetoimasia.Math.Affine2 (identity)"
    , "import Hetoimasia.Math.Vector (V2 (..))"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , "import Hetoimasia.Render.TwoD.Material"
    , "import Hetoimasia.Render.TwoD.Material.Backend (materialRef)"
    , "import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)"
    , "import Hetoimasia.Render.TwoD.Snapshot"
    , "import Hetoimasia.Render.TwoD.Validation (validateSnapshot)"
    , ""
    , "frame ∷ TextureHandle → Bool"
    , "frame texture = either (const False) (const True) (validateSnapshot snapshot)"
    , "  where"
    , "    material = materialRef 1 (MaterialFacts False (RecordLayout 1 0) 4)"
    , "    held = Map.fromList [(material, MaterialData [MaterialRecord [texture] []] (ByteString.pack [0, 0, 0, 0]))]"
    , "    snapshot = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [view]]"
    , "    view = ViewWith (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 640 480)) defaultViewSettings [] held [layer]"
    , "    layer = UiLayer [Instance identity (UvRect 0 0 1 1) texture 0 (Tint 255 255 255 255) SamplerDefault False False 0 0 material]"
    ]
