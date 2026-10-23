-- | An export table crossing into Lua by reference (LFE-11): the very table the VM holds, pushed on
-- the owner under the protected boundary, with its functions, its cycles and its shared upvalues
-- as they are; never a copy; refused when it names another VM's table or a slot that holds none.
--
-- Every example runs a real interpreter through the public owner. A binding hands the table to a
-- script, and the script reports what it sees, so "the same table" is read from Lua's own
-- @rawequal@ and from a counter that lives in the module's upvalue.
module Test.Lua.Boundary.ExportTable (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Hetoimasia.Scripting.Lua.Internal.ExportTypes (ExportHandle (..))
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (libraries)

-- | A module whose table has a cycle, a function and an upvalue it shares.
cyclic ∷ Text
cyclic =
  Text.unlines
    [ "local count = 0"
    , "local t = { id = 'cyc' }"
    , "t.self = t"
    , "t.bump = function() count = count + 1 return count end"
    , "return t"
    ]

driver ∷ ModuleSource
driver =
  ModuleSource
    (ModuleRef "driver" "1")
    ( encodeUtf8 . Text.unlines $
        [ "function probe()"
        , "  local a = t.exports()"
        , "  local b = t.exports()"
        , "  return rawequal(a, b), a.self == a, a.bump(), b.bump(), a.id"
        , "end"
        ]
    )
    [EntryPoint "probe" Required [] [SBoolean, SBoolean, SInteger, SInteger, SText]]

-- | A registration whose one binding hands out the table the reference names.
registered ∷ IORef ExportHandle → Registration
registered ref = either (error . show) id (registration [] [namespace "t" [exporting]])
  where
    exporting = stateOperation "exports" [] [SExportTable] $ \_ → do
      handle ← readIORef ref
      pure [exportTableValue handle]

configOf ∷ IORef ExportHandle → VmConfig
configOf ref =
  (vmConfig libraries)
    { vmRegistration = registered ref
    , vmPolicy = ["t"]
    , vmOwnerName = "export table owner"
    }

-- | The table a module came to, or the example fails.
evaluated ∷ OwnedVm → Text → Text → IO ExportHandle
evaluated owned name body = do
  outcome ← evaluateExport owned (ExportSource (ExportIdentity (encodeUtf8 name)) name (encodeUtf8 body))
  case outcome of
    ExportReady handle → pure handle
    ExportFailed fault → expectationFailure ("the module failed: " <> show fault) >> error "unreachable"

spec ∷ Spec
spec = describe "an export table crossing into Lua by reference" $ do
  it "is the very table the VM holds: the same each time, with its cycle, its function and its upvalue as they are" $ do
    ref ← newIORef (error "no table yet")
    withVmOwner (configOf ref) $ \owned → do
      handle ← loadModule owned driver
      writeIORef ref =<< evaluated owned "cyc" cyclic
      outcome ← callEntry owned handle "probe" []
      outcome `shouldBe` Returned [VBoolean True, VBoolean True, VInteger 1, VInteger 2, VText "cyc"]
      -- The count lives in the module's upvalue: a second call goes on from where the first stopped.
      callEntry owned handle "probe" [] >>= (`shouldBe` Returned [VBoolean True, VBoolean True, VInteger 3, VInteger 4, VText "cyc"])
      retrieved ← retrieveExport owned (ExportIdentity "cyc")
      retrieved `shouldSatisfy` \case Just (ExportReady _) → True; _ → False

  it "is refused when it names another VM's table: checked against the VM that builds the crossing" $ do
    foreignRef ← newIORef (error "no table yet")
    ref ← newIORef (error "no table yet")
    withVmOwner (configOf foreignRef) $ \other →
      withVmOwner (configOf ref) $ \owned → do
        handle ← loadModule owned driver
        writeIORef ref =<< evaluated other "cyc" cyclic
        outcome ← try (callEntry owned handle "probe" [])
        case outcome of
          Left failure
            | Just fault ← fromException (failure ∷ SomeException) →
                boundaryReason fault `shouldSatisfy` \case ValueRefused refusal → refusalRule refusal == RuleForeignHandle; _ → False
          other' → expectationFailure ("expected a refusal, found " <> show other')

  it "is refused as an engine fault, not a crash or a nil, when the slot holds no table" $ do
    ref ← newIORef (error "no table yet")
    withVmOwner (configOf ref) $ \owned → do
      handle ← loadModule owned driver
      real ← evaluated owned "cyc" cyclic
      writeIORef ref real {exportHandleSlot = exportHandleSlot real + 1000}
      outcome ← try (callEntry owned handle "probe" [])
      case outcome of
        Left failure
          | Just fault ← fromException (failure ∷ SomeException) →
              boundaryReason fault `shouldSatisfy` \case InternalError _ → True; _ → False
        other -> expectationFailure ("expected a fault, found " <> show other)
