-- | How an owner is given its leases: what is refused before anything starts, and that
-- a handle serves one owner.
module Test.LuaRuntime.Instance.Lease.Configure (spec) where

import Control.Exception (SomeException, tryWithContext)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease
import Hetoimasia.Scripting.Lua.Lending (LendingRefused (LendingInUse), newLending)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Lease.Support
import Test.LuaRuntime.Support (bounded, failureOf, requiredPolicy, withBoundary)
import Test.LuaRuntime.Instance.Support (admit, awaitPhase, moduleNamed)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)

-- | What starting an owner with this specification refused it for, when it did.
refusal ∷ LuaRuntime → ScheduledSpec → IO (Maybe [LeasesViolation])
refusal runtime spec' = do
  outcome ← tryWithContext @SomeException (startScheduledOwner runtime spec')
  pure $ case outcome of
    Left failure → case failureOf failure of
      Just (LeasesRefused violations) → Just (foldr (:) [] violations)
      Nothing → Nothing
    Right _ → Nothing

spec ∷ Spec
spec = describe "giving an owner its leases" $ do
  it "refuses, before anything starts, leases on an owner that hosts no instances or lends no collection, and says so for each" $ bounded $ do
    fixture ← newLFix 4
    withBoundary $ \_ runtime → do
      let spec' = leaseSpec fixture "refused" [plain] leaseConfig requiredPolicy
      refusal runtime spec' {scheduledInstances = Nothing} >>= (`shouldBe` Just [LeasesNeedInstances])
      refusal runtime spec' {scheduledLending = Nothing} >>= (`shouldBe` Just [LeasesNeedLending])
      -- Nothing was taken: the same handles serve an owner once the specification fits.
      owner ← startLeased fixture runtime "accepted" [plain] leaseConfig requiredPolicy
      _ ← admit (lfBase fixture) owner "p" (moduleNamed "plain")
      awaitPhase (lfBase fixture) owner "p" Active
      retireScheduled owner

  it "refuses leases made over another handle than the one the owner lends through" $ bounded $ do
    fixture ← newLFix 4
    other ← newLending
    withBoundary $ \_ runtime → do
      let spec' = leaseSpec fixture "mismatch" [plain] leaseConfig requiredPolicy
      refusal runtime spec' {scheduledLending = Just other} >>= (`shouldBe` Just [LeasesLendingMismatch])

  it "refuses an owner whose collection cannot hold every instance at its capacity" $ bounded $ do
    fixture ← newLFix 4
    withBoundary $ \_ runtime → do
      let spec' = leaseSpec fixture "small" [plain] leaseConfig requiredPolicy
      -- Eight live instances at four each need thirty-two members.
      refusal runtime spec' {scheduledMemberLimit = 31} >>= (`shouldBe` Just [LeasesMembersTooFew 31 32])
      refusal runtime spec' {scheduledMemberLimit = 32} >>= (`shouldSatisfy` (== Nothing))

  it "refuses a capacity below one" $ do
    fixture ← newLFix 4
    outcome ← tryWithContext @SomeException (newLeases (lfLending fixture) 0)
    either (\failure → failureOf failure) (const Nothing) outcome
      `shouldBe` Just (LeasesRefused (CapacityBelowOne 0 :| []))

  it "serves one owner, as the lending handle it is made over does: a second is refused" $ bounded $ do
    fixture ← newLFix 4
    withBoundary $ \_ runtime → do
      owner ← startLeased fixture runtime "first" [plain] leaseConfig requiredPolicy
      -- The handle it is made over is taken with it, so a second owner cannot be given either.
      outcome ← tryWithContext @SomeException (startLeased fixture runtime "second" [plain] leaseConfig requiredPolicy)
      either failureOf (const Nothing) outcome `shouldBe` Just LendingInUse
      retireScheduled owner
