-- | Exclusive publication claims of scene targets (TRA-9).
--
-- = What a claim is
--
-- A terrain view publishes to its target only under that target's claim, and while the claim is held nothing
-- else publishes there: not a second view, and not an M1 publication, which is refused ordinarily
-- ('Hetoimasia.LuaEngine.Graphics.Scene.Publish.TargetClaimed'). A claim names the target by the host's
-- 'SceneTargetKey', which is one incarnation (a window incarnation's 'WindowId' or an offscreen registration, never
-- reused within a host), and the view by its incarnation, so a late close or publication of an old view cannot
-- touch a newer view's claim or a reopened target.
--
-- Every operation is one STM step, composed by the caller into the same transaction as the authority it decides
-- with: a claim is taken in the transaction that checks the target is usable, a terrain publication commits in
-- the transaction that checks the claim still names its view, and an M1 publication reads the claim in its
-- commit transaction. Nothing can be written between a check and its effect.
--
-- = Owned state, threads and lifetime
--
-- +-------------+-------------------+-----------------------------------+----------------------+-----------------+
-- | State       | Owner             | Writers                           | Readers              | Lifetime        |
-- +=============+===================+===================================+======================+=================+
-- | The claims  | the scene session | a terrain view's attachment, its  | the M1 publisher's   | the session's;  |
-- | (target to  | ('SceneSession')  | publication and its close (STM,   | commit, a view's     | a claim lives   |
-- | view)       |                   | any thread)                       | publication (STM)    | from its take to|
-- |             |                   |                                   |                      | its release     |
-- +-------------+-------------------+-----------------------------------+----------------------+-----------------+
module Hetoimasia.LuaEngine.Graphics.Scene.Claims
  ( SceneClaims
  , newSceneClaims
  , Claim (..)
  , claimOf
  , takeClaim
  , markClaimPublished
  , releaseClaim
  , claimsHeld
  ) where

import Control.Concurrent.STM (STM, TVar, newTVarIO, readTVar, writeTVar)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Word (Word64)

-- | The claims of one session's targets, by the host's target key ('SceneTargetKey' in production; a suite without a
-- host keys its model's targets its own way).
newtype SceneClaims k = SceneClaims (TVar (Map k Claim))

-- | One target's claim: the view incarnation that holds it, and whether that view has published to it (which
-- decides what its release publishes).
data Claim = Claim
  { claimView ∷ !Word64
  , claimPublished ∷ !Bool
  }
  deriving (Eq, Show)

newSceneClaims ∷ IO (SceneClaims k)
newSceneClaims = SceneClaims <$> newTVarIO Map.empty

-- | The target's claim, if any.
claimOf ∷ Ord k ⇒ SceneClaims k → k → STM (Maybe Claim)
claimOf (SceneClaims var) key = Map.lookup key <$> readTVar var

-- | Take the target's claim for this view: 'False', changing nothing, when any claim already holds it.
takeClaim ∷ Ord k ⇒ SceneClaims k → k → Word64 → STM Bool
takeClaim (SceneClaims var) key view = do
  held ← readTVar var
  case Map.lookup key held of
    Just _ → pure False
    Nothing → True <$ writeTVar var (Map.insert key (Claim view False) held)

-- | Record that the view holding the claim has published: 'False', changing nothing, when the claim does not name
-- this view.
markClaimPublished ∷ Ord k ⇒ SceneClaims k → k → Word64 → STM Bool
markClaimPublished (SceneClaims var) key view = do
  held ← readTVar var
  case Map.lookup key held of
    Just claim | claimView claim == view → True <$ writeTVar var (Map.insert key claim {claimPublished = True} held)
    _ → pure False

-- | Release the target's claim if, and only if, it names this view, answering what it was. A release by any other
-- view, or of a claim already released, changes nothing and answers 'Nothing'.
releaseClaim ∷ Ord k ⇒ SceneClaims k → k → Word64 → STM (Maybe Claim)
releaseClaim (SceneClaims var) key view = do
  held ← readTVar var
  case Map.lookup key held of
    Just claim | claimView claim == view → Just claim <$ writeTVar var (Map.delete key held)
    _ → pure Nothing

-- | Every claim held now.
claimsHeld ∷ SceneClaims k → STM (Map k Claim)
claimsHeld (SceneClaims var) = readTVar var
