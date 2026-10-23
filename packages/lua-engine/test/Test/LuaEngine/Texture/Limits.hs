{-# LANGUAGE OverloadedStrings #-}

-- | The admission banks, each independently full: busy that does no file, decode or backend work and
-- leaves nothing reserved, every bank's value at its edge and one past, the conservative reservation
-- made before anything is read, and concurrent admissions that cannot take capacity from one another.
module Test.LuaEngine.Texture.Limits (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (forM_, when)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..))
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), fixedM1Profile)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..), RequestEndpoint (..))
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (layout, loadAs, small, started)
import Test.LuaEngine.Texture.Png
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "limits" $ do
  banks
  refusals
  concurrency
  fixedValues

keyOf ∷ Int → Text
keyOf = Text.pack . ("k" <>) . show

-- | What a refused load answers when a bank is named.
busy ∷ Text → Text → Text
busy name bank = name <> " start z busy:busy:request capacity is not available: " <> bank

-- | Gate every read of this path, so the accepted loads stay accepted without finishing.
holdReads ∷ Session → IO ()
holdReads session = closeGate (ssProbe session) "a.png"

-- | Start this many held loads of @a.png@ for the instance.
fill ∷ Session → Vm → Text → Int → IO ()
fill session vm name n = forM_ [0 .. n - 1] $ \i → started session vm name (keyOf i) "a.png"

-- | Refuse this load, naming the bank, and show nothing was done and nothing is left reserved: the
-- pipeline, the instance's banks, the session's, the pool's and the reader read exactly as before,
-- and the refusal is no failure of the instance.
refusing ∷ Session → Vm → Text → Text → IO ()
refusing session vm name bank = do
  pipelineBefore ← pipelineNow session
  owner ← ownerNow vm name
  sessionBefore ← sessionNow session
  poolBefore ← poolReading session
  readsBefore ← readsStarted (ssProbe session)
  uploadsBefore ← uploadsSeen (ssFake session)
  line ← loadAs session vm name "z" "a.png"
  line `shouldBe` busy name bank
  pipelineNow session >>= (`shouldBe` pipelineBefore)
  ownerNow vm name >>= (`shouldBe` owner)
  sessionNow session >>= (`shouldBe` sessionBefore)
  poolAfter ← poolReading session
  (statusReserved poolAfter, statusQueued poolAfter, statusLive poolAfter) `shouldBe` (statusReserved poolBefore, statusQueued poolBefore, statusLive poolBefore)
  readsStarted (ssProbe session) `shouldReturn` readsBefore
  uploadsSeen (ssFake session) `shouldReturn` uploadsBefore
  d ← vmDiagnostics vm
  (rdLatched d, rdBusy d >= 1) `shouldBe` (0, True)

