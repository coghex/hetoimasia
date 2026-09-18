-- | Examples for the private window attachment model: exclusive attachments,
-- their authority checks, and the retirement evidence that frees a window.
--
-- The model in "Hetoimasia.GLFW.Internal.Attachment" is pure, so almost every
-- example scripts transitions directly and compares answers and models. Window
-- identities come from windows created, and released, in seam sessions; nothing
-- initializes GLFW. The one scripted owner with a publishing thread coordinates
-- through 'MVar's and STM, never a sleep.
module Test.GLFW.Attachment (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (foldM, forM, forM_, replicateM)
import Data.Unique (newUnique)
import Hetoimasia.GLFW.Internal.Attachment
import Hetoimasia.GLFW.Internal.Seam (asProcessMainThread, defaultScript, newSeam)
import Hetoimasia.GLFW.Internal.Window (windowSessionIdentity)
import Hetoimasia.GLFW.Window (WindowId, hiddenTestWindowConfig, windowIdentity, withWindow)
import Test.GLFW.Support (boundedExample, entered, unexpected)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)

type Model = AttachmentModel String

spec ∷ Spec
spec = describe "GLFW window attachment model" $ do
  describe "attaching" $ do
    it "refuses a closing, ended, unregistered, or occupied window before issuing an incarnation" $ do
      [first, second, third, unregistered] ← sessionWindows 4
      (host, model) ← hostWith 4 [first, second, third]
      (_, closing) ← accept (markWindowClosing (hostOwner host) first model)
      attachWindow (hostOwner host) (hostIdentityOf host) first closing `refusedWith` WindowIsClosing first
      (_, forgotten) ← accept (forgetWindow (hostOwner host) second model)
      attachWindow (hostOwner host) (hostIdentityOf host) second forgotten `refusedWith` WindowHasEnded second
      attachWindow (hostOwner host) (hostIdentityOf host) unregistered model `refusedWith` WindowNotRegistered unregistered
      (occupant, occupied) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) third model)
      attachWindow (hostOwner host) (hostIdentityOf host) third occupied
        `refusedWith` WindowOccupied (registeredAttachment occupant)
      -- A retiring attachment still occupies its window.
      (_, retiring) ← accept (beginRetirement (hostOwner host) (registeredAttachment occupant) (registeredAcknowledgement occupant) Detach occupied)
      attachWindow (hostOwner host) (hostIdentityOf host) third retiring
        `refusedWith` WindowOccupied (registeredAttachment occupant)
      -- No refusal consumed an incarnation: the first accepted attachment is the first issued.
      (registered, _) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) second model)
      attachmentIncarnation (registeredAttachment registered) `shouldBe` 1
      attachmentIncarnation (registeredAttachment occupant) `shouldBe` 1

    it "refuses another host, another session, or another owner's authority" $ do
      [window] ← sessionWindows 1
      [foreignWindow] ← sessionWindows 1
      (host, model) ← hostWith 2 [window]
      (other, otherModel) ← hostWith 2 [foreignWindow]
      attachWindow (hostOwner host) (hostIdentityOf other) window model `refusedWith` AttachmentMisuse ForeignHost
      attachWindow (hostOwner host) (hostIdentityOf host) foreignWindow model `refusedWith` AttachmentMisuse ForeignSession
      attachWindow (hostOwner other) (hostIdentityOf host) window model `refusedWith` AttachmentMisuse ForeignOwnerAuthority
      registerWindow (hostOwner host) foreignWindow model `refusedWith` AttachmentMisuse ForeignSession
      markWindowClosing (hostOwner other) foreignWindow model `refusedWith` AttachmentMisuse ForeignOwnerAuthority
      _ ← accept (attachWindow (hostOwner other) (hostIdentityOf other) foreignWindow otherModel)
      pure ()

    it "registers windows only in issue order and within the window limit, and forgets none still attached" $ do
      [first, second, third] ← sessionWindows 3
      (host, empty) ← hostOver 2 first
      (_, one) ← accept (registerWindow (hostOwner host) second empty)
      registerWindow (hostOwner host) first one `refusedWith` WindowHasEnded first
      registerWindow (hostOwner host) second one `refusedWith` WindowAlreadyRegistered second
      (_, two) ← accept (registerWindow (hostOwner host) third one)
      (registered, attached) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) second two)
      forgetWindow (hostOwner host) second attached `refusedWith` WindowStillAttached (registeredAttachment registered)
      windowRecordCount two `shouldBe` 2
      [a, b, c] ← sessionWindows 3
      limited ← hostOver 2 a >>= \(limitedHost, limitedEmpty) → do
        (_, m1) ← accept (registerWindow (hostOwner limitedHost) a limitedEmpty)
        (_, m2) ← accept (registerWindow (hostOwner limitedHost) b m1)
        pure (registerWindow (hostOwner limitedHost) c m2)
      limited `refusedWith` WindowLimitReached 2
      newAttachmentModel (hostIdentityOf host) (windowSessionIdentity first) 0 `shouldSatisfyLeft` (== WindowLimitBelowOne 0)

  describe "transitions" $ do
    it "publishes a capability only from a registering attachment and settles construction once" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      (registered, attached) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) window model)
      let target = registeredAttachment registered
          acknowledgement = registeredAcknowledgement registered
      statusView target attached >>= \view → do
        viewPhase view `shouldBe` AttachmentRegistering
        viewConstruction view `shouldBe` ConstructionPending
      (published, active) ← accept (constructionSucceeded (hostOwner host) target acknowledgement attached)
      publishedTarget published `shouldBe` Just target
      constructionSucceeded (hostOwner host) target acknowledgement active
        `refusedWith` ConstructionAlreadySettled Constructed
      constructionFailed (hostOwner host) target acknowledgement "late" RollbackSafe active
        `refusedWith` ConstructionAlreadySettled Constructed
      recordRetirementFact (hostOwner host) target acknowledgement CpuUseRetired active
        `refusedWith` NotRetiring AttachmentActive
      recordDisposalFailure (hostOwner host) target acknowledgement "early" active
        `refusedWith` NotRetiring AttachmentActive
      (begun, retiring) ← accept (beginRetirement (hostOwner host) target acknowledgement Detach active)
      begun `shouldBe` RetirementBegun
      (again, retiringAgain) ← accept (beginRetirement (hostOwner host) target acknowledgement Detach retiring)
      again `shouldBe` RetirementAlreadyBegun
      retiringAgain `sameModel` retiring
      statusView target retiring >>= \view → do
        viewPhase view `shouldBe` AttachmentRetiring
        viewCause view `shouldBe` Just RetiredByDetach
        viewMissing view `shouldBe` allRetirementFacts

    it "moves a registering or active attachment to retiring when its window begins closing" $ do
      [first, second] ← sessionWindows 2
      (host, model) ← hostWith 2 [first, second]
      (registering, m1) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) first model)
      (active, m2) ← activated host second m1
      (closedFirst, m3) ← accept (markWindowClosing (hostOwner host) first m2)
      closedFirst `shouldBe` WindowNowClosing (Just (registeredAttachment registering))
      (closedSecond, m4) ← accept (markWindowClosing (hostOwner host) second m3)
      closedSecond `shouldBe` WindowNowClosing (Just (registeredAttachment active))
      (closedAgain, m5) ← accept (markWindowClosing (hostOwner host) second m4)
      closedAgain `shouldBe` WindowAlreadyClosing
      m5 `sameModel` m4
      forM_ [registering, active] $ \registered →
        statusView (registeredAttachment registered) m4 >>= \view → do
          viewPhase view `shouldBe` AttachmentRetiring
          viewCause view `shouldBe` Just RetiredByWindowClosing
      -- Closing during construction: success afterwards publishes nothing.
      (superseded, m6) ←
        accept (constructionSucceeded (hostOwner host) (registeredAttachment registering) (registeredAcknowledgement registering) m4)
      superseded `shouldBe` PublicationSuperseded
      statusView (registeredAttachment registering) m6 >>= \view → do
        viewPhase view `shouldBe` AttachmentRetiring
        viewConstruction view `shouldBe` Constructed

  describe "misuse" $ do
    it "refuses the acknowledgement of another window's attachment, changing nothing" $ do
      [first, second] ← sessionWindows 2
      (host, model) ← hostWith 2 [first, second]
      (one, m1) ← retiringOn host first model
      (two, m2) ← retiringOn host second m1
      let owner = hostOwner host
          target = registeredAttachment one
          foreignAck = registeredAcknowledgement two
      recordRetirementFact owner target foreignAck CpuUseRetired m2 `refusedWith` AttachmentMisuse AcknowledgementForOtherWindow
      beginRetirement owner target foreignAck Cancel m2 `refusedWith` AttachmentMisuse AcknowledgementForOtherWindow
      recordDisposalFailure owner target foreignAck "wrong" m2 `refusedWith` AttachmentMisuse AcknowledgementForOtherWindow
      -- The earlier window's acknowledgement against the later window, too.
      recordRetirementFact owner (registeredAttachment two) (registeredAcknowledgement one) CpuUseRetired m2
        `refusedWith` AttachmentMisuse AcknowledgementForOtherWindow
      recordRetirementFact owner target (registeredAcknowledgement one) CpuUseRetired m2 `shouldSatisfyRight` const True

    it "refuses an earlier incarnation's acknowledgement or target after detach and reattach" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (earlier, m1) ← retiringOn host window model
      (retired, m2) ← recordFacts owner earlier allRetirementFacts m1
      retired `shouldBe` AttachmentNowRetired
      windowVeto window m2 `shouldBe` Right NoAttachmentVeto
      (later, m3) ← activated host window m2
      attachmentIncarnation (registeredAttachment later) `shouldBe` 2
      let stale = registeredAcknowledgement earlier
          staleTarget = registeredAttachment earlier
          current = registeredAttachment later
      -- The stale acknowledgement against the replacement.
      recordRetirementFact owner current stale CpuUseRetired m3 `refusedWith` AttachmentMisuse AcknowledgementForOtherIncarnation
      beginRetirement owner current stale Detach m3 `refusedWith` AttachmentMisuse AcknowledgementForOtherIncarnation
      constructionSucceeded owner current stale m3 `refusedWith` AttachmentMisuse AcknowledgementForOtherIncarnation
      -- The stale target while the window holds the replacement: identity
      -- mismatch takes precedence over terminal idempotence.
      recordRetirementFact owner staleTarget stale CpuUseRetired m3 `refusedWith` AttachmentMisuse ReplacedAttachment
      beginRetirement owner staleTarget stale Detach m3 `refusedWith` AttachmentMisuse ReplacedAttachment
      attachmentStatus staleTarget m3 `shouldBe` Left ReplacedAttachment
      statusView current m3 >>= \view → viewPhase view `shouldBe` AttachmentActive

    it "refuses another host's or session's identity, and an incarnation never issued" $ do
      [window] ← sessionWindows 1
      [foreignWindow] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      (other, otherModel) ← hostWith 1 [foreignWindow]
      (ours, m1) ← retiringOn host window model
      (theirs, _) ← retiringOn other foreignWindow otherModel
      let owner = hostOwner host
      -- Another host's attachment, with its own acknowledgement.
      recordRetirementFact owner (registeredAttachment theirs) (registeredAcknowledgement theirs) CpuUseRetired m1
        `refusedWith` AttachmentMisuse ForeignHost
      -- Our target with another host's acknowledgement.
      recordRetirementFact owner (registeredAttachment ours) (registeredAcknowledgement theirs) CpuUseRetired m1
        `refusedWith` AttachmentMisuse AcknowledgementForOtherHost
      -- Our authority value is the owner's alone.
      recordRetirementFact (hostOwner other) (registeredAttachment ours) (registeredAcknowledgement ours) CpuUseRetired m1
        `refusedWith` AttachmentMisuse ForeignOwnerAuthority
      -- The same host identity over another session: a violated trusted input
      -- is still caught by the session binding.
      (sameHostOwner, sameHostModel) ←
        either (unexpected . show) pure (newAttachmentModel (hostIdentityOf host) (windowSessionIdentity foreignWindow) 1)
      (_, sameHostRegistered) ← accept (registerWindow sameHostOwner foreignWindow (sameHostModel ∷ Model))
      (sessionAttachment, sameHostAttached) ←
        accept (attachWindow sameHostOwner (hostIdentityOf host) foreignWindow sameHostRegistered)
      recordRetirementFact sameHostOwner (registeredAttachment sessionAttachment) (registeredAcknowledgement ours) CpuUseRetired sameHostAttached
        `refusedWith` AttachmentMisuse AcknowledgementForOtherSession
      recordRetirementFact owner (registeredAttachment sessionAttachment) (registeredAcknowledgement sessionAttachment) CpuUseRetired m1
        `refusedWith` AttachmentMisuse ForeignSession
      -- An identity issued by a model sharing this host and session, before this model issued it.
      (_, unissued) ← hostModelFor host [window]
      recordRetirementFact owner (registeredAttachment ours) (registeredAcknowledgement ours) CpuUseRetired unissued
        `refusedWith` AttachmentMisuse UnknownAttachment

  describe "retirement evidence" $ do
    it "releases the window for no single fact, and for the full set" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      forM_ allRetirementFacts $ \fact → do
        (registered, retiring) ← retiringOn host window model
        (answer, recorded) ← recordFacts owner registered [fact] retiring
        answer `shouldBe` FactRecorded (filter (/= fact) allRetirementFacts)
        windowVeto window recorded
          `shouldBe` Right (VetoedByAttachment (registeredAttachment registered) AttachmentRetiring (filter (/= fact) allRetirementFacts))
        liveAttachmentCount recorded `shouldBe` 1
      (registered, retiring) ← retiringOn host window model
      (answer, retired) ← recordFacts owner registered allRetirementFacts retiring
      answer `shouldBe` AttachmentNowRetired
      windowVeto window retired `shouldBe` Right NoAttachmentVeto
      attachmentStatus (registeredAttachment registered) retired `shouldBe` Right AttachmentGone
      liveAttachmentCount retired `shouldBe` 0

    it "releases nothing for cancellations or disposal failures, keeping the first failure" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (registered, retiring) ← retiringOn host window model
      let target = registeredAttachment registered
          acknowledgement = registeredAcknowledgement registered
      (_, m1) ← accept (recordDisposalFailure owner target acknowledgement "first" retiring)
      (_, m2) ← accept (recordDisposalFailure owner target acknowledgement "second" m1)
      (_, m3) ← accept (beginRetirement owner target acknowledgement Cancel m2)
      (_, m4) ← accept (beginRetirement owner target acknowledgement Cancel m3)
      statusView target m4 >>= \view → do
        viewEvidence view `shouldBe` AttachmentEvidence (Just (DisposalFailure "first")) 1 2
        viewMissing view `shouldBe` allRetirementFacts
        viewCause view `shouldBe` Just RetiredByDetach
      windowVeto window m4 `shouldSatisfyRight` (/= NoAttachmentVeto)

    it "keeps a window whose scripted owner certified CPU retirement and submission completion but not presentation" $ boundedExample $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (registered, retiring) ← retiringOn host window model
      inbox ← atomically (newCompletionInbox 4) >>= either (unexpected . show) pure
      published ← newEmptyMVar
      -- A render thread publishes its two certified facts; the owner folds them.
      _ ← forkIO $ do
        admissions ← forM [CpuUseRetired, SubmittedWorkEnded] $ \fact →
          atomically (offerCompletion inbox (completionNotice (registeredAttachment registered) (registeredAcknowledgement registered) fact))
        putMVar published admissions
      takeMVar published >>= (`shouldBe` [NoticeAdmitted, NoticeAdmitted])
      notices ← atomically (takeCompletions inbox)
      let (answers, folded) = foldCompletions owner notices retiring
      map snd answers
        `shouldBe` [ Right (FactRecorded [SubmittedWorkEnded, PresentationEnded, DependentsDisposed])
                   , Right (FactRecorded [PresentationEnded, DependentsDisposed])
                   ]
      windowVeto window folded
        `shouldBe` Right (VetoedByAttachment (registeredAttachment registered) AttachmentRetiring [PresentationEnded, DependentsDisposed])
      forgetWindow owner window folded `refusedWith` WindowStillAttached (registeredAttachment registered)
      (answer, released) ← recordFacts owner registered [PresentationEnded, DependentsDisposed] folded
      answer `shouldBe` AttachmentNowRetired
      windowVeto window released `shouldBe` Right NoAttachmentVeto

    it "accepts duplicate completion idempotently, before and after retirement" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (registered, retiring) ← retiringOn host window model
      let target = registeredAttachment registered
          acknowledgement = registeredAcknowledgement registered
      (_, once) ← accept (recordRetirementFact owner target acknowledgement PresentationEnded retiring)
      (twice, again) ← accept (recordRetirementFact owner target acknowledgement PresentationEnded once)
      twice `shouldBe` FactAlreadyRecorded
      again `sameModel` once
      (_, retired) ← recordFacts owner registered allRetirementFacts once
      forM_ allRetirementFacts $ \fact → do
        (late, unchanged) ← accept (recordRetirementFact owner target acknowledgement fact retired)
        late `shouldBe` AttachmentAlreadyRetired
        unchanged `sameModel` retired
      (lateRetire, r1) ← accept (beginRetirement owner target acknowledgement Cancel retired)
      lateRetire `shouldBe` RetirementAlreadyComplete
      (lateFailure, r2) ← accept (recordDisposalFailure owner target acknowledgement "late" r1)
      lateFailure `shouldBe` FailureAfterRetirement
      (latePublish, r3) ← accept (constructionSucceeded owner target acknowledgement r2)
      latePublish `shouldBe` PublicationSuperseded
      r3 `sameModel` retired
      liveAttachmentCount r3 `shouldBe` 0

  describe "construction ownership" $ do
    it "retires a failed construction whose rollback is safe, discharging every fact" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (registered, attached) ← accept (attachWindow owner (hostIdentityOf host) window model)
      (answer, rolledBack) ←
        accept (constructionFailed owner (registeredAttachment registered) (registeredAcknowledgement registered) "no surface" RollbackSafe attached)
      answer `shouldBe` RolledBackAndRetired
      windowVeto window rolledBack `shouldBe` Right NoAttachmentVeto
      liveAttachmentCount rolledBack `shouldBe` 0
      -- The window is free for a fresh incarnation.
      (next, _) ← accept (attachWindow owner (hostIdentityOf host) window rolledBack)
      attachmentIncarnation (registeredAttachment next) `shouldBe` 2

    it "retains a failed construction whose rollback is unsafe until each fact is certified" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      (registered, attached) ← accept (attachWindow owner (hostIdentityOf host) window model)
      let target = registeredAttachment registered
          acknowledgement = registeredAcknowledgement registered
      (answer, retained) ← accept (constructionFailed owner target acknowledgement "no surface" RollbackUnsafe attached)
      answer `shouldBe` RollbackRetained allRetirementFacts
      constructionFailed owner target acknowledgement "again" RollbackSafe retained
        `refusedWith` ConstructionAlreadySettled (ConstructionFailed RollbackUnsafe)
      constructionSucceeded owner target acknowledgement retained
        `refusedWith` ConstructionAlreadySettled (ConstructionFailed RollbackUnsafe)
      (_, disposalFailed) ← accept (recordDisposalFailure owner target acknowledgement "dispose" retained)
      statusView target disposalFailed >>= \view → do
        viewPhase view `shouldBe` AttachmentRetiring
        viewCause view `shouldBe` Just RetiredByConstructionFailure
        viewEvidence view `shouldBe` AttachmentEvidence (Just (ConstructionFailure "no surface" RollbackUnsafe)) 1 0
      windowVeto window disposalFailed
        `shouldBe` Right (VetoedByAttachment target AttachmentRetiring allRetirementFacts)
      attachWindow owner (hostIdentityOf host) window disposalFailed `refusedWith` WindowOccupied target
      (released, retired) ← recordFacts owner registered allRetirementFacts disposalFailed
      released `shouldBe` AttachmentNowRetired
      windowVeto window retired `shouldBe` Right NoAttachmentVeto

    it "leaves no constructed dependent outside registration for a cancellation at each handoff" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
          identity = hostIdentityOf host
      -- Before registration: the refused or unattempted attachment left nothing.
      liveAttachmentCount model `shouldBe` 0
      windowVeto window model `shouldBe` Right NoAttachmentVeto

      -- After registration, before construction created anything.
      (beforeConstruction, a1) ← accept (attachWindow owner identity window model)
      let targetA = registeredAttachment beforeConstruction
          ackA = registeredAcknowledgement beforeConstruction
      (_, a2) ← accept (beginRetirement owner targetA ackA Cancel a1)
      recordRetirementFact owner targetA ackA DependentsDisposed a2 `refusedWith` ConstructionStillPending
      windowVeto window a2 `shouldBe` Right (VetoedByAttachment targetA AttachmentRetiring allRetirementFacts)
      (rolled, a3) ← accept (constructionFailed owner targetA ackA "cancelled" RollbackSafe a2)
      rolled `shouldBe` RolledBackAndRetired
      windowVeto window a3 `shouldBe` Right NoAttachmentVeto

      -- After construction created dependents, before publication.
      (afterConstruction, b1) ← accept (attachWindow owner identity window a3)
      let targetB = registeredAttachment afterConstruction
          ackB = registeredAcknowledgement afterConstruction
      (_, b2) ← accept (beginRetirement owner targetB ackB Cancel b1)
      (published, b3) ← accept (constructionSucceeded owner targetB ackB b2)
      published `shouldBe` PublicationSuperseded
      windowVeto window b3 `shouldBe` Right (VetoedByAttachment targetB AttachmentRetiring allRetirementFacts)
      statusView targetB b3 >>= \view → do
        viewCause view `shouldBe` Just RetiredByCancellation
        viewEvidence view `shouldBe` AttachmentEvidence Nothing 0 1
      (_, b4) ← recordFacts owner afterConstruction allRetirementFacts b3
      windowVeto window b4 `shouldBe` Right NoAttachmentVeto

      -- After publication, cancelled repeatedly.
      (afterPublication, c1) ← activated host window b4
      let targetC = registeredAttachment afterPublication
          ackC = registeredAcknowledgement afterPublication
      (_, c2) ← accept (beginRetirement owner targetC ackC Cancel c1)
      (repeated, c3) ← accept (beginRetirement owner targetC ackC Cancel c2)
      repeated `shouldBe` RetirementAlreadyBegun
      statusView targetC c3 >>= \view → viewEvidence view `shouldBe` AttachmentEvidence Nothing 0 2
      windowVeto window c3 `shouldBe` Right (VetoedByAttachment targetC AttachmentRetiring allRetirementFacts)
      (_, c4) ← recordFacts owner afterPublication allRetirementFacts c3
      windowVeto window c4 `shouldBe` Right NoAttachmentVeto
      attachmentIncarnation targetC `shouldBe` 3

  describe "windows" $ do
    it "retires one of two windows while the other's attachment still vetoes" $ do
      [first, second] ← sessionWindows 2
      (host, model) ← hostWith 2 [first, second]
      let owner = hostOwner host
      (one, m1) ← retiringOn host first model
      (two, m2) ← retiringOn host second m1
      (_, m3) ← recordFacts owner one allRetirementFacts m2
      (_, m4) ← recordFacts owner two [CpuUseRetired, SubmittedWorkEnded, DependentsDisposed] m3
      windowVeto first m4 `shouldBe` Right NoAttachmentVeto
      windowVeto second m4 `shouldBe` Right (VetoedByAttachment (registeredAttachment two) AttachmentRetiring [PresentationEnded])
      (_, m5) ← accept (forgetWindow owner first m4)
      forgetWindow owner second m5 `refusedWith` WindowStillAttached (registeredAttachment two)
      liveAttachmentCount m5 `shouldBe` 1
      windowRecordCount m5 `shouldBe` 1

    it "keeps bookkeeping equal to the live count across many attach-and-retire cycles" $ do
      [steady, cycling] ← sessionWindows 2
      (host, model) ← hostWith 2 [steady, cycling]
      let owner = hostOwner host
      (_, withSteady) ← activated host steady model
      final ← foldM (\current _ → do
        (registered, retiring) ← retiringOn host cycling current
        snd <$> recordFacts owner registered allRetirementFacts retiring) withSteady [1 ∷ Int .. 500]
      liveAttachmentCount final `shouldBe` 1
      windowRecordCount final `shouldBe` 2
      (next, _) ← accept (attachWindow owner (hostIdentityOf host) cycling final)
      attachmentIncarnation (registeredAttachment next) `shouldBe` 502
      -- Windows themselves cycle within the limit without growing the records.
      windows ← sessionWindows 40
      (windowHost, empty) ← hostOver 2 (head' windows)
      churned ← foldM (\current window → do
        (_, registered) ← accept (registerWindow (hostOwner windowHost) window current)
        (attachment, retiring) ← retiringOn windowHost window registered
        (_, retired) ← recordFacts (hostOwner windowHost) attachment allRetirementFacts retiring
        (_, closing) ← accept (markWindowClosing (hostOwner windowHost) window retired)
        snd <$> accept (forgetWindow (hostOwner windowHost) window closing)) empty windows
      windowRecordCount churned `shouldBe` 0
      liveAttachmentCount churned `shouldBe` 0
      forM_ windows $ \window →
        attachWindow (hostOwner windowHost) (hostIdentityOf windowHost) window churned `refusedWith` WindowHasEnded window

  describe "completion notices" $ do
    it "admits, coalesces, and rejects at capacity, keeping accepted notices until the owner takes them" $ do
      [first, second] ← sessionWindows 2
      (host, model) ← hostWith 2 [first, second]
      (one, m1) ← retiringOn host first model
      (two, m2) ← retiringOn host second m1
      atomically (newCompletionInbox 0) >>= (`shouldSatisfyLeft` (== InboxCapacityBelowOne 0))
      inbox ← atomically (newCompletionInbox 2) >>= either (unexpected . show) pure
      let notice registered = completionNotice (registeredAttachment registered) (registeredAcknowledgement registered)
      atomically (offerCompletion inbox (notice one CpuUseRetired)) >>= (`shouldBe` NoticeAdmitted)
      atomically (offerCompletion inbox (notice one CpuUseRetired)) >>= (`shouldBe` NoticeCoalesced)
      atomically (offerCompletion inbox (notice two CpuUseRetired)) >>= (`shouldBe` NoticeAdmitted)
      atomically (offerCompletion inbox (notice two PresentationEnded)) >>= (`shouldBe` NoticeRejectedFull)
      -- Publication changed no model; the owner's fold does.
      windowVeto first m2 `shouldBe` Right (VetoedByAttachment (registeredAttachment one) AttachmentRetiring allRetirementFacts)
      taken ← atomically (takeCompletions inbox)
      map noticeFact taken `shouldBe` [CpuUseRetired, CpuUseRetired]
      map noticeTarget taken `shouldBe` [registeredAttachment one, registeredAttachment two]
      atomically (takeCompletions inbox) >>= (`shouldBe` [])
      atomically (offerCompletion inbox (notice two PresentationEnded)) >>= (`shouldBe` NoticeAdmitted)
      let (answers, folded) = foldCompletions (hostOwner host) taken m2
      map snd answers `shouldBe` replicate 2 (Right (FactRecorded [SubmittedWorkEnded, PresentationEnded, DependentsDisposed]))
      liveAttachmentCount folded `shouldBe` 2
      -- Another owner's fold changes nothing.
      (other, _) ← hostOver 1 first
      let (foreignAnswers, unchanged) = foldCompletions (hostOwner other) taken m2
      map snd foreignAnswers `shouldBe` replicate 2 (Left (AttachmentMisuse ForeignOwnerAuthority))
      unchanged `sameModel` m2

    it "refuses a notice queued for an attachment replaced before the owner folds it" $ do
      [window] ← sessionWindows 1
      (host, model) ← hostWith 1 [window]
      let owner = hostOwner host
      inbox ← atomically (newCompletionInbox 4) >>= either (unexpected . show) pure
      (earlier, m1) ← retiringOn host window model
      _ ←
        atomically
          (offerCompletion inbox (completionNotice (registeredAttachment earlier) (registeredAcknowledgement earlier) PresentationEnded))
      -- The owner retires the earlier attachment directly and a replacement attaches.
      (_, m2) ← recordFacts owner earlier allRetirementFacts m1
      (replacement, m3) ← retiringOn host window m2
      (_, m4) ← recordFacts owner replacement [CpuUseRetired, SubmittedWorkEnded, DependentsDisposed] m3
      notices ← atomically (takeCompletions inbox)
      let (answers, folded) = foldCompletions owner notices m4
      map snd answers `shouldBe` [Left (AttachmentMisuse ReplacedAttachment)]
      folded `sameModel` m4
      windowVeto window folded
        `shouldBe` Right (VetoedByAttachment (registeredAttachment replacement) AttachmentRetiring [PresentationEnded])
      -- Once the replacement retires too, the old notice is terminal and still changes nothing.
      (_, m5) ← recordFacts owner replacement [PresentationEnded] m4
      let (lateAnswers, lateFolded) = foldCompletions owner notices m5
      map snd lateAnswers `shouldBe` [Right AttachmentAlreadyRetired]
      lateFolded `sameModel` m5
      liveAttachmentCount lateFolded `shouldBe` 0

-- ---------------------------------------------------------------------------
-- Fixtures

data Host = Host
  { hostIdentityOf ∷ HostIdentity
  , hostOwner ∷ OwnerAuthority
  }

-- | Distinct window identities from windows created, and released, in one
-- fresh seam session.
sessionWindows ∷ Int → IO [WindowId]
sessionWindows count = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session →
    replicateM count (withWindow session (hiddenTestWindowConfig "attachment" 64 48) (pure . windowIdentity))

-- | A fresh host whose model, over the session of the given window, has no
-- window registered.
hostOver ∷ Int → WindowId → IO (Host, Model)
hostOver limit window = do
  identity ← hostIdentity <$> newUnique
  (authority, empty) ← either (unexpected . show) pure (newAttachmentModel identity (windowSessionIdentity window) limit)
  pure (Host identity authority, empty)

-- | A fresh host whose model registers the given windows, of one session, in order.
hostWith ∷ Int → [WindowId] → IO (Host, Model)
hostWith limit windows = do
  (host, empty) ← hostOver limit (head' windows)
  model ← foldM (\current window → snd <$> accept (registerWindow (hostOwner host) window current)) empty windows
  pure (host, model)

head' ∷ [WindowId] → WindowId
head' = \case
  window : _ → window
  [] → error "expected a window identity"

-- | A second model for the same host and session, registering the same windows.
hostModelFor ∷ Host → [WindowId] → IO (OwnerAuthority, Model)
hostModelFor host windows = case windows of
  [] → unexpected "expected a window"
  window : _ → do
    (authority, empty) ←
      either (unexpected . show) pure (newAttachmentModel (hostIdentityOf host) (windowSessionIdentity window) (length windows))
    model ← foldM (\current registered → snd <$> accept (registerWindow authority registered current)) empty windows
    pure (authority, model)

accept ∷ Either AttachmentRefusal (r, Model) → IO (r, Model)
accept = either (\refusal → unexpected ("the transition was refused: " <> show refusal)) pure

refusedWith ∷ Either AttachmentRefusal (r, Model) → AttachmentRefusal → Expectation
refusedWith outcome expected = case outcome of
  Left refusal → refusal `shouldBe` expected
  Right _ → expectationFailure ("the transition was accepted; expected " <> show expected)

shouldSatisfyLeft ∷ Show l ⇒ Either l r → (l → Bool) → Expectation
shouldSatisfyLeft outcome predicate = case outcome of
  Left value | predicate value → pure ()
  Left value → expectationFailure ("unexpected refusal: " <> show value)
  Right _ → expectationFailure "expected a refusal"

shouldSatisfyRight ∷ Either l r → (r → Bool) → Expectation
shouldSatisfyRight outcome predicate = case outcome of
  Right value | predicate value → pure ()
  _ → expectationFailure "expected an accepted answer satisfying the predicate"

-- | The attachment a construction answer published a capability for.
publishedTarget ∷ ConstructionAnswer → Maybe AttachmentId
publishedTarget = \case
  CapabilityPublished capability → Just (activeAttachment capability)
  PublicationSuperseded → Nothing

statusView ∷ AttachmentId → Model → IO (AttachmentView String)
statusView target model = case attachmentStatus target model of
  Right (AttachmentLive view) → pure view
  other → unexpected ("expected a live attachment, got " <> show other)

-- | Attach and complete construction.
activated ∷ Host → WindowId → Model → IO (Registered, Model)
activated host window model = do
  (registered, attached) ← accept (attachWindow (hostOwner host) (hostIdentityOf host) window model)
  (published, active) ←
    accept (constructionSucceeded (hostOwner host) (registeredAttachment registered) (registeredAcknowledgement registered) attached)
  case published of
    CapabilityPublished capability | activeAttachment capability == registeredAttachment registered → pure (registered, active)
    _ → unexpected ("expected a published capability, got " <> show published)

-- | Attach, complete construction, and detach.
retiringOn ∷ Host → WindowId → Model → IO (Registered, Model)
retiringOn host window model = do
  (registered, active) ← activated host window model
  (_, retiring) ←
    accept (beginRetirement (hostOwner host) (registeredAttachment registered) (registeredAcknowledgement registered) Detach active)
  pure (registered, retiring)

-- | Record facts in order, answering the last answer.
recordFacts ∷ OwnerAuthority → Registered → [RetirementFact] → Model → IO (FactAnswer, Model)
recordFacts owner registered facts model =
  foldM
    ( \(_, current) fact →
        accept (recordRetirementFact owner (registeredAttachment registered) (registeredAcknowledgement registered) fact current)
    )
    (FactAlreadyRecorded, model)
    facts

sameModel ∷ Model → Model → Expectation
sameModel actual expected
  | actual == expected = pure ()
  | otherwise = expectationFailure "the model changed"
