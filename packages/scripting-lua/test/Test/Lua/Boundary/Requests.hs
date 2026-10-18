-- | An asynchronous request, and a wait for one's settlement, are delivered only to an owner that
-- was configured with a request context, and are then handed that owner's own context and no
-- other.
--
-- Everything here is about the host library alone: the context is an opaque value of the
-- application's runtime that the library never reads, so the examples use plain values for it.
-- What an application does with one is the runtime adapter's (LUA-7).
module Test.Lua.Boundary.Requests (spec) where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (..)
  , Effect (..)
  , FaultReason (NotYetSupported, SuspendRefused)
  , SuspendRefusal (SuspendOutsideTask)
  , VmConfig (vmOwnerName, vmPolicy, vmRegistration, vmRequests)
  , vmConfig
  )
import Hetoimasia.Scripting.Lua.Registration
  ( BindingKind (AsynchronousNativeRequest, SchedulerOperation)
  , Registration
  , WaitKind (WaitSettlement)
  , asynchronousNativeRequest
  , asynchronousNativeRequestIn
  , capabilityType
  , fromRequestContext
  , namespace
  , registration
  , requestContext
  , waitOperation
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SText), Value (VText))
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Boundary.Support (libraries, run, runFault, withOwnerOf)

-- | What the actions ran, oldest first.
note ∷ IORef [Text] → Text → IO ()
note ref line = atomicModifyIORef' ref (\held → (held <> [line], ()))

-- | Requests of each shape, and a wait for one.
requestRegistration ∷ IORef [Text] → Registration
requestRegistration ref =
  either (error . show) id $
    registration
      [capabilityType "request" (const (pure True))]
      [ namespace
          "req"
          [ asynchronousNativeRequest "plain" [] [] (\_ → note ref "plain: ran" >> pure [])
          , asynchronousNativeRequestIn "context" [] [SText] $ \context _ → do
              note ref "context: ran"
              pure [VText (fromMaybe "none" (fromRequestContext context))]
          , waitOperation "wait" WaitSettlement [SCapability "request"]
          ]
      ]

-- | An owner granted @req@, configured with this request context if it has one.
owner ∷ IORef [Text] → Maybe Text → VmConfig
owner ref context =
  (vmConfig libraries)
    { vmRegistration = requestRegistration ref
    , vmPolicy = ["req"]
    , vmOwnerName = "request owner"
    , vmRequests = requestContext <$> context
    }

spec ∷ Spec
spec = describe "asynchronous requests" $ do
  it "are refused as not yet supported, their actions never run, by an owner configured with no request context" $ do
    ref ← newIORef []
    withOwnerOf (owner ref Nothing) $ \owned → do
      plain ← runFault owned "req.plain()"
      boundaryReason plain `shouldBe` NotYetSupported AsynchronousNativeRequest
      boundaryEffect plain `shouldBe` LuaRan
      inContext ← runFault owned "req.context()"
      boundaryReason inContext `shouldBe` NotYetSupported AsynchronousNativeRequest
    readIORef ref >>= (`shouldBe` [])

  it "are delivered to an owner configured with one, and an action that asks is handed that owner's context" $ do
    ref ← newIORef []
    withOwnerOf (owner ref (Just "granted")) $ \owned →
      run owned (Text.unlines ["req.plain()", "assert(req.context() == 'granted')"])
    readIORef ref >>= (`shouldBe` ["plain: ran", "context: ran"])
    -- Each owner has its own: the one registration serves both.
    first ← newIORef []
    second ← newIORef []
    withOwnerOf (owner first (Just "one")) $ \one →
      withOwnerOf (owner second (Just "two")) $ \two → do
        run one "assert(req.context() == 'one')"
        run two "assert(req.context() == 'two')"

  it "hand an action a context only as the type it was made from" $ do
    ref ← newIORef []
    let config = (owner ref Nothing) {vmRequests = Just (requestContext (7 ∷ Int))}
    withOwnerOf config $ \owned → run owned "assert(req.context() == 'none')"
    readIORef ref >>= (`shouldBe` ["context: ran"])

  describe "a wait for one's settlement" $ do
    it "is refused as not yet supported by an owner configured with no request context, before anything else is looked at" $ do
      ref ← newIORef []
      withOwnerOf (owner ref Nothing) $ \owned → do
        fault ← runFault owned "req.wait(nil)"
        boundaryReason fault `shouldBe` NotYetSupported SchedulerOperation

    it "is delivered to an owner configured with one, which refuses it where it cannot reach a scheduler, as any wait is" $ do
      ref ← newIORef []
      withOwnerOf (owner ref (Just "granted")) $ \owned → do
        fault ← runFault owned "req.wait(nil)"
        -- Past the not-yet-supported check, it is the argument that is refused, then the place.
        boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
