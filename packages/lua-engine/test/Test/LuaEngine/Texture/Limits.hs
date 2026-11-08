{-# LANGUAGE OverloadedStrings #-}

-- | The admission banks, each independently full: busy that does no file, decode or backend work and
-- leaves nothing reserved, every bank's value at its edge and one past, the conservative reservation
-- made before anything is read, and concurrent admissions that cannot take capacity from one another.
module Test.LuaEngine.Texture.Limits (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (forM_, void, when)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..))
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), Profile, fixedM1Profile)
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

-- | The fixed profile with its texture banks cut to the 128 MiB and 256 MiB the first milestone had, so that the byte
-- banks, not the request places, are what fills.
limited ∷ Profile
limited = smaller [] [(TextureBytesPerUiInstance, 128 * 1048576), (TextureBytesPerSession, 256 * 1048576)]

keyOf ∷ Int → Text
keyOf = Text.pack . ("k" <>) . show

-- | The same answer for a load started under another key.
withKey ∷ Text → Text → Text
withKey line key = Text.replace " start z " (" start " <> key <> " ") line

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
  -- Reads accepted earlier are inside the reader, so no snapshot can see one move from queued to active.
  awaitReadsEntered session
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
  it "admits a reservation that exactly fits the instance's bank and refuses, naming bytes, when one byte is missing: nothing reserved by the refused attempt" $ do
    -- 16,384 bytes hold exactly four reservations of 4,096; one byte less room holds three.
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "exact" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 4
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
      refusing session vm "i" "the provider has no room in texture bytes"
    withSession (config (smaller [(PngPixels, 1024), (PngAxisMaximum, 32)] (banksOf 16383 32768)) layout) $ \session _ runtime → do
      vm ← startVm session runtime "short" OnArrival
      admitDriver session vm "i"
      holdReads session
      fill session vm "i" 3
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 3 12288)
      refusing session vm "i" "the provider has no room in texture bytes"

  it "refuses with one byte less room in the session's bank than two instances' reservations need, naming bytes, and admits when the room is exact" $ do
    -- Session room 32,768 holds exactly eight reservations (four for each instance); 32,767 holds seven.
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "session-exact" OnArrival
      mapM_ (admitDriver session vm) ["i", "j"]
      holdReads session
      fill session vm "i" 4
      fill session vm "j" 4
      sessionNow session `shouldReturn` 32768
    withSession (config (smaller [(PngPixels, 1024), (PngAxisMaximum, 32)] (banksOf 16384 32767)) layout) $ \session _ runtime → do
      vm ← startVm session runtime "session-short" OnArrival
      mapM_ (admitDriver session vm) ["i", "j"]
      holdReads session
      fill session vm "i" 4
      fill session vm "j" 3
      sessionNow session `shouldReturn` 28672
      ownerNow vm "j" >>= (`shouldBe` OwnerReading 3 12288)
      refusing session vm "j" "the provider has no room in texture bytes"

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
      loadAs session vm "i" "z1" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes" `withKey` "z1")
      -- k0's read is inside the reader (a cancel before that could withdraw it unissued and return its charge).
      awaitReadsEntered session
      command session vm "i" "cancel" "k0"
      awaitNote session "i cancel k0 cancelled"
      command session vm "i" "take" "k0"
      awaitNote session "i take k0 {status=cancelled}"
      -- Consuming the cancellation is not the retirement of the read a worker has started.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
      -- A fresh key: the helper answers the oldest line of a key, so a reused key would read the first answer.
      loadAs session vm "i" "z2" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes" `withKey` "z2")
      openGate (ssProbe session) "b.png"
      awaitOwner vm "i" (== OwnerReading 3 12288)
      started session vm "i" "y" "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 4 16384)
  where
    bytes = banksOf 16384 32768

