-- | A check of a binding's copied argument values, made after the host's own checks of them and
-- before the action ('withArgumentCheck'): a fact only the values carry (an integer that is
-- positive, a sum that is representable) is an ordinary Lua error like any other refusal made
-- before the action, and nothing else about the binding changes.
--
-- Everything runs a chunk in a real interpreter. The fixture's bindings note what their actions
-- did, so a refused call is seen to have run nothing.
module Test.Lua.Boundary.ArgumentChecks (spec) where

import Control.Exception (IOException, SomeException, fromException, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (refusal, run, runFault, withOwnerOf)

-- | What the bindings observe.
data Fx = Fx
  { fxLog ∷ !(IORef [Text])
    -- ^ The actions that ran, oldest last, and the checks, in the order they were made.
  , fxLive ∷ !(IORef (Set Word64))
  }

note ∷ Fx → Text → IO ()
note fx entry = atomicModifyIORef' (fxLog fx) (\held → (entry : held, ()))

logged ∷ Fx → IO [Text]
logged fx = reverse <$> readIORef (fxLog fx)

registrationOf ∷ Fx → Registration
registrationOf fx = either (error . ("registration refused: " <>) . show) id (registration [capabilityType "ticket" alive] [checked])
  where
    alive key = Set.member key <$> readIORef (fxLive fx)
    positive name = \_ values → do
      note fx ("check " <> name)
      pure $ case values of
        [VInteger n] | n <= 0 → Just "not a positive integer"
        _ → Nothing
    checked =
      namespace
        "checked"
        [ withArgumentCheck (positive "positive") (stateOperation "positive" [SInteger] [SInteger] (\arguments → note fx "positive" >> pure arguments))
        , withArgumentCheck
            ( \_ values → do
                note fx "check sum"
                pure $ case values of
                  [VInteger a, VInteger b] | a + b > 100 → Just ("the sum " <> Text.pack (show (a + b)) <> " passes 100")
                  _ → Nothing
            )
            (stateOperation "sum" [SInteger, SInteger] [SInteger] (\arguments → note fx "sum" >> pure (case arguments of [VInteger a, VInteger b] → [VInteger (a + b)]; _ → [])))
        , -- A precondition first, then the argument check: the order they were added in is the order they run in.
          withArgumentCheck (positive "second") . withPrecondition (\_ → note fx "precondition" >> pure Nothing) $
            stateOperation "ordered" [SInteger] [] (\_ → note fx "ordered" >> pure [])
        , withArgumentCheck (\_ _ → ioError (userError "the check failed")) (stateOperation "explodes" [SInteger] [] (\_ → note fx "explodes" >> pure []))
        , withArgumentCheck (\_ _ → pure (Just (Text.replicate (refusalReasonLimit + 1) "r"))) (stateOperation "wordy" [SInteger] [] (\_ → note fx "wordy" >> pure []))
        , withArgumentCheck (positive "ticket") (stateOperation "redeem" [SCapability "ticket"] [] (\_ → note fx "redeem" >> pure []))
        , snapshotQuery "ticket" [SInteger] [SCapability "ticket"] $ \arguments → case arguments of
            [VInteger key] → do
              atomicModifyIORef' (fxLive fx) (\held → (Set.insert (fromIntegral key) held, ()))
              pure [VCapability (capability "ticket" (fromIntegral key))]
            _ → pure []
        ]

withFx ∷ (Fx → OwnedVm → IO a) → IO a
withFx body = do
  fx ← Fx <$> newIORef [] <*> newIORef Set.empty
  withOwnerOf
    (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
      { vmRegistration = registrationOf fx
      , vmPolicy = ["checked"]
      , vmOwnerName = "argument checks"
      }
    (body fx)

-- | What a chunk that catches the call, checks it was refused with this message, and goes on says.
caught ∷ Text → Text → Text
caught call expected = "do local ok, err = pcall(function() " <> call <> " end); assert(ok == false and err == '" <> expected <> "', tostring(err)) end"

spec ∷ Spec
spec = describe "a check of the copied argument values" $ do
  it "refuses what only the values carry as an ordinary Lua error pcall catches, runs no action and lets the invocation succeed" $
    withFx $ \fx owned → do
      run owned (caught "checked.positive(0)" "checked.positive: not a positive integer")
      run owned (caught "checked.positive(-5)" "checked.positive: not a positive integer")
      run owned (caught "checked.sum(60, 41)" "checked.sum: the sum 101 passes 100")
      run owned "assert(checked.positive(3) == 3 and checked.sum(60, 40) == 100)"
      logged fx
        >>= (`shouldBe` ["check positive", "check positive", "check sum", "check positive", "positive", "check sum", "sum"])

  it "decides after the host's own checks of the values: a value of the wrong shape never reaches it" $
    withFx $ \fx owned → do
      run owned (caught "checked.positive(1.5)" "checked.positive: argument 1: a float where an integer is declared")
      run owned (caught "checked.positive('a')" "checked.positive: argument 1: expected integer, found string")
      run owned (caught "checked.sum(1)" "checked.sum: the arguments: expected 2 values, found 1")
      logged fx >>= (`shouldBe` [])

  it "decides after a handle has been found live, so a handle that has ended is refused as one and never reaches it" $
    withFx $ \fx owned → do
      run owned "ticket = checked.ticket(7); checked.redeem(ticket)"
      atomicModifyIORef' (fxLive fx) (\held → (Set.delete 7 held, ()))
      run owned (caught "checked.redeem(ticket)" "checked.redeem: argument 1: a ticket handle that has ended")
      logged fx >>= (`shouldBe` ["check ticket", "redeem"])

  it "runs after a precondition, in the order they were added" $
    withFx $ \fx owned → do
      run owned "checked.ordered(1)"
      run owned (caught "checked.ordered(0)" "checked.ordered: not a positive integer")
      logged fx >>= (`shouldBe` ["precondition", "check second", "ordered", "precondition", "check second"])

  it "is the application's own failure when it raises, with its type, however the script catches" $
    withFx $ \fx owned → do
      outcome ← try @SomeException (run owned "local ok = pcall(checked.explodes, 1); assert(ok == false)")
      case outcome of
        Left failure | Just raised ← fromException failure → show (raised ∷ IOException) `shouldBe` "user error (the check failed)"
        other → expectationFailure ("not the check's own failure: " <> show other)
      logged fx >>= (`shouldBe` [])

  it "is a defect of the application when its reason passes the bound, a typed fault of the call whatever the script does" $
    withFx $ \fx owned → do
      fault ← runFault owned "pcall(checked.wordy, 1)"
      fmap refusalRule (refusal fault) `shouldSatisfy` (== Just (RuleBytesLimit refusalReasonLimit))
      logged fx >>= (`shouldBe` [])
