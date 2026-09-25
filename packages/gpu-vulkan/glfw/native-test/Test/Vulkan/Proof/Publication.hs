{-# LANGUAGE OverloadedRecordDot #-}

-- | How the run stops, and the one step a stop must not be taken in the middle
-- of.
--
-- The two halves belong together because each is the other's constraint. A
-- proof that breaks says which requirement it broke at rather than only that
-- it broke, so every failure becomes a named 'Stop'; and a cancellation is a
-- failure that arrives from outside, at whatever point the code happens to be
-- at, including between a native call that had an effect and the line that
-- records it.
--
-- That interval is what 'publishing' closes. The rule is the one
-- "Test.Vulkan.Proof.Ownership" states for a handle — a native call and the
-- write that hands its effect over are one step that nothing can land between
-- — applied to a result rather than to a handle. @vkQueuePresentKHR@ enqueues
-- the slot's semaphore waits and chains its present fence; the ledger entry
-- that says so is what teardown reads to learn that the presentation is owed.
-- A cancellation taken after the enqueue and before that entry leaves an
-- obligation that exists on the device and nowhere in the run's own evidence,
-- and teardown then destroys the present fence, the presentation semaphore and
-- the swapchain behind it — a use-after-free rather than a failed assertion.
--
-- The mask covers the native presentation call and the 'IORef' write that
-- records its effect. The driver may block inside that call: the binding's
-- @safe@ import does not make it interruptible or bound cancellation latency.
-- Explicit fence and acquire waits stay outside this mask with their existing
-- cancellation behaviour; they too may defer cancellation until native return.
-- No native call is made preemptible and no destroy is wrapped in a timeout.
-- 'published' takes any cancellation deferred across the handoff after the
-- effect has been recorded: at the presentation step, carrying the
-- cancellation's own failure, rather than escaping to 'catchAll' as an
-- unexpected exception.
--
-- Nothing here makes a native call, so the whole mechanism the native path
-- uses is exercised headlessly by "Test.Vulkan.Proof.PublicationSpec", with
-- the enqueue replaced by a stand-in.
module Test.Vulkan.Proof.Publication
  ( -- * Stopping
    Stop (..)
  , stop
  , require
  , catchAll

    -- * Publishing a native result before a cancellation can be taken
  , Publication (..)
  , publishing
  , published

    -- * The present handoff
  , presentationStep
  , publishPresent
  ) where

import Control.Exception
  ( Exception
  , SomeException
  , displayException
  , fromException
  , mask
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.IORef (IORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text

import Vulkan.Core10.Enums.Result (Result)
import Vulkan.Exception (VulkanException (..))

import Test.Vulkan.Proof.Findings (Failure (..))
import Test.Vulkan.Proof.Ownership (Ledger, observe)
import Test.Vulkan.Proof.Retention
  ( NativeResult
  , Observation (..)
  , SlotName
  , classifyResult
  , classifyThrown
  )

-- --------------------------------------------------------------------------
-- Stopping

newtype Stop = Stop Failure

instance Show Stop where
  show (Stop failure) = Text.unpack (failureStep failure <> ": " <> failureDetail failure)

instance Exception Stop

stop ∷ Text → Text → IO a
stop step detail = throwIO (Stop (Failure step detail))

require ∷ Text → Text → Bool → IO ()
require step detail ok = unless ok (stop step detail)

-- | Turn any escaping failure into a named stop, so a proof that breaks says
-- which requirement it broke at rather than only that it broke.
catchAll ∷ IO a → (Failure → IO a) → IO a
catchAll action handler = do
  outcome ← try action
  case outcome of
    Right value → pure value
    Left escaped
      | Just (Stop failure) ← fromException escaped → handler failure
      | Just (VulkanException result) ← fromException escaped →
          handler (Failure "a Vulkan call failed" (Text.pack (show result)))
      | otherwise →
          handler (Failure "the proof raised an unexpected exception" (Text.pack (displayException escaped)))

-- --------------------------------------------------------------------------
-- Publishing a native result

-- | What one protected handoff produced.
data Publication a = Publication
  { publicationValue ∷ a
    -- ^ Whatever the publication returned, which is what the caller was after.
    -- It exists whether or not a cancellation was waiting, because the
    -- publication ran either way — that is the whole point.
  , publicationCancellation ∷ Maybe SomeException
    -- ^ The cancellation the mask held off until the publication was complete,
    -- if one arrived. Deferred, never discarded: 'published' takes it as this
    -- step's failure, so the run stops at the step it was cancelled in and
    -- reports the cancellation itself rather than an unexpected exception
    -- raised somewhere further on.
  }

-- | Make the native presentation call and record what it did, with no point
-- between the two at which a cancellation can be taken. The driver may block
-- inside the call; its @safe@ import does not promise interruptibility or
-- bounded cancellation latency. Explicit fence and acquire waits remain
-- outside this handoff, with their cancellation behaviour unchanged.
--
-- The call's own synchronous failure is not what this is about: 'try' hands
-- that to the publication, which classifies it exactly as it classifies a
-- returned result. What the mask adds is that an asynchronous exception
-- delivered once the call has returned — when its effect exists on the device
-- and the run has not yet written it down — waits until it has been written
-- down.
--
-- 'restore' is where it then lands, rather than at some later allocation the
-- compiler chose: restoring the caller's masking state is a point at which a
-- pending exception is delivered, so the deferral ends here, inside this
-- function, where it can be reported. A caller that was itself masked has
-- nothing delivered here and nothing to report, which is correct — it asked
-- for exactly that.
publishing ∷ (Either SomeException a → IO b) → IO a → IO (Publication b)
publishing publish call = mask $ \restore → do
  outcome ← try @SomeException call
  value ← publish outcome
  deferred ← try @SomeException (restore (pure ()))
  pure
    Publication
      { publicationValue = value
      , publicationCancellation = either Just (const Nothing) deferred
      }

-- | Take what was published, or stop at this step with the cancellation the
-- handoff deferred.
--
-- The cancellation stays the run's primary failure: it is reported with its
-- own message, at the step it interrupted, and everything teardown then
-- observes is recorded beside it rather than in place of it.
published ∷ Text → Publication a → IO a
published step publication = case publication.publicationCancellation of
  Nothing → pure publication.publicationValue
  Just escaped → stop step (Text.pack (displayException escaped))

-- --------------------------------------------------------------------------
-- The present handoff

-- | The step a present that could not be completed is reported at.
presentationStep ∷ Text
presentationStep = "presentation"

-- | Enqueue one present and record the obligation it created, as one step.
--
-- The 'PresentAttempted' entry goes in first, and before anything that can
-- itself fail. A status query, an event poll, or a wait that threw between the
-- present and this line would leave the obligation unrecorded, and a present's
-- semaphore waits are enqueued whether the call reported success, out-of-date,
-- or surface-lost. Marking the slot presented here rather than after the wait
-- is the same rule: the obligation exists from the enqueue, not from its
-- retirement.
--
-- The two ways this can fail are recorded differently, because they are
-- different facts. A call that threw has no result, and
-- 'Test.Vulkan.Proof.Retention.classifyThrown' says what its exception meant —
-- the binding's own error code, or 'Test.Vulkan.Proof.Retention.NativeResult'
-- @NotAResult@ for an exception that carries none. A call that returned and
-- was then cancelled has a result, and it is that result which is recorded:
-- the cancellation happened to the run, not to the present, and writing the
-- present down as an exception would lose what the device actually reported.
publishPresent
  ∷ Ledger
  → SlotName
  → IORef Bool
  → IO Result
  → IO (Either SomeException Result, NativeResult)
publishPresent ledger slot presented enqueue =
  publishing
    ( \outcome → do
        let result = either classifyThrown classifyResult outcome
        observe ledger (PresentAttempted slot result)
        writeIORef presented True
        pure (outcome, result)
    )
    enqueue
    >>= published presentationStep
