{-# LANGUAGE CApiFFI #-}

-- | Whether a process is still running, read from outside it.
--
-- Signal 0 cannot answer that: a process that has exited but has not been
-- reaped — a zombie — still accepts it. A descendant the launcher
-- ("Test.GLFW.Native.Child") kills is exactly that until its parent waits for
-- it, and once the child that started it has exited, that parent is whatever
-- adopts orphans — init, a container's init such as @tini@ under
-- @docker run --init@, or launchd — which reaps it in its own time. The
-- launcher does not wait for it, so it may still be a zombie when the launcher
-- returns.
--
-- 'inspectPresence' asks @ps -o stat= -p <pid>@ instead, bounded by the
-- launcher's own deadline. A process @ps@ does not list is 'Absent', one whose
-- state is @Z@ is a 'Zombie', and both are 'gone'; any other state is
-- 'Running'. A state is read only as this platform's @ps@ documents it — one
-- run-state letter followed by its own modifiers — so a @ps@ that cannot be
-- started, misses its deadline, or answers anything else, a malformed state
-- included, fails the inspection with what it did answer, and is never read as
-- gone.
module Test.GLFW.Native.Presence
  ( Presence (..)
  , gone
  , presenceFrom
  , inspectPresence
  , inspectPresenceUsing
  , withZombie
  ) where

import Control.Exception (IOException, displayException, finally, try)
import Control.Monad (unless)
import Data.Char (isSpace)
import Foreign.C.Error (Errno (..), errnoToIOError)
import Foreign.C.Types (CInt (..))
import System.Exit (ExitCode (..))
import System.Info (os)
import System.Posix.Types (CPid (..), ProcessID)
import System.Process (createProcess, getPid, proc, waitForProcess)
import Test.GLFW.Native.Child (ChildEnd (..), Launched (..), launchCommand)

-- | What @ps@ reported about a process.
data Presence
  = Running !String
    -- ^ Listed in this state, which is not a zombie's.
  | Zombie
    -- ^ Exited, and not yet reaped by its parent.
  | Absent
    -- ^ Not listed at all.
  deriving (Eq, Show)

-- | Whether the process has ended, reaped or not.
gone ∷ Presence → Bool
gone = \case
  Running _ → False
  Zombie → True
  Absent → True

-- | Read how @ps -o stat= -p <pid>@ ended and what it wrote, on the named
-- platform, as 'System.Info.os' names it. It lists a process it finds as one
-- state word and exits 0, and exits 1 writing nothing when it finds none, on
-- Linux's procps and on macOS alike; every other answer, a state word that
-- platform's @ps@ does not document included, is a failed inspection,
-- described.
presenceFrom ∷ String → ChildEnd → String → String → Either String Presence
presenceFrom platform end out err = case end of
  ChildExpired seconds _ → Left ("did not answer within its " <> show seconds <> "-second deadline")
  ChildExited _
    | Nothing ← states → Left ("has no known state codes on platform " <> show platform)
  ChildExited ExitSuccess
    | [state@(first : modifiers)] ← words out
    , Just (runStates, modifierCodes) ← states
    , first `elem` runStates
    , all (`elem` modifierCodes) modifiers
    , blank err →
        Right (if first == 'Z' then Zombie else Running state)
  ChildExited (ExitFailure 1)
    | blank out
    , blank err →
        Right Absent
  ChildExited code →
    Left ("ended " <> show code <> ", writing " <> show out <> " and on stderr " <> show err)
  where
    blank = all isSpace
    -- The run states and the modifiers that may follow one, as procps's ps(1)
    -- and macOS's ps(1) list them for the stat keyword.
    states ∷ Maybe (String, String)
    states = lookup platform [("linux", ("DIRSTtWXZ", "<NLsl+")), ("darwin", ("IRSTUZ", "+<>AELNSsVWX"))]

-- | Ask @ps@ about a process, failing the inspection unless it answers.
inspectPresence ∷ ProcessID → IO Presence
inspectPresence = inspectPresenceUsing "ps"

-- | 'inspectPresence' through the given @ps@ command.
inspectPresenceUsing ∷ FilePath → ProcessID → IO Presence
inspectPresenceUsing command pid = do
  asked ← try (launchCommand inspectionDeadline command ["-o", "stat=", "-p", show pid])
  either failure pure $ case asked of
    Left (problem ∷ IOException) → Left ("could not be started: " <> displayException problem)
    Right answer → presenceFrom os (launchedEnd answer) (launchedOut answer) (launchedErr answer)
  where
    failure reason =
      ioError (userError ("could not tell whether process " <> show pid <> " is running: " <> command <> " " <> reason))
    inspectionDeadline = 10

-- | Run an action with the identifier of a child of this process that has
-- exited and has not been reaped, and reap it afterwards. The zombie is
-- observed, not waited for with a timer: 'awaitUnreapedExit' returns once the
-- kernel reports the exit, and leaves the child waitable.
withZombie ∷ (ProcessID → IO a) → IO a
withZombie action = do
  (_, _, _, handle) ← createProcess (proc "true" [])
  pid ← getPid handle >>= maybe (ioError (userError "true was reaped before its identifier was read")) pure
  (awaitUnreapedExit pid >> action pid) `finally` waitForProcess handle

awaitUnreapedExit ∷ ProcessID → IO ()
awaitUnreapedExit pid = do
  errno ← c_awaitUnreapedExit pid
  unless (errno == 0) $
    ioError (errnoToIOError ("waitid for process " <> show pid) (Errno errno) Nothing Nothing)

foreign import capi safe "hetoimasia_glfw_test_process.h hetoimasia_glfw_test_await_unreaped_exit"
  c_awaitUnreapedExit ∷ CPid → IO CInt
