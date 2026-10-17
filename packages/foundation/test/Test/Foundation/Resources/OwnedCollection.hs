-- | Examples for "Hetoimasia.Foundation.Resource.OwnedCollection", the scoped
-- collection owned by a capability instead of a thread.
--
-- The first groups mirror the examples of
-- "Test.Foundation.Resources.Collection" for the guarantees the two collections
-- share: the live-set bound, staged acquisition with masked registration and the
-- owner handoff, retirement exactly once, reentry rejection, foreign tokens,
-- poisoning, and latched cleanup evidence. The later groups are this
-- collection's own: the capability that owns it, serialization of the threads
-- that present it, lending, and the scope's exit racing an operation that is
-- already inside.
--
-- Every example enters a real collection through 'withScoped' and observes what
-- a caller can see: tokens and their 'MemberStatus', the 'Retirement' outcomes and
-- 'OwnedCollectionError' rejections, the failure that propagated with the
-- cleanup evidence 'cleanupFailures' reads out of it, and an ordered trace of
-- acquisitions, releases, and callback effects. A rejection is asserted to have
-- run nothing by checking that trace.
--
-- Concurrency is coordinated with 'MVar's and 'threadStatus', never with a
-- sleep. 'boundedExample' only stops an example that has already hung. The
-- retention examples ask the garbage collector whether a released payload is
-- still reachable, through weak references to it that the example holds.
module Test.Foundation.Resources.OwnedCollection (spec) where

import Control.Concurrent (ThreadId, forkIO, killThread, throwTo, yield)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , ErrorCall (ErrorCall)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , MaskingState (..)
  , SomeException
  , fromException
  , getMaskingState
  , mask_
  , throwIO
  , try
  , uninterruptibleMask_
  )
import Control.Monad (forM, forM_, void)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', mkWeakIORef, newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Conc (BlockReason (BlockedOnException, BlockedOnSTM), ThreadStatus (..), threadStatus)
import Hetoimasia.Foundation.Resource
  ( Assembly
  , CleanupFailure
  , acquirePart
  , cleanupFailureId
  , cleanupFailureLabel
  , cleanupFailures
  , releaseRank
  , restoredStep
  , withScoped
  )
import Hetoimasia.Foundation.Resource.OwnedCollection
  ( Activity (..)
  , Member
  , MemberStatus (..)
  , OwnedCollection
  , OwnedCollectionError (..)
  , OwnerCapability
  , Retirement (..)
  , acquireOwnedMember
  , acquireOwnedMemberThen
  , allocOwnedCollection
  , lendCapability
  , liveOwnedMemberCount
  , memberStatus
  , noCapability
  , retireOwnedMember
  , withOwnedMember
  )
import System.IO.Error (ioeGetErrorString)
import System.Mem (performMajorGC)
import System.Mem.Weak (Weak, deRefWeak)
import System.Timeout (timeout)
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldReturn
  )

spec ∷ Spec
spec = do
  describe "Owned resource collection admission" $ do
    it "rejects a limit below one before the body runs"
      testInvalidLimit
    it "rejects acquisition at the live-member limit before the assembly runs, and reuses a retired slot"
      testLimitAndReuse
    it "rolls back a failing stage, registers no member, consumes no capacity, and does not poison"
      testAcquisitionRollback
    it "rolls back a member cancelled during its assembly"
      (boundedExample testCancelledDuringAssembly)
    it "registers a member whose acquisition returns with a cancellation pending, and releases it at exit"
      (boundedExample testCancellationPendingAtRegistration)
    it "rolls back a member cancelled during its assembly before its handoff runs"
      (boundedExample testHandoffCancelledDuringAssembly)
    it "runs the handoff masked in the registering step, delivering a pending cancellation only after it"
      (boundedExample testHandoffBeforePendingCancellation)
    it "keeps a member registered when its handoff raises, releasing it at exit"
      testHandoffFailure

  describe "Owned resource collection borrowing and retirement" $ do
    it "retires a middle member while its neighbours stay live"
      testNonLifoRetirement
    it "treats a repeated successful retirement as inert and calls the release once"
      testRepeatedRetirement
    it "reports the stored failure on a repeated failed retirement without calling the release again"
      testRepeatedFailedRetirement
    it "answers in use while a member is borrowed, then retires it after the borrow ends"
      testRetirementDuringBorrow
    it "lets a borrowing callback borrow another live member"
      testNestedBorrow
    it "runs a borrowing callback with the caller's masking state"
      testBorrowMaskingState
    it "drops a borrow when its callback fails"
      testBorrowDroppedOnFailure
    it "drops a borrow when its callback is cancelled"
      (boundedExample testBorrowDroppedOnCancellation)

  describe "Owned resource collection misuse" $ do
    it "rejects a token from another collection before any effect"
      testForeignMember
    it "rejects acquisition, borrowing, and retirement re-entered from an assembly"
      testReentryFromAssembly
    it "rejects acquisition and retirement of other members from a borrowing callback"
      testReentryFromBorrow
    it "rejects retirement of other terminal members from a borrowing callback"
      testTerminalRetirementFromBorrow
    it "rejects acquisition, borrowing, and retirement re-entered from an early release"
      testReentryFromRetirementRelease
    it "rejects acquisition, borrowing, and retirement re-entered from a release at exit"
      testReentryFromClosingRelease
    it "lets a release at exit read the live count, while another thread is refused"
      (boundedExample testLiveCountFromClosingRelease)

  describe "Owned resource collection capability" $ do
    it "refuses every operation that presents no capability before any effect"
      testMissingCapability
    it "refuses every operation that presents another collection's capability before any effect"
      testForeignCapability
    it "refuses every operation that presents a lent capability after the lending ended, and serves it during"
      testStaleCapability
    it "revokes a lent capability when its action raises"
      testRevokedOnFailure
    it "revokes a lent capability when its action is cancelled"
      (boundedExample testRevokedOnCancellation)
    it "refuses to lend a missing or stale capability without running the action"
      testLendRefusals
    it "lets a lent capability act from another thread while the lending lasts, and not after"
      (boundedExample testLentOnOtherThread)
    it "is not tied to a thread: members acquired on one thread are retired on others"
      (boundedExample testCapabilityAcrossThreads)

  describe "Owned resource collection serialization" $ do
    it "refuses every operation from a second thread while a borrow is running, and the borrow proceeds"
      (boundedExample testConcurrentBorrow)
    it "refuses every operation from a second thread while an acquisition is running, and it registers"
      (boundedExample testConcurrentAcquisition)
    it "refuses every operation from a second thread while a retirement's release is running"
      (boundedExample testConcurrentRetirement)
    it "serializes the holders of different capabilities of one collection"
      (boundedExample testSerializedAcrossCapabilities)
    it "lets the thread inside an operation read the live count and make the calls the rules allow"
      testNestedCallsOnTheRunningThread

  describe "Owned resource collection scope exit" $ do
    it "waits for a borrow on another thread, refusing new operations meanwhile, before releasing"
      (boundedExample testExitWaitsForBorrow)
    it "waits for an acquisition on another thread and releases the member it registered"
      (boundedExample testExitWaitsForAcquisition)
    it "waits for an acquire-then handoff on another thread and releases the member"
      (boundedExample testExitWaitsForHandoff)
    it "waits for a retirement on another thread and releases nothing twice"
      (boundedExample testExitWaitsForRetirement)
    it "keeps waiting for the operation inside when the scope is cancelled, then releases and propagates"
      (boundedExample testExitCancelledWhileWaiting)
    it "accounts for an operation that fails while the exit waits for it"
      (boundedExample testExitAfterFailingOperation)

  describe "Owned resource collection terminal tokens" $ do
    it "reports terminal states after the collection exits and rejects the closed collection"
      testTerminalTokensAfterExit
    it "releases a failed early retirement's payload while its token keeps only the failure"
      testFailedRetirementPayloadReleased
    it "reports a release that failed at exit through the retained token, which keeps only the failure"
      testFailedAtExitToken
    it "keeps owner bookkeeping and payloads bounded by live members across open and retire cycles"
      testBoundedBookkeeping

  describe "Owned resource collection cleanup failures" $ do
    it "fails the exit with a caught early-retirement failure and still releases the remaining members"
      testCaughtRetirementFailureFailsExit
    it "keeps the body's failure primary beside early and final cleanup evidence"
      testBodyFailureStaysPrimary
    it "keeps a cancellation of the body primary beside the collection's evidence"
      (boundedExample testCancelledBodyStaysPrimary)
    it "poisons acquisition after a failing rollback and makes a successful body's exit fail with it"
      testRollbackFailurePoisons
    it "keeps the body's failure primary over a latched rollback failure"
      testRollbackFailureUnderBodyFailure
    it "releases remaining members in reverse registration order with each member's declared ranks"
      testExitOrderWithRanks
    it "fails a successful body's exit with the first final release failure and attempts the rest"
      testFinalReleaseFailures

