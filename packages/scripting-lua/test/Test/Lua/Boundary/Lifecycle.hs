-- | A lifecycle operation is delivered only to an owner that was configured with a lifecycle
-- context, and is then handed that owner's own context and no other.
--
-- Everything here is about the host library alone: the context is an opaque value of the
-- application's runtime that the library never reads, so the examples use plain values for it.
-- What an application does with one is the runtime adapter's (LUA-23).
module Test.Lua.Boundary.Lifecycle (spec) where

import Control.Exception (SomeException, tryWithContext)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
  ( BoundaryFault (..)
  , Effect (..)
  , FaultReason (NotYetSupported)
  , VmConfig (vmInitialChunks, vmLifecycle, vmOwnerName, vmPolicy, vmRegistration)
  , chunkName
  , vmConfig
  )
import Hetoimasia.Scripting.Lua.Registration
  ( BindingKind (AsynchronousNativeRequest, LifecycleOperation)
  , Registration
  , asynchronousNativeRequest
  , finalizerEligible
  , fromLifecycleContext
  , lifecycleContext
  , lifecycleOperation
  , lifecycleOperationIn
  , namespace
  , registration
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SText), Value (VText))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Boundary.Support (chunk, libraries, run, runFault, withOwnerOf)
import Test.Lua.Owner.Support (causeOf)

-- | What the actions ran, oldest first.
note ∷ IORef [Text] → Text → IO ()
note ref line = atomicModifyIORef' ref (\held → (held <> [line], ()))

-- | Lifecycle operations of each shape, an asynchronous request, and a lifecycle operation a
-- finalizer may call.
lifecycleRegistration ∷ IORef [Text] → Registration
lifecycleRegistration ref =
  either (error . show) id $
    registration
      []
      [ namespace
          "life"
          [ lifecycleOperation "plain" [] [] (\_ → note ref "plain: ran" >> pure [])
          , lifecycleOperationIn "context" [] [SText] $ \context _ → do
              note ref "context: ran"
              pure [VText (fromMaybe "none" (fromLifecycleContext context))]
          , asynchronousNativeRequest "async" [] [] (\_ → note ref "async: ran" >> pure [])
          , finalizerEligible (lifecycleOperation "gc" [] [] (\_ → note ref "gc: ran" >> pure []))
          ]
      ]

-- | An owner granted @life@, configured with this lifecycle context if it has one.
owner ∷ IORef [Text] → Maybe Text → VmConfig
owner ref context =
  (vmConfig libraries)
    { vmRegistration = lifecycleRegistration ref
    , vmPolicy = ["life"]
    , vmOwnerName = "lifecycle owner"
    , vmLifecycle = lifecycleContext <$> context
    }

spec ∷ Spec
spec = describe "lifecycle operations" $ do
  it "are refused as not yet supported, their actions never run, by an owner configured with no lifecycle context" $ do
    ref ← newIORef []
    withOwnerOf (owner ref Nothing) $ \owned → do
      plain ← runFault owned "life.plain()"
      boundaryReason plain `shouldBe` NotYetSupported LifecycleOperation
      boundaryEffect plain `shouldBe` LuaRan
      inContext ← runFault owned "life.context()"
      boundaryReason inContext `shouldBe` NotYetSupported LifecycleOperation
    readIORef ref >>= (`shouldBe` [])

  it "are delivered to an owner configured with one, and an action that asks is handed that owner's context" $ do
    ref ← newIORef []
    withOwnerOf (owner ref (Just "granted")) $ \owned →
      run owned (Text.unlines ["life.plain()", "assert(life.context() == 'granted')"])
    readIORef ref >>= (`shouldBe` ["plain: ran", "context: ran"])
    -- Each owner has its own: the one registration serves both.
    first ← newIORef []
    second ← newIORef []
    withOwnerOf (owner first (Just "one")) $ \one →
      withOwnerOf (owner second (Just "two")) $ \two → do
        run one "assert(life.context() == 'one')"
        run two "assert(life.context() == 'two')"

  it "hand an action a context only as the type it was made from" $ do
    ref ← newIORef []
    let config = (owner ref Nothing) {vmLifecycle = Just (lifecycleContext (7 ∷ Int))}
    withOwnerOf config $ \owned → run owned "assert(life.context() == 'none')"
    readIORef ref >>= (`shouldBe` ["context: ran"])

  it "leave an asynchronous request refused whatever context the owner has" $ do
    ref ← newIORef []
    withOwnerOf (owner ref (Just "granted")) $ \owned → do
      fault ← runFault owned "life.async()"
      boundaryReason fault `shouldBe` NotYetSupported AsynchronousNativeRequest
    readIORef ref >>= (`shouldBe` [])

  it "are never delivered when a finalizer may call them, whatever context the owner has" $ do
    ref ← newIORef []
    let config =
          (owner ref (Just "granted"))
            { vmInitialChunks = [(chunkName "guard", chunk "guard = setmetatable({}, {__gc = function() life.gc() end})")]
            }
    outcome ← tryWithContext @SomeException (withOwnerOf config (\_ → pure ()))
    case outcome of
      Right () → expectationFailure "the unsupported call was dropped"
      Left failure → case causeOf failure of
        Just fault → boundaryReason fault `shouldBe` NotYetSupported LifecycleOperation
        Nothing → expectationFailure ("not a boundary fault: " <> show failure)
    readIORef ref >>= (`shouldBe` [])
