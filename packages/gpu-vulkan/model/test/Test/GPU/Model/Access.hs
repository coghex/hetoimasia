-- | The ordering rules for managed resources (GRS-3): every kind's legal and
-- illegal uses and transitions, the boundary barriers a batch owes, refusal to
-- seal a batch that ends away from rest, and image initialization — refused
-- before the initializing batch is submitted, published only by a confirmed
-- submission, and left unchanged by discard, reset, skip and failure.
module Test.GPU.Model.Access (spec) where

import Data.Foldable (for_)
import Hetoimasia.GPU.Model
import Hetoimasia.GPU.Model.Access
import Hetoimasia.GPU.Model.Identity
import Test.GPU.Model.Support
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

-- | A resource, as the rules key it here.
data Key = Texture | Depth | Color | Vertex | Index | Instance | Lookup | Staging
  deriving (Eq, Ord, Show, Enum, Bounded)

kindOf ∷ Key → ResourceKind
kindOf = \case
  Texture → TextureResource
  Depth → DepthTargetResource
  Color → ColorTargetResource
  Vertex → VertexResource
  Index → IndexResource
  Instance → InstanceResource
  Lookup → LookupResource
  Staging → StagingResource

allUses ∷ [ResourceUse]
allUses = [minBound .. maxBound]

-- | Apply one step, failing the example with the refusal it got.
step ∷ (Show e) ⇒ String → Either e (BatchAccess Key, [Barrier Key]) → IO (BatchAccess Key, [Barrier Key])
step label = either (\refusal → fail (label <> " was refused: " <> show refusal)) pure

-- | The barriers, as (resource, role, after, before, discards).
shape ∷ [Barrier Key] → [(Key, BarrierRole, ResourceUse, ResourceUse, Bool)]
shape = map (\b → (barrierResource b, barrierRole b, barrierAfter b, barrierBefore b, barrierDiscards b))

