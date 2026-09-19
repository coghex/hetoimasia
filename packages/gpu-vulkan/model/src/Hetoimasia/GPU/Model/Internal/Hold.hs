-- | The hold ledger: what is still owed on one generation or one managed
-- resource, and therefore whether it may be disposed of.
--
-- Five holds are tracked separately, because discharging one never implies
-- another. A logical release says the owner wants the object gone. Ended CPU
-- use says no retained capability can still record it. A recorded reference
-- says a batch that has not been submitted still names it. A submitted use is
-- keyed by the submission record that carries it, so a batch of several frames
-- sharing one record discharges once while separately submitted frames
-- discharge separately. A presentation obligation is keyed by its presentation
-- record, so rendering completion never recycles presentation synchronization.
--
-- An object is eligible for disposal only when every one of them has ended.
-- Nothing here decides that a hold /has/ ended: a submitted use and a
-- presentation obligation end only when the owning boundary supplies the
-- corresponding fact, and this module has no way to invent one.
module Hetoimasia.GPU.Model.Internal.Hold
  ( Holds (..)
  , newHolds
  , holdsSettled
  , outstandingHolds
  , HoldKind (..)
  , releaseLogically
  , endCpuUse
  , retainRecorded
  , dischargeRecorded
  , retainSubmitted
  , dischargeSubmitted
  , retainPresentation
  , dischargePresentation
  ) where

import qualified Data.Set as Set
import Data.Set (Set)
import Numeric.Natural (Natural)

-- | Everything still owed on one subject. The three sets hold the session-wide
-- record numbers of the batches, submissions and presentations that still name
-- the subject; the two flags hold the two facts that have no record.
data Holds = Holds
  { logicalReleased ∷ !Bool
  , cpuUseEnded ∷ !Bool
  , recordedReferences ∷ !(Set Natural)
  , submittedUses ∷ !(Set Natural)
  , presentationObligations ∷ !(Set Natural)
  }
  deriving (Eq, Show)

-- | A subject that has just been created: nothing has been released, CPU use
-- has not ended, and no record names it yet. Note that this is /not/ settled:
-- a newly created object is owed a release and an end of CPU use before it can
-- ever be disposed of.
newHolds ∷ Holds
newHolds =
  Holds
    { logicalReleased = False
    , cpuUseEnded = False
    , recordedReferences = Set.empty
    , submittedUses = Set.empty
    , presentationObligations = Set.empty
    }

-- | Which holds a subject still carries, in a fixed order.
data HoldKind
  = LogicalReleaseOwed
  | CpuUseOwed
  | RecordedReferenceOwed
  | SubmittedUseOwed
  | PresentationObligationOwed
  deriving (Eq, Ord, Show)

-- | Every hold that has not ended. Empty exactly when 'holdsSettled' holds.
outstandingHolds ∷ Holds → [HoldKind]
outstandingHolds holds =
  concat
    [ [LogicalReleaseOwed | not (logicalReleased holds)]
    , [CpuUseOwed | not (cpuUseEnded holds)]
    , [RecordedReferenceOwed | not (Set.null (recordedReferences holds))]
    , [SubmittedUseOwed | not (Set.null (submittedUses holds))]
    , [PresentationObligationOwed | not (Set.null (presentationObligations holds))]
    ]

-- | Whether every hold has ended, which is the only condition under which the
-- subject may be disposed of.
holdsSettled ∷ Holds → Bool
holdsSettled = null . outstandingHolds

releaseLogically ∷ Holds → Holds
releaseLogically holds = holds {logicalReleased = True}

endCpuUse ∷ Holds → Holds
endCpuUse holds = holds {cpuUseEnded = True}

-- | A batch that has been recorded but not submitted now names the subject.
retainRecorded ∷ Natural → Holds → Holds
retainRecorded batch holds =
  holds {recordedReferences = Set.insert batch (recordedReferences holds)}

-- | The batch was discarded, its recorder reset, or its unsubmitted work
-- abandoned. Exactly its own reference goes, and nothing else.
dischargeRecorded ∷ Natural → Holds → Holds
dischargeRecorded batch holds =
  holds {recordedReferences = Set.delete batch (recordedReferences holds)}

-- | A submission that names this subject is now outstanding. It is retained
-- before any recorded reference is discharged, so the subject is never briefly
-- unreferenced between the two.
retainSubmitted ∷ Natural → Holds → Holds
retainSubmitted submission holds =
  holds {submittedUses = Set.insert submission (submittedUses holds)}

-- | The owning boundary supplied the fact that this submission completed.
dischargeSubmitted ∷ Natural → Holds → Holds
dischargeSubmitted submission holds =
  holds {submittedUses = Set.delete submission (submittedUses holds)}

retainPresentation ∷ Natural → Holds → Holds
retainPresentation presentation holds =
  holds {presentationObligations = Set.insert presentation (presentationObligations holds)}

-- | The owning boundary supplied the fact that this presentation retired.
dischargePresentation ∷ Natural → Holds → Holds
dischargePresentation presentation holds =
  holds {presentationObligations = Set.delete presentation (presentationObligations holds)}
