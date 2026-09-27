-- | The representation of a composite under construction: release ranks, the
-- parts a construction has acquired, the ledger holding them, and the
-- 'Assembly' a constructor writes its stages in.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Resource.Internal" re-exports
-- it for the rest of the package, and "Hetoimasia.Foundation.Resource.Assembly"
-- imports it directly. "Hetoimasia.Foundation.Resource" exports 'Assembly' and
-- 'ReleaseRank' without their constructors, so a client can neither run an
-- assembly outside 'Hetoimasia.Foundation.Resource.withComposite' nor reach
-- the ledger it fills.
--
-- It defines representations and their instances only. The effects over them
-- — acquiring a part, restoring the caller's masking state, rolling back, and
-- lending — live in "Hetoimasia.Foundation.Resource.Assembly", which is why
-- this module imports no other resource module. 'runAssembly' is here rather
-- there because the 'Monad' instance needs it and an instance stays with its
-- type.
module Hetoimasia.Foundation.Resource.Types
  ( -- * Release order
    ReleaseRank (..)
  , releaseRank

    -- * Acquired parts
  , Part (..)
  , Ledger

    -- * Staged construction
  , Assembling (..)
  , Assembly (..)
  , runAssembly
  ) where

import Data.IORef (IORef)
import Data.Text (Text)

-- | Where one part falls in the composite's declared final release order.
--
-- Lower ranks are released first, and parts sharing a rank are released in
-- acquisition order. A rank is a declaration about the API the parts come
-- from, not a consequence of when a stage happened to run: a handle created
-- before the allocation behind it is often destroyed before that allocation is
-- freed, which is acquisition order rather than the reverse of it.
newtype ReleaseRank = ReleaseRank Int
  deriving (Eq, Ord, Show)

-- | Build a 'ReleaseRank' from an ordering key the constructor chooses.
releaseRank ∷ Int → ReleaseRank
releaseRank = ReleaseRank

-- | One acquired part, together with the release that covers it and the label
-- a failure of that release is retained under.
--
-- Both metadata fields are already evaluated when
-- 'Hetoimasia.Foundation.Resource.Assembly.acquirePart' builds this, so the
-- ordering and the labelling the release needs cannot fail while the
-- construction is being rolled back or the scope is exiting.
data Part = Part
  { partRank ∷ !ReleaseRank
  , partLabel ∷ !Text
  , partRelease ∷ IO ()
  }

-- | What a stage may reach while a composite is being constructed: the
-- caller's masking state, and the slot holding the one authoritative release.
--
-- The slot is not application state and is never observed outside the
-- construction it belongs to. It exists so that the release covering every
-- part acquired so far is a single value that later stages extend, rather than
-- a chain of nested handlers a stage could step outside of.
data Assembling = Assembling
  { assemblingRestore ∷ ∀ x. IO x → IO x
  , assemblingParts ∷ !(IORef [Part])
  }

-- | A staged construction of one composite value.
--
-- A composite owner acquires several parts in sequence, may fail between any
-- two of them, and must release them in an order its own API dictates. An
-- 'Assembly' is that sequence and nothing more: it is not a dependency
-- scheduler, it registers no delayed cleanup, and it hands no release action
-- to a caller.
--
-- Stages are written in @do@ notation, so a later stage may use what an
-- earlier one produced. 'Hetoimasia.Foundation.Resource.Assembly.acquirePart'
-- takes a part and installs its rollback as one protected step;
-- 'Hetoimasia.Foundation.Resource.Assembly.restoredStep' runs work that
-- acquires nothing with the caller's masking state restored.
-- 'Hetoimasia.Foundation.Resource.withComposite' runs the whole assembly and
-- owns what it produced.
newtype Assembly a = Assembly (Assembling → IO a)

instance Functor Assembly where
  fmap change (Assembly stages) = Assembly (fmap change . stages)

instance Applicative Assembly where
  pure value = Assembly (\_ → pure value)
  Assembly change <*> Assembly stages =
    Assembly (\assembling → change assembling <*> stages assembling)

instance Monad Assembly where
  Assembly stages >>= continue = Assembly $ \assembling → do
    value ← stages assembling
    runAssembly (continue value) assembling

-- | Run an assembly's stages against one construction's 'Assembling'.
runAssembly ∷ Assembly a → Assembling → IO a
runAssembly (Assembly stages) = stages

-- | The one authoritative release of a composite: every part acquired so far,
-- newest first. It is private to the construction or scope that created it.
type Ledger = IORef [Part]
