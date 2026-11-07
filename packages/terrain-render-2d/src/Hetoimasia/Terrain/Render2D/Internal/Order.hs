-- | The exact back-to-front ordering of projected faces, private to the package.
--
-- Two faces constrain each other only where their projections overlap with
-- positive area. At every point of that overlap the one with the larger
-- parameter along the viewing direction @(1, 1, 3)@ is nearer. The two planes
-- cannot cross inside the overlap (terrain faces do not interpenetrate), so the
-- sign of the difference at the vertices of the exact overlap polygon decides
-- the pair; a difference of both signs is a crossing and an all-zero one is
-- coincident overlapping faces, and both are reported, not ordered.
--
-- The constraints form a graph, and a total order is its topological order,
-- taking the smallest canonical key among the ready faces, so the order depends
-- on the faces alone and never on the order they were supplied in. A cycle has
-- no order: the faces of one are returned as the counterexample.
module Hetoimasia.Terrain.Render2D.Internal.Order
  ( Canon
  , OFace (..)
  , OrderError (..)
  , orderFaces
  ) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Hetoimasia.Terrain.Render2D.Internal.Polygon

-- | A face's canonical identity, independent of how it was enumerated: its
-- view-frame cell offsets, its relative level and its face index.
type Canon = (Integer, Integer, Integer, Int)

-- | A face to order: its projection in positive order and its plane
-- @n · p = d@ in the relative frame.
data OFace = OFace
  { ofCanon ∷ !Canon
  , ofPolygon ∷ ![P2]
  , ofNormal ∷ !(Rational, Rational, Rational)
  , ofOffset ∷ !Rational
  }

-- | Why no order exists, or why finding it was refused.
data OrderError
  = -- | The faces of one cycle of the front/back relation.
    OrderCycle [Canon]
  | -- | Two faces whose planes cross inside their overlap.
    OrderCrossing Canon Canon
  | -- | Two overlapping faces in one plane.
    OrderCoincident Canon Canon
  | -- | More overlapping-candidate pairs than the work bound allows.
    OrderTooManyPairs Int
  deriving stock (Eq, Show)

-- | The indices of the faces from back to front, or the reason there is none.
-- The first argument bounds the candidate pairs examined.
orderFaces ∷ Int → [OFace] → Either OrderError [Int]
orderFaces pairLimit faces = do
  pairs ← candidatePairs pairLimit indexed
  edges ← concat <$> traverse (constrain byIndex) pairs
  topological byIndex edges
  where
    indexed = zip [0 ..] faces
    byIndex = Map.fromList indexed

-- The pairs of faces whose bounding boxes share a grid bucket and overlap.
candidatePairs ∷ Int → [(Int, OFace)] → Either OrderError [(Int, Int)]
candidatePairs limit indexed = go (Set.empty ∷ Set.Set (Int, Int)) (Map.elems buckets)
  where
    size = 96 ∷ Rational
    buckets = Map.fromListWith (flip (<>)) [(cell, [i]) | (i, f) ← indexed, cell ← cellsOf f]
    boxes = Map.fromList [(i, boundingBox (ofPolygon f)) | (i, f) ← indexed]
    cellsOf f =
      let (x1, x2, y1, y2) = boundingBox (ofPolygon f)
       in [(bx, by) | bx ← [floor (x1 / size) .. floor (x2 / size)], by ← [floor (y1 / size) .. floor (y2 / size)]] ∷ [(Integer, Integer)]
    go found [] = Right (Set.toAscList found)
    go found (members : rest) = do
      found' ← collect found (overlapping members)
      go found' rest
    -- One distinct pair past the limit proves insufficiency; stop there, so the
    -- quadratic enumeration of a bucket never outruns the bound.
    collect found [] = Right found
    collect found (pair : pairs)
      | pair `Set.member` found = collect found pairs
      | Set.size found >= limit = Left (OrderTooManyPairs limit)
      | otherwise = collect (Set.insert pair found) pairs
    overlapping members =
      [ (i, j)
      | (n, i) ← zip [0 ∷ Int ..] members
      , j ← drop (n + 1) members
      , boxesOverlap (boxes Map.! i) (boxes Map.! j)
      ]
    boxesOverlap (a1, a2, b1, b2) (c1, c2, d1, d2) = a1 < c2 && c1 < a2 && b1 < d2 && d1 < b2

-- The edges @(behind, nearer)@ a pair contributes, none when the projections
-- only touch.
constrain ∷ Map.Map Int OFace → (Int, Int) → Either OrderError [(Int, Int)]
constrain byIndex (i, j)
  | signedArea overlap <= 0 = Right []
  | any (> 0) diffs && any (< 0) diffs = Left (OrderCrossing (ofCanon f) (ofCanon g))
  | any (> 0) diffs = Right [(j, i)]
  | any (< 0) diffs = Right [(i, j)]
  | otherwise = Left (OrderCoincident (ofCanon f) (ofCanon g))
  where
    f = byIndex Map.! i
    g = byIndex Map.! j
    overlap = clipConvex (ofPolygon f) (ofPolygon g)
    diffs = [nearness f p - nearness g p | p ← overlap]

-- The parameter along the viewing direction at which a face's plane meets the
-- line of sight through a render-world point; larger is nearer.
nearness ∷ OFace → P2 → Rational
nearness face (sx, sy) = (ofOffset face - (nx * a + ny * b)) / (nx + ny + 3 * nz)
  where
    (nx, ny, nz) = ofNormal face
    a = (sx / 48 + sy / 24) / 2
    b = (sy / 24 - sx / 48) / 2

-- The smallest-canonical-key topological order of the edges.
topological ∷ Map.Map Int OFace → [(Int, Int)] → Either OrderError [Int]
topological byIndex edges = go initial indegree []
  where
    canon i = ofCanon (byIndex Map.! i)
    successors = Map.fromListWith (<>) [(a, [b]) | (a, b) ← edges]
    indegree0 = Map.fromListWith (+) ([(i, 0 ∷ Int) | i ← Map.keys byIndex] <> [(b, 1) | (_, b) ← edges])
    indegree = indegree0
    initial = Set.fromList [(canon i, i) | (i, 0) ← Map.toList indegree0]
    go ready degrees acc = case Set.minView ready of
      Nothing
        | length acc == Map.size byIndex → Right (reverse acc)
        | otherwise → Left (OrderCycle (cycleIn (Map.keysSet (Map.filter (> 0) degrees))))
      Just ((_, i), ready') →
        let outs = Map.findWithDefault [] i successors
            (degrees', released) = foldl' release (degrees, []) outs
            release (ds, rs) b =
              let d = ds Map.! b - 1
               in (Map.insert b d ds, [b | d == 0] <> rs)
         in go (foldl' (\r b → Set.insert (canon b, b) r) ready' released) degrees' (i : acc)
    -- A cycle among the faces that never became ready: follow predecessors
    -- until one repeats.
    predecessors = Map.fromListWith (<>) [(b, [a]) | (a, b) ← edges]
    cycleIn left = case Set.toAscList left of
      [] → []
      (start : _) → walk [] start
        where
          walk path cur
            | cur `elem` path = map canon (reverse (takeWhile (/= cur) path) <> [cur])
            | otherwise = case [p | p ← Map.findWithDefault [] cur predecessors, p `Set.member` left] of
                [] → map canon (reverse (cur : path))
                (p : _) → walk (cur : path) p
