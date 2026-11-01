-- | The command line of @hetoimasia run@: a pure function from the arguments after @run@ to a parse, so the
-- grammar is examined without a root, a filesystem, a VM or a window.
--
-- = The grammar (P-71 part 1, D-74)
--
-- > hetoimasia run [--vulkan-validation] [--] GAME_ROOT
-- > hetoimasia run --help
--
-- * Exactly one folder argument. A relative or an absolute path is accepted as written; the content
--   service resolves it once, and nothing here looks at it.
-- * Without the separator, an argument that starts with a hyphen is an unknown option, except the one option
--   below.
-- * After the separator the next argument is literal, @--help@, @--vulkan-validation@ and a leading hyphen included.
-- * @--help@ alone prints the command's help and is not a usage error. @--help@ beside anything else, the
--   option included, is.
-- * @--vulkan-validation@ (LFE-28) asks for Vulkan validation as far as the loader offers it. It is accepted
--   only before GAME_ROOT, with or without the separator after it, and at most once; after the root, given twice,
--   or without a root it is a usage error. Without it nothing is requested.
-- * A missing or an extra argument, and every other option, is a usage error.
--
-- There is no default root, no parent search, no entry override, no mod, seed, cadence or window option and
-- no forwarding of arguments to a script. Nothing in this module reads the environment or the filesystem: the
-- validation choice is a value of this parse, and nothing else (no variable, manifest field or build flag)
-- produces one.
module Hetoimasia.Run.Options
  ( RunParse (..)
  , RunProblem (..)
  , ValidationChoice (..)
  , parseRun
  , validationOption
  , problemReason
  , runUsage
  , runHelp
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Console.Usage (diagnosticText)
import Hetoimasia.GPU.Vulkan.GLFW (ValidationChoice (..))

-- | What a valid command line asks for.
data RunParse
  = -- | @run --help@, alone.
    RunHelp
  | -- | @run [--vulkan-validation] [--] GAME_ROOT@: whether validation was asked for, and the folder, exactly as
    -- typed.
    RunRoot !ValidationChoice !FilePath
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
  | -- | @--vulkan-validation@ given after GAME_ROOT.
    ValidationAfterRoot
  | -- | @--vulkan-validation@ given more than once.
    ValidationRepeated
  deriving (Eq, Show)

-- | The option that asks for Vulkan validation, as typed.
validationOption ∷ String
validationOption = "--vulkan-validation"

-- | Parse the arguments after @run@.
parseRun ∷ [String] → Either RunProblem RunParse
parseRun = \case
  ["--help"] → Right RunHelp
  arguments → options ValidationOff arguments
  where
    -- The options come before the separator and the root, in any number the grammar allows (one).
    options choice = \case
      "--help" : _ → Left HelpNotAlone
      option : rest
        | option == validationOption → case choice of
            ValidationOn → Left ValidationRepeated
            ValidationOff → options ValidationOn rest
      "--" : rest → case rest of
        [] → Left MissingRoot
        [root] → Right (RunRoot choice root)
        _ → Left ExtraArguments
      [] → Left MissingRoot
      first : rest
        | startsWithHyphen first → Left (UnknownOption first)
        | null rest → Right (RunRoot choice first)
        | validationOption `elem` rest → Left ValidationAfterRoot
        | otherwise → Left ExtraArguments
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
  ValidationAfterRoot → "--vulkan-validation must come before GAME_ROOT"
  ValidationRepeated → "--vulkan-validation is given more than once"

-- | The usage line, written to stderr by a usage error.
runUsage ∷ Text
runUsage = "Usage: hetoimasia run [--vulkan-validation] [--] GAME_ROOT | hetoimasia run --help"

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
    , "  --vulkan-validation"
    , "               Ask for Vulkan validation: the Khronos validation layer and"
    , "               synchronization validation, each only if the loader offers"
    , "               it. One the loader lacks is dropped with a warning, never a"
    , "               failure; what was asked and what was enabled is logged once"
    , "               before the first window. Off unless given, and only before"
    , "               GAME_ROOT."
    , "  --           Everything after it is the folder, a leading hyphen,"
    , "               --help and --vulkan-validation included."
    , "  --help       Print this text and exit 0."
    , ""
    , "Exit status: 0 the game quit or its window was closed, 1 a failure (the"
    , "folder, the manifest, a script, a request, a provider or cleanup), 2 invalid"
    , "usage, 130 an orderly stop on SIGINT or SIGTERM. A second signal while the"
    , "game is stopping leaves the process at once with status 130, running no"
    , "script, cleanup or flush."
    , ""
    , "Print goes to stdout; warnings and the engine's diagnostics go to stderr."
    , "There is no option to select a provider, a window, a seed or a cadence;"
    , "--vulkan-validation is the only option besides --help."
    ]
