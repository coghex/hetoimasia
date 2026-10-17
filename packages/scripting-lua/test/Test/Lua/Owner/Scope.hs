-- | The scope an owner runs around each of its VM's callbacks.
--
-- 'withVmOwnerScoped' lets an owner that holds something lend it to a callback
-- and take it back: its scope starts on the callback's own thread after the VM
-- has recorded the thread as one of its callbacks, and ends before the record is
-- removed, however the callback ends. It is told by the VM's own record whether a
-- thread is one of its callbacks. These examples run it through the public
-- configuration where a registered binding is enough, and through the
-- package-private one where the example needs a callback a finalizer reaches or
-- one the finalizer policy refuses.
module Test.Lua.Owner.Scope (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally, throwIO)
import Data.ByteString (ByteString)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Bridge (Library (LibraryBase), chunkName)
import Hetoimasia.Scripting.Lua.Internal.Callback (CallbackResult (NoResult), installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterLibraries, ownerAllowlist, ownerCallbackScope, ownerChunks)
  , defaultOwnerConfig
  )
import Hetoimasia.Scripting.Lua.Owner
  ( CallbackScope (CallbackScope)
  , CallbackSite (siteIsCallback)
  , VmConfig (vmInitialChunks, vmPolicy, vmRegistration)
  , evalOwned
  , vmConfig
  , withVmOwnerScoped
  )
import Hetoimasia.Scripting.Lua.Registration (namespace, registration, stateOperation)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Owner.Support

-- | A scope that notes entering and leaving, keeps the site it was given, and
-- records the thread it ran on.
noting ∷ Events → IORef (Maybe CallbackSite) → IORef [ThreadId] → CallbackScope
noting log' kept threads = CallbackScope $ \site action → do
  note log' "enter"
  writeIORef kept (Just site)
  self ← myThreadId
  atomicPush threads self
  action `finally` note log' "leave"
  where
    atomicPush ref thread = readIORef ref >>= writeIORef ref . (thread :)

source ∷ Text → ByteString
source = Text.encodeUtf8

-- | A public configuration whose one binding, @probe.mark@, notes that it ran.
publicConfig ∷ Events → [(Text, Text)] → VmConfig
publicConfig log' chunks =
  (vmConfig [LibraryBase])
    { vmRegistration = either (error . show) id (registration [] [namespace "probe" [stateOperation "mark" [] [] mark]])
    , vmPolicy = ["probe"]
    , vmInitialChunks = [(chunkName name, source text) | (name, text) ← chunks]
    }
  where
    mark _ = note log' "callback" >> pure []

spec ∷ Spec
spec = describe "the scope around each callback" $ do
  it "runs around each callback on its own thread, for exactly its duration, and not otherwise" $ do
    log' ← newEvents
    kept ← newIORef Nothing
    threads ← newIORef []
    owner ← myThreadId
    withVmOwnerScoped (noting log' kept threads) (publicConfig log' []) $ \vm → do
      note log' "no callback yet"
      evalOwned vm (chunkName "two") (source "probe.mark() probe.mark()")
      note log' "after"
    events log'
      >>= (`shouldBe` ["no callback yet", "enter", "callback", "leave", "enter", "callback", "leave", "after"])
    -- Each callback ran its scope on a thread of its own, none the owner's.
    ran ← readIORef threads
    length ran `shouldBe` 2
    ran `shouldSatisfy` notElem owner
    ran `shouldSatisfy` \found → length (Set.fromList found) == 2

  it "runs for the callbacks of the initial chunks, before the body" $ do
    log' ← newEvents
    kept ← newIORef Nothing
    threads ← newIORef []
    withVmOwnerScoped (noting log' kept threads) (publicConfig log' [("init", "probe.mark()")]) $ \_ →
      note log' "body"
    events log' >>= (`shouldBe` ["enter", "callback", "leave", "body"])

  it "is told by the VM's own record: yes inside the callback, no from a thread it starts and no once it has returned" $ do
    log' ← newEvents
    kept ← newIORef Nothing
    verdicts ← newIORef []
    let record label answer = readIORef verdicts >>= writeIORef verdicts . (<> [(label ∷ Text, answer ∷ Bool)])
        askingScope = CallbackScope $ \site action → do
          record "inside" =<< siteIsCallback site
          child ← newEmptyMVar
          _ ← forkIO (siteIsCallback site >>= record "child" >> putMVar child ())
          takeMVar child
          writeIORef kept (Just site)
          action
    withVmOwnerScoped askingScope (publicConfig log' [("init", "probe.mark()")]) $ \_ → do
      Just site ← readIORef kept
      siteIsCallback site >>= record "owner"
    readIORef verdicts >>= (`shouldBe` [("inside", True), ("child", False), ("owner", False)])
    -- The record is the VM's own: even this thread, after the lifetime has ended,
    -- is no callback.
    Just site ← readIORef kept
    siteIsCallback site >>= (`shouldBe` False)

  it "ends the scope when the callback's action fails, and the failure reaches the caller unchanged" $ do
    log' ← newEvents
    kept ← newIORef Nothing
    threads ← newIORef []
    outcome ←
      runOwner
        ( (defaultOwnerConfig [LibraryBase])
            { ownerCallbackScope = noting log' kept threads
            , ownerAfterLibraries = \vm →
                installCallback vm "boom" (note log' "callback" >> throwIO (BodyBroke "action") >> pure NoResult) (pure ())
            , ownerChunks = [(chunkName "init", source "boom()")]
            }
        )
        (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the callback's failure was dropped"
      Left failure → causeOf failure `shouldBe` Just (BodyBroke "action")
    events log' >>= (`shouldBe` ["enter", "callback", "leave"])

  it "runs for a callback a finalizer reaches that the policy allows, and never for one it refuses" $ do
    log' ← newEvents
    kept ← newIORef Nothing
    threads ← newIORef []
    let config =
          (defaultOwnerConfig [LibraryBase])
            { ownerCallbackScope = noting log' kept threads
            , ownerAllowlist = Set.fromList ["allowed"]
            , ownerAfterLibraries = \vm → do
                installCallback vm "allowed" (note log' "allowed" >> pure NoResult) (pure ())
                installCallback vm "denied" (note log' "denied" >> pure NoResult) (pure ())
            , ownerChunks =
                [ (chunkName "guard", source "guard = setmetatable({}, {__gc = function() allowed() pcall(denied) end})")
                ]
            }
    _ ← runOwner config (\_ → note log' "body")
    -- The body ran with no callback; the finalizer's allowed callback was scoped
    -- and the refused one, which never ran, was not.
    events log' >>= (`shouldBe` ["body", "enter", "allowed", "leave"])
