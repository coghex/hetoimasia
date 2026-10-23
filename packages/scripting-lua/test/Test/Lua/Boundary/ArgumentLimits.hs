-- | A binding's own bound on the crossing of its arguments ('withArgumentLimits'): the reader applies,
-- for each of bytes, depth and elements, the smaller of the owner's limit and the binding's, while it
-- reads. A binding with none keeps the owner's, a binding can only tighten, the results of a bound
-- binding and every other binding are unchanged, and the refusal is the one the owner's limits give:
-- an ordinary Lua error for an opted-in binding, a fault of the call for a generic one.
--
-- Everything runs a chunk in a real interpreter. The bindings note what their actions did, so a call
-- refused at a limit is seen to have run nothing, and the stack and the registry are read before and
-- after many accepted and refused calls.
module Test.Lua.Boundary.ArgumentLimits (spec) where

import Control.Exception (SomeException, fromException, try)
import Control.Monad (forM, replicateM_)
import Data.List (nub)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm)
import Hetoimasia.Scripting.Lua.Internal.Vm (stackDepth)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (refusal, run, runFault, withOwnerOf)
import Test.Lua.Owner.Support (runOwner)
import Hetoimasia.Scripting.Lua.Internal.Owner (OwnerConfig (..), defaultOwnerConfig)
import Test.Lua.Support (referenceSlot)

newtype Fx = Fx (IORef [Text])

note ∷ Fx → Text → IO ()
note (Fx ref) entry = atomicModifyIORef' ref (\held → (entry : held, ()))

logged ∷ Fx → IO [Text]
logged (Fx ref) = reverse <$> readIORef ref

limitsOf ∷ Int → Int → Int → ValueLimits
limitsOf bytes depth elements = either (error . show) id (valueLimits bytes depth elements)

-- | Lists of numbers in, the same out, under these bounds of the binding: a list of n numbers is
-- 5 + 18 n bytes, n + 1 elements and depth 1.
registrationOf ∷ Fx → Registration
registrationOf fx = either (error . ("registration refused: " <>) . show) id (registration [] [scoped])
  where
    echo name wrap = wrap (snapshotQuery name [SList SNumber] [SList SNumber] (\values → note fx name >> pure values))
    nested name wrap = wrap (snapshotQuery name [SList (SList SNumber)] [SInteger] (\_ → note fx name >> pure [VInteger 0]))
    scoped =
      namespace
        "scoped"
        [ echo "open" recoverableRefusals
        , echo "bytes" (recoverableRefusals . withArgumentLimits (limitsOf 59 8 4096))
        , echo "elements" (recoverableRefusals . withArgumentLimits (limitsOf 65536 8 4))
        , nested "depth" (recoverableRefusals . withArgumentLimits (limitsOf 65536 2 4096))
        , echo "wider" (recoverableRefusals . withArgumentLimits (limitsOf 1048576 64 65536))
        , echo "generic_bytes" (withArgumentLimits (limitsOf 59 8 4096))
        , echo "generic_elements" (withArgumentLimits (limitsOf 65536 8 4))
        , -- A bound on what comes in leaves what goes out to the owner's.
          withArgumentLimits (limitsOf 59 8 4096) . recoverableRefusals $
            snapshotQuery "grow" [SInteger] [SList SNumber] $ \arguments → do
              note fx "grow"
              pure $ case arguments of
                [VInteger n] → [VList (map VInteger [1 .. n])]
                _ → []
        ]