-- Fixtures -------------------------------------------------------------------

-- | A collection with the capability that owns it.
data Owned = Owned OwnedCollection OwnerCapability

-- | Allocate a collection for the continuation, with its capability.
withOwned ∷ Int → (Owned → IO a) → IO a
withOwned limit body =
  withScoped (allocOwnedCollection limit) $ \(collection, capability) →
    body (Owned collection capability)

-- | The collection's operations, presenting its own capability.
acquireMember ∷ Owned → Assembly a → IO (Member a)
acquireMember (Owned collection capability) = acquireOwnedMember collection capability

acquireMemberThen ∷ Owned → Assembly a → (Member a → IO b) → IO b
acquireMemberThen (Owned collection capability) = acquireOwnedMemberThen collection capability

withMember ∷ Owned → Member a → (a → IO r) → IO r
withMember (Owned collection capability) = withOwnedMember collection capability

retireMember ∷ Owned → Member a → IO Retirement
retireMember (Owned collection capability) = retireOwnedMember collection capability

liveMemberCount ∷ Owned → IO Int
liveMemberCount (Owned collection capability) = liveOwnedMemberCount collection capability

-- | An ordered log of what an example observed.
newtype Trail = Trail (MVar [Text])

newTrail ∷ IO Trail
newTrail = Trail <$> newMVar []

record ∷ Trail → Text → IO ()
record (Trail slot) entry = modifyMVar_ slot (pure . (<> [entry]))

trail ∷ Trail → IO [Text]
trail (Trail slot) = readMVar slot

-- | A one-part member named @name@ whose release succeeds.
tracked ∷ Trail → Text → Assembly Text
tracked events name =
  acquirePart
    name
    (releaseRank 0)
    (name <$ record events ("acquire " <> name))
    (\_ → record events ("release " <> name))

-- | A one-part member named @name@ whose release throws an 'IOException'
-- carrying @name <> " released"@.
failing ∷ Trail → Text → Assembly Text
failing events name =
  acquirePart
    name
    (releaseRank 0)
    (name <$ record events ("acquire " <> name))
    ( \_ → do
        record events ("release " <> name)
        throwIO (userError (Text.unpack name <> " released"))
    )

-- | Run @action@, requiring it to fail, and return what propagated.
expectFailure ∷ IO a → IO SomeException
expectFailure action = do
  outcome ← try action
  case outcome of
    Left exception → pure exception
    Right _ → fail "expected a failure, but the action returned"

-- | Require @action@ to be rejected with exactly @expected@.
rejectedWith ∷ OwnedCollectionError → IO a → Expectation
rejectedWith expected action = rejection action `shouldReturn` Just expected

-- | The 'CollectionError' an action was rejected with, if it was.
rejection ∷ IO a → IO (Maybe OwnedCollectionError)
rejection action = either Just (const Nothing) <$> try action

errorCallMessage ∷ SomeException → Maybe String
errorCallMessage exception = case fromException exception of
  Just (ErrorCall message) → Just message
  Nothing → Nothing

ioErrorMessage ∷ SomeException → Maybe String
ioErrorMessage exception = case fromException exception of
  Just failure → Just (ioeGetErrorString (failure ∷ IOException))
  Nothing → Nothing

labelsOf ∷ [CleanupFailure] → [Text]
labelsOf = map cleanupFailureLabel

occurrences ∷ Text → [Text] → Int
occurrences entry = length . filter (== entry)

-- | The failure a failed terminal state stored, without its context.
storedFailure ∷ MemberStatus → Maybe SomeException
storedFailure status = case status of
  MemberRetirementFailed (ExceptionWithContext _ exception) → Just exception
  _ → Nothing

isRetired ∷ MemberStatus → Bool
isRetired status = case status of
  MemberRetired → True
  _ → False

isLive ∷ MemberStatus → Bool
isLive status = case status of
  MemberLive → True
  _ → False

-- | A member whose payload is a fresh 'IORef' the example can observe only
-- through a weak reference, recorded into @weaks@.
observedPayload ∷ IORef [Weak (IORef ())] → Assembly (IORef ())
observedPayload weaks =
  acquirePart
    "payload"
    (releaseRank 0)
    ( do
        payload ← newIORef ()
        weak ← mkWeakIORef payload (pure ())
        readIORef weaks >>= writeIORef weaks . (weak :)
        pure payload
    )
    (\_ → pure ())

-- | 'observedPayload' whose release throws an 'IOException' carrying
-- @"payload released"@.
failingPayload ∷ IORef [Weak (IORef ())] → Assembly (IORef ())
failingPayload weaks =
  acquirePart
    "payload"
    (releaseRank 0)
    ( do
        payload ← newIORef ()
        weak ← mkWeakIORef payload (pure ())
        readIORef weaks >>= writeIORef weaks . (weak :)
        pure payload
    )
    (\_ → throwIO (userError "payload released"))

-- | How many of the observed payloads the garbage collector still reaches.
reachablePayloads ∷ IORef [Weak (IORef ())] → IO Int
reachablePayloads weaks = do
  performMajorGC
  observed ← readIORef weaks
  length . filter id <$> traverse (fmap isJust . deRefWeak) observed

-- | Stop an example that has hung rather than letting the suite wait forever.
-- No example depends on this bound for its result.
boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- | Wait until @target@ has stopped making progress towards its 'throwTo'.
awaitPendingThrow ∷ ThreadId → IO ()
awaitPendingThrow target = do
  status ← threadStatus target
  case status of
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield *> awaitPendingThrow target

-- | Run an owner body on a thread of its own, returning that thread and a
-- slot the scope's outcome is written to.
forkOwner ∷ IO () → IO (ThreadId, MVar (Either SomeException ()))
forkOwner body = do
  outcome ← newEmptyMVar
  owner ← forkIO (try body >>= putMVar outcome)
  pure (owner, outcome)

-- Admission ------------------------------------------------------------------

testInvalidLimit ∷ Expectation
testInvalidLimit = do
  events ← newTrail
  for_ [0, -1] $ \limit →
    rejectedWith
      (OwnedInvalidMemberLimit limit)
      (withOwned limit (\_ → record events "body"))
  trail events `shouldReturn` []

testLimitAndReuse ∷ Expectation
testLimitAndReuse = do
  events ← newTrail
  withOwned 2 $ \collection → do
    first ← acquireMember collection (tracked events "first")
    _ ← acquireMember collection (tracked events "second")
    rejectedWith (OwnedLimitReached 2) (acquireMember collection (tracked events "third"))
    trail events `shouldReturn` ["acquire first", "acquire second"]
    retireMember collection first `shouldReturn` Retired
    liveMemberCount collection `shouldReturn` 1
    _ ← acquireMember collection (tracked events "third")
    liveMemberCount collection `shouldReturn` 2
  trail events
    `shouldReturn` [ "acquire first"
                   , "acquire second"
                   , "release first"
                   , "acquire third"
                   , "release third"
                   , "release second"
                   ]