spec ∷ Spec
spec = describe "access" $ do
  describe "kinds and uses" $ do
    it "rests every kind in the use the issue fixes, which is one of its legal uses" $ do
      map (restingUse . kindOf) [minBound .. maxBound]
        `shouldBe` [ShaderSampled, DepthAttachment, ColorAttachment, GeometryRead, GeometryRead, InstanceRead, StorageRead, TransferRead]
      for_ [minBound .. maxBound] $ \key →
        take 1 (legalUses (kindOf key)) `shouldBe` [restingUse (kindOf key)]

    it "gives each kind exactly the uses its usage provides for" $
      map (legalUses . kindOf) [minBound .. maxBound]
        `shouldBe` [ [ShaderSampled, TransferWrite, TransferRead]
                   , [DepthAttachment]
                   , [ColorAttachment, TransferRead]
                   , [GeometryRead, TransferWrite]
                   , [GeometryRead, TransferWrite]
                   , [InstanceRead]
                   , [StorageRead]
                   , [TransferRead]
                   ]

    it "admits every transition between two legal uses of a kind, and refuses one into or out of any other use" $
      for_ [minBound .. maxBound] $ \key → do
        let kind = kindOf key
            legalUse = (`elem` legalUses kind)
        for_ allUses $ \to → do
          -- From rest, as a first touch.
          let answer = transition key kind (FromUse (restingUse kind)) to emptyAccess
          if legalUse to
            then fmap fst answer `shouldSatisfy` either (const False) (\access → accessUse key access == Just to)
            else fmap fst answer `shouldBe` Left (UseNotLegal kind to)
          -- Out of a use the kind never takes, the source is refused first
          -- when the destination is legal.
          for_ (filter (not . legalUse) allUses) $ \from →
            if legalUse to
              then fmap fst (transition key kind (FromUse from) to emptyAccess) `shouldBe` Left (UseNotLegal kind from)
              else pure ()

    it "admits a transition from undefined contents only for an image, into a legal use" $
      for_ [minBound .. maxBound] $ \key → do
        let kind = kindOf key
        for_ (legalUses kind) $ \to →
          if isImageKind kind
            then fmap snd (transition key kind FromUndefined to emptyAccess)
              `shouldBe` Right [Barrier key kind EntryBarrier (restingUse kind) to True]
            else fmap snd (transition key kind FromUndefined to emptyAccess) `shouldBe` Left (DiscardNotLegal kind)

    it "refuses a use or transition that does not match the use the batch left the resource in" $ do
      (uploading, _) ← step "into the copy" (transition Texture TextureResource (FromUse ShaderSampled) TransferWrite emptyAccess)
      fmap snd (touch Texture TextureResource ShaderSampled KeepsContents uploading) `shouldBe` Left (UseMismatch TransferWrite ShaderSampled)
      fmap snd (transition Texture TextureResource (FromUse ShaderSampled) TransferWrite uploading) `shouldBe` Left (UseMismatch TransferWrite ShaderSampled)
      -- A first touch finds the resource at rest, never in another use.
      fmap snd (transition Color ColorTargetResource (FromUse TransferRead) ColorAttachment emptyAccess) `shouldBe` Left (UseMismatch ColorAttachment TransferRead)
      fmap snd (touch Vertex VertexResource TransferWrite KeepsContents emptyAccess) `shouldBe` Left (UseMismatch GeometryRead TransferWrite)
      -- A resource keeps the kind the batch first touched it as.
      fmap snd (touch Texture DepthTargetResource DepthAttachment KeepsContents uploading) `shouldBe` Left (KindMismatch TextureResource DepthTargetResource)

  describe "boundary barriers" $ do
    it "owes an entry barrier from rest on the first touch only, and an exit barrier back to rest for every resource touched" $ do
      (first, entered) ← step "the first touch" (touch Depth DepthTargetResource DepthAttachment KeepsContents emptyAccess)
      shape entered `shouldBe` [(Depth, EntryBarrier, DepthAttachment, DepthAttachment, False)]
      (again, nothing) ← step "the second touch" (touch Depth DepthTargetResource DepthAttachment KeepsContents first)
      nothing `shouldBe` []
      -- A first touch's transition is the entry barrier itself, from rest
      -- straight into its destination.
      (writing, barriers) ← step "into the copy" (transition Vertex VertexResource (FromUse GeometryRead) TransferWrite again)
      shape barriers `shouldBe` [(Vertex, EntryBarrier, GeometryRead, TransferWrite, False)]
      (rested, back) ← step "back to rest" (transition Vertex VertexResource (FromUse TransferWrite) GeometryRead writing)
      shape back `shouldBe` [(Vertex, TransitionBarrier, TransferWrite, GeometryRead, False)]
      fmap shape (sealAccess rested)
        `shouldBe` Right
          [ (Depth, ExitBarrier, DepthAttachment, DepthAttachment, False)
          , (Vertex, ExitBarrier, GeometryRead, GeometryRead, False)
          ]

    it "takes a same-use transition as a barrier with no layout change: the entry barrier on the first touch, and an explicit one after" $ do
      (first, entered) ← step "a pass" (transition Depth DepthTargetResource (FromUse DepthAttachment) DepthAttachment emptyAccess)
      shape entered `shouldBe` [(Depth, EntryBarrier, DepthAttachment, DepthAttachment, False)]
      (_, between) ← step "a second pass" (transition Depth DepthTargetResource (FromUse DepthAttachment) DepthAttachment first)
      shape between `shouldBe` [(Depth, TransitionBarrier, DepthAttachment, DepthAttachment, False)]

    it "makes a first touch that discards the entry barrier from undefined, and a later one an explicit transition from undefined" $ do
      (cleared, entry) ← step "a clearing pass" (touch Depth DepthTargetResource DepthAttachment DiscardsContents emptyAccess)
      shape entry `shouldBe` [(Depth, EntryBarrier, DepthAttachment, DepthAttachment, True)]
      map entryInitializes entry `shouldBe` [True]
      (_, later) ← step "cleared again from undefined" (transition Depth DepthTargetResource FromUndefined DepthAttachment cleared)
      shape later `shouldBe` [(Depth, TransitionBarrier, DepthAttachment, DepthAttachment, True)]
      map entryInitializes later `shouldBe` [False]
      fmap snd (touch Lookup LookupResource StorageRead DiscardsContents emptyAccess) `shouldBe` Left (DiscardNotLegal LookupResource)

    it "owes nothing for a batch that touched nothing" $
      fmap shape (sealAccess (emptyAccess ∷ BatchAccess Key)) `shouldBe` Right []

  describe "sealing" $ do
    it "refuses to seal a batch that ends with any resource away from rest, and never repairs the omission" $ do
      (uploading, _) ← step "into the copy" (transition Texture TextureResource FromUndefined TransferWrite emptyAccess)
      (both, _) ← step "the depth target" (touch Depth DepthTargetResource DepthAttachment KeepsContents uploading)
      fmap shape (sealAccess both) `shouldBe` Left (AwayFromRest Texture TextureResource TransferWrite)
      (rested, _) ← step "back to rest" (transition Texture TextureResource (FromUse TransferWrite) ShaderSampled both)
      fmap shape (sealAccess rested)
        `shouldBe` Right
          [ (Texture, ExitBarrier, ShaderSampled, ShaderSampled, False)
          , (Depth, ExitBarrier, DepthAttachment, DepthAttachment, False)
          ]

    it "refuses every kind left in each of its non-resting uses" $
      for_ [minBound .. maxBound] $ \key → do
        let kind = kindOf key
        for_ (drop 1 (legalUses kind)) $ \away → do
          (left, _) ← step "away" (transition key kind (FromUse (restingUse kind)) away emptyAccess)
          fmap shape (sealAccess left) `shouldBe` Left (AwayFromRest key kind away)

  describe "initialization" $ do
    it "lets only a batch that discards an image's contents touch it first, and no other batch until that one is submitted" $ do
      (model, first, second, image) ← twoFrames
      awaiting ← admitted_ "requiring initialization" (requireInitialization image model)
      resourceInitialization image awaiting `shouldBe` Just Uninitialized
      (recorded, batch) ← admitted "recording the first batch" (recordBatch first [image] awaiting)
      enterResource batch image KeepsContents recorded `shouldBeRejected` WrongPhase ResourceIdentity
      initializing ← admitted_ "initializing" (enterResource batch image DiscardsContents recorded)
      resourceInitialization image initializing `shouldBe` Just (InitializingIn batch)
      (other, otherBatch) ← admitted "recording the second batch" (recordBatch second [image] initializing)
      enterResource otherBatch image KeepsContents other `shouldBeRejected` WrongPhase ResourceIdentity
      enterResource otherBatch image DiscardsContents other `shouldBeRejected` WrongPhase ResourceIdentity
      -- Submitting the initializing batch publishes it before anything has
      -- completed; the other batch may then use it.
      (submitted, answer) ← admitted "submitting the first frame" (submitFrames [first] SubmissionAccepted other)
      answer `shouldSatisfy` recordedSubmission
      resourceInitialization image submitted `shouldBe` Just Initialized
      _ ← admitted_ "the other batch's use" (enterResource otherBatch image KeepsContents submitted)
      pure ()

    it "publishes nothing on recording, a fence reset or a no-effect failure, and publishes on the retry that is accepted" $ do
      (model, first, _, image) ← twoFrames
      awaiting ← admitted_ "requiring initialization" (requireInitialization image model)
      (recorded, batch) ← admitted "recording" (recordBatch first [image] awaiting)
      initializing ← admitted_ "initializing" (enterResource batch image DiscardsContents recorded)
      fenced ← admitted_ "resetting the fence" (resetSubmissionFence first initializing)
      resourceInitialization image fenced `shouldBe` Just (InitializingIn batch)
      (failed, answer) ← admitted "a no-effect failure" (submitFrames [first] SubmissionFailedWithoutEffect fenced)
      answer `shouldBe` AcquisitionRetained
      resourceInitialization image failed `shouldBe` Just (InitializingIn batch)
      (retried, again) ← admitted "the retry" (submitFrames [first] SubmissionAccepted failed)
      again `shouldSatisfy` recordedSubmission
      resourceInitialization image retried `shouldBe` Just Initialized

    it "publishes nothing when the submission's effect is unknown" $ do
      (model, first, _, image) ← twoFrames
      awaiting ← admitted_ "requiring initialization" (requireInitialization image model)
      (recorded, batch) ← admitted "recording" (recordBatch first [image] awaiting)
      initializing ← admitted_ "initializing" (enterResource batch image DiscardsContents recorded)
      (uncertain, answer) ← admitted "an unknown effect" (submitFrames [first] SubmissionEffectUncertain initializing)
      answer `shouldBe` EffectUncertain
      resourceInitialization image uncertain `shouldBe` Just Uninitialized

    it "leaves an image uninitialized when its initializing batch is discarded, reset or skipped, so another batch may initialize it" $ do
      (model, first, _, image) ← twoFrames
      awaiting ← admitted_ "requiring initialization" (requireInitialization image model)
      let initializingBatch current = do
            (recorded, batch) ← admitted "recording" (recordBatch first [image] current)
            initializing ← admitted_ "initializing" (enterResource batch image DiscardsContents recorded)
            pure (initializing, batch)
      (one, batch) ← initializingBatch awaiting
      discarded ← admitted_ "discarding" (discardBatch batch one)
      resourceInitialization image discarded `shouldBe` Just Uninitialized
      (two, _) ← initializingBatch discarded
      reset ← admitted_ "resetting the recorder" (resetRecorder first two)
      resourceInitialization image reset `shouldBe` Just Uninitialized
      (three, _) ← initializingBatch reset
      skipped ← admitted_ "skipping the frame" (skipUnsubmittedFrame first three)
      resourceInitialization image skipped `shouldBe` Just Uninitialized

    it "never asks anything of a resource that needs no initialization, and refuses to require it twice or after use" $ do
      (model, first, _, resource) ← twoFrames
      resourceInitialization resource model `shouldBe` Just InitializationNotRequired
      (recorded, batch) ← admitted "recording" (recordBatch first [resource] model)
      _ ← admitted_ "keeping the contents" (enterResource batch resource KeepsContents recorded)
      requireInitialization resource recorded `shouldBeRejected` WrongPhase ResourceIdentity
      awaiting ← admitted_ "requiring initialization" (requireInitialization resource model)
      requireInitialization resource awaiting `shouldBeRejected` AlreadyConsumed ResourceIdentity

    it "admits a first touch only of a resource the batch already retains" $ do
      (model, first, _, image) ← twoFrames
      (recorded, batch) ← admitted "recording" (recordBatch first [] model)
      enterResource batch image KeepsContents recorded `shouldBeRejected` WrongParent ResourceIdentity
  where
    recordedSubmission = \case
      SubmissionRecorded _ → True
      _ → False

-- | Two acquired frames of one target, and one managed resource.
twoFrames ∷ IO (GpuModel, FrameSlotId, FrameSlotId, ResourceId)
twoFrames = do
  model ← freshModel
  (active, target, _) ← activeTarget 3 model
  (one, first) ← acquiredFrame target active
  (two, second) ← acquiredFrame target one
  (withResource, resource) ← aResource 64 two
  pure (withResource, first, second, resource)

shouldBeRejected ∷ Outcome GpuModel → Misuse → Expectation
shouldBeRejected answer misuse = case answer of
  Rejected actual → actual `shouldBe` misuse
  Admitted _ → expectationFailure ("expected " <> show misuse <> ", but it was admitted")
  Backpressure kind → expectationFailure ("expected " <> show misuse <> ", but it was backpressure on " <> show kind)