-- | Small PNG limits and these texture banks: the instance's and the session's.
banksOf ∷ Word64 → Word64 → [(ByteLimit, Word64)]
banksOf instanceBytes sessionBytes =
  [ (PngEncodedBytes, 65536)
  , (PngInflatedScanlineBytes, 65536)
  , (PngPipelineWorkspaceBytes, 1048576)
  , (TextureBytesPerUiInstance, instanceBytes)
  , (TextureBytesPerSession, sessionBytes)
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
        , specInstanceBytes numbers
        , specSessionBytes numbers
        )
        `shouldBe` (2, 2, 1, 128 * 1048576, 32 * 1048576, 16 * 1048576, 512 * 1048576, 1024 * 1048576)
      awaitPipeline session ((== 1) . readingDecodeWorkers)
      length . readingLanes <$> pipelineNow session `shouldReturn` 2
      statusWorkers <$> poolReading session `shouldReturn` 2

  it "reserves the maximum 16 MiB before anything is read, and the request bounds answer before the bytes: sixteen reservations hold half of the instance's 512 MiB, and the seventeenth is refused on the request places" $
    withSession (config fixedM1Profile (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      vm ← startVm session runtime "fixed" OnArrival
      admitDriver session vm "i"
      holdReads session
      started session vm "i" "k0" "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 (16 * 1048576))
      sessionNow session `shouldReturn` 16 * 1048576
      forM_ [1 .. 15] $ \n → started session vm "i" (keyOf n) "a.png"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 16 (256 * 1048576))
      -- The bytes could take more (512 MiB); the host's request places do not.
      refusing session vm "i" "the instance holds all 16 of its request places"

  it "reserves the maximum 16 MiB per texture against a 128 MiB instance bank and a 256 MiB session bank (a profile smaller than the fixed one): eight per instance, sixteen per session, and refuses the next on bytes" $
    withSession (config limited (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      vm ← startVm session runtime "limited" OnArrival
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

  it "lets a small image be refused busy by the conservative reservation, and admits it once an earlier decode has shrunk its charge to the minimum charge, not to its few bytes" $
    withSession (config limited (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      vm ← startVm session runtime "shrink" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "a.png"
      forM_ [0 .. 7] $ \n → started session vm "i" (keyOf n) "a.png"
      loadAs session vm "i" "z" "a.png" >>= (`shouldBe` busy "i" "the provider has no room in texture bytes")
      -- The first two reads decode a two by two image (16 bytes) and shrink their 16 MiB to the 4 KiB minimum charge each.
      openGate (ssProbe session) "a.png"
      -- Room for one more full reservation, not merely less than a full bank.
      awaitOwner vm "i" (\reading → 128 * 1048576 - ownerNominalHeld reading >= 16 * 1048576)
      started session vm "i" "y" "a.png"

  it "charges a texture smaller than the minimum exactly the minimum, 4,096 bytes, in both banks, from admission to its end, and returns it once" $
    withSession (config limited (Layout [("a.png", opaque 2 2)])) $ \session _ runtime → do
      setAutoRetire (ssFake session) True
      vm ← startVm session runtime "minimum" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      awaitUploads (ssFake session) 1
      -- A two by two image decodes to 16 bytes; both banks hold the minimum charge, not 16.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      sessionNow session `shouldReturn` 4096
      void (uploadN (ssFake session) 0 >>= finishUpload (ssFake session))
      command session vm "i" "wait_take" "k0"
      line ← lineStarting session "i wait_take k0 "
      line `shouldSatisfy` Text.isInfixOf "status=success"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      command session vm "i" "release" "k0"
      awaitNote session "i release k0 done"
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0

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

  it "refuse an instance whose facade boundary declared it logical, before any reservation or work: acquisition is presentation-instance hook work" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "logical" OnArrival
      admitModuleAs session vm LogicalRole "driver" "l"
      pipelineBefore ← pipelineNow session
      commandWith session vm "l" "pstart" "a" (Just (load "a.png"))
      line ← lineStarting session "l pstart a "
      line `shouldSatisfy` Text.isInfixOf "presentation-instance hook work"
      pipelineNow session >>= (`shouldBe` pipelineBefore)
      ownerNow vm "l" >>= (`shouldBe` OwnerReading 0 0)
      readsStarted (ssProbe session) `shouldReturn` 0
      d <- vmDiagnostics vm
      (rdBusy d, rdLatched d) `shouldBe` (0, 0)

  it "refuse, as a permanent refusal and not as busy, a request whose owner is closed between the argument check and the admission: nothing is reserved and no work is done" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "closing" OnArrival
      admitDriver session vm "i"
      pipelineBefore ← pipelineNow session
      setRaceClose session True
      commandWith session vm "i" "pstart" "a" (Just (load "a.png"))
      line ← lineStarting session "i pstart a "
      -- The facade got a permanent refusal back, with its reason: not the host's busy answer.
      line `shouldBe` "i pstart a busy:refused:the texture owner has ended"
      pipelineNow session >>= (`shouldBe` pipelineBefore)
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 0 0)
      readsStarted (ssProbe session) `shouldReturn` 0
      d <- vmDiagnostics vm
      rdLatched d `shouldBe` 0

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