testAcquisitionRollback ∷ Expectation
testAcquisitionRollback = do
  events ← newTrail
  withOwned 1 $ \collection → do
    propagated ←
      expectFailure . acquireMember collection $ do
        _ ← tracked events "part"
        restoredStep (throwIO (ErrorCall "stage failed") ∷ IO ())
        tracked events "never"
    errorCallMessage propagated `shouldBe` Just "stage failed"
    length (cleanupFailures propagated) `shouldBe` 0
    trail events `shouldReturn` ["acquire part", "release part"]
    liveMemberCount collection `shouldReturn` 0
    -- The only slot is still free, and a clean rollback did not poison.
    member ← acquireMember collection (tracked events "after")
    withMember collection member pure `shouldReturn` "after"
  trail events
    `shouldReturn` ["acquire part", "release part", "acquire after", "release after"]

testCancelledDuringAssembly ∷ Expectation
testCancelledDuringAssembly = do
  events ← newTrail
  reached ← newEmptyMVar
  blocker ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 2 $ \collection → do
      _ ← acquireMember collection (tracked events "earlier")
      void . acquireMember collection $ do
        _ ← tracked events "cancelled"
        restoredStep (putMVar reached () *> takeMVar blocker ∷ IO ())
  takeMVar reached
  killThread owner
  takeMVar outcome >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      fromException propagated `shouldBe` Just ThreadKilled
      -- The cancelled member was rolled back at once; the earlier member was
      -- released at the collection's exit.
      trail events
        `shouldReturn` [ "acquire earlier"
                       , "acquire cancelled"
                       , "release cancelled"
                       , "release earlier"
                       ]

testCancellationPendingAtRegistration ∷ Expectation
testCancellationPendingAtRegistration = do
  events ← newTrail
  acquiring ← newEmptyMVar
  killerSlot ← newEmptyMVar
  neverFilled ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 2 $ \collection → do
      _ ← acquireMember collection (tracked events "earlier")
      _ ←
        acquireMember collection $
          acquirePart
            "pending"
            (releaseRank 0)
            ( uninterruptibleMask_ $ do
                record events "acquire pending"
                putMVar acquiring ()
                readMVar killerSlot >>= awaitPendingThrow
            )
            (\_ → record events "release pending")
      -- Not reached: the pending cancellation is delivered as soon as the
      -- acquisition restores the caller's masking state.
      record events "body resumed"
      takeMVar neverFilled
  takeMVar acquiring
  killer ← forkIO (throwTo owner ThreadKilled)
  putMVar killerSlot killer
  takeMVar outcome >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      fromException propagated `shouldBe` Just ThreadKilled
      performed ← trail events
      -- Registered before the cancellation was delivered, so released exactly
      -- once, by the exit, newest first.
      performed
        `shouldBe` [ "acquire earlier"
                   , "acquire pending"
                   , "release pending"
                   , "release earlier"
                   ]
      occurrences "release pending" performed `shouldBe` 1

testHandoffCancelledDuringAssembly ∷ Expectation
testHandoffCancelledDuringAssembly = do
  events ← newTrail
  reached ← newEmptyMVar
  blocker ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 2 $ \collection → do
      _ ← acquireMember collection (tracked events "earlier")
      acquireMemberThen
        collection
        ( do
            _ ← tracked events "cancelled"
            restoredStep (putMVar reached () *> takeMVar blocker ∷ IO ())
        )
        (\_ → record events "handoff")
  takeMVar reached
  killThread owner
  takeMVar outcome >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      fromException propagated `shouldBe` Just ThreadKilled
      trail events
        `shouldReturn` [ "acquire earlier"
                       , "acquire cancelled"
                       , "release cancelled"
                       , "release earlier"
                       ]

testHandoffBeforePendingCancellation ∷ Expectation
testHandoffBeforePendingCancellation = do
  events ← newTrail
  handing ← newEmptyMVar
  killerSlot ← newEmptyMVar
  neverFilled ← newEmptyMVar
  masking ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 2 $ \collection → do
      _ ←
        acquireMemberThen collection (tracked events "pending") $ \member → do
          getMaskingState >>= putMVar masking
          record events "handoff"
          putMVar handing ()
          -- Waiting for the killer is itself uninterruptible; the check that its
          -- cancellation is pending is not a blocking operation.
          uninterruptibleMask_ (readMVar killerSlot) >>= awaitPendingThrow
          liveMemberCount collection >>= record events . ("handoff saw " <>) . Text.pack . show
          withMember collection member (record events . ("handoff borrowed " <>))
      -- Not reached: the pending cancellation is delivered once the handoff
      -- returns and the acquisition restores the caller's masking state.
      record events "body resumed"
      takeMVar neverFilled
  takeMVar handing
  killer ← forkIO (throwTo owner ThreadKilled)
  putMVar killerSlot killer
  takeMVar outcome >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      fromException propagated `shouldBe` Just ThreadKilled
      takeMVar masking `shouldReturn` MaskedInterruptible
      trail events
        `shouldReturn` [ "acquire pending"
                       , "handoff"
                       , "handoff saw 1"
                       , "handoff borrowed pending"
                       , "release pending"
                       ]

testHandoffFailure ∷ Expectation
testHandoffFailure = do
  events ← newTrail
  outcome ←
    try . withOwned 2 $ \collection → do
      _ ← acquireMemberThen collection (tracked events "kept") (\_ → throwIO (ErrorCall "handoff failed") ∷ IO ())
      liveMemberCount collection >>= record events . ("live after " <>) . Text.pack . show
  case outcome of
    Right () → expectationFailure "expected the handoff's failure to propagate"
    Left (ErrorCall message) → message `shouldBe` "handoff failed"
  -- The failure left the body before its count; the member was released at exit.
  trail events `shouldReturn` ["acquire kept", "release kept"]

-- Borrowing and retirement ---------------------------------------------------

testNonLifoRetirement ∷ Expectation
testNonLifoRetirement = do
  events ← newTrail
  withOwned 3 $ \collection → do
    first ← acquireMember collection (tracked events "first")
    middle ← acquireMember collection (tracked events "middle")
    lastOne ← acquireMember collection (tracked events "last")
    retireMember collection middle `shouldReturn` Retired
    isRetired <$> memberStatus middle `shouldReturn` True
    withMember collection first pure `shouldReturn` "first"
    withMember collection lastOne pure `shouldReturn` "last"
    liveMemberCount collection `shouldReturn` 2
  trail events
    `shouldReturn` [ "acquire first"
                   , "acquire middle"
                   , "acquire last"
                   , "release middle"
                   , "release last"
                   , "release first"
                   ]

testRepeatedRetirement ∷ Expectation
testRepeatedRetirement = do
  events ← newTrail
  withOwned 1 $ \collection → do
    member ← acquireMember collection (tracked events "member")
    retireMember collection member `shouldReturn` Retired
    retireMember collection member `shouldReturn` AlreadyRetired
    retireMember collection member `shouldReturn` AlreadyRetired
    rejectedWith OwnedMemberNotLive (withMember collection member (record events . ("borrowed " <>)))
  trail events `shouldReturn` ["acquire member", "release member"]

testRepeatedFailedRetirement ∷ Expectation
testRepeatedFailedRetirement = do
  events ← newTrail
  exited ←
    expectFailure $
      withOwned 1 $ \collection → do
        member ← acquireMember collection (failing events "member")
        first ← expectFailure (retireMember collection member)
        ioErrorMessage first `shouldBe` Just "member released"
        again ← expectFailure (retireMember collection member)
        ioErrorMessage again `shouldBe` Just "member released"
        map cleanupFailureId (cleanupFailures again)
          `shouldBe` map cleanupFailureId (cleanupFailures first)
        labelsOf (cleanupFailures first) `shouldBe` ["member"]
        status ← memberStatus member
        (storedFailure status >>= ioErrorMessage) `shouldBe` Just "member released"
        rejectedWith OwnedMemberNotLive (withMember collection member pure)
  performed ← trail events
  performed `shouldBe` ["acquire member", "release member"]
  occurrences "release member" performed `shouldBe` 1
  -- The caught failure was latched, so the exit failed with it.
  ioErrorMessage exited `shouldBe` Just "member released"
  labelsOf (cleanupFailures exited) `shouldBe` ["member"]

