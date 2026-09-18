-- | Stack and reference discipline.
--
-- A completed operation leaves the interpreter's stack at the depth it entered
-- at and holds none of the registry references it took, on the paths that
-- failed as well as the one that succeeded. The registry hands a released slot
-- back before it allocates a new one, so taking a reference before an operation
-- and again after it answers the same slot only if everything the operation
-- took was released.
--
-- What a completed operation does not restore is the VM's own state. Loading a
-- library or defining a global is the point of running a chunk, and those
-- entries stay in the registry and the globals table afterwards. The claim
-- being made is about what the bridge borrowed, not about the interpreter being
-- unchanged.
module Test.Lua.Discipline (spec) where

import Control.Exception (Exception, SomeException, throwIO, try)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , LuaFault
  , chunkName
  , evalChunk
  )
import Hetoimasia.Scripting.Lua.Internal.Call (globalIsFunction)
import Hetoimasia.Scripting.Lua.Internal.Callback (installCallback)
import Hetoimasia.Scripting.Lua.Internal.Vm (stackDepth)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Support (referenceSlot, withVm)

newtype DisciplineBroke = DisciplineBroke String
  deriving (Eq, Show)

instance Exception DisciplineBroke

spec ∷ Spec
spec = describe "discipline" $ do
  it "restores the entry stack depth after a chunk that succeeded" $
    withVm [LibraryBase] $ \vm → do
      before ← stackDepth vm
      slot ← referenceSlot vm
      evalChunk vm (chunkName "ok") "local value = 1 + 1"
      stackDepth vm >>= (`shouldBe` before)
      referenceSlot vm >>= (`shouldBe` slot)

  it "restores the entry stack depth and the registry slot after a Lua fault" $
    withVm [LibraryBase] $ \vm → do
      before ← stackDepth vm
      slot ← referenceSlot vm
      outcome ← try @LuaFault (evalChunk vm (chunkName "raise") "error('boom')")
      case outcome of
        Right () → expectationFailure "the chunk succeeded"
        Left _ → pure ()
      stackDepth vm >>= (`shouldBe` before)
      -- The bridge reports a fault without taking a registry reference at all,
      -- because `luaL_ref` can raise a memory error where no protected frame
      -- is left to catch it. The registry is therefore exactly as it was.
      referenceSlot vm >>= (`shouldBe` slot)

  it "restores the entry stack depth after a callback's exception escaped" $
    withVm [LibraryBase] $ \vm → do
      installCallback vm "boom" (throwIO (DisciplineBroke "escaped")) (pure ())
      before ← stackDepth vm
      slot ← referenceSlot vm
      outcome ← try @SomeException (evalChunk vm (chunkName "escape") "pcall(boom)")
      case outcome of
        Right () → expectationFailure "the boundary reported success"
        Left _ → pure ()
      stackDepth vm >>= (`shouldBe` before)
      referenceSlot vm >>= (`shouldBe` slot)

  it "stays balanced across repeated loads and calls" $
    withVm [LibraryBase] $ \vm → do
      before ← stackDepth vm
      slot ← referenceSlot vm
      mapM_
        ( \index → do
            evalChunk vm (chunkName "define") "function defined() end"
            _ ← try @LuaFault (evalChunk vm (chunkName "raise") "error('boom')")
            _ ← try @LuaFault (evalChunk vm (chunkName "bad") "!! not lua")
            pure (index ∷ Int)
        )
        [1 .. 20]
      stackDepth vm >>= (`shouldBe` before)
      referenceSlot vm >>= (`shouldBe` slot)

  it "keeps the VM state a chunk intentionally left behind" $
    withVm [LibraryBase] $ \vm → do
      before ← stackDepth vm
      evalChunk vm (chunkName "define") "function retained() end"
      -- The balance claim is about what the bridge borrowed. The global the
      -- chunk defined is exactly what running it was for, and it is still here.
      globalIsFunction vm "retained" >>= (`shouldBe` True)
      stackDepth vm >>= (`shouldBe` before)
