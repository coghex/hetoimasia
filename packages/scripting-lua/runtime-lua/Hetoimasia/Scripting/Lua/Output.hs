-- | The bounded form of a script's @print@ and @warn@, for an application that rebinds them (LFE-12).
--
-- The base library's @print@ and @warn@ write to the process's C streams. The script runner
-- ("Hetoimasia.Scripting.Lua.Runner") rebinds both to bindings that write through Haskell, and so
-- does the Lua-first engine's facade; this module is the one definition of how a call is bounded
-- and made safe, so that neither duplicates the other and the runner's own output is unchanged.
--
-- = What a call writes
--
-- The script converts and joins its arguments in Lua ('renderFunctionLines'): each with @tostring@,
-- joined with a tab, and cut to 'outputCallLimit' bytes with the truncation marker counted in them,
-- so that no call can make the value boundary refuse it for length. What crosses is the bytes. The
-- application bounds it again, after decoding and escaping, which can make the text longer
-- ('authoredLines'): the bytes are decoded as UTF-8 with every invalid sequence replaced, split at
-- their line breaks (@\\n@), have every control character but a tab replaced by an escape, and each
-- line takes the application's prefix. One call writes at most 'outputCallLimit' bytes of UTF-8 in
-- all, a line counting its bytes and one more for its end, the prefixes and the visible truncation
-- marker included. Each line is one call of the application's sink.
--
-- = A prefix marks every line
--
-- When the application gives a prefix, every line that is written begins with the whole of it, the line
-- a cut ends included: the marker is put at the end of the last line that is kept, which is a prefixed
-- line, and is never a line of its own and never follows a cut prefix. (A call with no prefix is cut as
-- the runner's own output is, by 'boundLines', with the marker alone on a line when that is where the
-- cut falls.) A bound too small to hold one prefix, the marker and a line end cannot give this, and the
-- call is then the first @limit - 1@ bytes of the prefix and the marker, cut at a character: the bound
-- wins over the format, and the profiles the engine validates never give a bound that small.
module Hetoimasia.Scripting.Lua.Output
  ( outputCallLimit
  , truncationMarker
  , authoredLines
  , authoredLinesWith
  , renderFunctionLines
  , renderFunctionLinesWith
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Hetoimasia.Scripting.Lua.Runner.Render (boundLines, tameLine)
import Hetoimasia.Scripting.Lua.Runner.Types (outputCallLimit, truncationMarker)

-- | The lines one call writes: the bytes the script passed, decoded as UTF-8 with every invalid
-- sequence replaced (so any Lua string is accepted, an embedded NUL byte included), split at its line
-- breaks, each line's control characters replaced (a tab kept) and the prefix put before it, and then
-- bounded as a whole to 'outputCallLimit' bytes of UTF-8, each line counting its bytes and one more for
-- its end. A call that would write more is cut, at a character, and ends in the truncation marker,
-- which is counted. The prefix is the application's own text and is made safe too.
authoredLines ∷ Text → ByteString → [Text]
authoredLines = authoredLinesWith outputCallLimit

-- | 'authoredLines' for a call that writes at most this many bytes: a smaller bound than the default is
-- what a validated smaller profile gives.
authoredLinesWith ∷ Int → Text → ByteString → [Text]
authoredLinesWith limit prefix bytes
  | Text.null safePrefix = boundLines limit bodies
  | otherwise = boundPrefixed limit safePrefix bodies
  where
    safePrefix = tameLine prefix
    bodies = map tameLine (Text.splitOn "\n" (Text.decodeUtf8With Text.lenientDecode bytes))

-- | These lines, each after the prefix, as a call may write them: in total at most this many bytes, a line
-- counting its bytes and one more for its end. Lines that fit are returned. Otherwise the lines that fit
-- are kept with room beside them for a prefixed marker line, and the first line that does not fit is cut
-- at a character so that the prefix, what is kept of it, the marker and the line's end fit, and no line
-- follows it.
boundPrefixed ∷ Int → Text → [Text] → [Text]
boundPrefixed limit prefix bodies
  | sum (map (size . (prefix <>)) bodies) <= limit = map (prefix <>) bodies
  | limit < reserve = [takeBytes (limit - 1) (prefix <> truncationMarker)]
  | otherwise = go limit bodies
  where
    size line = ByteString.length (Text.encodeUtf8 line) + 1
    -- A line that holds only a prefix and the marker.
    reserve = size (prefix <> truncationMarker)
    go _ [] = [prefix <> truncationMarker]
    go room (body : rest)
      | size line <= room - reserve = line : go (room - size line) rest
      | otherwise = [prefix <> takeBytes (room - reserve) body <> truncationMarker]
      where
        line = prefix <> body

-- | The longest start of this text, cut at a character, of at most this many bytes of UTF-8.
takeBytes ∷ Int → Text → Text
takeBytes room = Text.pack . fit 0 . Text.unpack
  where
    fit _ [] = []
    fit used (character : more)
      | used + width > room = []
      | otherwise = character : fit (used + width) more
      where
        width = ByteString.length (Text.encodeUtf8 (Text.singleton character))

-- | The Lua that defines @render(prefix, ...)@, as lines of source: it converts each argument with
-- @tostring@, joins them with a tab after the prefix, and cuts the result to 'outputCallLimit' bytes
-- with the truncation marker counted. It expects @tostring@, @concat@ (@table.concat@), @select@ and
-- @sub@ (@string.sub@) to be local names already bound to the originals, so that nothing a script
-- redefines afterwards changes what a call does. A @tostring@ that raises (a @__tostring@ or
-- @__name@ metamethod) raises out of @render@ before anything is written.
renderFunctionLines ∷ [Text]
renderFunctionLines = renderFunctionLinesWith outputCallLimit

-- | 'renderFunctionLines' cutting to this many bytes.
renderFunctionLinesWith ∷ Int → [Text]
renderFunctionLinesWith limit =
  [ "local limit, marker = " <> Text.pack (show limit) <> ", " <> Text.pack (show (Text.unpack truncationMarker))
  , "local function render(prefix, ...)"
  , "  local parts = {}"
  , "  for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end"
  , "  local text = prefix .. concat(parts, '\\t')"
  , "  if #text > limit then text = sub(text, 1, limit - #marker) .. marker end"
  , "  return text"
  , "end"
  ]