testRetirementDuringBorrow ∷ Expectation
testRetirementDuringBorrow = do
  events ← newTrail
  withOwned 1 $ \collection → do
    member ← acquireMember collection (tracked events "member")
    withMember collection member $ \_ → do
      retireMember collection member `shouldReturn` RetirementInUse
      isLive <$> memberStatus member `shouldReturn` True
      record events "borrow ends"
    retireMember collection member `shouldReturn` Retired
  trail events `shouldReturn` ["acquire member", "borrow ends", "release member"]

testNestedBorrow ∷ Expectation
testNestedBorrow = do
  events ← newTrail
  withOwned 2 $ \collection → do
    left ← acquireMember collection (tracked events "left")
    right ← acquireMember collection (tracked events "right")
    joined ←
      withMember collection left $ \l →
        withMember collection right $ \r → pure (l <> "+" <> r)
    joined `shouldBe` "left+right"
    retireMember collection left `shouldReturn` Retired
    retireMember collection right `shouldReturn` Retired

testBorrowMaskingState ∷ Expectation
testBorrowMaskingState = do
  events ← newTrail
  withOwned 1 $ \collection → do
    member ← acquireMember collection (tracked events "member")
    withMember collection member (const getMaskingState) `shouldReturn` Unmasked
    mask_ (withMember collection member (const getMaskingState))
      `shouldReturn` MaskedInterruptible
    uninterruptibleMask_ (withMember collection member (const getMaskingState))
      `shouldReturn` MaskedUninterruptible

testBorrowDroppedOnFailure ∷ Expectation
testBorrowDroppedOnFailure = do
  events ← newTrail
  withOwned 1 $ \collection → do
    member ← acquireMember collection (tracked events "member")
    propagated ←
      expectFailure (withMember collection member (\_ → throwIO (ErrorCall "borrow failed")))
    errorCallMessage propagated `shouldBe` Just "borrow failed"
    retireMember collection member `shouldReturn` Retired
  trail events `shouldReturn` ["acquire member", "release member"]

testBorrowDroppedOnCancellation ∷ Expectation
testBorrowDroppedOnCancellation = do
  events ← newTrail
  borrowing ← newEmptyMVar
  neverFilled ← newEmptyMVar
  retired ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 1 $ \collection → do
      member ← acquireMember collection (tracked events "member")
      cancelled ←
        try (withMember collection member (\_ → putMVar borrowing () *> takeMVar neverFilled))
      case cancelled of
        Left ThreadKilled → pure ()
        Left other → throwIO other
        Right () → fail "the borrow was not cancelled"
      retireMember collection member >>= putMVar retired
  takeMVar borrowing
  -- Returns once the cancellation has been delivered inside the callback.
  killThread owner
  takeMVar retired `shouldReturn` Retired
  takeMVar outcome >>= either throwIO pure
  trail events `shouldReturn` ["acquire member", "release member"]

-- Misuse ---------------------------------------------------------------------

testForeignMember ∷ Expectation
testForeignMember = do
  events ← newTrail
  withOwned 1 $ \issuer →
    withOwned 1 $ \other → do
      member ← acquireMember issuer (tracked events "member")
      rejectedWith OwnedForeignMember (withMember other member (\_ → record events "borrowed"))
      rejectedWith OwnedForeignMember (retireMember other member)
      trail events `shouldReturn` ["acquire member"]
      isLive <$> memberStatus member `shouldReturn` True
      liveMemberCount other `shouldReturn` 0

-- | The three re-entrant calls, each made against an existing live member of
-- the same collection, with the rejections they produced.
reenter ∷ Trail → Owned → Member Text → IO [Maybe OwnedCollectionError]
reenter events collection existing =
  sequence
    [ rejection (acquireMember collection (tracked events "nested"))
    , rejection (withMember collection existing (\_ → record events "borrowed"))
    , rejection (retireMember collection existing)
    ]

testReentryFromAssembly ∷ Expectation
testReentryFromAssembly = do
  events ← newTrail
  observed ← newIORef []
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    _ ← acquireMember collection $ do
      value ← tracked events "outer"
      restoredStep (reenter events collection existing >>= writeIORef observed)
      pure value
    readIORef observed `shouldReturn` replicate 3 (Just (OwnedReentered Acquiring))
    trail events `shouldReturn` ["acquire existing", "acquire outer"]
    liveMemberCount collection `shouldReturn` 2
    withMember collection existing pure `shouldReturn` "existing"

testReentryFromBorrow ∷ Expectation
testReentryFromBorrow = do
  events ← newTrail
  withOwned 3 $ \collection → do
    borrowed ← acquireMember collection (tracked events "borrowed")
    other ← acquireMember collection (tracked events "other")
    withMember collection borrowed $ \_ → do
      rejectedWith
        (OwnedReentered Borrowing)
        (acquireMember collection (tracked events "nested"))
      rejectedWith (OwnedReentered Borrowing) (retireMember collection other)
      retireMember collection borrowed `shouldReturn` RetirementInUse
      withMember collection other pure `shouldReturn` "other"
    trail events `shouldReturn` ["acquire borrowed", "acquire other"]
    liveMemberCount collection `shouldReturn` 2

testTerminalRetirementFromBorrow ∷ Expectation
testTerminalRetirementFromBorrow = do
  events ← newTrail
  exited ←
    expectFailure $
      withOwned 3 $ \collection → do
        borrowed ← acquireMember collection (tracked events "borrowed")
        retired ← acquireMember collection (tracked events "retired")
        broken ← acquireMember collection (failing events "broken")
        retireMember collection retired `shouldReturn` Retired
        void (expectFailure (retireMember collection broken))
        withMember collection borrowed $ \_ → do
          rejectedWith (OwnedReentered Borrowing) (retireMember collection retired)
          rejectedWith (OwnedReentered Borrowing) (retireMember collection broken)
          retireMember collection borrowed `shouldReturn` RetirementInUse
        -- Outside the borrow, both answer from their stored state again.
        retireMember collection retired `shouldReturn` AlreadyRetired
        again ← expectFailure (retireMember collection broken)
        ioErrorMessage again `shouldBe` Just "broken released"
  ioErrorMessage exited `shouldBe` Just "broken released"
  performed ← trail events
  occurrences "release retired" performed `shouldBe` 1
  occurrences "release broken" performed `shouldBe` 1

-- | A member whose release probes its own collection through the slot, and
-- records what the probe observed.
probing
  ∷ Trail
  → IORef (Maybe (Owned, Member Text, Member Text))
  → IORef [Maybe OwnedCollectionError]
  → Assembly ()
probing events slot observed =
  acquirePart
    "probe"
    (releaseRank 0)
    (record events "acquire probe")
    ( \_ → do
        readIORef slot >>= \case
          Nothing → pure ()
          Just (collection, existing, self) → do
            nested ← reenter events collection existing
            itself ← rejection (retireMember collection self)
            writeIORef observed (nested <> [itself])
        record events "release probe"
    )

testReentryFromRetirementRelease ∷ Expectation
testReentryFromRetirementRelease = do
  events ← newTrail
  slot ← newIORef Nothing
  observed ← newIORef []
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    probe ← acquireMember collection (probing events slot observed)
    self ← acquireMember collection (tracked events "self")
    writeIORef slot (Just (collection, existing, self))
    retireMember collection probe `shouldReturn` Retired
    readIORef observed `shouldReturn` replicate 4 (Just (OwnedReentered Retiring))
    liveMemberCount collection `shouldReturn` 2
    withMember collection existing pure `shouldReturn` "existing"
    writeIORef slot Nothing
  trail events
    `shouldReturn` [ "acquire existing"
                   , "acquire probe"
                   , "acquire self"
                   , "release probe"
                   , "release self"
                   , "release existing"
                   ]

