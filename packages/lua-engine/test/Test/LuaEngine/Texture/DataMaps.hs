{-# LANGUAGE OverloadedStrings #-}

-- | Data textures and shared versioned CPU coverage through the real texture pipeline (TRA-15): the image
-- kind a request asks for reaches the backend as an interpretation, the declared policies are checked
-- on the decoded bytes before anything is uploaded, and a retained coverage plane is charged to the one
-- injected account from the request's admission until the last CPU interest in its version lets go.
--
-- Nothing here uses the real graphics adapter: the backend is the suite's fake, which says so. It proves
-- ownership transitions, charges and the interpretation handed over, not texels on a device. Every
-- ordering is established by an observed event (an upload held, a note recorded, an account read), never
-- by a sleep.
--
-- The profile is 'small': at most 1,024 texels, so a coverage reservation is 128 plane bytes and the fixed
-- 128 bytes of metadata, 256 in all, until the decode shrinks it to the exact figure: 130 for a 3×3 or a 4×4
-- image (two plane bytes) and 129 for a 2×2 or a 2×1 image (one plane byte).
module Test.LuaEngine.Texture.DataMaps (spec) where

import Control.Concurrent.MVar (readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Concurrent (yield)
import Control.Monad (unless, void)
import qualified Data.ByteString as BS
import Data.IORef (readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import Hetoimasia.Asset.Image (TexelFormat (..))
import Hetoimasia.Asset.Image.DataMap (coverageBits, coverageRetainedBytes)
import Test.Hspec
import Test.LuaEngine.Texture.Contract (small)
import Test.LuaEngine.Texture.Png
import Test.LuaEngine.Texture.Support

-- The images -------------------------------------------------------------------------------------------------

-- | 3×3 with alphas 255 0 255 / 0 255 0 / 255 255 0 and colour (7,8,9): binary, so it has coverage.
binary3 ∷ BS.ByteString
binary3 = rgba8 3 3 (\x y → (7, 8, 9, if [255, 0, 255, 0, 255, 0, 255, 255, 0] !! (y * 3 + x) == (255 ∷ Word8) then 255 else 0))

-- | 2×2 whose last texel has alpha 254: not binary.
nonBinary2 ∷ BS.ByteString
nonBinary2 = rgba8 2 2 (\x y → (7, 8, 9, if (x, y) == (1, 1) then 254 else 255))

-- | 2×2 of translucent colour (200, 10x, 20y, 128): the colour policy premultiplies it, the data policy must not.
translucent2 ∷ BS.ByteString
translucent2 = rgba8 2 2 (\x y → (200, fromIntegral (10 * x), fromIntegral (20 * y), 128))

-- | 2×1 whose texels are fully transparent with colour (9,9,9): data keeps the RGB, colour zeroes it.
clear2 ∷ BS.ByteString
clear2 = rgba8 2 1 (\_ _ → (9, 9, 9, 0))

-- | 4×1: flat-up, the W ramp, an extreme and a transparent texel whose RGB would be invalid.
normalsOk ∷ BS.ByteString
normalsOk = rgba8 4 1 (\x _ → [(128, 128, 255, 255), (38, 128, 218, 255), (1, 255, 1, 255), (0, 0, 0, 0)] !! x)

-- | 2×1 with the zero vector in a nontransparent texel.
zeroVector ∷ BS.ByteString
zeroVector = rgba8 2 1 (\x _ → [(128, 128, 255, 255), (128, 128, 128, 255)] !! x)

-- | 2×1 with a zero channel in a nontransparent, fractionally transparent texel.
zeroChannel ∷ BS.ByteString
zeroChannel = rgba8 2 1 (\x _ → [(128, 128, 255, 255), (0, 128, 255, 128)] !! x)

-- | 4×4 binary alpha, to tell one version's plane from another's: only the diagonal is opaque.
diagonal4 ∷ BS.ByteString
diagonal4 = rgba8 4 4 (\x y → (1, 2, 3, if x == y then 255 else 0))

files ∷ Layout
files =
  Layout
    [ ("binary3.png", binary3)
    , ("binary3b.png", binary3)
    , ("nonbinary2.png", nonBinary2)
    , ("translucent2.png", translucent2)
    , ("clear2.png", clear2)
    , ("normals.png", normalsOk)
    , ("zerovector.png", zeroVector)
    , ("zerochannel.png", zeroChannel)
    , ("diagonal4.png", diagonal4)
    ]

-- Helpers ----------------------------------------------------------------------------------------------------

-- | What the injected account holds.
charged ∷ Session → IO Word64
charged = atomically . accountCharged . ssAccount

-- | Wait, in STM, until the account holds exactly this.
awaitCharged ∷ Session → Word64 → IO ()
awaitCharged session wanted = atomically $ do
  now ← accountCharged (ssAccount session)
  unless (now == wanted) retry

-- | Start a load asking for these policy words and wait for the host to accept it.
startWords ∷ Session → Vm → Text → Text → Text → [Text] → IO ()
startWords session vm name key path wordsGiven = do
  commandWith session vm name "start" key (Just (loadWith wordsGiven path))
  awaitNote session (name <> " start " <> key <> " started")

-- | Take the settled request's answer line.
takeLine ∷ Session → Vm → Text → Text → IO Text
takeLine session vm name key = do
  command session vm name "wait_take" key
  lineStarting session (name <> " wait_take " <> key <> " ")

-- | Load to a live lease: start, finish the held upload, take. The registration's identity, and the upload
-- the backend was handed.
loadLive ∷ Session → Vm → Text → Text → Text → [Text] → IO (Word64, Upload)
loadLive session vm name key path wordsGiven = do
  earlier ← uploadsSeen (ssFake session)
  startWords session vm name key path wordsGiven
  awaitUploads (ssFake session) (earlier + 1)
  accepted ← uploadN (ssFake session) earlier
  identity ← finishUpload (ssFake session) accepted
  line ← takeLine session vm name key
  Text.unpack line `shouldContain` "status=success"
  pure (identity, heldUpload accepted)

-- | Issue a command and wait for the one new line with this prefix it causes, however many of the same shape the
-- history already holds: a note is told apart by its position, never by its text alone.
awaitNewLine ∷ Session → Text → IO () → IO Text
awaitNewLine session prefix issue = do
  seen ← length . filter (Text.isPrefixOf prefix) <$> history session
  issue
  let wait = do
        found ← filter (Text.isPrefixOf prefix) <$> history session
        if length found > seen then pure (found !! seen) else yield >> wait
  wait

-- | Retain the instance's texture under the key, as a consumer would, and answer what the boundary said.
retainAs ∷ Session → Vm → Text → Text → Text → [Text] → IO Text
retainAs session vm name key label wordsGiven =
  awaitNewLine session (name <> " retain " <> key <> " ") $
    commandWith session vm name "retain" key (Just (loadWith wordsGiven label))

-- | Let go of a retained texture, as a consumer would.
unretain ∷ Session → Vm → Text → Text → Text → IO ()
unretain session vm name key label =
  void . awaitNewLine session (name <> " unretain " <> key <> " ") $
    commandWith session vm name "unretain" key (Just (Load label False))

-- | The texture a consumer retained under this label.
heldAs ∷ Vm → Text → IO RetainedTexture
heldAs vm label = do
  found ← Map.lookup label <$> readIORef (vmRetained vm)
  maybe (expectationFailure ("nothing is retained as " <> Text.unpack label) >> fail "none") pure found

-- | How many CPU interests the version of a retained texture holds now.
interestsOf ∷ RetainedTexture → IO Int
interestsOf = atomically . retainedInterests

cancelled ∷ Session → Vm → Text → Text → IO ()
cancelled session vm name key = do
  command session vm name "cancel" key
  awaitNote session (name <> " cancel " <> key <> " cancelled")

failureCode ∷ Text → Text → IO ()
failureCode code line = do
  Text.unpack line `shouldContain` "status=failure"
  Text.unpack line `shouldContain` Text.unpack ("code=" <> code <> ",")

-- | The Config of an example that holds the decode worker at the gate, so that what admission reserved is read before
-- the decode shrinks it.
gatedAtDecode ∷ Gate → Config
gatedAtDecode gate = (config small files) {cfgHooks = noHooks {hookDecoding = hold gate}, cfgRelease = releaseHeldGate gate}

spec ∷ Spec
spec = describe "data textures and shared versioned coverage" $ do
  kinds
  coverage
  profile
  account
  versions
  teardown

-- The image kind ---------------------------------------------------------------------------------------------

kinds ∷ Spec
kinds = describe "the image kind reaches the backend as the interpretation of the level" $ do
  it "hands a default request premultiplied sRGB colour and charges nothing to the account" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "colour" OnArrival
      admitDriver session vm "i"
      (_, upload) ← loadLive session vm "i" "a" "translucent2.png" []
      uploadFormat upload `shouldBe` TexelRgba8Srgb
      -- The first texel is (200, 0, 0, 128); premultiplied in linear light its red is lower, its alpha unchanged.
      let texel = BS.unpack (BS.take 4 (uploadTexels upload))
      texel !! 3 `shouldBe` 128
      texel !! 0 `shouldSatisfy` (< 200)
      charged session `shouldReturn` 0

  it "hands a data request the linear level exactly as the file states it: translucent colour unpremultiplied" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "data" OnArrival
      admitDriver session vm "i"
      (_, upload) ← loadLive session vm "i" "a" "translucent2.png" ["data"]
      uploadFormat upload `shouldBe` TexelRgba8Linear
      (uploadWidth upload, uploadHeight upload) `shouldBe` (2, 2)
      -- Texels (x, y) = (200, 10x, 20y, 128), row by row, top row first.
      BS.unpack (uploadTexels upload) `shouldBe` [200, 0, 0, 128, 200, 10, 0, 128, 200, 0, 20, 128, 200, 10, 20, 128]
      -- No coverage was asked for, so nothing was reserved from the account.
      charged session `shouldReturn` 0

  it "keeps the RGB of a fully transparent texel for data, and zeroes it for colour" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "transparent" OnArrival
      admitDriver session vm "i"
      (_, asData) ← loadLive session vm "i" "d" "clear2.png" ["data"]
      BS.unpack (uploadTexels asData) `shouldBe` [9, 9, 9, 0, 9, 9, 9, 0]
      (_, asColour) ← loadLive session vm "i" "c" "clear2.png" []
      BS.unpack (uploadTexels asColour) `shouldBe` [0, 0, 0, 0, 0, 0, 0, 0]

  it "refuses without a backend call a request the decoder cannot read as data either: an unsupported format keeps its code" $
    withSession (config small (Layout [("text.png", "not a png at all, whatever the name says")])) $ \session _ runtime → do
      vm ← startVm session runtime "unsupported" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "text.png" ["data", "coverage"]
      line ← takeLine session vm "i" "a"
      failureCode "unsupported_format" line
      uploadsSeen (ssFake session) `shouldReturn` 0
      awaitCharged session 0

-- Binary coverage --------------------------------------------------------------------------------------------

coverage ∷ Spec
coverage = describe "binary coverage" $ do
  it "reserves the worst case at the one admission, shrinks to the exact plane and metadata once the dimensions are validated, and returns it with the last interest" $ do
    gate ← newGate
    withSession (gatedAtDecode gate) $ \session _ runtime → do
      vm ← startVm session runtime "reserve" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      readMVar (arrived gate)
      -- The decode worker is held before it has read a header: the admission's reservation, 128 plane bytes for the
      -- 1,024 texels the profile allows and 128 bytes of metadata.
      charged session `shouldReturn` 256
      _ ← tryPutMVar (proceed gate) ()
      awaitUploads (ssFake session) 1
      -- The dimensions were validated: 3×3 = 9 texels = 2 plane bytes, and the metadata.
      charged session `shouldReturn` fromIntegral (coverageRetainedBytes 3 3)
      charged session `shouldReturn` 130
      held' ← uploadN (ssFake session) 0
      _ ← finishUpload (ssFake session) held'
      line ← takeLine session vm "i" "a"
      Text.unpack line `shouldContain` "status=success"
      -- The lease holds the version; the plane is still charged, once.
      charged session `shouldReturn` 130
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      -- The lease's CPU interest ended with its release: no GPU retirement is needed for the plane to go.
      charged session `shouldReturn` 0
      -- The texture itself is still charged until the backend proves it retired.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 36)

  it "refuses a nonbinary image as invalid_image before any upload, naming the policy, and returns every charge" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "nonbinary" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "nonbinary2.png" ["coverage"]
      line ← takeLine session vm "i" "a"
      failureCode "invalid_image" line
      Text.unpack line `shouldContain` "coverage=binary"
      Text.unpack line `shouldContain` "alpha 254"
      uploadsSeen (ssFake session) `shouldReturn` 0
      awaitOwner vm "i" (== OwnerReading 0 0)
      lanesCharged session `shouldReturn` [0, 0]
      awaitCharged session 0

  it "loads the same translucent image without coverage: no binary authority is invented" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "plain" OnArrival
      admitDriver session vm "i"
      _ ← loadLive session vm "i" "a" "nonbinary2.png" []
      _ ← loadLive session vm "i" "d" "nonbinary2.png" ["data"]
      charged session `shouldReturn` 0
      retainAs session vm "i" "a" "plain" ["coverage"] >>= (`shouldSatisfy` Text.isInfixOf "refused: the texture has no binary coverage")

  it "keeps the plane's bits, the version's identity and the texture together through the protected retention boundary" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "retain" OnArrival
      admitDriver session vm "i"
      (identity, _) ← loadLive session vm "i" "a" "binary3.png" ["coverage"]
      retainAs session vm "i" "a" "r1" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      first ← heldAs vm "r1"
      viewIdentity (retainedView first) `shouldBe` identity
      (retainedWidth first, retainedHeight first) `shouldBe` (3, 3)
      retainedKind first `shouldBe` ColourKind
      fmap coverageBits (retainedCoverage first) `shouldBe` Just (BS.pack [0xD5, 0x00])
      -- The lease's interest, and this one.
      interestsOf first `shouldReturn` 2
      -- A second consumer shares the very plane: no copy, no second charge.
      retainAs session vm "i" "a" "r2" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      second ← heldAs vm "r2"
      retainedVersion second `shouldBe` retainedVersion first
      interestsOf second `shouldReturn` 3
      charged session `shouldReturn` 130
      unretain session vm "i" "a" "r1"
      unretain session vm "i" "a" "r2"
      interestsOf first `shouldReturn` 1
      charged session `shouldReturn` 130

-- The checked profile ----------------------------------------------------------------------------------------

profile ∷ Spec
profile = describe "unit-normal-rgb-v1" $ do
  it "accepts flat-up, the W ramp, a legal extreme and a transparent invalid texel, uploads the bytes unchanged and records the checked fact" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "normals" OnArrival
      admitDriver session vm "i"
      (_, upload) ← loadLive session vm "i" "a" "normals.png" ["data", "normal"]
      uploadFormat upload `shouldBe` TexelRgba8Linear
      BS.unpack (uploadTexels upload) `shouldBe` [128, 128, 255, 255, 38, 128, 218, 255, 1, 255, 1, 255, 0, 0, 0, 0]
      retainAs session vm "i" "a" "n1" ["data", "normal"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      fact ← heldAs vm "n1"
      retainedNormal fact `shouldBe` Just UnitNormalRgbV1
      retainedKind fact `shouldBe` DataKind
      -- Asking for the profile does not assert binary alpha.
      fmap coverageBits (retainedCoverage fact) `shouldBe` Nothing
      charged session `shouldReturn` 0

  it "refuses the zero vector and a zero channel as invalid_image before any upload, and a transparent texel needs neither" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "badnormals" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "zerovector.png" ["data", "normal"]
      zero ← takeLine session vm "i" "a"
      failureCode "invalid_image" zero
      Text.unpack zero `shouldContain` "normal_encoding=unit-normal-rgb-v1"
      Text.unpack zero `shouldContain` "zero vector"
      startWords session vm "i" "b" "zerochannel.png" ["data", "normal"]
      channel ← takeLine session vm "i" "b"
      failureCode "invalid_image" channel
      Text.unpack channel `shouldContain` "(0, 128, 255)"
      uploadsSeen (ssFake session) `shouldReturn` 0
      awaitOwner vm "i" (== OwnerReading 0 0)

  it "does not gain the validated fact for an otherwise identical raw-data request, which loads the same bytes" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "rawdata" OnArrival
      admitDriver session vm "i"
      (_, upload) ← loadLive session vm "i" "a" "zerovector.png" ["data"]
      uploadFormat upload `shouldBe` TexelRgba8Linear
      BS.unpack (BS.drop 4 (uploadTexels upload)) `shouldBe` [128, 128, 128, 255]
      retainAs session vm "i" "a" "n" ["normal"] >>= (`shouldSatisfy` Text.isInfixOf "refused: the texture's texels were not validated as normal_encoding=unit-normal-rgb-v1")
      retainAs session vm "i" "a" "k" ["colour"] >>= (`shouldSatisfy` Text.isInfixOf "refused: the texture is not a colour texture")

-- The shared account ------------------------------------------------------------------------------------------

account ∷ Spec
account = describe "the injected account" $ do
  it "admits a request that fits exactly and refuses, as busy with nothing reserved, one a byte short" $ do
    -- 256 bytes is the worst case of this profile.
    withSession ((config small files) {cfgAccountBytes = 256}) $ \session _ runtime → do
      vm ← startVm session runtime "exact" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      awaitUploads (ssFake session) 1
    withSession ((config small files) {cfgAccountBytes = 255}) $ \session _ runtime → do
      vm ← startVm session runtime "short" OnArrival
      admitDriver session vm "i"
      line ← awaitNewLine session "i start a " (commandWith session vm "i" "start" "a" (Just (loadWith ["coverage"] "binary3.png")))
      Text.unpack line `shouldContain` "busy:"
      Text.unpack line `shouldContain` "coverage bytes"
      -- Nothing was reserved, no record is held, no file was opened, no handle was made.
      charged session `shouldReturn` 0
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 0 0)
      readingJobs <$> pipelineNow session `shouldReturn` 0
      startedPaths (ssProbe session) `shouldReturn` []

  it "counts a simultaneous charge against the same allowance: another consumer's byte makes the request busy until it is returned" $
    withSession ((config small files) {cfgAccountBytes = 256}) $ \session _ runtime → do
      vm ← startVm session runtime "other" OnArrival
      admitDriver session vm "i"
      atomically (accountReserve (ssAccount session) 1) `shouldReturn` True
      line ← awaitNewLine session "i start a " (commandWith session vm "i" "start" "a" (Just (loadWith ["coverage"] "binary3.png")))
      Text.unpack line `shouldContain` "busy:"
      charged session `shouldReturn` 1
      atomically (accountRelease (ssAccount session) 1)
      startWords session vm "i" "b" "binary3.png" ["coverage"]
      awaitUploads (ssFake session) 1

  it "never converts accepted work to busy: a request admitted at the exact fit finishes however full the account is afterwards" $
    withSession ((config small files) {cfgAccountBytes = 260}) $ \session _ runtime → do
      vm ← startVm session runtime "afterwards" OnArrival
      admitDriver session vm "i"
      (_, _) ← loadLive session vm "i" "a" "binary3.png" ["coverage"]
      -- 130 held; the account has 130 left, so a second 256-byte admission is busy, and the first is untouched.
      line ← awaitNewLine session "i start b " (commandWith session vm "i" "start" "b" (Just (loadWith ["coverage"] "binary3b.png")))
      Text.unpack line `shouldContain` "busy:"
      charged session `shouldReturn` 130

-- Versions, overlap and independence ---------------------------------------------------------------------------

versions ∷ Spec
versions = describe "loaded versions" $ do
  it "charges two loads of one path as two versions, keeps each pair with its own texture, and returns each charge with its own last interest" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "overlap" OnArrival
      admitDriver session vm "i"
      (old, _) ← loadLive session vm "i" "old" "binary3.png" ["coverage"]
      retainAs session vm "i" "old" "o" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      (new, _) ← loadLive session vm "i" "new" "diagonal4.png" ["coverage"]
      retainAs session vm "i" "new" "n" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      oldPair ← heldAs vm "o"
      newPair ← heldAs vm "n"
      retainedVersion oldPair `shouldNotBe` retainedVersion newPair
      viewIdentity (retainedView oldPair) `shouldBe` old
      viewIdentity (retainedView newPair) `shouldBe` new
      -- Old 3×3 (130) and new 4×4 (130) overlap: two charges.
      charged session `shouldReturn` 260
      fmap coverageBits (retainedCoverage oldPair) `shouldBe` Just (BS.pack [0xD5, 0x00])
      -- 4×4 diagonal: bits 0, 5, 10, 15 = 0b00100001 (byte 0 = 0x21), 0b10000100 (byte 1 = 0x84).
      fmap coverageBits (retainedCoverage newPair) `shouldBe` Just (BS.pack [0x21, 0x84])
      -- Releasing the old lease keeps the old version alive for its consumer, and the new one is untouched.
      command session vm "i" "release" "old"
      awaitNote session "i release old retiring"
      charged session `shouldReturn` 260
      unretain session vm "i" "old" "o"
      charged session `shouldReturn` 130
      fmap coverageBits (retainedCoverage newPair) `shouldBe` Just (BS.pack [0x21, 0x84])

  it "leaves a previous retained pair usable when a later acquisition fails" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "failed" OnArrival
      admitDriver session vm "i"
      _ ← loadLive session vm "i" "good" "binary3.png" ["coverage"]
      retainAs session vm "i" "good" "kept" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      startWords session vm "i" "bad" "nonbinary2.png" ["coverage"]
      takeLine session vm "i" "bad" >>= failureCode "invalid_image"
      kept ← heldAs vm "kept"
      fmap coverageBits (retainedCoverage kept) `shouldBe` Just (BS.pack [0xD5, 0x00])
      charged session `shouldReturn` 130

  it "keeps the CPU plane for a consumer after the Lua release and after the registration retired, and gives it back only with the last interest" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "independent" OnArrival
      admitDriver session vm "i"
      (identity, _) ← loadLive session vm "i" "a" "binary3.png" ["coverage"]
      retainAs session vm "i" "a" "r" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      -- A Lua release prevents new authority...
      retainAs session vm "i" "a" "late" ["coverage"] >>= (`shouldSatisfy` Text.isInfixOf "refused:")
      -- ...and leaves the interest already taken. The texture is retiring on the backend and the plane is charged.
      charged session `shouldReturn` 130
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 36)
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)
      -- The registration's retirement did not stand in for the CPU interest.
      charged session `shouldReturn` 130
      kept ← heldAs vm "r"
      fmap coverageBits (retainedCoverage kept) `shouldBe` Just (BS.pack [0xD5, 0x00])
      unretain session vm "i" "a" "r"
      charged session `shouldReturn` 0
      -- A repeated release of a consumer's interest returns nothing twice.
      releaseRetained kept
      releaseRetained kept
      charged session `shouldReturn` 0

  it "lets go of the plane at the lease's release although the GPU retirement is withheld" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "withheld" OnArrival
      admitDriver session vm "i"
      (identity, _) ← loadLive session vm "i" "a" "binary3.png" ["coverage"]
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      charged session `shouldReturn` 0
      -- The CPU scope's exit is not retirement evidence: the slot and the nominal bytes are still held.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 36)
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)

  it "does not pair an old plane with a new texture when a registration identity is reused for a different image" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "reuse" OnArrival
      admitDriver session vm "i"
      (first, _) ← loadLive session vm "i" "a" "binary3.png" ["coverage"]
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      retireTexture (ssFake session) first
      awaitOwner vm "i" (== OwnerReading 0 0)
      (second, _) ← loadLive session vm "i" "b" "diagonal4.png" ["coverage"]
      second `shouldNotBe` first
      retainAs session vm "i" "b" "r" ["coverage"] >>= (`shouldSatisfy` Text.isSuffixOf "retained")
      pair ← heldAs vm "r"
      viewIdentity (retainedView pair) `shouldBe` second
      (retainedWidth pair, retainedHeight pair) `shouldBe` (4, 4)
      fmap coverageBits (retainedCoverage pair) `shouldBe` Just (BS.pack [0x21, 0x84])

