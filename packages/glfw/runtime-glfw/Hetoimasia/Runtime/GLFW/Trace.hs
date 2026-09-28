-- | The owner loop's measurement trace, for an explicitly activated probe.
--
-- A host's session owns one bounded, record-only trace, stopped until a probe
-- starts it: once started it records every owner turn's beginning, the native
-- event call's entry and exit, and every window callback delivered — inside
-- that call included — each stamped from the one monotonic source the probe
-- starts it with. A probe may place its own records in the same order with
-- 'recordTrace' and 'Marked', from any thread: an interaction it asked a
-- person to perform, or what a graphics owner did while the main thread was
-- inside the native call. Recording never raises and never waits; a record the
-- bound refused, or one that could not be stored, is counted, and evidence
-- with either count above zero is incomplete ('evidenceComplete').
--
-- It is measurement, not a logger or a diagnostic path: nothing in the runtime
-- starts it, and an ordinary run records nothing.
module Hetoimasia.Runtime.GLFW.Trace
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

import Hetoimasia.Runtime.GLFW.Internal.Measurement