testReentryFromClosingRelease ∷ Expectation
testReentryFromClosingRelease = do
  events ← newTrail
  slot ← newIORef Nothing
  observed ← newIORef []
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    self ← acquireMember collection (tracked events "self")
    _ ← acquireMember collection (probing events slot observed)
    writeIORef slot (Just (collection, existing, self))
  readIORef observed `shouldReturn` replicate 4 (Just (OwnedReentered Closing))
  trail events
    `shouldReturn` [ "acquire existing"
                   , "acquire self"
                   , "acquire probe"
                   , "release probe"
                   , "release self"
                   , "release existing"
                   ]

testLiveCountFromClosingRelease ∷ Expectation
testLiveCountFromClosingRelease = do
  events ← newTrail
  slot ← newIORef Nothing
  seen ← newIORef []
  let counting name =
        acquirePart
          name
          (releaseRank 0)
          (name <$ record events ("acquire " <> name))
          ( \_ → do
              readIORef slot >>= \case
                Nothing → pure ()
                Just collection → do
                  count ← liveMemberCount collection
                  elsewhere ← rejection (onThread (liveMemberCount collection))
                  atomicModifyIORef' seen (\held → (held <> [(name, count, elsewhere)], ()))
              record events ("release " <> name)
          )
  withOwned 2 $ \collection → do
    _ ← acquireMember collection (counting "first")
    _ ← acquireMember collection (counting "second")
    writeIORef slot (Just collection)
  -- The thread running the exit may read, as the thread-owned collection's owner
  -- may; every other thread is refused, whatever the exit is doing.
  readIORef seen
    `shouldReturn` [ ("second", 0, Just (OwnedReentered Closing))
                   , ("first", 0, Just (OwnedReentered Closing))
                   ]
  trail events
    `shouldReturn` ["acquire first", "acquire second", "release second", "release first"]

-- Terminal tokens ------------------------------------------------------------

testTerminalTokensAfterExit ∷ Expectation
testTerminalTokensAfterExit = do
  events ← newTrail
  weaks ← newIORef []
  (collection, early, atExit) ←
    withOwned 2 $ \collection → do
      early ← acquireMember collection (observedPayload weaks)
      atExit ← acquireMember collection (observedPayload weaks)
      retireMember collection early `shouldReturn` Retired
      pure (collection, early, atExit)
  isRetired <$> memberStatus early `shouldReturn` True
  isRetired <$> memberStatus atExit `shouldReturn` True
  -- Retained tokens keep neither payload reachable.
  reachablePayloads weaks `shouldReturn` 0
  rejectedWith OwnedClosed (acquireMember collection (tracked events "late"))
  rejectedWith OwnedClosed (withMember collection atExit (\_ → record events "borrowed"))
  rejectedWith OwnedClosed (retireMember collection early)
  rejectedWith OwnedClosed (liveMemberCount collection)
  trail events `shouldReturn` []

testFailedRetirementPayloadReleased ∷ Expectation
testFailedRetirementPayloadReleased = do
  weaks ← newIORef []
  retained ← newEmptyMVar
  exited ←
    expectFailure $
      withOwned 1 $ \collection → do
        member ← acquireMember collection (failingPayload weaks)
        reachablePayloads weaks `shouldReturn` 1
        void (expectFailure (retireMember collection member))
        -- The collection and the token are both still live here.
        reachablePayloads weaks `shouldReturn` 0
        putMVar retained member
  member ← takeMVar retained
  ioErrorMessage exited `shouldBe` Just "payload released"
  status ← memberStatus member
  (storedFailure status >>= ioErrorMessage) `shouldBe` Just "payload released"
  reachablePayloads weaks `shouldReturn` 0

testFailedAtExitToken ∷ Expectation
testFailedAtExitToken = do
  weaks ← newIORef []
  retained ← newEmptyMVar
  exited ←
    expectFailure $
      withOwned 1 $ \collection → do
        acquireMember collection (failingPayload weaks) >>= putMVar retained
        reachablePayloads weaks `shouldReturn` 1
  member ← takeMVar retained
  status ← memberStatus member
  (storedFailure status >>= ioErrorMessage) `shouldBe` Just "payload released"
  ioErrorMessage exited `shouldBe` Just "payload released"
  labelsOf (cleanupFailures exited) `shouldBe` ["payload"]
  -- The retained token and the failure it stores keep no payload reachable.
  reachablePayloads weaks `shouldReturn` 0

testBoundedBookkeeping ∷ Expectation
testBoundedBookkeeping = do
  weaks ← newIORef []
  tokens ←
    withOwned 1 $ \collection → do
      tokens ← forM [1 ∷ Int .. 200] $ \_ → do
        member ← acquireMember collection (observedPayload weaks)
        withMember collection member (\_ → pure ())
        retireMember collection member `shouldReturn` Retired
        liveMemberCount collection `shouldReturn` 0
        pure member
      -- Every payload opened so far is unreachable while the owner is live.
      reachablePayloads weaks `shouldReturn` 0
      length <$> readIORef weaks `shouldReturn` 200
      pure tokens
  forM_ tokens $ \member → isRetired <$> memberStatus member `shouldReturn` True

-- Cleanup failures -----------------------------------------------------------

testCaughtRetirementFailureFailsExit ∷ Expectation
testCaughtRetirementFailureFailsExit = do
  events ← newTrail
  caughtSlot ← newEmptyMVar
  exited ←
    expectFailure $
      withOwned 3 $ \collection → do
        first ← acquireMember collection (tracked events "first")
        broken ← acquireMember collection (failing events "broken")
        _ ← acquireMember collection (tracked events "last")
        expectFailure (retireMember collection broken) >>= putMVar caughtSlot
        rejectedWith OwnedPoisoned (acquireMember collection (tracked events "refused"))
        withMember collection first pure `shouldReturn` "first"
  caught ← takeMVar caughtSlot
  ioErrorMessage exited `shouldBe` Just "broken released"
  map cleanupFailureId (cleanupFailures exited)
    `shouldBe` map cleanupFailureId (cleanupFailures caught)
  trail events
    `shouldReturn` [ "acquire first"
                   , "acquire broken"
                   , "acquire last"
                   , "release broken"
                   , "release last"
                   , "release first"
                   ]

testBodyFailureStaysPrimary ∷ Expectation
testBodyFailureStaysPrimary = do
  events ← newTrail
  exited ←
    expectFailure $
      withOwned 3 $ \collection → do
        _ ← acquireMember collection (tracked events "first")
        early ← acquireMember collection (failing events "early")
        _ ← acquireMember collection (failing events "final")
        void (expectFailure (retireMember collection early))
        throwIO (ErrorCall "body failed") ∷ IO ()
  errorCallMessage exited `shouldBe` Just "body failed"
  labelsOf (cleanupFailures exited) `shouldBe` ["early", "final"]
  trail events
    `shouldReturn` [ "acquire first"
                   , "acquire early"
                   , "acquire final"
                   , "release early"
                   , "release final"
                   , "release first"
                   ]

testCancelledBodyStaysPrimary ∷ Expectation
testCancelledBodyStaysPrimary = do
  events ← newTrail
  waiting ← newEmptyMVar
  neverFilled ← newEmptyMVar
  (owner, outcome) ← forkOwner $
    withOwned 2 $ \collection → do
      _ ← acquireMember collection (tracked events "first")
      early ← acquireMember collection (failing events "early")
      void (expectFailure (retireMember collection early))
      putMVar waiting ()
      takeMVar neverFilled
  takeMVar waiting
  killThread owner
  takeMVar outcome >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → do
      fromException propagated `shouldBe` Just ThreadKilled
      labelsOf (cleanupFailures propagated) `shouldBe` ["early"]
      trail events
        `shouldReturn` ["acquire first", "acquire early", "release early", "release first"]

