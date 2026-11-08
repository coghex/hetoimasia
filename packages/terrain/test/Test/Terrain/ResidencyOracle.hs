-- | A brute-force oracle for the model's admission decisions.
--
-- Given a model and an explicit request (a query for regions, or a whole-cell
-- removal), 'oracle' says what class the answer must be: admitted, busy,
-- permanently invalid, or (for a removal) retained edits exhausted. It uses only
-- what the model exposes for observation (its regions, jobs, interests, holds,
-- requests and limits) and the contract's charge table restated here by hand; it
-- shares no code with the admission path.
--
-- The decisions it checks:
--
-- * __never permanently invalid for capacity__: the configuration was validated
--   against the worst-case footprint of the largest admissible request, so a
--   well-formed request within its caps is admitted or busy (or, for a removal,
--   retained-edit exhaustion), whatever the state. The oracle never expects an
--   invalid answer for one;
-- * __admitted__ exactly when every slot and bank has room and the resident
--   shortfall can be covered by some set of evictable regions, found here by
--   trying /every subset/ of them (not by the model's least-recently-used walk);
-- * __busy__ otherwise.
module Test.Terrain.ResidencyOracle
  ( Verdict (..)
  , oracle
  ) where

import Data.List (subsequences)
import Data.Maybe (isJust, isNothing)
import Hetoimasia.Terrain.Residency
import Test.Terrain.ResidencySupport (Ledgers (..), independentLedgers)

-- | 'Never' is the answer "invalid": no verdict of the oracle is ever 'Never'; it
-- names the class of a model answer that must not occur for such a request.
data Verdict = Admit | NotNow | Never | Exhausted
  deriving stock (Eq, Show)

-- | What the answer must be. The request must otherwise be well formed: a live
-- arena at its current revision, a new request identity, a nonempty set of distinct
-- supported regions within the demand limit.
oracle ∷ Model → ArenaId → [RegionDemand] → Bool → Verdict
oracle m arena demands removal
  | any evicting demands = NotNow
  | removal && editOccupied + retainedBytes > lim EditBank = Exhausted
  | commandsUsed + 1 > slot CommandSlot = NotNow
  | stagingNeed > stagingFree = NotNow
  | removal && retainedBytes > editFree = NotNow
  | shortfall > 0 && not (any (>= shortfall) subsetBytes) = NotNow
  | otherwise = Admit
  where
    limits = modelLimits m
    lim b = toInteger (limitBytes limits b)
    slot s = toInteger (limitSlot limits s)
    n = toInteger (length demands)

    -- The contract's charges, restated.
    metadata = 256
    interest = 64
    growth = if removal then 62 else 0
    removalStaging = if removal then 512 else 0
    retainedBytes = 64
    commandBytes = 128 + 32 * n

    regionOf d = case [r | r ← modelRegions m, regionArena r == arena, regionCoord r == demandRegion d] of
      (r : _) → Just r
      [] → Nothing
    evicting d = maybe False regionEvicting (regionOf d)
    residentRegion d = case regionOf d of
      Just r | not (regionEvicting r) → Just r
      _ → Nothing
    -- Coverage with an explicit "nothing" so that no empty value has to be built.
    uncoveredBy c Nothing = Just c
    uncoveredBy c (Just o) = nonEmpty (coverageDifference c o)
    nonEmpty c = if coverageIsEmpty c then Nothing else Just c

    parts d =
      let c = demandCoverage d
          res = residentRegion d
          resCov = fmap regionCoverage res
          uncovered = uncoveredBy c resCov
          prom = promisedCover d
          new = case uncovered of
            Nothing → Nothing
            Just u → uncoveredBy u prom
          old = case (uncovered, new) of
            (Nothing, _) → Nothing
            (Just u, Nothing) → Just u
            (Just u, Just nw) → nonEmpty (coverageDifference u nw)
          absent = isNothing res
          reserve = case new of
            Nothing → 0
            Just nw → (if absent then metadata else 0) + 48 * toInteger (coverageColumns nw) + 96 * toInteger (coverageSegments nw)
          promisedLeast = case old of
            Nothing → 0
            Just o → (if absent && isNothing new then metadata else 0) + 48 * toInteger (coverageColumns o) + 34 * toInteger (coverageSegments o)
          scratch = case new of
            Nothing → 0
            Just nw → 256 + 2 * toInteger (coverageCells nw)
       in (maybe 0 (toInteger . regionBytes) res, reserve, promisedLeast, scratch, isJust new)
    promisedCover d = case [jobCoverage j | j ← modelJobs m, jobArena j == arena, jobRegion j == demandRegion d, jobPhase j /= JobCancellingPhase] of
      [] → Nothing
      (c : cs) → Just (foldr coverageUnion c cs)

    ps = map parts demands
    reserveSum = sum [r | (_, r, _, _, _) ← ps]
    scratchSum = sum [s | (_, _, _, s, _) ← ps]

    ledgers = independentLedgers m
    (residentOcc, residentRes) = both (resident ledgers)
    (stagingOcc, stagingRes) = both (staging ledgers)
    (editOccupied, editReserved) = both (edit ledgers)
    both (a, b) = (toInteger a, toInteger b)

    stagingFree = lim StagingBank - stagingOcc - stagingRes
    editFree = lim EditBank - editOccupied - editReserved
    stagingNeed = interest * n + scratchSum + commandBytes + removalStaging
    commandsUsed = toInteger (length (modelRequests m))

    -- Resident funding: free bytes, then some set of regions that nothing needs.
    freeResident = lim ResidentBank - residentOcc - residentRes
    shortfall = max 0 (reserveSum + growth - freeResident)
    requested = [demandRegion d | d ← demands]
    -- A camera view's interest does not protect a region from an explicit request.
    interested r = or [True | i ← modelInterests m, interestArena i == regionArena r, interestRegion i == regionCoord r, requestOwned (interestOwner i)]
    requestOwned (OwnerRequest _) = True
    requestOwned (OwnerView _) = False
    held r = or [True | (_, a, _, regions) ← modelHolds m, a == regionArena r, regionCoord r `elem` regions]
    busyJob r = or [True | j ← modelJobs m, jobArena j == regionArena r, jobRegion j == regionCoord r]
    liveArena r = or [True | a ← modelArenas m, arenaId a == regionArena r, arenaPhase a == ArenaLive]
    evictable =
      [ toInteger (regionBytes r)
      | r ← modelRegions m
      , not (regionArena r == arena && regionCoord r `elem` requested)
      , liveArena r
      , not (regionEvicting r)
      , not (regionDirty r)
      , isNothing (regionHandoff r)
      , not (interested r)
      , not (held r)
      , not (busyJob r)
      ]
    -- Every subset of the evictable regions, exhaustively.
    subsetBytes = map sum (subsequences evictable)
