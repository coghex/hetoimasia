-- | The pure core: the world, the seeded stream, and the tick-local candidate (requirements 4, 5, 8
-- and 12). None of these examples starts an owner.
module Test.Domains.World (spec) where

import Data.Int (Int64)
import Data.Maybe (fromJust)
import qualified Data.Sequence as Seq
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains.Bounds
import Hetoimasia.Sample.LuaDomains.Candidate
import Hetoimasia.Sample.LuaDomains.Intention
import Hetoimasia.Sample.LuaDomains.World
import Test.Hspec

bounds ∷ Bounds
bounds = defaultBounds {boundStaleListed = 2}

world0 ∷ World
world0 = initialWorld bounds 7 99

intention ∷ Int → Word64 → Int64 → Int64 → Intention
intention entity version dx dy = Intention 7 0 entity version dx dy

place ∷ Word64 → Placement
place order = Placement 1 (fromIntegral order)

versionOf ∷ World → Int → Word64
versionOf world index = entityVersion (fromJust (entityAt world index))

spec ∷ Spec
spec = describe "the world, the random stream and the candidate" $ do
  describe "the world" $ do
    it "has the configured number of entities, at most the documented maximum" $ do
      Seq.length (worldEntities world0) `shouldBe` boundEntities bounds
      validateBounds bounds {boundEntities = maxEntities + 1} `shouldBe` [TooManyEntities (maxEntities + 1)]
      validateBounds bounds {boundEntities = maxEntities} `shouldBe` []
      validateBounds bounds {boundSessionTasks = maxSessionTasks + 1} `shouldBe` [TooManySessionTasks (maxSessionTasks + 1)]
      validateBounds bounds {boundSessionTasks = maxSessionTasks} `shouldBe` []

    it "changes an entity's version if and only if its position changed" $ do
      versionOf (moveEntity 0 0 0 world0) 0 `shouldBe` 0
      versionOf (moveEntity 0 1 0 world0) 0 `shouldBe` 1
      versionOf (moveEntity 0 0 (-1) (moveEntity 0 1 0 world0)) 0 `shouldBe` 2

    it "keeps an entity inside the position limit however large the delta, and leaves a move of no entity unchanged" $ do
      -- The sum is taken wide, so an extreme delta clamps and never wraps.
      mapM_
        (\(dx, dy, expected) → fmap (\entity → (entityX entity, entityY entity)) (entityAt (moveEntity 0 dx dy (moveEntity 0 positionLimit positionLimit world0)) 0) `shouldBe` Just expected)
        [ (maxBound, maxBound, (positionLimit, positionLimit))
        , (minBound, minBound, (negate positionLimit, negate positionLimit))
        , (maxBound, minBound, (positionLimit, negate positionLimit))
        ]
      let far = moveEntity 0 positionLimit 0 (moveEntity 0 positionLimit 0 world0)
      fmap entityX (entityAt far 0) `shouldBe` Just positionLimit
      moveEntity 99 1 1 world0 `shouldBe` world0

  describe "the delta bound" $ do
    it "is checked with two comparisons, so the minimum integer is outside it in either component" $ do
      let at dx dy = validate bounds (Submitted 7 0 0 0 dx dy)
          limit = fromIntegral (boundDelta bounds)
      mapM_
        (\(dx, dy) → at dx dy `shouldBe` Left RefusedDelta)
        [ (minBound, 0)
        , (0, minBound)
        , (minBound, minBound)
        , (maxBound, 0)
        , (0, maxBound)
        , (limit + 1, 0)
        , (0, negate limit - 1)
        ]
      -- The bounds themselves are in.
      fmap (\i → (intentDx i, intentDy i)) (at limit (negate limit)) `shouldBe` Right (limit, negate limit)

    it "is the same check when a move is staged: no extreme delta is staged in either component" $ do
      let candidate = beginCandidate bounds world0 1 []
          refused dx dy = either Just (const Nothing) (stage bounds (Move 0 dx dy) candidate)
      mapM_
        (\(dx, dy) → refused dx dy `shouldBe` Just StagingDelta)
        [(minBound, 0), (0, minBound), (minBound, minBound), (maxBound, 0), (0, maxBound)]
      refused 8 (-8) `shouldBe` Nothing

  describe "the random stream" $ do
    it "is SplitMix64: the first outputs of seed zero are the published ones" $ do
      let (a, s1) = nextRandom 0
          (b, s2) = nextRandom s1
          (c, _) = nextRandom s2
      (a, b, c) `shouldBe` (0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4, 0x06C45D188009454F)

    it "draws from the bound it is given, and draws nothing for a bound it does not accept" $ do
      drawBelow 0 5 `shouldBe` Nothing
      drawBelow (-1) 5 `shouldBe` Nothing
      drawBelow (randomLimit + 1) 5 `shouldBe` Nothing
      all (\seed → maybe False ((\v → v >= 0 && v < 7) . fst) (drawBelow 7 seed)) [0 .. 200] `shouldBe` True
      fmap fst (drawBelow 1 12345) `shouldBe` Just 0

  describe "the candidate" $ do
    it "applies a tick's intentions in the order of their places, before gameplay reads" $ do
      let sealed = [(place 0, intention 0 0 1 0), (place 1, intention 1 0 0 2)]
          candidate = beginCandidate bounds world0 1 sealed
      versionOf (candidateWorld candidate) 0 `shouldBe` 1
      versionOf (candidateWorld candidate) 1 `shouldBe` 1
      dispApplied (candidateDispositions candidate) `shouldBe` [place 0, place 1]
      -- The committed world is untouched.
      versionOf world0 0 `shouldBe` 0

    it "revalidates sequentially: two intentions for one entity with one version apply the first and reject the second" $ do
      let first = intention 3 0 1 0
          second = intention 3 0 0 1
          candidate = beginCandidate bounds world0 1 [(place 0, first), (place 1, second)]
          dispositions = candidateDispositions candidate
      dispApplied dispositions `shouldBe` [place 0]
      map stalePlace (dispStale dispositions) `shouldBe` [place 1]
      map staleReason (dispStale dispositions) `shouldBe` [StaleVersion]
      -- Only the first moved the entity.
      fmap (\entity → (entityX entity, entityY entity)) (entityAt (candidateWorld candidate) 3) `shouldBe` Just (entityX (fromJust (entityAt world0 3)) + 1, entityY (fromJust (entityAt world0 3)))

    it "rejects an intention of another session as stale, and one carrying an old version" $ do
      let other = (intention 0 0 1 0) {intentSession = 8}
          old = intention 1 5 1 0
          dispositions = candidateDispositions (beginCandidate bounds world0 1 [(place 0, other), (place 1, old)])
      map staleReason (dispStale dispositions) `shouldBe` [StaleSession, StaleVersion]
      dispApplied dispositions `shouldBe` []

    it "accounts for every sealed intention exactly once: applied, listed as stale or counted as omitted" $
      mapM_
        ( \count → do
            let sealed = [(place (fromIntegral n), intention (n `mod` 3) (if even n then 0 else 7) 1 0) | n ← [0 .. count - 1]]
                dispositions = candidateDispositions (beginCandidate bounds world0 1 sealed)
            length (dispApplied dispositions) + length (dispStale dispositions) + dispStaleOmitted dispositions `shouldBe` count
            -- No place appears twice among the applied and the listed stale.
            let places = dispApplied dispositions <> map stalePlace (dispStale dispositions)
            length places `shouldBe` length (foldr (\one seen → if one `elem` seen then seen else one : seen) [] places)
        )
        [0 .. 12 ∷ Int]

    it "lists at most the bound of stale rejections, earliest places first, and counts the rest" $ do
      let sealed = [(place n, intention 0 9 1 0) | n ← [0 .. 4]]
          dispositions = candidateDispositions (beginCandidate bounds world0 1 sealed)
      map stalePlace (dispStale dispositions) `shouldBe` [place 0, place 1]
      dispStaleOmitted dispositions `shouldBe` 3

    it "stages nothing visible: the batch is applied only by the commit" $ do
      let candidate = beginCandidate bounds world0 1 []
      case stage bounds (Move 2 1 1) candidate of
        Left refused → expectationFailure ("refused: " <> show refused)
        Right staged → do
          candidateWorld staged `shouldBe` candidateWorld candidate
          let (committed, _) = commit (finish staged)
          fmap entityVersion (entityAt committed 2) `shouldBe` Just 1
          worldTick committed `shouldBe` 1

    it "refuses a move past the bound, of no entity, or over the delta, as a recoverable answer" $ do
      let small = bounds {boundStaging = 1}
          candidate = beginCandidate small world0 1 []
      one ← either (fail . show) pure (stage small (Move 0 1 0) candidate)
      refusal (stage small (Move 1 1 0) one) `shouldBe` Just StagingFull
      refusal (stage bounds (Move (-1) 1 0) candidate) `shouldBe` Just StagingNoEntity
      refusal (stage bounds (Move (boundEntities bounds) 1 0) candidate) `shouldBe` Just StagingNoEntity
      refusal (stage bounds (Move 0 (fromIntegral (boundDelta bounds) + 1) 0) candidate) `shouldBe` Just StagingDelta
      refusal (stage bounds (Move 0 1 0) candidate) `shouldBe` Nothing

    it "advances the stream in the candidate only, and commits it with the tick" $ do
      let candidate = beginCandidate bounds world0 1 []
      case draw 10 candidate of
        Nothing → expectationFailure "no draw"
        Just (_, drawn) → do
          candidateRandom drawn `shouldNotBe` worldRandom world0
          worldRandom (candidateWorld drawn) `shouldBe` worldRandom world0
          worldRandom (fst (commit (finish drawn))) `shouldBe` candidateRandom drawn
      -- A bound the stream refuses draws nothing.
      fmap fst (draw 0 candidate) `shouldBe` Nothing

    it "commits nothing when it is not committed: the committed world and stream are what they were" $ do
      let candidate = beginCandidate bounds world0 1 [(place 0, intention 0 0 1 0)]
      -- The candidate is a value; discarding it changes no committed field.
      candidateWorld candidate `shouldNotBe` world0
      world0 `shouldBe` initialWorld bounds 7 99
  where
    refusal = either Just (const Nothing)