-- | An assembly whose only part's release throws, followed by a failing stage.
failingRollback ∷ Trail → Assembly Text
failingRollback events = do
  _ ← failing events "rolled"
  restoredStep (throwIO (ErrorCall "construction failed") ∷ IO ())
  pure "never"

testRollbackFailurePoisons ∷ Expectation
testRollbackFailurePoisons = do
  events ← newTrail
  caughtSlot ← newEmptyMVar
  exited ←
    expectFailure $
      withOwned 3 $ \collection → do
        live ← acquireMember collection (tracked events "live")
        caught ← expectFailure (acquireMember collection (failingRollback events))
        errorCallMessage caught `shouldBe` Just "construction failed"
        labelsOf (cleanupFailures caught) `shouldBe` ["rolled"]
        putMVar caughtSlot caught
        liveMemberCount collection `shouldReturn` 1
        rejectedWith OwnedPoisoned (acquireMember collection (tracked events "refused"))
        -- Unaffected members stay borrowable and retirable.
        withMember collection live pure `shouldReturn` "live"
        retireMember collection live `shouldReturn` Retired
  caught ← takeMVar caughtSlot
  -- The body succeeded, so the earliest latched cleanup failure is primary.
  ioErrorMessage exited `shouldBe` Just "rolled released"
  map cleanupFailureId (cleanupFailures exited)
    `shouldBe` map cleanupFailureId (cleanupFailures caught)
  trail events
    `shouldReturn` ["acquire live", "acquire rolled", "release rolled", "release live"]

testRollbackFailureUnderBodyFailure ∷ Expectation
testRollbackFailureUnderBodyFailure = do
  events ← newTrail
  exited ←
    expectFailure $
      withOwned 2 $ \collection → do
        _ ← acquireMember collection (tracked events "live")
        void (expectFailure (acquireMember collection (failingRollback events)))
        throwIO (ErrorCall "body failed") ∷ IO ()
  errorCallMessage exited `shouldBe` Just "body failed"
  labelsOf (cleanupFailures exited) `shouldBe` ["rolled"]
  trail events
    `shouldReturn` ["acquire live", "acquire rolled", "release rolled", "release live"]

-- | A two-part member whose declared release order is the reverse of the
-- order its parts were acquired in.
ranked ∷ Trail → Text → Assembly ()
ranked events name = do
  _ ← part "first" 1
  _ ← part "second" 0
  pure ()
  where
    part suffix rank =
      acquirePart
        (name <> "." <> suffix)
        (releaseRank rank)
        (record events ("acquire " <> name <> "." <> suffix))
        (\_ → record events ("release " <> name <> "." <> suffix))

testExitOrderWithRanks ∷ Expectation
testExitOrderWithRanks = do
  events ← newTrail
  withOwned 2 $ \collection → do
    _ ← acquireMember collection (ranked events "one")
    _ ← acquireMember collection (ranked events "two")
    pure ()
  trail events
    `shouldReturn` [ "acquire one.first"
                   , "acquire one.second"
                   , "acquire two.first"
                   , "acquire two.second"
                   , "release two.second"
                   , "release two.first"
                   , "release one.second"
                   , "release one.first"
                   ]

testFinalReleaseFailures ∷ Expectation
testFinalReleaseFailures = do
  events ← newTrail
  exited ←
    expectFailure $
      withOwned 3 $ \collection → do
        _ ← acquireMember collection (failing events "oldest")
        _ ← acquireMember collection (tracked events "middle")
        _ ← acquireMember collection (failing events "newest")
        pure ()
  ioErrorMessage exited `shouldBe` Just "newest released"
  labelsOf (cleanupFailures exited) `shouldBe` ["newest", "oldest"]
  trail events
    `shouldReturn` [ "acquire oldest"
                   , "acquire middle"
                   , "acquire newest"
                   , "release newest"
                   , "release middle"
                   , "release oldest"
                   ]

-- Capability -----------------------------------------------------------------

-- | The five operations a collection offers, presented by the calling thread
-- against an existing live member of the same collection, with the rejection
-- each produced. A rejected operation must have run nothing.
refusedOperations ∷ Trail → Owned → Member Text → IO [Maybe OwnedCollectionError]
refusedOperations events collection existing =
  sequence
    [ rejection (acquireMember collection (tracked events "refused"))
    , rejection (acquireMemberThen collection (tracked events "refused") (\_ → record events "handed"))
    , rejection (withMember collection existing (\_ → record events "borrowed"))
    , rejection (retireMember collection existing)
    , rejection (liveMemberCount collection)
    ]

-- | Run @action@ on a thread of its own and return what it returned, raising
-- what it raised.
onThread ∷ IO a → IO a
onThread action = do
  slot ← newEmptyMVar
  _ ← forkIO (try action >>= putMVar slot)
  takeMVar slot >>= either (\failure → throwIO (failure ∷ SomeException)) pure

testMissingCapability ∷ Expectation
testMissingCapability = do
  events ← newTrail
  withOwned 2 $ \owned@(Owned collection _) → do
    existing ← acquireMember owned (tracked events "existing")
    let missing = Owned collection noCapability
    refusedOperations events missing existing `shouldReturn` replicate 5 (Just CapabilityMissing)
    trail events `shouldReturn` ["acquire existing"]
    liveMemberCount owned `shouldReturn` 1
    isLive <$> memberStatus existing `shouldReturn` True

testForeignCapability ∷ Expectation
testForeignCapability = do
  events ← newTrail
  withOwned 2 $ \owned@(Owned collection _) →
    withOwned 2 $ \(Owned _ otherCapability) → do
      existing ← acquireMember owned (tracked events "existing")
      let impostor = Owned collection otherCapability
      refusedOperations events impostor existing `shouldReturn` replicate 5 (Just CapabilityForeign)
      trail events `shouldReturn` ["acquire existing"]
      liveMemberCount owned `shouldReturn` 1

testStaleCapability ∷ Expectation
testStaleCapability = do
  events ← newTrail
  kept ← newEmptyMVar
  withOwned 2 $ \owned@(Owned collection capability) → do
    existing ← acquireMember owned (tracked events "existing")
    lendCapability capability $ \lent → do
      putMVar kept lent
      let lendee = Owned collection lent
      -- The lent capability serves every operation while the lending lasts.
      member ← acquireMember lendee (tracked events "lent")
      withMember lendee member pure `shouldReturn` "lent"
      liveMemberCount lendee `shouldReturn` 2
      retireMember lendee member `shouldReturn` Retired
    lent ← takeMVar kept
    refusedOperations events (Owned collection lent) existing
      `shouldReturn` replicate 5 (Just CapabilityStale)
    trail events `shouldReturn` ["acquire existing", "acquire lent", "release lent"]
    -- The capability it was lent from is untouched.
    withMember owned existing pure `shouldReturn` "existing"

testRevokedOnFailure ∷ Expectation
testRevokedOnFailure = do
  events ← newTrail
  kept ← newEmptyMVar
  withOwned 2 $ \owned@(Owned collection capability) → do
    existing ← acquireMember owned (tracked events "existing")
    propagated ←
      expectFailure . lendCapability capability $ \lent →
        putMVar kept lent *> throwIO (ErrorCall "lending failed") ∷ IO ()
    errorCallMessage propagated `shouldBe` Just "lending failed"
    lent ← takeMVar kept
    refusedOperations events (Owned collection lent) existing
      `shouldReturn` replicate 5 (Just CapabilityStale)
    trail events `shouldReturn` ["acquire existing"]

