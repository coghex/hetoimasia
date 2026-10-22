-- | Reading a native errno as a content failure.
--
-- The classification is deliberately small. An errno the service does not name
-- becomes 'Unreadable' with its number kept, so a later caller can still tell
-- permission from I/O; it is never reported as missing content, and a
-- cancellation or a cleanup failure never passes through here at all.
module Hetoimasia.Content.Internal.Errno
  ( errnoIs
  , classifyErrno
  , isMissing
  ) where

import Foreign.C.Error
  ( Errno (Errno)
  , eINVAL
  , eLOOP
  , eNAMETOOLONG
  , eNOENT
  , eNOSYS
  , eNOTDIR
  , eOPNOTSUPP
  )
import Hetoimasia.Content.Internal.Types

errnoIs ∷ Errno → Int → Bool
errnoIs expected code = Errno (fromIntegral code) == expected

-- | Missing: the name is absent, or too long to exist.
isMissing ∷ Int → Bool
isMissing code = errnoIs eNOENT code || errnoIs eNAMETOOLONG code

-- | The failure an errno stands for when nothing more is known
-- about the entry.
--
-- @EINVAL@, @ENOSYS@ and @EOPNOTSUPP@ are the platform saying it cannot do what
-- was asked (an unsupported filesystem, an operation the kernel lacks), so they
-- refuse as unsupported; the entry-type cases that share those numbers (a
-- socket answers @ENXIO@ or @EOPNOTSUPP@ to an open) are classified by the
-- no-follow type query before this is consulted.
classifyErrno ∷ Int → FailureKind
classifyErrno code
  | isMissing code = NotFound
  | errnoIs eLOOP code = ForbiddenLink
  | errnoIs eNOTDIR code = NotDirectory
  | errnoIs eINVAL code || errnoIs eNOSYS code || errnoIs eOPNOTSUPP code = Unsupported code
  | otherwise = Unreadable code