-- Ends of the work --------------------------------------------------------------------------------------------

teardown ∷ Spec
teardown = describe "an ending request returns its reservation exactly once" $ do
  it "when it is cancelled while the decode worker holds it, before any header was read" $ do
    gate ← newGate
    withSession (gatedAtDecode gate) $ \session _ runtime → do
      vm ← startVm session runtime "cancel-decode" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      readMVar (arrived gate)
      charged session `shouldReturn` 256
      cancelled session vm "i" "a"
      _ ← tryPutMVar (proceed gate) ()
      awaitPipeline session (\reading → readingSettled reading == 1)
      command session vm "i" "take" "a"
      awaitNote session "i take a {status=cancelled}"
      uploadsSeen (ssFake session) `shouldReturn` 0
      charged session `shouldReturn` 0

  it "when it is cancelled with its plane built and the upload not yet finished, and the late callback does not return it twice" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "cancel-upload" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      awaitUploads (ssFake session) 1
      held' ← uploadN (ssFake session) 0
      charged session `shouldReturn` 130
      cancelled session vm "i" "a"
      awaitUploadCancelled held'
      _ ← withdrawUpload (ssFake session) held'
      command session vm "i" "take" "a"
      awaitNote session "i take a {status=cancelled}"
      awaitOwner vm "i" (== OwnerReading 0 0)
      awaitCharged session 0
      -- A callback that arrives after the end is late: it takes nothing and returns nothing.
      _ ← finishUpload (ssFake session) held'
      charged session `shouldReturn` 0

  it "when the backend refuses the hand-over (a provider defect, injected), before the failure ends the example" $ do
    _ ← fatalSession (config small files) $ \session control runtime → do
      vm ← startVm session runtime "raising" OnArrival
      admitDriver session vm "i"
      setRaiseOnUpload (ssFake session) True
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      _ ← awaitEnd control vm
      awaitCharged session 0
    pure ()

  it "when the instance ends with the upload accepted and its texture not yet delivered" $
    withSession (config small files) $ \session _ runtime → do
      vm ← startVm session runtime "exits" OnArrival
      admitDriver session vm "i"
      startWords session vm "i" "a" "binary3.png" ["coverage"]
      awaitUploads (ssFake session) 1
      held' ← uploadN (ssFake session) 0
      charged session `shouldReturn` 130
      stopInstance session vm "i"
      awaitUploadCancelled held'
      _ ← withdrawUpload (ssFake session) held'
      awaitOwner vm "i" (== OwnerReading 0 0)
      awaitCharged session 0
