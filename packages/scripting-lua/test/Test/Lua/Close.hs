-- | Closing a VM, once.
--
-- Close is terminal and happens exactly once. What makes that worth proving is
-- the order it has to hold under: @lua_close@ runs the interpreter's finalizers,
-- including the one that frees each pushed Haskell function, so anything the
-- callbacks borrowed has to outlive it; and a cancellation arriving in the
-- middle must not release those dependencies early, nor leave a half-finished
-- close for a later call to start again.
--
-- The scope these examples run under is this suite's own, not @withResource@.
-- An unrestricted @lua_close@ is not a release that the resource contract's
-- mask discipline describes, and pretending otherwise would claim a property
-- this slice has not established; LUA-2 owns the protected owner that will.
module Test.Lua.Close (spec) where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , Exception
  , SomeException
  , fromException
  , mask_
  , throwIO
  , try
  )
import Hetoimasia.Scripting.Lua.Bridge
  ( CloseFault (closeFailures)
  , Library (LibraryBase)
  , Vm
  , VmClosed
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain)
import Test.Lua.Support (ScopeFailure (BodyFailed, CloseFailed), runScoped)
import Test.Support.Bounded (bounded)

newtype BodyBroke = BodyBroke String
  deriving (Eq, Show)

instance Exception BodyBroke

newtype ReleaseBroke = ReleaseBroke String
  deriving (Eq, Show)

instance Exception ReleaseBroke

