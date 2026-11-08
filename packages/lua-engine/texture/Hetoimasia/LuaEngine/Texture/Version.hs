-- | The request policy of a texture load and the immutable loaded asset version that carries its
-- validated facts (TRA-15).
--
-- = The policy
--
-- A 'TexturePolicy' is what @api.content.texture(path, options)@ asked beyond the path: the image
-- kind (premultiplied sRGB colour, or linear numeric data), whether binary alpha coverage is
-- required, and the normal encoding the texels are declared to carry. It is a plain value, checked
-- by 'texturePolicy' for the one incompatible combination (a normal encoding on a colour image) and
-- otherwise by the pipeline when the decoded bytes exist.
--
-- = The version
--
-- A 'Version' is one loaded asset: the facts the pipeline established for exactly one decode, tied
-- to the texture that was uploaded from that same decode. Two requests for the same path are two
-- versions. Its identity is a number the pipeline issues once, so a path, a recycled registration
-- slot or the same dimensions never stand for it. It holds, immutably:
--
-- * the kind, the dimensions, and the normal encoding the pipeline /checked/ (never merely
--   declared, and absent for a request that did not ask).
--
-- and, in a variable of its own, the shared coverage plane, when binary coverage was asked: the one
-- bitplane of this version, referenced by every reader and copied by none, fully evaluated before the
-- version exists and holding nothing of the decoded RGBA image. The variable is cleared by the last
-- interest's drop, in the transaction that returns the charge, so a job, a cell or a lease record that
-- still names the version (a texture awaiting its GPU retirement, say) no longer reaches the payload.
-- A reader reaches the plane only through an interest ('interestPlane'), never through the version.
--
-- = Interests
--
-- The plane is shared, so its lifetime is a count of /interests/: the pipeline's own while the
-- version is being delivered, the lease's once a lease adopts the texture, and one for each
-- consumer that retains the version through the protected-resource boundary. An interest is a
-- token that is dropped exactly once however many paths reach it. Taking an interest on a version
-- whose last interest was dropped answers 'Nothing': authority does not come back. When the last
-- interest is dropped the version's reservation on the shared account is returned
-- ('Hetoimasia.LuaEngine.Texture.Account.returnOwned'). That is the end of the /CPU/ coverage and
-- of nothing else: the GPU registration and the texture's nominal charges retire on the backend's
-- evidence, and neither event stands in for the other.
--
-- Owner: the pipeline, which makes versions and holds the first interest. Readers and writers:
-- every operation is one STM transaction on the version's own count. Thread: any. Lifetime: from the
-- decode that built it to its last interest. Nothing is reset.
module Hetoimasia.LuaEngine.Texture.Version
  ( -- * The policy
    TextureKind (..)
  , TexturePolicy (..)
  , colourPolicy
  , texturePolicy
  , PolicyRefused (..)
  , policyRefusalText

    -- * The version
  , Version
  , VersionFacts (..)
  , newVersion
  , versionPlane
  , versionId
  , versionFacts
  , versionInterests
  , versionReservation

    -- * Interests
  , Interest
  , interestVersion
  , takeInterest
  , dropInterest
  , interestHeld
  , interestPlane
  ) where

import Control.Concurrent.STM (STM, TVar, newTVar, readTVar, writeTVar)
import Control.Monad (when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding)
import Hetoimasia.LuaEngine.Texture.Account (Reservation, returnOwned, takeOwnership)

-- | What the texels are.
data TextureKind
  = -- | Premultiplied sRGB colour: the default, and what every M1 texture is.
    ColourKind
  | -- | Linear numeric data, exactly as decoded: no gamma conversion, no premultiplication.
    DataKind
  deriving (Eq, Show)

-- | What a texture request asks of the load beyond the path.
data TexturePolicy = TexturePolicy
  { policyKind ∷ !TextureKind
  , policyBinaryCoverage ∷ !Bool
    -- ^ Require binary alpha and keep its one-bit-per-texel plane with the version.
  , policyNormalEncoding ∷ !(Maybe NormalEncoding)
    -- ^ Validate the texels against this encoding before upload, and record the fact.
  }
  deriving (Eq, Show)

-- | The default: premultiplied sRGB colour, no coverage, no encoding.
colourPolicy ∷ TexturePolicy
colourPolicy = TexturePolicy ColourKind False Nothing

-- | Why a combination of options is not a request.
data PolicyRefused
  = -- | A normal encoding is data-image policy; a colour image (the default) has none. Never an
    -- implicit @kind = "data"@.
    EncodingNeedsData
  deriving (Eq, Show)