-- | The owner's own limits: 59 bytes, depth 8 and 4,096 elements.
config ∷ Fx → Int → VmConfig
config fx bytes =
  (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
    { vmRegistration = registrationOf fx
    , vmPolicy = ["scoped"]
    , vmOwnerName = "argument limits"
    , vmValueLimits = limitsOf bytes 8 4096
    }

withFx ∷ Int → (Fx → OwnedVm → IO a) → IO a
withFx ownerBytes body = do
  fx ← Fx <$> newIORef []
  withOwnerOf (config fx ownerBytes) (body fx)

-- | What a chunk that catches the call and checks its message says.
caught ∷ Text → Text → Text
caught call expected = "do local ok, err = pcall(function() " <> call <> " end); assert(ok == false and err == '" <> expected <> "', tostring(err)) end"

readings ∷ OwnedVm → IO (Int, Int)
readings owned = (,) <$> stackDepth (ownedInternalVm owned) <*> (fromIntegral <$> referenceSlot (ownedInternalVm owned))

spec ∷ Spec
spec = describe "a binding's argument limits" $ do
  tightening
  refusing
  disciplined
  allocation

tightening ∷ Spec
tightening = describe "tighten the owner's, and only tighten" $ do
  it "keep the owner's limits for a binding that declares none" $
    withFx 65536 $ \fx owned → do
      run owned "assert(#scoped.open({1, 2, 3, 4, 5, 6, 7, 8, 9, 10}) == 10)"
      logged fx >>= (`shouldBe` ["open"])

  it "read a copy at the binding's byte limit and refuse one past it, while the owner's limit would admit both" $
    withFx 65536 $ \fx owned → do
      run owned "assert(#scoped.bytes({1, 2, 3}) == 3)"
      run owned (caught "scoped.bytes({1, 2, 3, 4})" "scoped.bytes: argument 1: more than 59 bytes")
      run owned "assert(#scoped.open({1, 2, 3, 4}) == 4)"
      logged fx >>= (`shouldBe` ["bytes", "open"])

  it "read a copy at the binding's element limit and refuse one past it" $
    withFx 65536 $ \fx owned → do
      -- A list of three numbers is four elements: the list and each number.
      run owned "assert(#scoped.elements({1, 2, 3}) == 3)"
      run owned (caught "scoped.elements({1, 2, 3, 4})" "scoped.elements: argument 1: more than 4 values")
      logged fx >>= (`shouldBe` ["elements"])

  it "read nesting at the binding's depth limit and refuse one past it" $
    withFx 65536 $ \fx owned → do
      run owned "assert(scoped.depth({{1}}) == 0)"
      run owned (caught "scoped.depth({{{1}}})" "scoped.depth: argument 1: nested deeper than 2")
      logged fx >>= (`shouldBe` ["depth"])

  it "never widen the owner's: the smaller of the two applies, so a wider binding is held to the owner's limit" $
    withFx 59 $ \fx owned → do
      run owned "assert(#scoped.wider({1, 2, 3}) == 3)"
      run owned (caught "scoped.wider({1, 2, 3, 4})" "scoped.wider: argument 1: more than 59 bytes")
      logged fx >>= (`shouldBe` ["wider"])

  it "bound the arguments only: results are held to the owner's limits, and a bound binding can answer more than it accepts" $
    withFx 65536 $ \fx owned → do
      run owned "assert(#scoped.grow(40) == 40)"
      run owned (caught "scoped.grow(1.5)" "scoped.grow: argument 1: a float where an integer is declared")
      logged fx >>= (`shouldBe` ["grow"])

  it "are readable from the binding, and absent unless declared" $ do
    fx ← Fx <$> newIORef []
    let found name = case [b | ns ← registrationNamespaces (registrationOf fx), namespaceName ns == "scoped", b ← namespaceBindings ns, bindingName b == name] of
          b : _ → bindingArgumentLimits b
          [] → error "no such binding"
    found "open" `shouldBe` Nothing
    found "bytes" `shouldBe` Just (limitsOf 59 8 4096)

refusing ∷ Spec
refusing = describe "refuse as the owner's limits would" $ do
  it "as a typed fault of the call for a generic binding, after visiting no more than the limit plus one" $
    withFx 65536 $ \fx owned → do
      fault ← runFault owned "local t = {}; for i = 1, 100000 do t[i] = i end; scoped.generic_elements(t)"
      case refusal fault of
        Just found → do
          refusalRule found `shouldBe` RuleElementLimit 4
          refusalVisited found `shouldSatisfy` (<= 5)
        Nothing → fail "the fault was not the refusal of a value"
      logged fx >>= (`shouldBe` []) 
      fault' ← runFault owned "local t = {}; for i = 1, 50 do t[i] = i end; scoped.generic_bytes(t)"
      fmap refusalRule (refusal fault') `shouldBe` Just (RuleBytesLimit 59)

  it "as an ordinary error pcall catches for an opted-in binding, whatever the size of the input, and the call goes on" $
    withFx 65536 $ \fx owned → do
      run owned (caught "local t = {}; for i = 1, 100000 do t[i] = i end; scoped.elements(t)" "scoped.elements: argument 1: more than 4 values")
      run owned "assert(#scoped.elements({1}) == 1)"
      logged fx >>= (`shouldBe` ["elements"])

disciplined ∷ Spec
disciplined =
  it "leave the stack and the registry as they found them across accepted and refused calls" $
    withFx 65536 $ \_ owned → do
      before ← readings owned
      replicateM_ 300 $ do
        run
          owned
          ( Text.unlines
              [ "assert(#scoped.bytes({1, 2, 3}) == 3)"
              , "assert(pcall(scoped.bytes, {1, 2, 3, 4}) == false)"
              , "assert(pcall(scoped.elements, {1, 2, 3, 4}) == false)"
              , "assert(pcall(scoped.depth, {{{1}}}) == false)"
              , "assert(#scoped.open({1, 2, 3, 4}) == 4)"
              ]
          )
        _ ← try @SomeException (run owned "scoped.generic_bytes({1, 2, 3, 4})")
        pure ()
      readings owned >>= (`shouldBe` before)

-- | Memory running out wherever the bounded read or the refusal is built is a classified failure: a fault of
-- the call or the interpreter's own error, never a panic, an unclassified exception or a stack left deeper.
allocation ∷ Spec
allocation =
  it "is a classified failure wherever memory runs out while a bounded argument is read or refused, with the stack as it was" $ do
    fx ← Fx <$> newIORef []
    outcomes ←
      forM [0, 50 .. 100000] $ \budget → do
        result ←
          runOwner
            ( (defaultOwnerConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
                { ownerBudget = Just budget
                , ownerRegistration = registrationOf fx
                , ownerGranted = ["scoped"]
                , ownerLimits = limitsOf 65536 8 4096
                }
            )
            $ \owned → do
              depth ← stackDepth (ownedInternalVm owned)
              forM
                [ ("within", "assert(#scoped.bytes({1, 2, 3}) == 3)")
                , ("over", "assert(pcall(scoped.bytes, {1, 2, 3, 4}) == false)")
                , ("elements", "local t = {}; for i = 1, 40 do t[i] = i end; assert(pcall(scoped.elements, t) == false)")
                , ("generic", "scoped.generic_bytes({1, 2, 3, 4})")
                ]
                $ \(label, source) → do
                  outcome ← try @SomeException (run owned source)
                  after ← stackDepth (ownedInternalVm owned)
                  after `shouldBe` depth
                  pure (label <> ":" <> classified outcome)
        pure $ case result of
          Right steps → steps
          Left _ → ["construction"]
    let kinds = nub (concat outcomes)
    filter (Text.isInfixOf "unclassified") kinds `shouldBe` []
    kinds `shouldSatisfy` elem "within:ok"
    kinds `shouldSatisfy` elem "over:ok"
    kinds `shouldSatisfy` elem "generic:refused"

classified ∷ Either SomeException a → Text
classified = \case
  Right _ → "ok"
  Left failure
    | Just (fault ∷ LuaFault) ← fromException failure, faultKind fault == MemoryExhausted → "memory in Lua"
    | Just (fault ∷ BoundaryFault) ← fromException failure → case boundaryReason fault of
        ScriptFailed MemoryExhausted _ → "memory at the boundary"
        ValueRefused _ → "refused"
        other → "unclassified " <> Text.pack (show other)
    | otherwise → "unclassified " <> Text.pack (show failure)