testRevokedOnCancellation ∷ Expectation
testRevokedOnCancellation = do
  events ← newTrail
  kept ← newEmptyMVar
  lending ← newEmptyMVar
  neverFilled ← newEmptyMVar
  cancelled ← newEmptyMVar
  withOwned 2 $ \owned@(Owned collection capability) → do
    existing ← acquireMember owned (tracked events "existing")
    borrower ←
      forkIO $
        try (lendCapability capability (\lent → putMVar kept lent *> putMVar lending () *> takeMVar neverFilled))
          >>= putMVar cancelled
    takeMVar lending
    killThread borrower
    takeMVar cancelled >>= \case
      Left ThreadKilled → pure ()
      Left other → throwIO other
      Right () → expectationFailure "the lending was not cancelled"
    lent ← takeMVar kept
    refusedOperations events (Owned collection lent) existing
      `shouldReturn` replicate 5 (Just CapabilityStale)

testLendRefusals ∷ Expectation
testLendRefusals = do
  ran ← newIORef False
  withOwned 1 $ \(Owned _ capability) → do
    kept ← newEmptyMVar
    lendCapability capability (putMVar kept)
    stale ← takeMVar kept
    forM_ [(noCapability, CapabilityMissing), (stale, CapabilityStale)] $ \(presented, expected) →
      rejectedWith expected (lendCapability presented (\_ → writeIORef ran True))
  readIORef ran `shouldReturn` False

testLentOnOtherThread ∷ Expectation
testLentOnOtherThread = do
  events ← newTrail
  withOwned 2 $ \owned@(Owned collection capability) → do
    (member, lent) ← lendCapability capability $ \lent → do
      let lendee = Owned collection lent
      member ← onThread (acquireMember lendee (tracked events "elsewhere"))
      withMember lendee member pure `shouldReturn` "elsewhere"
      pure (member, lent)
    -- Once the lending has ended it is refused on every thread, while the
    -- member it acquired is the collection's, and the owner's capability
    -- retires it.
    rejection (onThread (retireMember (Owned collection lent) member))
      `shouldReturn` Just CapabilityStale
    isLive <$> memberStatus member `shouldReturn` True
    retireMember owned member `shouldReturn` Retired
  trail events `shouldReturn` ["acquire elsewhere", "release elsewhere"]

testCapabilityAcrossThreads ∷ Expectation
testCapabilityAcrossThreads = do
  events ← newTrail
  withOwned 3 $ \owned → do
    (first, second) ←
      onThread $
        (,) <$> acquireMember owned (tracked events "first") <*> acquireMember owned (tracked events "second")
    withMember owned first pure `shouldReturn` "first"
    retireMember owned first `shouldReturn` Retired
    onThread (retireMember owned second) `shouldReturn` Retired
    liveMemberCount owned `shouldReturn` 0
  trail events
    `shouldReturn` ["acquire first", "acquire second", "release first", "release second"]

-- Serialization --------------------------------------------------------------

-- | Hold the collection busy on a second thread with @busy@, which signals
-- through @inside@ once it is inside and waits on @proceed@, and present every
-- operation from this thread meanwhile. Returns the rejections and what the
-- busy operation returned.
refusedWhileBusy
  ∷ Trail
  → Owned
  → Member Text
  → MVar ()
  → MVar ()
  → IO a
  → IO ([Maybe OwnedCollectionError], a)
refusedWhileBusy events collection existing inside proceed busy = do
  finished ← newEmptyMVar
  _ ← forkIO (try busy >>= putMVar finished)
  takeMVar inside
  refused ← refusedOperations events collection existing
  putMVar proceed ()
  outcome ← takeMVar finished >>= either (\failure → throwIO (failure ∷ SomeException)) pure
  pure (refused, outcome)

testConcurrentBorrow ∷ Expectation
testConcurrentBorrow = do
  events ← newTrail
  inside ← newEmptyMVar
  proceed ← newEmptyMVar
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    borrowed ← acquireMember collection (tracked events "borrowed")
    (refused, value) ←
      refusedWhileBusy events collection existing inside proceed $
        withMember collection borrowed $ \held → do
          record events "borrow begins"
          putMVar inside ()
          takeMVar proceed
          record events "borrow ends"
          pure held
    -- One operation proceeded, undisturbed; the other was refused before any
    -- effect.
    refused `shouldBe` replicate 5 (Just ConcurrentPresentation)
    value `shouldBe` "borrowed"
    trail events
      `shouldReturn` ["acquire existing", "acquire borrowed", "borrow begins", "borrow ends"]
    -- Once it has finished, the same operations are admitted.
    liveMemberCount collection `shouldReturn` 2
    retireMember collection borrowed `shouldReturn` Retired

testConcurrentAcquisition ∷ Expectation
testConcurrentAcquisition = do
  events ← newTrail
  inside ← newEmptyMVar
  proceed ← newEmptyMVar
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    (refused, member) ←
      refusedWhileBusy events collection existing inside proceed $
        acquireMember collection $
          acquirePart
            "slow"
            (releaseRank 0)
            (record events "acquire slow" *> putMVar inside () *> takeMVar proceed *> pure ("slow" ∷ Text))
            (\_ → record events "release slow")
    refused `shouldBe` replicate 5 (Just ConcurrentPresentation)
    isLive <$> memberStatus member `shouldReturn` True
    liveMemberCount collection `shouldReturn` 2
  trail events
    `shouldReturn` ["acquire existing", "acquire slow", "release slow", "release existing"]

testConcurrentRetirement ∷ Expectation
testConcurrentRetirement = do
  events ← newTrail
  inside ← newEmptyMVar
  proceed ← newEmptyMVar
  withOwned 3 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    blocking ←
      acquireMember collection $
        acquirePart
          "blocking"
          (releaseRank 0)
          (record events "acquire blocking" *> pure ("blocking" ∷ Text))
          (\_ → record events "release begins" *> putMVar inside () *> takeMVar proceed *> record events "release ends")
    (refused, retirement) ←
      refusedWhileBusy events collection existing inside proceed (retireMember collection blocking)
    refused `shouldBe` replicate 5 (Just ConcurrentPresentation)
    retirement `shouldBe` Retired
    isRetired <$> memberStatus blocking `shouldReturn` True
    liveMemberCount collection `shouldReturn` 1
  performed ← trail events
  performed
    `shouldBe` [ "acquire existing"
               , "acquire blocking"
               , "release begins"
               , "release ends"
               , "release existing"
               ]
  occurrences "release begins" performed `shouldBe` 1

testSerializedAcrossCapabilities ∷ Expectation
testSerializedAcrossCapabilities = do
  events ← newTrail
  inside ← newEmptyMVar
  proceed ← newEmptyMVar
  withOwned 2 $ \owned@(Owned collection capability) → do
    existing ← acquireMember owned (tracked events "existing")
    lendCapability capability $ \lent → do
      (refused, _) ←
        refusedWhileBusy events (Owned collection lent) existing inside proceed $
          withMember owned existing $ \_ → putMVar inside () *> takeMVar proceed
      -- The gate belongs to the collection, not to a capability.
      refused `shouldBe` replicate 5 (Just ConcurrentPresentation)
      liveMemberCount (Owned collection lent) `shouldReturn` 1
    trail events `shouldReturn` ["acquire existing"]

testNestedCallsOnTheRunningThread ∷ Expectation
testNestedCallsOnTheRunningThread = do
  events ← newTrail
  let sawLive label collection =
        liveMemberCount collection >>= record events . ((label <> " saw ") <>) . Text.pack . show
  withOwned 2 $ \collection → do
    existing ← acquireMember collection (tracked events "existing")
    _ ← acquireMember collection $ do
      value ← tracked events "outer"
      restoredStep (sawLive "assembly" collection)
      pure value
    withMember collection existing $ \_ → sawLive "borrow" collection
  trail events
    `shouldReturn` [ "acquire existing"
                   , "acquire outer"
                   , "assembly saw 1"
                   , "borrow saw 2"
                   , "release outer"
                   , "release existing"
                   ]

-- Scope exit -----------------------------------------------------------------

