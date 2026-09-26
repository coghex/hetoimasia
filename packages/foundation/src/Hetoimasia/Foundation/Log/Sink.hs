-- | Building a 'LogSink' over a borrowed handle or a caller's callback, and
-- forwarding an entry or a flush to one.
--
-- 'newHandleSink' writes 'Hetoimasia.Foundation.Log.Format.formatEntry' lines
-- to a borrowed handle, serializing every write and flush across the loggers
-- sharing it. The handle stays the caller's: the sink never closes it and never
-- changes its buffering.
--
-- 'writeEntry' and 'flushSink' forward an already-prepared entry, and a flush,
-- to a sink an adapter has borrowed. They are the whole of what a caller
-- holding a 'LogSink' can do to it: neither exposes the sink's construction or
-- its internals, and both keep the sink's own synchronous write, flush, and
-- exception semantics.
--
-- The public facade is "Hetoimasia.Foundation.Log", which re-exports every
-- operation here; this module is private to the foundation package.
module Hetoimasia.Foundation.Log.Sink
  ( -- * Construction
    newHandleSink
  , newHandleSinkWith
  , callbackSink
  , callbackSinkWith

    -- * Forwarding to a sink
  , writeEntry
  , flushSink
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Monad (when)
import qualified Data.Text.IO as Text
import Hetoimasia.Foundation.Log.Base (FormatOptions (..), defaultFormatOptions)
import Hetoimasia.Foundation.Log.Format (formatEntry)
import Hetoimasia.Foundation.Log.Types (LogEntry, LogSink (..))
import System.IO (Handle, hFlush)

-- | 'newHandleSinkWith' with 'defaultFormatOptions'.
newHandleSink ∷ Handle → IO LogSink
newHandleSink = newHandleSinkWith defaultFormatOptions

-- | Borrow a handle. The sink writes each record as one whole line and never
-- closes the handle, changes its buffering, or outlives the caller's own
-- ownership of it; the handle stays usable after every logger sharing this
-- sink is discarded.
--
-- Writes and flushes are serialized across every logger sharing this sink, so
-- concurrent producers never interleave within a line and each producer's own
-- order is preserved. Ordering between threads is unspecified. That guarantee
-- is the sink value's, not the handle's: two roots sharing one handle must
-- share one sink, and constructing two handle sinks over one handle is
-- unsupported.
--
-- A failing or interrupted write releases the serialization state before the
-- exception leaves, so the next call on any sharing logger proceeds rather
-- than deadlocking. Such a write may leave a partial record; no transactional
-- file write is promised.
newHandleSinkWith ∷ FormatOptions → Handle → IO LogSink
newHandleSinkWith options handle = do
  ownership ← newMVar ()
  let serialized action = withMVar ownership (const action)
  pure LogSink
    { sinkWrite = \entry → serialized $ do
        Text.hPutStr handle (formatEntry options entry <> "\n")
        when (formatFlush options) (hFlush handle)
    , sinkFlush = serialized (hFlush handle)
    }

-- | 'callbackSinkWith' with a no-op flush, for a callback with no flushable
-- state of its own.
callbackSink ∷ (LogEntry → IO ()) → LogSink
callbackSink callback = callbackSinkWith callback (pure ())

-- | Wrap a caller-supplied callback and its flush action. The callback may
-- receive concurrent calls and supplies its own synchronization; it must not
-- emit to the same sink recursively. Exceptions from either action propagate
-- like any other sink failure.
callbackSinkWith ∷ (LogEntry → IO ()) → IO () → LogSink
callbackSinkWith callback flush = LogSink { sinkWrite = callback, sinkFlush = flush }

-- | Forward an already-prepared entry to a sink, exactly as
-- 'Hetoimasia.Foundation.Log.logEvent' forwards the one it built.
--
-- The write is synchronous on the calling thread and its exceptions propagate
-- to that caller, like every other sink write. No filter is applied and no
-- metadata is obtained: the entry is emitted as it stands, so an entry carried
-- across a thread boundary keeps the level, component, context, timestamp,
-- thread identity, and source attribution it was built with.
writeEntry ∷ LogSink → LogEntry → IO ()
writeEntry = sinkWrite

-- | Flush a sink directly, for a caller that holds the sink rather than a
-- logger over it. 'Hetoimasia.Foundation.Log.flushLogger' is this operation on
-- a logger's own sink, and both fail the same way.
flushSink ∷ LogSink → IO ()
flushSink = sinkFlush
