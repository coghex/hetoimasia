-- | The texture registry's release policy on constructed handles (GUIDE-5):
-- stale handles are refused, the current generation keeps its marker through
-- the table release, an index never registered reports nothing, and a
-- generation that wraps from its largest value to 1 is ordered by
-- registration. Every expected answer is written here, from the issue's rules,
-- never read from the code under test.
module Test.Render.TwoD.Vulkan.Ledger (spec) where

import Data.Maybe (fromMaybe)
import Data.Word (Word32)
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Vulkan.Textures (SwapPolicy (..), TextureRefusal (..), swapCheck)
import Hetoimasia.Render.TwoD.Vulkan.Textures.Ledger
import Test.Hspec (Spec, describe, it, shouldBe)

h ∷ Word32 → Word32 → Api.TextureHandle
h = textureHandle

-- | Mark a handle's release, as the registry's logical release does.
marked ∷ Api.TextureHandle → Ledger → Ledger
marked handle ledger = fromMaybe (error "the handle could not be marked") (markHandleReleased handle ledger)

-- | What 'swapCheck' answers for a replacement of the same mark.
swapOf ∷ Ledger → Api.TextureHandle → Either TextureRefusal ()
swapOf ledger handle = swapCheck ledger handle True RefuseMarkChange

spec ∷ Spec
spec = describe "Ledger (the registry's release policy)" $ do
  it "reports nothing released for an index never registered, and refuses a swap there as unknown" $ do
    let ledger = registerHandle (h 3 1) True emptyLedger
    handleReleased ledger (h 9 1) `shouldBe` False
    handleReleased emptyLedger (h 3 1) `shouldBe` False
    swapOf ledger (h 9 1) `shouldBe` Left (TextureUnknown (h 9 1))

  it "reports a marked current generation released before and after the table release, until a later generation is registered" $ do
    let live = marked (h 3 1) (registerHandle (h 3 1) True emptyLedger)
        afterTable = forgetMark (h 3 1) live
    handleReleased live (h 3 1) `shouldBe` True
    handleReleased afterTable (h 3 1) `shouldBe` True
    -- the marker persists through the table release; the mark does not
    markOf live (h 3 1) `shouldBe` Just True
    markOf afterTable (h 3 1) `shouldBe` Nothing
    -- precedence: a registered marked handle is TextureReleased, one whose mark the table release removed is TextureUnknown
    swapOf live (h 3 1) `shouldBe` Left (TextureReleased (h 3 1))
    swapOf afterTable (h 3 1) `shouldBe` Left (TextureUnknown (h 3 1))

  it "does not report an unmarked current generation released, including after a direct table release" $ do
    let live = registerHandle (h 3 1) False emptyLedger
        afterTable = forgetMark (h 3 1) live
    handleReleased live (h 3 1) `shouldBe` False
    handleReleased afterTable (h 3 1) `shouldBe` False
    -- the handle was registered unmarked, so a replacement computing the same mark passes the check
    swapCheck live (h 3 1) False RefuseMarkChange `shouldBe` Right ()
    swapOf afterTable (h 3 1) `shouldBe` Left (TextureUnknown (h 3 1))

  it "reports a stale generation released whether its release was marked or not, and answers a swap there as unknown" $ do
    let afterMarked = registerHandle (h 3 2) True (forgetMark (h 3 1) (marked (h 3 1) (registerHandle (h 3 1) True emptyLedger)))
        afterUnmarked = registerHandle (h 3 2) True (forgetMark (h 3 1) (registerHandle (h 3 1) True emptyLedger))
    handleReleased afterMarked (h 3 1) `shouldBe` True
    handleReleased afterUnmarked (h 3 1) `shouldBe` True
    -- the new generation is live in both
    handleReleased afterMarked (h 3 2) `shouldBe` False
    handleReleased afterUnmarked (h 3 2) `shouldBe` False
    swapOf afterMarked (h 3 1) `shouldBe` Left (TextureUnknown (h 3 1))
    swapOf afterUnmarked (h 3 1) `shouldBe` Left (TextureUnknown (h 3 1))
    swapOf afterUnmarked (h 3 2) `shouldBe` Right ()

  it "gives the new generation its own marker: marking it does not touch the stale one, and registering it clears the previous marker" $ do
    let ledger = marked (h 3 2) (registerHandle (h 3 2) True (marked (h 3 1) (registerHandle (h 3 1) True emptyLedger)))
    handleReleased ledger (h 3 1) `shouldBe` True
    handleReleased ledger (h 3 2) `shouldBe` True
    -- a third generation: both earlier ones are stale, it is live
    let third = registerHandle (h 3 3) False ledger
    map (handleReleased third) [h 3 1, h 3 2, h 3 3] `shouldBe` [True, True, False]

  it "does not let a table release of a stale handle change the current one" $ do
    let ledger = forgetMark (h 3 1) (registerHandle (h 3 2) True (registerHandle (h 3 1) True emptyLedger))
    markOf ledger (h 3 2) `shouldBe` Just True
    handleReleased ledger (h 3 2) `shouldBe` False

  it "marks a release once, and not for a stale handle, an unknown one, or one whose table release ran" $ do
    let ledger = registerHandle (h 3 2) True (registerHandle (h 3 1) True emptyLedger)
    fmap (`handleReleased` h 3 2) (markHandleReleased (h 3 2) ledger) `shouldBe` Just True
    (markHandleReleased (h 3 1) ledger >>= const (Just ())) `shouldBe` Nothing
    (markHandleReleased (h 8 1) ledger >>= const (Just ())) `shouldBe` Nothing
    (markHandleReleased (h 3 2) (forgetMark (h 3 2) ledger) >>= const (Just ())) `shouldBe` Nothing
    (markHandleReleased (h 3 2) (marked (h 3 2) ledger) >>= const (Just ())) `shouldBe` Nothing

  it "orders generations by registration across the wraparound: after the largest generation comes 1, which is current while the largest is stale" $ do
    let wrapped = registerHandle (h 4 1) True (marked (h 4 maxBound) (registerHandle (h 4 maxBound) True emptyLedger))
    -- a numeric comparison would call the largest the newer
    handleReleased wrapped (h 4 maxBound) `shouldBe` True
    handleReleased wrapped (h 4 1) `shouldBe` False
    swapOf wrapped (h 4 maxBound) `shouldBe` Left (TextureUnknown (h 4 maxBound))
    swapOf wrapped (h 4 1) `shouldBe` Right ()

  it "treats a handle reissued with an identical index and generation as the new live handle until it is marked again" $ do
    let first = marked (h 4 1) (registerHandle (h 4 1) True emptyLedger)
        moved = registerHandle (h 4 2) True first
        reissued = registerHandle (h 4 1) False moved
    handleReleased first (h 4 1) `shouldBe` True
    handleReleased moved (h 4 1) `shouldBe` True
    -- the identical value is live again, and the generation before it is stale
    handleReleased reissued (h 4 1) `shouldBe` False
    handleReleased reissued (h 4 2) `shouldBe` True
    markOf reissued (h 4 1) `shouldBe` Just False
    handleReleased (marked (h 4 1) reissued) (h 4 1) `shouldBe` True

  it "keeps one entry per registered index, however many handles were registered and released at it" $ do
    let cycleAt ledger generation =
          let handle = h 5 generation
              registered = registerHandle handle (even generation) ledger
           in forgetMark handle (if odd generation then marked handle registered else registered)
        once = cycleAt emptyLedger 1
        many = foldl' cycleAt emptyLedger [1 .. 2000]
        spread = foldl' (\ledger index → registerHandle (h index 1) True ledger) many [6 .. 9]
    (retainedEntries emptyLedger, retainedEntries once, retainedEntries many, retainedEntries spread) `shouldBe` (0, 1, 1, 5)
