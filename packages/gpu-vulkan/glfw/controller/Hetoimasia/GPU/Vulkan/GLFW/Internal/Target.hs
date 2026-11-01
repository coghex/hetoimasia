-- | The key every scene the host holds is held under (LFE-27): a window, or a
-- surface-free offscreen target the application registered with the host.
--
-- There is one key space. The release barrier, the scene lifecycle, the scene
-- observation and the texture hold ledger of a consumer are all keyed by
-- 'SceneTargetKey', so a target that has no window takes part in the same
-- ownership a window does and no consumer needs a second path for it.
--
-- = Identities
--
-- A window's key carries the 'WindowId' the GLFW session issued for it, which
-- this package neither widens nor mints. An offscreen target's key carries an
-- 'OffscreenTargetId', which only the host that registered the target issues:
-- the host's own identity and the registration's incarnation number, which
-- rises with every registration and is never reused. A key issued by another
-- host, or by an earlier registration that has ended, is therefore never equal
-- to a live one, and cannot publish to, unregister, or satisfy the barrier of
-- another registration.
--
-- The constructors of 'OffscreenTargetId' are visible to this package's
-- private sublibrary and not to anything the public module re-exports, so no
-- application can forge one.
--
-- = State
--
-- Nothing here holds state: these are the identities, ordered and shown.
module Hetoimasia.GPU.Vulkan.GLFW.Internal.Target
  ( -- * Keys
    SceneTargetKey (..)
  , OffscreenTargetId (..)

    -- * Adopters
  , Adopter (..)
  , adopterKey
  ) where

import Data.Unique (Unique, hashUnique)
import Numeric.Natural (Natural)

import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.Runtime.GLFW (AttachmentId, attachmentWindow)

-- | An offscreen target's identity: the host that registered it and the
-- registration's incarnation, which is never reused within that host.
data OffscreenTargetId = OffscreenTargetId !Unique !Natural
  deriving (Eq, Ord)

instance Show OffscreenTargetId where
  showsPrec precedence (OffscreenTargetId host incarnation) =
    showParen (precedence > 10) $
      showString "OffscreenTargetId " . shows (hashUnique host) . showString "." . shows incarnation

-- | What a scene is held under: a window, or an offscreen target. An offscreen
-- target is never represented as a window.
data SceneTargetKey
  = KeyWindow !WindowId
  | KeyOffscreen !OffscreenTargetId
  deriving (Eq, Ord, Show)

-- | What adopts scenes for a key: one window attachment — a window reattached
-- under a new attachment adopts again, and each adoption is accounted on its
-- own — or the one offscreen target.
data Adopter
  = AttachmentAdopter !AttachmentId
  | TargetAdopter !OffscreenTargetId
  deriving (Eq, Ord, Show)

-- | The key an adopter's adoptions are reported and awaited under.
adopterKey ∷ Adopter → SceneTargetKey
adopterKey = \case
  AttachmentAdopter attachment → KeyWindow (attachmentWindow attachment)
  TargetAdopter target → KeyOffscreen target