spec ∷ Spec
spec = describe "close" $ do
  it "refuses every operation after the close, rather than reaching a freed state" $ do
    vm ← newVm [LibraryBase]
    closeVm vm
    vmPhase vm >>= (`shouldBe` Closed)
    outcome ← try @VmClosed (evalChunk vm (chunkName "after") "local ignored = 1")
    case outcome of
      Right () → expectationFailure "the closed VM ran a chunk"
      Left _ → pure ()

  it "treats a second close as a no-op rather than a second free" $ do
    vm ← newVm []
    closeVm vm
    closeVm vm
    vmPhase vm >>= (`shouldBe` Closed)

  it "releases a callback's borrowed dependency once, and only at the close" $ do
    vm ← newVm [LibraryBase]
    releases ← newMVar (0 ∷ Int)
    installCallback
      vm
      "used"
      (pure NoResult)
      (modifyMVar_ releases (pure . succ))
    evalChunk vm (chunkName "use") "used()"
    -- Lua could still call back, so nothing has been released.
    readMVar releases >>= (`shouldBe` 0)
    closeVm vm
    readMVar releases >>= (`shouldBe` 1)
    closeVm vm
    readMVar releases >>= (`shouldBe` 1)

  it "reports the body's failure ahead of the close's, retaining both" $ do
    vm ← newVm [LibraryBase]
    installCallback vm "used" (pure NoResult) (throwIO (ReleaseBroke "the release failed"))
    outcome ← runScoped vm $ \scoped → do
      evalChunk scoped (chunkName "use") "used()"
      throwIO (BodyBroke "the body failed")
    case outcome of
      Right () → expectationFailure "the scope reported success"
      Left (CloseFailed _) → expectationFailure "the close displaced the body's failure"
      Left (BodyFailed failed alsoFailed) → do
        fromException failed `shouldBe` Just (BodyBroke "the body failed")
        case alsoFailed >>= fromException of
          Just fault → case closeFailures fault of
            [retained] →
              fromException retained `shouldBe` Just (ReleaseBroke "the release failed")
            other → expectationFailure ("the close retained " <> show (length other) <> " failures")
          Nothing → expectationFailure "the close failure was not retained"

  it "reports a close failure on its own when the body succeeded" $ do
    vm ← newVm [LibraryBase]
    installCallback vm "used" (pure NoResult) (throwIO (ReleaseBroke "the release failed"))
    outcome ← runScoped vm (\scoped → evalChunk scoped (chunkName "use") "used()")
    case outcome of
      Right () → expectationFailure "the close failure was dropped"
      Left (BodyFailed _ _) → expectationFailure "a body failure was invented"
      Left (CloseFailed failed) → case fromException failed of
        Just fault → length (closeFailures fault) `shouldBe` 1
        Nothing → expectationFailure "the close raised something else"

  it "attempts every release rather than stopping at the first that failed" $ do
    vm ← newVm [LibraryBase]
    installCallback vm "first" (pure NoResult) (throwIO (ReleaseBroke "first"))
    installCallback vm "second" (pure NoResult) (throwIO (ReleaseBroke "second"))
    outcome ← try @CloseFault (closeVm vm)
    case outcome of
      Right () → expectationFailure "the close reported success"
      Left fault → length (closeFailures fault) `shouldBe` 2

  it "cannot be cancelled into releasing early or into a retried partial close" $ do
    vm ← newVm [LibraryBase]
    releases ← newMVar (0 ∷ Int)
    installCallback vm "used" (pure NoResult) (modifyMVar_ releases (pure . succ))
    evalChunk vm (chunkName "use") "used()"
    finished ← newEmptyMVar
    -- Forked under a mask, so the child is masked from its first instruction:
    -- a cancellation that landed before the close began would prove nothing
    -- about a close being interrupted.
    closer ← mask_ (forkIO (try @SomeException (closeVm vm) >>= putMVar finished))
    -- Repeated cancellation of the closing thread. The close is masked, so none
    -- of these can land inside it.
    mapM_ (\_ → throwTo closer UserInterrupt) [1 .. 5 ∷ Int]
    outcome ← bounded (takeMVar finished)
    case outcome of
      Left thrown → expectationFailure ("the close failed: " <> show thrown)
      Right () → pure ()
    vmPhase vm >>= (`shouldBe` Closed)
    readMVar releases >>= (`shouldBe` 1)
    -- Closing again releases nothing further: the close was complete, not
    -- partial.
    closeVm vm
    readMVar releases >>= (`shouldBe` 1)

  it "retains a callback's release even when publishing it was cancelled" $ do
    vm ← newVm [LibraryBase]
    releases ← newMVar (0 ∷ Int)
    entered ← newEmptyMVar
    released ← newEmptyMVar
    raised ← newEmptyMVar
    installCallback
      vm
      "hold"
      (putMVar entered () >> takeMVar released >> pure NoResult)
      (pure ())
    -- Publishing a global now runs Haskell, and that Haskell can be paused.
    evalChunk vm (chunkName "trap") "setmetatable(_G, {__newindex = function(t, k, v) hold() end})"
    installer ←
      forkIO $ do
        outcome ←
          try @SomeException
            ( installCallback
                vm
                "later"
                (pure NoResult)
                (modifyMVar_ releases (pure . succ))
            )
        putMVar raised outcome
    bounded (takeMVar entered)
    _ ← forkIO (throwTo installer UserInterrupt)
    putMVar released ()
    _ ← bounded (takeMVar raised)
    -- However that install ended, its borrowed dependency was retained before
    -- anything was published, so the close still frees it exactly once.
    closeVm vm
    readMVar releases >>= (`shouldBe` 1)

  it "reports a Haskell finalizer that failed while the interpreter closed" $ do
    vm ← newVm [LibraryBase]
    installCallback vm "boom" (throwIO (ReleaseBroke "the finalizer failed")) (pure ())
    -- Lua marks a value for finalization when its metatable is set, so this
    -- runs during lua_close.
    evalChunk vm (chunkName "finalizer") "guard = setmetatable({}, {__gc = function() boom() end})"
    outcome ← try @CloseFault (closeVm vm)
    case outcome of
      Right () → expectationFailure "the close reported success"
      Left fault → case closeFailures fault of
        [failed] → fromException failed `shouldBe` Just (ReleaseBroke "the finalizer failed")
        other → expectationFailure ("the close reported " <> show (length other) <> " failures")

  it "reports every finalizer that failed, not only the first" $ do
    vm ← newVm [LibraryBase]
    installCallback vm "first_boom" (throwIO (ReleaseBroke "first")) (pure ())
    installCallback vm "second_boom" (throwIO (ReleaseBroke "second")) (pure ())
    -- Two values marked for finalization, so lua_close runs two callbacks that
    -- fail. The close is not one operation, and keeping the first would be
    -- dropping the other.
    evalChunk
      vm
      (chunkName "finalizers")
      ( "first_guard = setmetatable({}, {__gc = function() first_boom() end})\n"
          <> "second_guard = setmetatable({}, {__gc = function() second_boom() end})\n"
      )
    outcome ← try @CloseFault (closeVm vm)
    case outcome of
      Right () → expectationFailure "the close reported success"
      Left fault → do
        length (closeFailures fault) `shouldBe` 2
        let reported = [failed | Just failed ← map fromException (closeFailures fault)]
        reported `shouldContain` [ReleaseBroke "first"]
        reported `shouldContain` [ReleaseBroke "second"]

  it "makes a second close wait for the teardown rather than report it done" $ do
    vm ← newVm [LibraryBase]
    order ← newMVar ([] ∷ [String])
    let note entry = modifyMVar_ order (pure . (<> [entry]))
    finalizing ← newEmptyMVar
    release ← newEmptyMVar
    firstDone ← newEmptyMVar
    secondDone ← newEmptyMVar
    installCallback
      vm
      "linger"
      (putMVar finalizing () >> takeMVar release >> note "finalizer-left" >> pure NoResult)
      (pure ())
    evalChunk vm (chunkName "finalizer") "guard = setmetatable({}, {__gc = function() linger() end})"
    _ ← forkIO (closeVm vm >> note "first-close" >> putMVar firstDone ())
    bounded (takeMVar finalizing)
    _ ← forkIO (closeVm vm >> note "second-close" >> putMVar secondDone ())
    putMVar release ()
    bounded (takeMVar firstDone)
    bounded (takeMVar secondDone)
    -- The second caller cannot report a finished close while the interpreter is
    -- still running a finalizer that calls back into Haskell.
    entries ← readMVar order
    take 1 entries `shouldBe` ["finalizer-left"]
    entries `shouldContain` ["second-close"]

  it "leaves a VM closed even when the chunk that ran last failed" $ do
    vm ← newVm [LibraryBase] ∷ IO Vm
    _ ← try @SomeException (evalChunk vm (chunkName "raise") "error('boom')")
    closeVm vm
    vmPhase vm >>= (`shouldBe` Closed)
