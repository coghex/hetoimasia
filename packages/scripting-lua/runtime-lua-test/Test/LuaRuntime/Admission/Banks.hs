-- | The banks of an opt-in admission: a request is accepted with every bank reserved in one
-- transaction or answered busy with nothing reserved at all; a bank that is merely full is
-- never a Lua error, the instance's failure or a hidden retry; and the places come back where the
-- owner accounts for them, once.
module Test.LuaRuntime.Admission.Banks (spec) where

import Control.Concurrent.STM (throwSTM)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Lease (Ownership (..), ScopeSummary (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Request.Support (Submitted (..), answerResult, awaitCancelled, awaitDiagnostic, diagnostics, finishWork, submissionAt, submissions)
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (Broken (Broken), brokenIs, bounded, expectFatal, requiredPolicy, withBoundary)

-- | Start an owner of admitters on elapsed time with this room, the way most examples do.
arrival ∷ AFix → Int → LuaRuntime → Text → IO ScheduledOwner
arrival fixture bound runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture bound SettleOnArrival) requiredPolicy

spec ∷ Spec
spec = describe "banks" $ do
  describe "the instance's accepted, unretired requests" $ do
    it "answers busy past the bound, as data and with nothing accepted, and a later call succeeds once a place is really free" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 2})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "instance bank"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b started"
        acommand fixture owner "i" "start" "c"
        -- Busy is an answer. No second provider request, no refusal counted, no latent failure.
        awaitNote fixture "cmd start c busy:busy"
        submissions (afFake fixture) >>= (`shouldBe` 2)
        d ← diagnostics owner
        (rdAdmitted d, rdBusy d, rdRefused d, rdHeld d) `shouldBe` (2, 1, 0, 2)
        -- The instance goes on: the answer was no error of its call.
        acommand fixture owner "i" "ready" "a"
        awaitNote fixture "cmd ready a false"
        -- Settling and taking a is not enough until its provider's work is accounted retired; both
        -- have happened by the time the ledger shows the place free.
        answerResult (afFake fixture) 0 5 >>= (`shouldBe` ReplySettled)
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=5}}"
        awaitDiagnostic owner ((== 1) . rdHeld)
        acommand fixture owner "i" "start" "c"
        awaitNote fixture "cmd start c started"
        submissions (afFake fixture) >>= (`shouldBe` 3)

    it "counts per instance, so another instance of the VM still has room" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 1, polPerVm = 8})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "per instance"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b busy:busy"
        acommand fixture owner "j" "start" "a"
        awaitStarts fixture 2
        heldBy fixture owner "i" >>= (`shouldBe` 1)
        heldBy fixture owner "j" >>= (`shouldBe` 1)

  describe "the VM's accepted, unretired requests" $ do
    it "is reached through two instances whose own bounds are lower than it" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 2, polPerVm = 3})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "vm bank"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        acommand fixture owner "i" "start" "a"
        acommand fixture owner "i" "start" "b"
        awaitStarts fixture 2
        acommand fixture owner "j" "start" "a"
        awaitStarts fixture 3
        acommand fixture owner "j" "start" "b"
        -- j has one of its own two places left, and the VM has none.
        awaitNote fixture "cmd start b busy:busy"
        d <- diagnostics owner
        (rdHeld d, rdBusy d) `shouldBe` (3, 1)

  describe "the owner's places" $ do
    it "answers busy, naming the bank, where the generic requests would refuse the call" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 1 runtime "owner bank"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture "cmd pstart b busy:busy the owner holds all 1 of its request places"
        d ← diagnostics owner
        (rdBusy d, rdRefused d) `shouldBe` (1, 0)

  describe "the result lease" $ do
    it "is reserved with the request, and a full lease bank is busy with no credit kept" $ bounded $ do
      fixture ← newAFix 1
      bank ← newBank 5
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polCredits = [bankCredit "bytes" False bank]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "lease bank"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        leaseSummary fixture "i" >>= \summary → (summaryCharged summary, summaryLive summary, summaryConstructing summary) `shouldBe` (1, 0, 1)
        bankAvailable bank >>= (`shouldBe` 4)
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture "cmd pstart b busy:busy the instance's lease capacity is charged: 1 of 1"
        -- The lease bank was refused first: nothing of the credit bank was taken, no handle exists,
        -- the provider was asked once.
        bankAvailable bank >>= (`shouldBe` 4)
        leaseSummary fixture "i" >>= \summary -> summaryCharged summary `shouldBe` 1
        submissions (afFake fixture) >>= (`shouldBe` 1)

  describe "a provider's credits" $ do
    it "are taken with the request, and a bank without room is busy while the credits before it are undone" $ bounded $ do
      fixture ← newAFix 4
      first ← newBank 1
      second ← newBank 0
      setPolicy fixture (\held → held {polCredits = [bankCredit "first" False first, bankCredit "second" False second]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "credit banks"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "pstart" "a"
        awaitNote fixture "cmd pstart a busy:busy the provider has no room in second"
        -- Both were attempted in order, and the first's reservation went with the whole admission.
        bankAvailable first >>= (`shouldBe` 1)
        bankLog first >>= (`shouldBe` [])
        bankLog second >>= (`shouldBe` [])
        submissions (afFake fixture) >>= (`shouldBe` 0)
        d <- diagnostics owner
        (rdBusy d, rdHeld d, rdOutstanding d) `shouldBe` (1, 0, 0)

    it "that are full for good refuse the request for good, as an ordinary error the script catches, nothing reserved, and a bank that may empty is still busy" $ bounded $ do
      fixture ← newAFix 4
      first ← newBank 2
      let forGood = Credit {creditName = "for good", creditReserve = throwSTM (CreditRefused "nothing will ever return a place"), creditRelease = const (pure ()), creditTransfers = False}
      setPolicy fixture (\held → held {polCredits = [bankCredit "first" False first, forGood]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "credit for good"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "pstart" "a"
        -- Caught by the script's pcall: an ordinary error naming the reason, not busy data and not a fault.
        awaitNote fixture "cmd pstart a error ad.start: request refused: nothing will ever return a place"
        -- The credit before it was undone with the admission, nothing reached the provider, and the
        -- instance went on: it asks again, and a request that can be had is started.
        bankAvailable first >>= (`shouldBe` 2)
        submissions (afFake fixture) >>= (`shouldBe` 0)
        d <- diagnostics owner
        (rdBusy d, rdRefused d, rdHeld d, rdOutstanding d) `shouldBe` (0, 1, 0, 0)
        setPolicy fixture (\held → held {polCredits = [bankCredit "first" False first]})
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture "cmd pstart b started"
        -- Where a bank may empty the answer stays busy data.
        empty ← newBank 0
        setPolicy fixture (\held → held {polCredits = [bankCredit "empty" False empty]})
        acommand fixture owner "i" "pstart" "c"
        awaitNote fixture "cmd pstart c busy:busy the provider has no room in empty"

    it "name themselves in a busy answer in UTF-8 bytes, cut between characters" $ bounded $ do
      fixture ← newAFix 4
      empty ← newBank 0
      setPolicy fixture (\held → held {polCredits = [bankCredit (Text.replicate 64 "é") False empty], polSource = Text.replicate 100 "😀"})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "credit name"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "pstart" "a"
        -- 64 two-byte characters are 128 bytes: the name is shown as the 32 that fit in 64 bytes.
        awaitNote fixture ("cmd pstart a busy:busy the provider has no room in " <> Text.replicate 32 "é")
        -- A source of four-byte characters is kept as the 32 that fit in 128 bytes, once a request is admitted.
        setPolicy fixture (\held → held {polCredits = []})
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture "cmd pstart b started"
        info ← sbInfo <$> submissionAt (afFake fixture) 0
        infoSource info `shouldBe` Just (Text.replicate 32 "😀")

    it "that are full for good win over a full temporary bank: the refusal is decided before any bank is asked" $ bounded $ do
      fixture ← newAFix 4
      let forGood = Credit {creditName = "for good", creditReserve = throwSTM (CreditRefused "nothing will ever return a place"), creditRelease = const (pure ()), creditTransfers = False}
      setPolicy fixture (\held → held {polPerInstance = 1})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "refusal before banks"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "pstart" "a"
        awaitNote fixture "cmd pstart a started"
        -- The instance's one place is held: a request is busy ...
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture "cmd pstart b busy:busy the instance holds all 1 of its request places"
        -- ... until the credit says it can never be had, and then it is refused, not busy, though that bank is still full.
        setPolicy fixture (\held → held {polPerInstance = 1, polCredits = [forGood]})
        acommand fixture owner "i" "pstart" "c"
        awaitNote fixture "cmd pstart c error ad.start: request refused: nothing will ever return a place"

    it "bound the reason of a refusal a script reads in bytes, cut between characters, so it is always delivered as the ordinary error it is" $ bounded $ do
      fixture ← newAFix 4
      let wordy reason = Credit {creditName = "wordy", creditReserve = throwSTM (CreditRefused reason), creditRelease = const (pure ()), creditTransfers = False}
      setPolicy fixture (\held → held {polCredits = [wordy (Text.replicate 1000 "x")]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "credit wordy"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "pstart" "a"
        awaitNote fixture ("cmd pstart a error ad.start: request refused: " <> Text.replicate refusalReasonBytes "x")
        -- A reason of four-byte characters, past the bound in bytes though not in characters: cut at 64 of them, not 256,
        -- delivered as an ordinary error that pcall catches, and the invocation goes on.
        setPolicy fixture (\held → held {polCredits = [wordy (Text.replicate refusalReasonBytes "😀")]})
        acommand fixture owner "i" "pstart" "b"
        awaitNote fixture ("cmd pstart b error ad.start: request refused: " <> Text.replicate (refusalReasonBytes `div` 4) "😀")
        setPolicy fixture (\held → held {polCredits = [wordy (Text.replicate 100 "é" <> "😀")]})
        acommand fixture owner "i" "pstart" "c"
        awaitNote fixture ("cmd pstart c error ad.start: request refused: " <> Text.replicate 100 "é" <> "😀")
        setPolicy fixture (\held → held {polCredits = []})
        acommand fixture owner "i" "pstart" "d"
        awaitNote fixture "cmd pstart d started"

    it "cannot be overbooked by two admissions that compete for the last unit" $ bounded $ do
      fixture ← newAFix 4
      pool ← newBank 1
      setPolicy fixture (\held → held {polCredits = [bankCredit "shared" False pool]})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "competing"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        acommand fixture owner "i" "start" "a"
        acommand fixture owner "j" "start" "a"
        awaitHistory fixture ((== 2) . length . filter (Text.isPrefixOf "cmd start a "))
        seen <- history fixture
        length (filter (== "cmd start a started") seen) `shouldBe` 1
        length (filter (== "cmd start a busy:busy") seen) `shouldBe` 1
        bankAvailable pool >>= (`shouldBe` 0)
        submissions (afFake fixture) >>= (`shouldBe` 1)

    it "that raise when asked are a failure of the host, and nothing the admission began stays reserved" $ bounded $ do
      fixture ← newAFix 4
      bank ← newBank 3
      let broken = (bankCredit "broken" False bank) {creditReserve = throwSTM (Broken "bank")}
      setPolicy fixture (\held → held {polCredits = [bankCredit "ok" False bank, broken], polLease = Just InstanceOwned})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "raising bank"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "bank"
      -- The transaction that raised was undone whole: the first credit and the lease slot were
      -- never kept.
      bankAvailable bank >>= (`shouldBe` 3)
      submissions (afFake fixture) >>= (`shouldBe` 0)

  describe "a full ordinary bank" $ do
    it "still lets completion, cancellation and the instance's end drain" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polPerInstance = 2})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture 8 runtime "full drains"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        acommand fixture owner "i" "start" "b"
        awaitStarts fixture 2
        acommand fixture owner "i" "start" "c"
        awaitNote fixture "cmd start c busy:busy"
        -- Complete one, cancel the other: neither needs a place.
        answerResult (afFake fixture) 0 7 >>= (`shouldBe` ReplySettled)
        acommand fixture owner "i" "cancel" "b"
        awaitNote fixture "cmd cancel b cancelled"
        awaitCancelled (afFake fixture) 1
        finishWork (afFake fixture) 1
        acommand fixture owner "i" "take" "a"
        acommand fixture owner "i" "take" "b"
        awaitNote fixture "cmd take b {status=cancelled}"
        awaitDiagnostic owner ((== 0) . rdHeld)
