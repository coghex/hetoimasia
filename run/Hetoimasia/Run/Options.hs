-- | The command line of @hetoimasia run@: a pure function from the arguments after @run@ to a parse, so the
-- grammar is examined without a root, a filesystem, a VM or a window.
--
-- = The grammar (P-71 part 1, D-74)
--
-- > hetoimasia run GAME_ROOT
-- > hetoimasia run -- GAME_ROOT
-- > hetoimasia run --help
--
-- * Exactly one folder argument. A relative or an absolute path is accepted as written; the content
--   service resolves it once, and nothing here looks at it.
-- * Without the separator, an argument that starts with a hyphen is an unknown option.
-- * After the separator the next argument is literal, @--help@ and a leading hyphen included.
-- * @--help@ alone prints the command's help and is not a usage error. @--help@ beside anything else is.
-- * A missing or an extra argument, and every other option, is a usage error.
--
-- There is no default root, no parent search, no entry override, no mod, seed, cadence or window option and
-- no forwarding of arguments to a script. Nothing in this module reads the environment or the filesystem.
module Hetoimasia.Run.Options
  ( RunParse (..)
  , RunProblem (..)
  , parseRun
  , problemReason
  , runUsage
  , runHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Console.Usage (diagnosticText)

-- | What a valid command line asks for.
data RunParse
  = -- | @run --help@, alone.
    RunHelp
  | -- | @run [--] GAME_ROOT@: the folder, exactly as typed.
    RunRoot !FilePath
  deriving (Eq, Show)

-- | Why a command line is a usage error.
data RunProblem
  = -- | No folder was given (nothing, or only the separator).
    MissingRoot
  | -- | More than one folder argument, or one beside the separator's.
    ExtraArguments
  | -- | An option the command does not have (the argument, as typed).
    UnknownOption !String
  | -- | @--help@ with another argument beside it.
    HelpNotAlone
  deriving (Eq, Show)

-- | Parse the arguments after @run@.
parseRun ∷ [String] → Either RunProblem RunParse
parseRun = \case
  ["--help"] → Right RunHelp
  "--help" : _ → Left HelpNotAlone
  "--" : rest → case rest of
    [] → Left MissingRoot
    [root] → Right (RunRoot root)
    _ → Left ExtraArguments
  [] → Left MissingRoot
  first : rest
    | startsWithHyphen first → Left (UnknownOption first)
    | null rest → Right (RunRoot first)
    | otherwise → Left ExtraArguments
  where
    startsWithHyphen = \case
      '-' : _ → True
      _ → False

-- | The one-line reason a usage error is written with. What the user typed is escaped and cut by
-- 'diagnosticText', so it cannot add a line.
problemReason ∷ RunProblem → Text
problemReason = \case
  MissingRoot → "missing GAME_ROOT"
  ExtraArguments → "exactly one GAME_ROOT is accepted"
  UnknownOption option → "unknown option '" <> diagnosticText option <> "'"
  HelpNotAlone → "--help takes no other argument"

-- | The usage line, written to stderr by a usage error.
runUsage ∷ Text
runUsage = "Usage: hetoimasia run [--] GAME_ROOT | hetoimasia run --help"

-- | The command's help, written to stdout by @run --help@.
runHelp ∷ Text
runHelp =
  Text.unlines
    [ runUsage
    , ""
    , "  Run the game folder GAME_ROOT: a hetoimasia.json beside its Lua and"
    , "  content, opened once, scanned whole, and run in a window. The command"
    , "  knows how to assemble the engine's services, not what game to run."
    , ""
    , "  GAME_ROOT    The folder, relative to the working directory or absolute."
    , "               Every file in it is scanned at start and any edit takes"
    , "               effect at the next start."
    , "  --           Everything after it is the folder, a leading hyphen and"
    , "               --help included."
    , "  --help       Print this text and exit 0."
    , ""
    , "Exit status: 0 the game quit or its window was closed, 1 a failure (the"
    , "folder, the manifest, a script, a request, a provider or cleanup), 2 invalid"
    , "usage, 130 an orderly stop on SIGINT or SIGTERM. A second signal while the"
    , "game is stopping leaves the process at once with status 130, running no"
    , "script, cleanup or flush."
    , ""
    , "Print goes to stdout; warnings and the engine's diagnostics go to stderr."
    , "There is no option to select a provider, a window, a seed or a cadence."
    ]
