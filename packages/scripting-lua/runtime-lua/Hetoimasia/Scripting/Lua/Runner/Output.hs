-- | Where a script's @print@ and @warn@ go.
--
-- The base library's @print@ and @warn@ write to the process's C streams. Before any module
-- loads, an initial chunk rebinds both to a binding that writes through Haskell, so a script's
-- output reaches the runner's sinks and nothing a script runs reaches the C streams. A namespace
-- cannot take the name @print@, so the binding is a namespace of its own, which the chunk reads
-- once and then removes from the globals: the originals are replaced, no reference to them stays
-- reachable, and a script has no way to the binding but the two functions the chunk defined.
--
-- = What a call writes
--
-- @print@ joins the @tostring@ of its arguments with a tab, and @warn@ does the same after the
-- prefix @Lua warning: @. The text is cut by the script, before it crosses, to
-- 'outputCallLimit' bytes with the truncation marker counted in them, so a script cannot make the
-- value boundary refuse it for length, and the runner bounds what it writes again after decoding and
-- escaping, which can make the text longer: one call writes at most that many bytes of UTF-8 in all. Any Lua string is
-- accepted: it crosses as bytes, is decoded as UTF-8 with every invalid sequence replaced, is split
-- at its line breaks, and has its control characters (an embedded NUL included) replaced by
-- escapes, a tab excepted. Each line is one call of the sink.
module Hetoimasia.Scripting.Lua.Runner.Output
  ( outputNamespaceName
  , outputNamespace
  , outputChunk
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Registration (Namespace, namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Runner.Render (outputLines)
import Hetoimasia.Scripting.Lua.Runner.Types (outputCallLimit, truncationMarker)
import Hetoimasia.Scripting.Lua.Value (Schema (SBytes), Value (VBytes))

-- | The name of the runner's own namespace of two bindings: @out@ and @err@. The initial chunk
-- removes it from the globals once it has read them.
outputNamespaceName ∷ Text
outputNamespaceName = "hetoimasia_runner_output"

-- | The namespace, writing the lines of each call, together, to these sinks. A sink's exception is
-- not the script's: it ends the owner as the failure of the host it is.
outputNamespace ∷ ([Text] → IO ()) → ([Text] → IO ()) → Namespace
outputNamespace output errors =
  namespace
    outputNamespaceName
    [ stateOperation "out" [SBytes] [] (write output)
    , stateOperation "err" [SBytes] [] (write errors)
    ]
  where
    write sink = \case
      [VBytes bytes] → sink (outputLines bytes) >> pure []
      _ → pure []

-- | The initial chunk that rebinds @print@ and @warn@.
outputChunk ∷ ByteString
outputChunk =
  Text.encodeUtf8 . Text.unlines $
    [ "local out, err = " <> outputNamespaceName <> ".out, " <> outputNamespaceName <> ".err"
    , outputNamespaceName <> " = nil"
    , "local tostring, concat, select, sub = tostring, table.concat, select, string.sub"
    , "local limit, marker = " <> Text.pack (show outputCallLimit) <> ", " <> Text.pack (show (Text.unpack truncationMarker))
    , "local function render(prefix, ...)"
    , "  local parts = {}"
    , "  for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end"
    , "  local text = prefix .. concat(parts, '\\t')"
    , "  if #text > limit then text = sub(text, 1, limit - #marker) .. marker end"
    , "  return text"
    , "end"
    , "print = function(...) out(render('', ...)) end"
    , "warn = function(...) err(render('Lua warning: ', ...)) end"
    ]