banks ∷ Spec
banks = describe "each bank, independently full" $ do
  it "refuses a texture slot beyond the instance's two, naming the bank, with nothing reserved" $
    withSession (config (smaller [(TextureLeasesPerUiInstance, 2), (PngPixels, 1024), (PngAxisMaximum, 32)] bytes) layout) $ \session _ runtime → do
      vm ← startVm session runtime "slots" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 2
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 2 8192)
      refusing session vm "i" "the provider has no room in texture slots"

  it "refuses nominal bytes beyond the instance's bank, and gives back the slot the refused attempt had taken" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "bytes" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 4
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
      -- The slot is taken before the bytes within one admission; the refusal leaves it as it was.
      refusing session vm "i" "the provider has no room in texture bytes"

  it "refuses nominal bytes beyond the session's bank for an instance whose own bank is empty" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "session" OnArrival
      mapM_ (admitDriver session vm) ["i", "j", "k"]
      holdReads session
      fill session vm "i" 4
      fill session vm "j" 4
      sessionNow session `shouldReturn` 32768
      ownerNow vm "k" >>= (`shouldBe` OwnerReading 0 0)
      refusing session vm "k" "the provider has no room in texture bytes"

  it "refuses a request beyond the pipeline's accepted-work records" $
    withSession ((config small layout) {cfgJobs = 2}) $ \session _ runtime → do
      vm ← startVm session runtime "jobs" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 2
      refusing session vm "i" "the provider has no room in texture jobs"

  it "refuses a request beyond the shared pool's queue slots, with no read started for it" $
    withSession ((config small layout) {cfgPool = (2, 2)}) $ \session _ runtime → do
      vm ← startVm session runtime "io" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 2
      refusing session vm "i" "the provider has no room in io queue"

  it "leaves the host's request banks to the host: the instance's second place is its last" $
    withSession (config (smaller [(RequestsPerInstance, 2), (PngPixels, 1024), (PngAxisMaximum, 32)] bytes) layout) $ \session _ runtime → do
      vm ← startVm session runtime "requests" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 2
      refusing session vm "i" "the instance holds all 2 of its request places"

  it "refuses a request beyond the instance's lease capacity, whose result the lease must hold" $
    withSession ((config small layout) {cfgLeases = 2}) $ \session _ runtime → do
      vm ← startVm session runtime "leases" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 2
      refusing session vm "i" "the instance's lease capacity is charged: 2 of 2"

  it "admits again once a refused bank has room: a cancelled request's reservation returns when its read has retired, not when its result is taken" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "again" OnArrival
      admitDriver session vm "i"
      holdReads session
      closeGate (ssProbe session) "b.png"
      started session vm "i" "k0" "b.png"
      forM_ [1 .. 3] $ \i → started session vm "i" (keyOf i) "a.png"
      loadAs session vm "i" "z" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes")
      command session vm "i" "cancel" "k0"
      awaitNote session "i cancel k0 cancelled"
      command session vm "i" "take" "k0"
      awaitNote session "i take k0 {status=cancelled}"
      -- Consuming the cancellation is not the retirement of the read a worker has started.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
      loadAs session vm "i" "z" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes")
      openGate (ssProbe session) "b.png"
      awaitOwner vm "i" (== OwnerReading 3 12288)
      started session vm "i" "y" "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
  where
    bytes =
      [ (PngEncodedBytes, 65536)
      , (PngInflatedScanlineBytes, 65536)
      , (PngPipelineWorkspaceBytes, 1048576)
      , (TextureBytesPerUiInstance, 16384)
      , (TextureBytesPerSession, 32768)
      ]

