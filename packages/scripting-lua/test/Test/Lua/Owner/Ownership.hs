-- | Exactly one owner per VM.
--
-- The VM's gate is mutual exclusion, so on its own it lets any thread that takes
-- it run Lua. A VM an owner constructed is stricter: it belongs to the thread
-- that runs its lifetime, and any other thread's attempt to use it or close it is
-- refused with 'VmNotOwned' before it takes the gate, which is to say before any
-- effect. These examples hold that from the three ways a VM could be reached by
-- someone else, a thread the body started, a second owner handed the first's VM,
-- and a reference that outlived the lifetime, and show each time that the rightful
-- owner goes on as if nothing had been tried.
module Test.Lua.Owner.Ownership (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, fromException, try)
import Data.Either (isRight)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , VmClosed (VmClosed)
  , VmNotOwned (VmNotOwned)
  , chunkName
  )
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnedVm
  , OwnerConfig (ownerAfterLibraries)
  , defaultOwnerConfig
  , evalOwned
  , ownedInternalVm
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed, Open), closeVm, vmPhase)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Owner.Support
import Test.Lua.Support (newRecorder, recorded, recordingCallback)
import Test.Support.Bounded (bounded)

-- | How a refused attempt ended: the operation the refusal names.
refusedAs ∷ Either SomeException a → Either String String
refusedAs = \case
  Right _ → Left "the attempt ran"
  Left failure
    | Just (VmNotOwned operation) ← fromException failure → Right ("not owned: " <> show operation)
    | Just (VmClosed operation) ← fromException failure → Right ("closed: " <> show operation)
    | otherwise → Left ("refused otherwise: " <> show failure)

spec ∷ Spec
spec = describe "exactly one owner per VM" $ do
  it "refuses a thread the body started before any effect, and leaves the owner able to go on" $ do
    trace ← newRecorder
    let config =
          (defaultOwnerConfig [LibraryBase])
            { ownerAfterLibraries = \vm → recordingCallback vm trace "touch" >> recordingCallback vm trace "untouched"
            }
    outcome ← runOwner config $ \owned → do
      attempted ← newEmptyMVar
      _ ← forkIO (try @SomeException (evalOwned owned (chunkName "foreign") "touched = true touch()") >>= putMVar attempted)
      attempt ← bounded (takeMVar attempted)
      -- The rightful owner is unaffected, and finds nothing the attempt did.
      evalOwned owned (chunkName "owner") "if touched == nil then untouched() end"
      pure (refusedAs attempt)
    either (const Nothing) Just outcome `shouldBe` Just (Right "not owned: \"eval-chunk\"")
    recorded trace >>= (`shouldBe` ["untouched"])

  it "refuses a close asked by another thread, leaving the VM open and the one close to its owner" $ do
    outcome ← runOwner (defaultOwnerConfig [LibraryBase]) $ \owned → do
      attempted ← newEmptyMVar
      _ ← forkIO (try @SomeException (closeVm (ownedInternalVm owned)) >>= putMVar attempted)
      attempt ← bounded (takeMVar attempted)
      phase ← vmPhase (ownedInternalVm owned)
      evalOwned owned (chunkName "after") "after_the_attempt = true"
      pure (refusedAs attempt, phase)
    either (const Nothing) Just outcome `shouldBe` Just (Right "not owned: \"close-vm\"", Open)

  it "refuses a second owner handed the first's VM, for use and for close, while the first goes on" $ do
    trace ← newRecorder
    shared ← newEmptyMVar
    attempted ← newEmptyMVar
    let first =
          (defaultOwnerConfig [LibraryBase])
            { ownerAfterLibraries = \vm → recordingCallback vm trace "first_still_works"
            }
    (_, firstSlot) ← ownerThread first $ \owned → do
      putMVar shared owned
      -- The second owner has made both attempts by now.
      bounded (takeMVar attempted)
      evalOwned owned (chunkName "first") "first_still_works()"
    (_, secondSlot) ← ownerThread (defaultOwnerConfig [LibraryBase]) $ \_ → do
      handed ← bounded (takeMVar shared)
      used ← try @SomeException (evalOwned (handed ∷ OwnedVm) (chunkName "other") "stolen = true")
      closed ← try @SomeException (closeVm (ownedInternalVm handed))
      putMVar attempted ()
      pure (refusedAs used, refusedAs closed)
    secondOutcome ← bounded (takeMVar secondSlot)
    either (const Nothing) Just secondOutcome
      `shouldBe` Just (Right "not owned: \"eval-chunk\"", Right "not owned: \"close-vm\"")
    firstOutcome ← bounded (takeMVar firstSlot)
    isRight firstOutcome `shouldBe` True
    recorded trace >>= (`shouldBe` ["first_still_works"])

  it "refuses every use of a reference that outlived the lifetime with VmClosed, from any thread" $ do
    escaped ← runOwner (defaultOwnerConfig [LibraryBase]) pure
    case escaped of
      Left failure → expectationFailure ("the lifetime failed: " <> show (causeOf failure ∷ Maybe VmClosed))
      Right owned → do
        vmPhase (ownedInternalVm owned) >>= (`shouldBe` Closed)
        here ← try @SomeException (evalOwned owned (chunkName "late") "late = true")
        refusedAs here `shouldBe` Right "closed: \"eval-chunk\""
        there ← newEmptyMVar
        _ ← forkIO (try @SomeException (evalOwned owned (chunkName "late") "late = true") >>= putMVar there)
        elsewhere ← bounded (takeMVar there)
        refusedAs elsewhere `shouldBe` Right "closed: \"eval-chunk\""
        -- A close of a closed VM is no close at all, from any thread.
        closeVm (ownedInternalVm owned)
