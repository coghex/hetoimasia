-- | Examples proving what the package boundary shows a client: the public
-- module supplies the handle's instances but neither its constructor nor a
-- field reader, and the backend-facing module supplies construction and access.
--
-- Each compiles a separate single-module client with the harness from
-- "Test.Support.ExternalClient", exposing @base@ and @hetoimasia-render-api@
-- and hiding everything else. The rejected clients must be refused for the
-- specific diagnostic naming their cause, so a missing package or an absent
-- compiler can never pass for the boundary holding. The accepted clients are
-- the environment control: they show the harness compiles against the package
-- at all, so a rejection is about the boundary and not the setup.
module Test.Render.Api.Opacity (spec) where

import System.Exit (ExitCode (ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)
import Test.Support.ExternalClient (Client (..), Mode (..), rejectedBecause, withPackageClient)

spec ∷ Spec
spec = describe "Texture handle opacity across the package boundary" $ do
  it "rejects a client that names the constructor through the public module" $
    withClient constructorClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-10237"
      clientOutput outcome `shouldContain` "TextureHandle"

  it "rejects a client that reads the index through the public module" $
    withClient indexReaderClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "handleIndex"

  it "rejects a client that reads the generation through the public module" $
    withClient generationReaderClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "handleGeneration"

  it "rejects a client that rewrites a field by record update through the public module" $
    withClient recordUpdateClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-22385"
      clientOutput outcome `shouldContain` "handleIndex"

  it "rejects a client that builds a handle through the public module's constructor function" $
    withClient constructionFunctionClient $ \compile → do
      outcome ← compile Typecheck
      rejectedBecause outcome "GHC-61689"
      clientOutput outcome `shouldContain` "textureHandle"

  it "accepts a client that only compares, orders and shows handles it was given" $
    withClient gameClient $ \compile → do
      outcome ← compile Typecheck
      accepted outcome

  it "accepts a client that imports the backend-facing module to build and read a handle" $
    withClient backendClient $ \compile → do
      outcome ← compile Typecheck
      accepted outcome

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "hetoimasia-render-api"] "Client.hs"

accepted ∷ Client → IO ()
accepted outcome = case clientStatus outcome of
  ExitSuccess → pure ()
  status →
    expectationFailure
      ( "the client must compile, but the compiler exited with "
          <> show status
          <> ":\n"
          <> clientOutput outcome
      )

-- | Naming the constructor to build a handle of the client's choosing.
constructorClient ∷ String
constructorClient =
  unlines
    [ "module Client (forged) where"
    , ""
    , "import Hetoimasia.Render.Api.Texture (TextureHandle (TextureHandle))"
    , ""
    , "forged ∷ TextureHandle"
    , "forged = TextureHandle 1 1"
    ]

-- | Taking a handle apart: the index.
indexReaderClient ∷ String
indexReaderClient =
  unlines
    [ "module Client (index) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle, handleIndex)"
    , ""
    , "index ∷ TextureHandle → Word32"
    , "index = handleIndex"
    ]

-- | Taking a handle apart: the generation.
generationReaderClient ∷ String
generationReaderClient =
  unlines
    [ "module Client (generation) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle, handleGeneration)"
    , ""
    , "generation ∷ TextureHandle → Word32"
    , "generation = handleGeneration"
    ]

-- | Rewriting one number of a handle through record-update syntax, which needs
-- a field label to be in scope.
recordUpdateClient ∷ String
recordUpdateClient =
  unlines
    [ "module Client (rewritten) where"
    , ""
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , ""
    , "rewritten ∷ TextureHandle → TextureHandle"
    , "rewritten handle = handle { handleIndex = 0 }"
    ]

-- | Calling the backend's construction function from the public module.
constructionFunctionClient ∷ String
constructionFunctionClient =
  unlines
    [ "module Client (made) where"
    , ""
    , "import Hetoimasia.Render.Api.Texture (TextureHandle, textureHandle)"
    , ""
    , "made ∷ TextureHandle"
    , "made = textureHandle 1 1"
    ]

-- | What game code may do with handles it was given: compare, order and show.
gameClient ∷ String
gameClient =
  unlines
    [ "module Client (same, earlier, described, smallest) where"
    , ""
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , ""
    , "same ∷ TextureHandle → TextureHandle → Bool"
    , "same a b = a == b"
    , ""
    , "earlier ∷ TextureHandle → TextureHandle → Bool"
    , "earlier a b = a < b"
    , ""
    , "described ∷ TextureHandle → String"
    , "described = show"
    , ""
    , "smallest ∷ [TextureHandle] → TextureHandle"
    , "smallest = minimum"
    ]

-- | What a backend does: build a handle and read both numbers back.
backendClient ∷ String
backendClient =
  unlines
    [ "module Client (issued, numbers) where"
    , ""
    , "import Data.Word (Word32)"
    , "import Hetoimasia.Render.Api.Texture (TextureHandle)"
    , "import Hetoimasia.Render.Api.Texture.Backend (handleGeneration, handleIndex, textureHandle)"
    , ""
    , "issued ∷ Word32 → Word32 → TextureHandle"
    , "issued = textureHandle"
    , ""
    , "numbers ∷ TextureHandle → (Word32, Word32)"
    , "numbers handle = (handleIndex handle, handleGeneration handle)"
    ]