concurrency ∷ Spec
concurrency = describe "concurrent admissions" $
  it "never turn one instance's refusals into another's busy: refused attempts take nothing from the session, even while they race" $
    withSession (config small layout) $ \session _ runtime → do
      -- The session holds exactly two instances' worth, and the first is full: every attempt it makes is
      -- refused after the admission has looked at its own bank, while the second asks for its four.
      vm1 ← startVm session runtime "racer-one" OnArrival
      vm2 ← startVm session runtime "racer-two" OnArrival
      admitDriver session vm1 "x"
      admitDriver session vm2 "y"
      holdReads session
      fill session vm1 "x" 4
      forM_ [1 .. 24 ∷ Int] $ \round' → do
        commandWith session vm1 "x" "start" "n" (Just (load "a.png"))
        when (round' <= 4) $ commandWith session vm2 "y" "start" (keyOf (round' - 1)) (Just (load "a.png"))
        awaitHistory session (\seen → length [() | line ← seen, "x start n busy" `Text.isPrefixOf` line] >= round')
      awaitNote session "y start k3 started"
      ownerNow vm2 "y" >>= (`shouldBe` OwnerReading 4 16384)
      awaitVmDiagnostic vm1 (\d → rdBusy d >= 24)
      history session >>= \seen → [line | line ← seen, "y start " `Text.isPrefixOf` line, "busy" `Text.isInfixOf` line] `shouldBe` []
      ownerNow vm1 "x" >>= (`shouldBe` OwnerReading 4 16384)
      sessionNow session `shouldReturn` 32768

fixedValues ∷ Spec
fixedValues = describe "the fixed profile's values" $ do
  it "builds the pipeline from the fixed numbers: two lanes, two read workers, one decode worker, 128 MiB of workspace and the PNG limits" $
    withSession (config fixedM1Profile (Layout [("a.png", opaque 2 2)])) $ \session _ _ → do
      let numbers = pipelineSpec (ssPipeline session)
      ( specLanes numbers
        , specIoWorkers numbers
        , specDecodeWorkers numbers
        , specWorkspace numbers
        , specSourceLimit numbers
        , specInitialNominal numbers
        , specInstanceSlots numbers
        , specInstanceBytes numbers
        , specSessionBytes numbers
        )
        `shouldBe` (2, 2, 1, 128 * 1048576, 32 * 1048576, 16 * 1048576, 16, 128 * 1048576, 256 * 1048576)
      awaitPipeline session ((== 1) . readingDecodeWorkers)
      length . readingLanes <$> pipelineNow session `shouldReturn` 2
      statusWorkers <$> poolReading session `shouldReturn` 2

  it "reserves the maximum 16 MiB before anything is read, eight of them per instance and sixteen per session, and refuses the next" $
    withSession (config fixedM1Profile (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      vm ← startVm session runtime "fixed" OnArrival
      mapM_ (admitDriver session vm) ["i", "j", "k"]
      holdReads session
      started session vm "i" "k0" "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 (16 * 1048576))
      sessionNow session `shouldReturn` 16 * 1048576
      forM_ [1 .. 7] $ \n → started session vm "i" (keyOf n) "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 8 (128 * 1048576))
      refusing session vm "i" "the provider has no room in texture bytes"
      forM_ [0 .. 7] $ \n → started session vm "j" (keyOf n) "a.png"
      sessionNow session `shouldReturn` 256 * 1048576
      refusing session vm "k" "the provider has no room in texture bytes"

  it "lets a small image be refused busy by the conservative reservation, and admits it once an earlier decode has shrunk its charge" $
    withSession (config fixedM1Profile (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      vm ← startVm session runtime "shrink" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "a.png"
      forM_ [0 .. 7] $ \n → started session vm "i" (keyOf n) "a.png"
      loadAs session vm "i" "z" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes")
      -- The first two reads decode a two by two image and shrink their 16 MiB to 16 bytes each.
      openGate (ssProbe session) "a.png"
      awaitOwner vm "i" (\reading → ownerNominalHeld reading < 128 * 1048576)
      started session vm "i" "y" "a.png"

-- | A request the service refuses is an ordinary Lua error before any admission, never busy, and
-- leaves nothing reserved and nothing done.
refusals ∷ Spec
refusals = describe "permanent refusals" $ do
  it "refuse a malformed address, a closed owner and a request from a hook that is ending as ordinary errors before any admission: never busy, nothing reserved, no work" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "refusals" OnArrival
      admitDriver session vm "i"
      admitModule session vm "ender" "e"
      pipelineBefore ← pipelineNow session
      commandWith session vm "i" "pstart" "a" (Just (load "a//b.png"))
      line ← lineStarting session "i pstart a "
      line `shouldSatisfy` Text.isPrefixOf "i pstart a error "
      line `shouldSatisfy` Text.isInfixOf "address refused"
      owner ← ownerOf vm "i"
      closeTextureOwner owner
      commandWith session vm "i" "pstart" "b" (Just (load "a.png"))
      closed ← lineStarting session "i pstart b "
      closed `shouldSatisfy` Text.isInfixOf "the texture owner has ended"
      -- An instance asking from its shutdown hook is refused by the host's own phase check.
      stopInstance session vm "e"
      -- The host's phase check refuses it, and says why.
      shutdownLine ← lineStarting session "shutdown load false "
      shutdownLine `shouldBe` "shutdown load false tex.load: request refused: the owner is no longer taking requests"
      pipelineNow session >>= (`shouldBe` pipelineBefore)
      readsStarted (ssProbe session) `shouldReturn` 0
      uploadsSeen (ssFake session) `shouldReturn` 0
      d ← vmDiagnostics vm
      (rdBusy d, rdLatched d) `shouldBe` (0, 0)

  it "take back every reservation when the provider raises as it is handed the request: the credits return unused and the pipeline keeps no job" $ do
    ExceptionWithContext _ failure ← fatalSession (config small layout) $ \session control runtime → do
      let raising endpoint = endpoint {endpointSubmit = \_ → note session "handing over" >> throwIO (userError "the provider refused the hand-over")}
      vm ← startVmWith session raising runtime "raising" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "k" (Just (load "a.png"))
      awaitNote session "handing over"
      -- The admission held its banks when the provider was handed the request, and is taken back whole.
      awaitVmDiagnostic vm (\d → rdHeld d == 0)
      -- Nothing stays reserved anywhere: the admission was taken back whole.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
      pipelineNow session >>= \reading → (readingReserved reading, readingJobs reading, readingPrepared reading) `shouldBe` (0, 0, 0)
      statusReserved <$> poolReading session `shouldReturn` 0
      readsStarted (ssProbe session) `shouldReturn` 0
      _ ← awaitEnd control vm
      pure ()
    show failure `shouldSatisfy` Text.isInfixOf "the provider refused the hand-over" . Text.pack
