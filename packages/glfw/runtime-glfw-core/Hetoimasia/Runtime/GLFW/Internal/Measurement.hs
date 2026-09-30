-- | The owner loop's measurement trace, reached through a host.
--
-- Every session owns one stopped trace ("Hetoimasia.GLFW.Internal.Trace"),
-- which records the owner turns, the native event call's entry and exit and
-- every callback delivered inside it once something starts it. The GLFW
-- package's own interaction probe reaches it through the private model; a
-- probe in another package — the Vulkan window integration's, which extends
-- that measurement with the graphics owner — reaches it here, through the host
-- it runs, and records what it observes on its own threads into the same order
-- and the same time domain with 'recordTrace' and 'Marked'.
--
-- Nothing in the runtime or the host starts it: it is measurement storage an
-- explicitly activated probe starts, and an ordinary run reads one 'IORef' per
-- recording point.
module Hetoimasia.Runtime.GLFW.Internal.Measurement
  ( Trace
  , hostTrace
  , startTrace
  , stopTrace
  , takeTrace
  , traceRunning
  , defaultTraceCapacity
  , PumpMode (..)
  , TraceEvent (..)
  , TraceRecord (..)
  , TraceEvidence (..)
  , evidenceComplete
  , recordTrace
  ) where

import Hetoimasia.GLFW.Internal.Session (sessionTrace)
import Hetoimasia.GLFW.Internal.Trace
  ( PumpMode (..)
  , Trace
  , TraceEvent (..)
  , TraceEvidence (..)
  , TraceRecord (..)
  , defaultTraceCapacity
  , evidenceComplete
  , recordTrace
  , startTrace
  , stopTrace
  , takeTrace
  , traceRunning
  )
import Hetoimasia.Runtime.GLFW.Internal.Host.State (WindowHost, hostSessionOf)

-- | The trace of the session this host owns.
hostTrace ∷ WindowHost → Trace
hostTrace = sessionTrace . hostSessionOf
