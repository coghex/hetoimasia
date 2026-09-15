-- | The test seam: the real GLFW session and window models over a scripted
-- native library.
--
-- A 'Seam' is a native table that initializes nothing. It records every native
-- operation the models ask for as a 'NativeCall', answers each from a
-- 'SeamScript', and invokes the error callback the session installed when a
-- scripted step reports an error. The models themselves — entry order, thread
-- checks, exclusivity, attribution, window construction, rollback, and
-- poisoning — are the production code, not a copy of it.
--
-- Thread identity is scripted as well. A seam treats as the process main
-- thread only the Haskell threads designated with
-- 'designateProcessMainThread'; 'asProcessMainThread' runs an action in a
-- bound thread designated that way. Boundness is the runtime's own answer, so
-- an unbound designated thread and an undesignated bound worker are both
-- rejected, each for its own reason.
--
-- Each seam has its own guard, so examples never share occupancy with each
-- other or with a production session. Windows are created in a seam session
-- through the public "Hetoimasia.GLFW.Window" interface.
--
-- This component is public only so the root package's test suite can depend on
-- it. It exposes no native handle, no session or window constructor, and no way
-- to deliver window callbacks or change a window's close intent: those drivers
-- live in the package's private @seam-core@ sublibrary and are used only by its
-- own @glfw-window-examples@ executable.
module Hetoimasia.GLFW.Seam
  ( -- * Seams
    Seam
  , newSeam
  , SeamScript (..)
  , defaultScript
  , seamSession
  , seamCalls
  , seamLiveCallbacks
  , seamLiveWindowCallbacks
  , featureUnavailableCode

    -- * Thread identity
  , asProcessMainThread
  , designateProcessMainThread

    -- * Reporting errors from a scripted step
  , Reporter
  , reportError
  , reportErrorFromOtherThread
  , reportErrorWithFailingIdentity

    -- * What the models asked of the native library
  , NativeCall (..)
  , WindowHint (..)
  , WindowAttribute (..)
  ) where

import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Reporter
  , Seam
  , SeamScript (..)
  , WindowAttribute (..)
  , WindowHint (..)
  , asProcessMainThread
  , defaultScript
  , designateProcessMainThread
  , featureUnavailableCode
  , newSeam
  , reportError
  , reportErrorFromOtherThread
  , reportErrorWithFailingIdentity
  , seamCalls
  , seamLiveCallbacks
  , seamLiveWindowCallbacks
  , seamSession
  )
