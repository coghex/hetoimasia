-- | The one-line protocol the confined helper speaks to its parent.
--
-- The helper's stdout and stderr share a pipe, so the parser is deliberately
-- total: a line it does not recognize becomes 'Noise' and is kept. A runtime
-- message about why the process died is evidence too, and a probe that threw
-- away everything it could not parse would discard exactly the lines that
-- explain an unexpected result.
--
-- Every field is a bounded token. The helper is the trusted side here -- this
-- is a feasibility probe, not the production wire boundary P-13 specifies --
-- but the framing is fixed and length-bounded anyway, because a proof that
-- needed an unbounded parse would not be evidence for the design it informs.
module Hetoimasia.Scripting.Lua.Internal.MacOS.Report
  ( Report (..)
  , Origin (..)
  , Outcome (..)
  , Refusal (..)
  , refusalName
  , refusalExitCode
  , renderReport
  , parseReport
  , parseReports
  , protocolTag
  , lineLimit
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Text.Read (readMaybe)

-- | The protocol's version tag. It leads every line the helper emits.
protocolTag ∷ Text
protocolTag = "hmp/1"

-- | The longest line the parser will consider. Anything longer is 'Noise'.
lineLimit ∷ Int
lineLimit = 4096

-- | Which layer attempted an access.
--
-- The distinction is required evidence rather than bookkeeping: a denial from
-- 'OriginNative' is the operating system refusing the helper's own C code,
-- while a denial from 'OriginLua' could also be a missing standard library.
-- The probe opens @io@, @os@, and @package@ on purpose so that the Lua-side
-- denials cannot be that.
data Origin
  = -- | C code in the helper, before any mod source was loaded.
    OriginNative
  | -- | C code in the helper, after the mod source was loaded.
    OriginNativePostLoad
  | -- | Lua code in the loaded mod source.
    OriginLua
  deriving (Eq, Ord, Show)

-- | Whether an attempted access got through.
data Outcome = Allowed | Denied
  deriving (Eq, Ord, Show)

-- | Why the helper refused to proceed.
--
-- Each one is terminal. The helper never continues as a plain unconfined child,
-- so there is no refusal here that means "carried on anyway".
data Refusal
  = -- | The confinement mechanism is not present on this system.
    ConfinementUnavailable
  | -- | The mechanism is present and rejected the profile.
    ConfinementFailed
  | -- | The mechanism reported success and a forbidden access still got
    -- through, so nothing was actually installed.
    ConfinementNotEnforced
  | -- | The approved module source could not be read from the private view.
    ModuleSourceUnavailable
  | -- | Initialization failed after confinement was verified.
    InitializationFailed
  deriving (Bounded, Enum, Eq, Ord, Show)

-- | The wire name of a refusal.
refusalName ∷ Refusal → Text
refusalName = \case
  ConfinementUnavailable → "confinement-unavailable"
  ConfinementFailed → "confinement-failed"
  ConfinementNotEnforced → "confinement-not-enforced"
  ModuleSourceUnavailable → "module-source-unavailable"
  InitializationFailed → "initialization-failed"

-- | The exit status the helper leaves behind for each refusal.
--
-- They are distinct so the parent can tell them apart from a status alone, and
-- all are outside the range a successful run uses.
refusalExitCode ∷ Refusal → Int
refusalExitCode = \case
  ConfinementUnavailable → 70
  ConfinementFailed → 71
  ConfinementNotEnforced → 72
  ModuleSourceUnavailable → 73
  InitializationFailed → 74

-- | One line of the helper's report.
data Report
  = -- | Confinement is installed and verified; the helper is admitted.
    Ready
  | -- | A terminal refusal and its detail.
    Refused Refusal Text
  | -- | An attempted access, where it came from, and the mechanism that
    -- decided it.
    Access Origin Text Outcome Text
  | -- | Descriptors above stderr the helper holds, how many are sockets, and a
    -- short census of them. A confined helper's must be none: a peer endpoint
    -- inherited across the spawn is a handle the sandbox's path policy never
    -- sees.
    Descriptors Int Int Text
  | -- | Physical footprint and virtual size, in bytes.
    Footprint Word64 Word64
  | -- | The smallest @RLIMIT_AS@ the helper could install, and the errno that
    -- rejected the next step down.
    RlimitFloor Word64 Int
  | -- | The workload has reached this many mebibytes.
    Held Int
  | -- | The workload's own finite ceiling was reached without interference.
    Ceiling Int
  | -- | The helper finished its mode.
    Done
  | -- | Anything else the helper or the runtime wrote.
    Noise Text
  deriving (Eq, Show)

-- | Render one report as the single line the helper writes.
renderReport ∷ Report → Text
renderReport report = Text.unwords (protocolTag : body report)
 where
  body = \case
    Ready → ["ready"]
    Refused refusal detail → ["refusal", refusalName refusal, sanitize detail]
    Access origin name outcome mechanism →
      ["access", originName origin, name, outcomeName outcome, sanitize mechanism]
    Descriptors extra sockets census →
      ["descriptors", showText extra, showText sockets, sanitize census]
    Footprint footprint virtualSize →
      ["footprint", showText footprint, showText virtualSize]
    RlimitFloor bytes code → ["rlimit-as-floor", showText bytes, showText code]
    Held mib → ["held", showText mib]
    Ceiling mib → ["ceiling", showText mib]
    Done → ["done"]
    Noise text → ["noise", sanitize text]

-- | Parse one line. An unrecognized line is 'Noise', never a failure.
parseReport ∷ Text → Report
parseReport raw
  | Text.length line > lineLimit = Noise (Text.take lineLimit line)
  | otherwise = case Text.words line of
      (tag : rest) | tag == protocolTag → fromWords rest
      _ → Noise line
 where
  line = Text.strip raw
  fromWords = \case
    ["ready"] → Ready
    ("refusal" : name : detail) → case lookup name refusalsByName of
      Just refusal → Refused refusal (Text.unwords detail)
      Nothing → Noise line
    ("access" : origin : name : outcome : mechanism)
      | Just parsedOrigin ← lookup origin originsByName
      , Just parsedOutcome ← lookup outcome outcomesByName →
          Access parsedOrigin name parsedOutcome (Text.unwords mechanism)
    ("descriptors" : extra : sockets : census)
      | Just a ← number extra, Just b ← number sockets → Descriptors a b (Text.unwords census)
    ["footprint", footprint, virtualSize]
      | Just a ← number footprint, Just b ← number virtualSize → Footprint a b
    ["rlimit-as-floor", bytes, code]
      | Just a ← number bytes, Just b ← number code → RlimitFloor a b
    ["held", mib] | Just value ← number mib → Held value
    ["ceiling", mib] | Just value ← number mib → Ceiling value
    ["done"] → Done
    ("noise" : rest) → Noise (Text.unwords rest)
    _ → Noise line

-- | Parse a whole captured stream.
parseReports ∷ Text → [Report]
parseReports = map parseReport . Text.lines

originName ∷ Origin → Text
originName = \case
  OriginNative → "native"
  OriginNativePostLoad → "native-post-load"
  OriginLua → "lua"

outcomeName ∷ Outcome → Text
outcomeName = \case
  Allowed → "allowed"
  Denied → "denied"

refusalsByName ∷ [(Text, Refusal)]
refusalsByName = [(refusalName refusal, refusal) | refusal ← [minBound .. maxBound]]

originsByName ∷ [(Text, Origin)]
originsByName =
  [(originName origin, origin) | origin ← [OriginNative, OriginNativePostLoad, OriginLua]]

outcomesByName ∷ [(Text, Outcome)]
outcomesByName = [(outcomeName outcome, outcome) | outcome ← [Allowed, Denied]]

-- | A field is one token, so whitespace in a free-text detail is folded and the
-- line stays parseable however the underlying diagnostic was formatted.
sanitize ∷ Text → Text
sanitize = Text.unwords . Text.words . Text.take lineLimit

number ∷ Read a ⇒ Text → Maybe a
number = readMaybe . Text.unpack

showText ∷ Show a ⇒ a → Text
showText = Text.pack . show
