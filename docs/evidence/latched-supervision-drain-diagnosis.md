# Latched supervision failure and the backend drain: production is not affected

Evidence record, 2026-11-05, on `origin/master` `547a3e44`. Found by #599 (PR #620); requested as a follow-up issue by the owner
(2026-11-02) and withdrawn by the manager once this showed the cycle is test-side only and #599 absorbs the repair. It records a
static trace and a headless model; **no native run was made**.

## Question

After the owner loop is left by a *latched* supervision failure, serving it again re-raises the failure before it services
anything (`checkRuntime`, `packages/runtime/src/Hetoimasia/Runtime/Supervision.hs:658`; a latched fatal failure is delivered by every
later call and never cleared). A window that holds a texture retires only on a served turn, and the texture backend's drain
(`withTextureGraphics`, `Texture.hs:104-108`) waits for that retirement. Does the shipped `hetoimasia run` hang the same way?

## Answer

No. The native test fixture hangs; the shipped command does not.

**The fixture** (`packages/lua-engine-graphics/native-test/Test/LuaEngine/Graphics/Native/Session.hs`, before #599's repair):
`withTextureGraphics` (`:216`) is a scope inside the host's body on the process main thread, which also serves the loop with the
application's control. Each turn calls `checkRuntime control` first (`packages/glfw/runtime-glfw-core/Hetoimasia/Runtime/GLFW/Internal/Host/Loop.hs:224`).

**The shipped command** (`run/Hetoimasia/Run/Graphics.hs`, `run/Hetoimasia/Run/Serve.hs`):

- The backend is on the **session thread** (`Graphics.hs:215`), not around the loop; the main thread owns only the owner application.
- When the loop fails, `serve` asks the session to stop and serves the owner again with `ownerDrain`, which makes its **own**
  supervision (`Graphics.hs:210`, comment `:208-209`; `Serve.hs:134-146`; `docs/run_command.md`, "When something fails during
  shutdown"), `drainAttempts = 3` (`Serve.hs:83`). If the owner still cannot be served it raises without joining, the application's
  protected exit destroys the windows, and the session is joined after (`Serve.hs:128-131`).
- The application's control carries one worker, the graphics owner's sentinel (`Graphics.hs:199`; `Owner/Lifetime.hs:217`); Lua VMs
  run under the session thread's own supervision. A latch in production therefore means the owner latched a required failure. The
  owner then ends its run as on a stop (`Owner/Worker.hs:181`), and the backend reads the owner as ended and fails what it cannot
  prove retired instead of waiting (`Texture/Backend.hs:563`, `:595-610`).

## Model

A scratch executable (source below) built against the repository's `hetoimasia-foundation` and `hetoimasia-runtime` packages, with
`run/Hetoimasia/Run/Serve.hs` and `Settle.hs` linked in unchanged (`Output.hs` is a stand-in with the same `reportText`, because the
real module imports the Lua facade). The latch is real: a required `Service` worker made to fail. Modelled: the window (retires only
on a served turn), the backend drain (waits for that), the loop (`checkRuntime` on the control it is given, then one turn).
Each scenario ran under a process alarm, at the default RTS and at `+RTS -N2`, once each; output identical.

| Scenario | Result |
| --- | --- |
| `fixture`: backend scope on the main thread, loop served again with the application's control | second serving raises the latched failure; the drain was still waiting after 3 s |
| `fixture-fresh`: the same, second serving under a fresh supervision | second serving returns; the scope exits with the latched failure |
| `production`: real `Serve`, wired as `Graphics.hs:207-211` | `Serve` raises the latched failure after the session settled; window retired |
| `production-reuses-control`: `ownerDrain` reuses the application's control | `Serve` raises the loop's failure without joining; window not retired by then (the protected exit's job) |

Raw output of one default-RTS run:

```text
== fixture
  the supervision has latched a required failure; a window that holds a texture has been asked to close
  first serving of the loop: raised Broken
  second serving of the loop (the application's control): raised Broken
  backend scope: its drain was still waiting for the window to retire after 3 s (cut off by this model's timeout)
  application boundary then raised the latched failure: Broken

== fixture-fresh
  the supervision has latched a required failure; a window that holds a texture has been asked to close
  first serving of the loop: raised Broken
  second serving of the loop (fresh supervision): returned
  backend scope left: raised Broken
  application boundary then raised the latched failure: Broken

== production
  the supervision has latched a required failure; the session is running with a window up
  Serve answered: raised Broken
  window retired by the time Serve answered: True
  application boundary then raised the latched failure: Broken

== production-reuses-control
  the supervision has latched a required failure; the session is running with a window up
  Serve answered: raised Broken
  window retired by the time Serve answered: False
  application boundary then raised the latched failure: Broken
```

(The `application boundary then raised the latched failure` line is the model's outer `withSupervision` rethrowing the latch on exit, as it
should; the earlier `fixture` run, before the wording of the timeout line was tidied, printed `backend scope left: raised <<timeout>>`.)

## What this does not show

- The model is not the real composition. A latch with a live window cannot be driven headless there, and no native run was made, so
  the production claim rests on the trace and on the model.
- No example of the shipped composition latches a supervision failure with a window live. `run-native-test/Test/Run/Native/Library.hs:196`
  and `:249` end the loop through the `Observation` hooks (`:340-341`), which raise from the loop's hook, not from a latched
  `checkRuntime`; the fresh supervision of `ownerDrain` is held by the fake-owner examples in `test-full/Test/Engine/Run/Serve.hs`
  (no supervision) and by reading. Adding one needs a seam on `Observation`, which would change a shipped module's surface; that is
  an owner decision and is not made here.

## Consequence

#599 repairs the fixture itself: after the loop is left abnormally it serves the loop again under a fresh supervision, inside the
backend's scope and before its drain, as `ownerDrain` does (the `fixture-fresh` row). No production change and no issue were needed.
Rejected for the fixture by the manager: waiting a bounded time and leaving the killed thread unjoined.

## Rebuild

Scratch project outside the repository, with `Serve.hs` and `Settle.hs` symlinked from `run/Hetoimasia/Run/`, the `Output.hs`
stand-in beside them, and this layout (`PATH=~/.cache/hetoimasia/toolchain/ghc-9.14.1/bin:$PATH`; each run under
`perl -e 'alarm 40; exec @ARGV'`; arguments select scenarios: `fixture`, `fixture-fresh`, `production`, `production-reuses-control`):

`cabal.project`

```text
packages: ., <repo>/packages/foundation, <repo>/packages/runtime
index-state: 2026-09-18T00:00:00Z
semaphore: False
```

`latch-model.cabal`

```cabal
cabal-version: 3.0
name: latch-model
version: 0
build-type: Simple
executable latch-model
    main-is: Main.hs
    hs-source-dirs: app, src
    other-modules: Hetoimasia.Run.Serve, Hetoimasia.Run.Settle, Hetoimasia.Run.Output
    default-language: GHC2024
    default-extensions: UnicodeSyntax OverloadedStrings
    ghc-options: -threaded -rtsopts -Wall
    build-depends: base, stm, text, containers, hetoimasia-foundation, hetoimasia-runtime
```

`app/Main.hs`

```haskell
-- | A headless MODEL of the scopes involved when an owner loop is left by a latched supervision failure.
--
-- Real parts: Hetoimasia.Run.Serve (symlink to run/Hetoimasia/Run/Serve.hs), Hetoimasia.Run.Settle (symlink),
-- Hetoimasia.Runtime.Supervision (withSupervision / startSupervised / checkRuntime), the foundation workers.
-- Modelled parts: the GLFW window ("closing" then "retired", where retirement is only done by a turn of the
-- main thread's loop), the texture backend's drain ("wait until the window retired"), and the loop itself
-- (checkRuntime on the control it is given, then one turn; exactly what runOwnerLoop does each turn).
--
--   fixture      the native test fixture's shape (Native/Session.hs): the backend scope sits on the main thread
--                around the loop, and the loop is served with the application's control.
--   fixture-fresh the same, but the second serving uses a fresh supervision (the production owner drain's move).
--   production   the production shape (Run/Graphics.hs): the backend scope is on the session thread; the main
--                thread runs the real Serve with the owner's ownerServe/ownerDrain wired as Graphics.hs wires them.
--   production-reuses-control  the same, but ownerDrain reuses the application's control instead of a fresh one.
module Main (main) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import Control.Concurrent.STM (TVar, atomically, check, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (Exception, SomeException, finally, throwIO, try)
import Control.Monad (unless, when)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Log
  ( DebugSelection (DebugAll)
  , LogFilter (..)
  , LogLevel (Info)
  , Logger
  , callbackSink
  , mkLogger
  , unsafeComponent
  )
import Hetoimasia.Foundation.Worker (awaitCompletion, workerDefinition)
import Hetoimasia.Run.Serve (Owner (..), serveSpawned)
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
import System.Environment (getArgs)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Timeout (timeout)

data Broken = Broken deriving (Show)

instance Exception Broken

-- | A window that holds a texture: asked to close, then retired only by a turn of the main thread's loop.
data Win = Win {closing ∷ TVar Bool, retired ∷ TVar Bool}

newWin ∷ IO Win
newWin = Win <$> newTVarIO False <*> newTVarIO False

-- | One turn of the main thread's loop: destroy a window that was asked to close.
turn ∷ Win → IO ()
turn w = atomically (readTVar (closing w) >>= \c → when c (writeTVar (retired w) True))

-- | The owner loop: every turn, checkRuntime on the control it was given, then the turn, until over.
loopWith ∷ RuntimeControl → Win → IO () → IO Bool → IO ()
loopWith control w extra over = go
  where
    go = do
      checkRuntime control
      turn w
      extra
      done ← over
      unless done (yield >> go)

-- | The texture backend's scope: on every exit it drains, waiting for the textures of the windows to retire.
backendScope ∷ Win → IO a → IO a
backendScope w body = body `finally` atomically (readTVar (retired w) >>= check)

logger ∷ Logger
logger =
  mkLogger
    LogFilter
      { filterEnabled = True
      , filterGlobalLevel = Info
      , filterComponentLevels = Map.empty
      , filterDebug = DebugAll
      , filterSource = False
      }
    (callbackSink (\_ → pure ()))

-- | Make the application's supervision latch a fatal failure of a required service, and wait until it is published.
latch ∷ RuntimeControl → IO ()
latch control = do
  gate ← newEmptyMVar
  started ←
    startSupervised
      control
      (WorkerPolicy Service Required (unsafeComponent "model.owner") (\_ → pure Unrecognized))
      (workerDefinition "model.owner.supervision" (\_ → pure ()) (\_ () → (readMVar gate >> throwIO Broken ∷ IO ())))
  handle ← case started of
    WorkerStarted h → pure h
    _ → fail "the model worker did not start"
  putMVar gate ()
  _ ← atomically (awaitCompletion (supervisedWorker handle))
  pure ()

say ∷ String → IO ()
say = putStrLn

-- | The fixture: backend scope on the main thread, loop served with the application's control.
fixture ∷ Bool → LoggingLifetime → IO ()
fixture freshSecond lifetime = withSupervision lifetime $ \control → do
  latch control
  w ← newWin
  atomically (writeTVar (closing w) True)
  say "  the supervision has latched a required failure; a window that holds a texture has been asked to close"
  outcome ←
    timeout 3_000_000 . try @SomeException . backendScope w $ do
      first ← try @SomeException (loopWith control w (pure ()) (pure False))
      say ("  first serving of the loop: " <> either (\e → "raised " <> show e) (const "returned") first)
      second ←
        try @SomeException $
          if freshSecond
            then withSupervision lifetime $ \fresh → loopWith fresh w (pure ()) (readTVarIO (retired w))
            else loopWith control w (pure ()) (readTVarIO (retired w))
      say ("  second serving of the loop " <> (if freshSecond then "(fresh supervision)" else "(the application's control)") <> ": " <> either (\e → "raised " <> show e) (const "returned") second)
      either throwIO pure first
  say $ case outcome of
    Nothing → "  backend scope: its drain was still waiting for the window to retire after 3 s (it never returned)"
    Just (Left e) | show e == "<<timeout>>" → "  backend scope: its drain was still waiting for the window to retire after 3 s (cut off by this model's timeout)"
    Just left → "  backend scope left: " <> either (\e → "raised " <> show e) (const "returned") left

-- | The production shape: the real Serve on the main thread, the backend scope on the session thread.
production ∷ Bool → LoggingLifetime → IO ()
production freshDrain lifetime = withSupervision lifetime $ \control → do
  latch control
  w ← newWin
  stop ← newTVarIO False
  let owner =
        Owner
          { ownerServe = \tick over → loopWith control w tick over
          , ownerDrain = \over →
              if freshDrain
                then withSupervision lifetime $ \fresh → loopWith fresh w (pure ()) over
                else loopWith control w (pure ()) over
          , ownerWake = pure ()
          }
      session = backendScope w $ do
        atomically (readTVar stop >>= check)
        atomically (writeTVar (closing w) True)
      stopSession = atomically (writeTVar stop True)
  say "  the supervision has latched a required failure; the session is running with a window up"
  outcome ← try @SomeException (serveSpawned lifetime owner (\_ → pure ()) stopSession (pure ()) session)
  settled ← readTVarIO (retired w)
  say ("  Serve answered: " <> either (\e → "raised " <> take 60 (show e)) (const "returned") outcome)
  say ("  window retired by the time Serve answered: " <> show settled)

scenarios ∷ [(String, LoggingLifetime → IO ())]
scenarios =
  [ ("fixture", fixture False)
  , ("fixture-fresh", fixture True)
  , ("production", production True)
  , ("production-reuses-control", production False)
  ]

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  names ← getArgs
  mapM_ run [s | s@(n, _) ← scenarios, n `elem` names]
  where
    run (name, action) = do
      say ("== " <> name)
      finished ← timeout 8_000_000 (try @SomeException (withLoggingLifetime logger action))
      say $ case finished of
        Nothing → "  RESULT: still blocked after 8 s"
        Just (Left e) → "  application boundary then raised the latched failure: " <> takeWhile (/= '\n') (show e)
        Just (Right ()) → "  application boundary returned"
```