-- | The refusal, as the bounded text of an ordinary argument error.
policyRefusalText ∷ PolicyRefused → Text
policyRefusalText EncodingNeedsData = "normal_encoding is valid only with kind=\"data\""

-- | A policy from its three options, or the combination's refusal.
texturePolicy ∷ TextureKind → Bool → Maybe NormalEncoding → Either PolicyRefused TexturePolicy
texturePolicy kind coverage encoding = case (kind, encoding) of
  (ColourKind, Just _) → Left EncodingNeedsData
  _ → Right (TexturePolicy kind coverage encoding)

-- The version -----------------------------------------------------------------------------------------------

-- | The immutable facts of one loaded version, readable by whoever holds an interest in it.
data VersionFacts = VersionFacts
  { factsKind ∷ !TextureKind
  , factsWidth ∷ !Word32
  , factsHeight ∷ !Word32
  , factsNormal ∷ !(Maybe NormalEncoding)
    -- ^ The encoding the pipeline checked before the upload: set only when it was asked for and
    -- every texel passed.
  }

-- | One loaded asset version.
data Version = Version
  { versionNumber ∷ !Word64
  , versionData ∷ !VersionFacts
  , versionCount ∷ !(TVar Int)
  , versionHold ∷ !(Maybe Reservation)
  , versionPlaneVar ∷ !(TVar (Maybe CoveragePlane))
  }

instance Eq Version where
  a == b = versionCount a == versionCount b

-- | The identity the pipeline issued this version: unique within the pipeline, never reused.
versionId ∷ Version → Word64
versionId = versionNumber

-- | The facts.
versionFacts ∷ Version → VersionFacts
versionFacts = versionData

-- | How many interests the version holds now.
versionInterests ∷ Version → STM Int
versionInterests = readTVar . versionCount

-- | The reservation the version owns on the shared account, if it holds a plane.
versionReservation ∷ Version → Maybe Reservation
versionReservation = versionHold

-- | Whether the version still holds its plane: only while an interest does. For observation.
versionPlane ∷ Version → STM Bool
versionPlane = fmap isJust . readTVar . versionPlaneVar

-- | A version of these facts and, if it retains a plane, that plane (already fully evaluated by the caller) and
-- the reservation that pays for it, which passes to the version in this transaction. The caller holds the first
-- interest.
newVersion ∷ Word64 → VersionFacts → Maybe CoveragePlane → Maybe Reservation → STM (Version, Interest)
newVersion number facts plane hold = do
  mapM_ takeOwnership hold
  count ← newTVar 1
  planeVar ← newTVar plane
  let version = Version number facts count hold planeVar
  held ← newTVar True
  pure (version, Interest version held)

-- | One holder's interest in a version, dropped exactly once.
data Interest = Interest
  { interestOf ∷ !Version
  , interestLive ∷ !(TVar Bool)
  }

instance Eq Interest where
  a == b = interestLive a == interestLive b

-- | The version an interest is in.
interestVersion ∷ Interest → Version
interestVersion = interestOf

-- | Whether the interest is still held.
interestHeld ∷ Interest → STM Bool
interestHeld = readTVar . interestLive

-- | Take another interest in a version, or 'Nothing' if the last one was already dropped.
takeInterest ∷ Version → STM (Maybe Interest)
takeInterest version = do
  count ← readTVar (versionCount version)
  if count <= 0
    then pure Nothing
    else do
      writeTVar (versionCount version) (count + 1)
      Just . Interest version <$> newTVar True

-- | The version's plane, through an interest that is still held: 'Nothing' once the interest was dropped, and for
-- a version that has no plane. The only way to a plane.
interestPlane ∷ Interest → STM (Maybe CoveragePlane)
interestPlane interest = do
  live ← readTVar (interestLive interest)
  if live then readTVar (versionPlaneVar (interestOf interest)) else pure Nothing

-- | Drop an interest: once. The last one detaches the plane and returns the version's reservation in the same
-- transaction, so the charge is never returned while the payload is still reachable from the version.
dropInterest ∷ Interest → STM ()
dropInterest interest = do
  live ← readTVar (interestLive interest)
  when live $ do
    writeTVar (interestLive interest) False
    let version = interestOf interest
    count ← readTVar (versionCount version)
    writeTVar (versionCount version) (count - 1)
    when (count == 1) $ do
      writeTVar (versionPlaneVar version) Nothing
      mapM_ returnOwned (versionHold version)