-- | Wait until @target@ is blocked in a transaction, which is where a scope's
-- exit waits for the operation inside the collection.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM target = do
  status ← threadStatus target
  case status of
    ThreadBlocked BlockedOnSTM → pure ()
    ThreadFinished → expectationFailure "the scope finished without waiting for the operation inside"
    ThreadDied → expectationFailure "the scope died without waiting for the operation inside"
    _ → yield *> awaitBlockedOnSTM target

-- | A scope whose body has returned while a second thread is still inside the
-- collection, so that the scope's exit is waiting for it.
data Racing a = Racing
  { racingOwner ∷ ThreadId
  , racingOutcome ∷ MVar (Either SomeException ())
  , racingCollection ∷ Owned
  , racingSetup ∷ a
  , racingProceed ∷ MVar ()
  , racingInflight ∷ MVar (Either SomeException ())
  }

-- | Enter a scope of @limit@ members on a thread of its own and prepare it with
-- @setup@. The body then starts @inflight@ on a second thread, which signals
-- through its first barrier once it is inside the collection and waits on its
-- second, and returns. This returns once the exit is waiting.
racingExit
  ∷ Int
  → (Owned → MVar () → MVar () → IO a)
  → (Owned → a → MVar () → MVar () → IO ())
  → IO (Racing a)
racingExit limit setup inflight = do
  handed ← newEmptyMVar
  inside ← newEmptyMVar
  proceed ← newEmptyMVar
  finished ← newEmptyMVar
  (owner, outcome) ← forkOwner . withOwned limit $ \collection → do
    prepared ← setup collection inside proceed
    putMVar handed (collection, prepared)
    _ ← forkIO (try (inflight collection prepared inside proceed) >>= putMVar finished)
    takeMVar inside
  (collection, prepared) ← takeMVar handed
  awaitBlockedOnSTM owner
  pure (Racing owner outcome collection prepared proceed finished)

-- | Release the operation inside and require both threads to end without
-- failing.
finishRacing ∷ Racing a → IO ()
finishRacing race = do
  putMVar (racingProceed race) ()
  takeMVar (racingOutcome race) >>= either throwIO pure
  takeMVar (racingInflight race) >>= either throwIO pure

-- | The member a race's scope was prepared with.
preparedMember ∷ Trail → Owned → MVar () → MVar () → IO (Member Text)
preparedMember events collection _ _ = acquireMember collection (tracked events "member")

-- | Require that, while the exit waits, nothing new is admitted from any thread
-- and nothing has run.
requireExitWaiting ∷ Trail → Race' → [Text] → Expectation
requireExitWaiting events (collection, member) before = do
  refusedOperations events collection member `shouldReturn` replicate 5 (Just (OwnedReentered Closing))
  isLive <$> memberStatus member `shouldReturn` True
  trail events `shouldReturn` before

-- | What 'requireExitWaiting' needs of a race.
type Race' = (Owned, Member Text)

testExitWaitsForBorrow ∷ Expectation
testExitWaitsForBorrow = do
  events ← newTrail
  race ←
    racingExit 2 (preparedMember events) $ \collection member inside proceed →
      withMember collection member $ \_ → do
        record events "borrow begins"
        putMVar inside ()
        takeMVar proceed
        record events "borrow ends"
  requireExitWaiting events (racingCollection race, racingSetup race) ["acquire member", "borrow begins"]
  finishRacing race
  -- The borrow ended before the member was released.
  trail events
    `shouldReturn` ["acquire member", "borrow begins", "borrow ends", "release member"]
  rejectedWith OwnedClosed (liveMemberCount (racingCollection race))

testExitWaitsForAcquisition ∷ Expectation
testExitWaitsForAcquisition = do
  events ← newTrail
  race ←
    racingExit 2 (preparedMember events) $ \collection _ inside proceed →
      void . acquireMember collection $
        acquirePart
          "slow"
          (releaseRank 0)
          (record events "acquire slow" *> putMVar inside () *> takeMVar proceed *> pure ("slow" ∷ Text))
          (\_ → record events "release slow")
  requireExitWaiting events (racingCollection race, racingSetup race) ["acquire member", "acquire slow"]
  finishRacing race
  -- The acquisition completed and registered before anything was released, so
  -- the exit released it, newest first.
  trail events
    `shouldReturn` ["acquire member", "acquire slow", "release slow", "release member"]

testExitWaitsForHandoff ∷ Expectation
testExitWaitsForHandoff = do
  events ← newTrail
  race ←
    racingExit 2 (preparedMember events) $ \collection _ inside proceed →
      acquireMemberThen collection (tracked events "late") $ \_ → uninterruptibleMask_ $ do
        record events "handoff begins"
        putMVar inside ()
        takeMVar proceed
        record events "handoff ends"
  requireExitWaiting events (racingCollection race, racingSetup race) ["acquire member", "acquire late", "handoff begins"]
  finishRacing race
  trail events
    `shouldReturn` [ "acquire member"
                   , "acquire late"
                   , "handoff begins"
                   , "handoff ends"
                   , "release late"
                   , "release member"
                   ]

testExitWaitsForRetirement ∷ Expectation
testExitWaitsForRetirement = do
  events ← newTrail
  race ←
    racingExit
      2
      ( \collection inside proceed →
          acquireMember collection $
            acquirePart
              "member"
              (releaseRank 0)
              (record events "acquire member" *> pure "member")
              ( \_ → do
                  record events "release begins"
                  putMVar inside ()
                  takeMVar proceed
                  record events "release ends"
              )
      )
      (\collection member _ _ → void (retireMember collection member))
  -- The member is already claimed by the retirement, so the exit has nothing of
  -- it to release.
  refusedOperations events (racingCollection race) (racingSetup race)
    `shouldReturn` replicate 5 (Just (OwnedReentered Closing))
  trail events `shouldReturn` ["acquire member", "release begins"]
  finishRacing race
  performed ← trail events
  performed `shouldBe` ["acquire member", "release begins", "release ends"]
  isRetired <$> memberStatus (racingSetup race) `shouldReturn` True

testExitCancelledWhileWaiting ∷ Expectation
testExitCancelledWhileWaiting = do
  events ← newTrail
  race ←
    racingExit 2 (preparedMember events) $ \collection member inside proceed →
      withMember collection member $ \_ → do
        record events "borrow begins"
        putMVar inside ()
        takeMVar proceed
        record events "borrow ends"
  killer ← forkIO (throwTo (racingOwner race) ThreadKilled)
  awaitPendingThrow killer
  -- The cancellation is queued against the scope, which is still waiting: the
  -- member has not been released under the borrow.
  trail events `shouldReturn` ["acquire member", "borrow begins"]
  isLive <$> memberStatus (racingSetup race) `shouldReturn` True
  putMVar (racingProceed race) ()
  takeMVar (racingInflight race) >>= either throwIO pure
  takeMVar (racingOutcome race) >>= \case
    Right () → expectationFailure "expected the cancellation to propagate"
    Left propagated → fromException propagated `shouldBe` Just ThreadKilled
  trail events
    `shouldReturn` ["acquire member", "borrow begins", "borrow ends", "release member"]

testExitAfterFailingOperation ∷ Expectation
testExitAfterFailingOperation = do
  events ← newTrail
  race ←
    racingExit 2 (preparedMember events) $ \collection member inside proceed →
      withMember collection member $ \_ → do
        record events "borrow begins"
        putMVar inside ()
        takeMVar proceed
        throwIO (ErrorCall "borrow failed")
  putMVar (racingProceed race) ()
  takeMVar (racingOutcome race) >>= either throwIO pure
  takeMVar (racingInflight race) >>= \case
    Right () → expectationFailure "expected the borrow's failure"
    Left failure → errorCallMessage failure `shouldBe` Just "borrow failed"
  -- The failed operation left the collection, so the exit went on and released.
  trail events `shouldReturn` ["acquire member", "borrow begins", "release member"]
