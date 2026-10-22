{-# LANGUAGE OverloadedStrings #-}

-- | The M1 selection of a role's behavior: the field each role selects, the
-- cadence rules of each with their numeric boundaries, the profile's limits for
-- export modules and the request that carries them. Pure: what a behavior table
-- read as goes in, an interval or a refusal comes out.
module Test.LuaEngine.Behavior (spec) where

import Data.Word (Word64)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import Hetoimasia.Foundation.Time (durationNanoseconds)
import Hetoimasia.LuaEngine.Behavior
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.LuaEngine.Profile
import Hetoimasia.Scripting.Lua.Instance (BehaviorFacade (FacadeData), BehaviorRequest (..), Interval (..))
import Hetoimasia.Scripting.Lua.Owner
  ( BehaviorShape (..)
  , CadenceField (..)
  , ExportIdentity (ExportIdentity)
  , ExportLimits (..)
  )
import Hetoimasia.Scripting.Lua.Scheduled (ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Value (Value (VText))
import Test.Hspec

-- | A behavior with an update hook and these cadence fields.
withUpdate ∷ CadenceField → CadenceField → BehaviorShape
withUpdate = BehaviorShape False True False

-- | A behavior with no update hook and these cadence fields.
withoutUpdate ∷ CadenceField → CadenceField → BehaviorShape
withoutUpdate = BehaviorShape True False True

-- | The nanoseconds of an elapsed interval.
nanosecondsOf ∷ Either CadenceRefusal (Maybe Interval) → Either CadenceRefusal (Maybe Integer)
nanosecondsOf = fmap (fmap interval)
  where
    interval = \case
      ElapsedEvery duration → toInteger (durationNanoseconds duration)
      other → error ("not an elapsed interval: " <> show other)

-- | What the exact value of a double converts to, written independently: integer
-- arithmetic on the exact rational the double is, rounded upward, against the
-- largest positive 64-bit count.
oracle ∷ Double → Either CadenceRefusal (Maybe Integer)
oracle number
  | count <= toInteger (maxBound ∷ Word64) = Right (Just count)
  | otherwise = Left SecondsTooLarge
  where
    count = ceiling (toRational number * 1000000000)

spec ∷ Spec
spec = describe "the M1 behavior selection" $ do
  describe "roles" $ do
    it "selects exactly the field of the role" $ do
      behaviorField Gameplay `shouldBe` "gameplay"
      behaviorField Presentation `shouldBe` "presentation"

  describe "limits" $ do
    it "take the fixed profile's source and identity ceilings: one mebibyte and 256" $
      exportLimits fixedM1Profile `shouldBe` ExportLimits {exportMaxSourceBytes = 1048576, exportMaxIdentities = 256}

    it "follow a smaller validated profile" $ do
      let spec' = profileSpec fixedM1Profile
          smaller =
            spec'
              { specBytes = \limit → if limit == ModuleSourceBytes then Bytes 4096 else specBytes spec' limit
              , specCounts = \limit → if limit == ModuleIdentitiesPerVm then Count 64 else specCounts spec' limit
              }
      case validateProfile smaller of
        Right profile → exportLimits profile `shouldBe` ExportLimits {exportMaxSourceBytes = 4096, exportMaxIdentities = 64}
        Left problems → expectationFailure ("the smaller profile was refused: " <> show problems)

  describe "gameplay cadence" $ do
    it "defaults to every tick, and takes the integer endpoints" $ do
      cadenceOf Gameplay (withUpdate FieldAbsent FieldAbsent) `shouldBe` Right (Just (LogicalTicks 1))
      cadenceOf Gameplay (withUpdate (FieldInteger 1) FieldAbsent) `shouldBe` Right (Just (LogicalTicks 1))
      cadenceOf Gameplay (withUpdate (FieldInteger 7) FieldAbsent) `shouldBe` Right (Just (LogicalTicks 7))
      cadenceOf Gameplay (withUpdate (FieldInteger maxBound) FieldAbsent) `shouldBe` Right (Just (LogicalTicks 9223372036854775807))

    it "refuses zero, negatives, floats of any value, strings and other types" $ do
      cadenceOf Gameplay (withUpdate (FieldInteger 0) FieldAbsent) `shouldBe` Left (TicksNotPositive 0)
      cadenceOf Gameplay (withUpdate (FieldInteger (-3)) FieldAbsent) `shouldBe` Left (TicksNotPositive (-3))
      cadenceOf Gameplay (withUpdate (FieldInteger minBound) FieldAbsent) `shouldBe` Left (TicksNotPositive minBound)
      -- An integer-valued float is a float: no coercion.
      cadenceOf Gameplay (withUpdate (FieldFloat 1.0) FieldAbsent) `shouldBe` Left (TicksNotInteger (FieldFloat 1.0))
      cadenceOf Gameplay (withUpdate (FieldFloat 2.5) FieldAbsent) `shouldBe` Left (TicksNotInteger (FieldFloat 2.5))
      cadenceOf Gameplay (withUpdate (FieldOther "string") FieldAbsent) `shouldBe` Left (TicksNotInteger (FieldOther "string"))
      -- 2^63 is not an integer: Lua reads it as a float.
      cadenceOf Gameplay (withUpdate (FieldFloat 9.223372036854775808e18) FieldAbsent) `shouldBe` Left (TicksNotInteger (FieldFloat 9.223372036854775808e18))

    it "refuses every_seconds, whatever it holds and whether or not ticks are given" $ do
      cadenceOf Gameplay (withUpdate FieldAbsent (FieldInteger 1)) `shouldBe` Left (FieldNotAllowed Gameplay EverySeconds)
      cadenceOf Gameplay (withUpdate FieldAbsent (FieldFloat 0.5)) `shouldBe` Left (FieldNotAllowed Gameplay EverySeconds)
      cadenceOf Gameplay (withUpdate (FieldInteger 2) (FieldInteger 1)) `shouldBe` Left (FieldNotAllowed Gameplay EverySeconds)

  describe "presentation cadence" $ do
    it "requires every_seconds and refuses every_ticks" $ do
      cadenceOf Presentation (withUpdate FieldAbsent FieldAbsent) `shouldBe` Left SecondsRequired
      cadenceOf Presentation (withUpdate (FieldInteger 1) (FieldInteger 1)) `shouldBe` Left (FieldNotAllowed Presentation EveryTicks)
      cadenceOf Presentation (withUpdate (FieldInteger 1) FieldAbsent) `shouldBe` Left (FieldNotAllowed Presentation EveryTicks)

    it "takes either Lua number type, finite and positive" $ do
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger 2))) `shouldBe` Right (Just 2000000000)
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 0.5))) `shouldBe` Right (Just 500000000)
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 2.0))) `shouldBe` Right (Just 2000000000)
      cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger 0)) `shouldBe` Left SecondsNotPositive
      cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger (-1))) `shouldBe` Left SecondsNotPositive
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 0)) `shouldBe` Left SecondsNotPositive
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat (-0.0))) `shouldBe` Left SecondsNotPositive
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat (-2))) `shouldBe` Left SecondsNotPositive
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat (0 / 0))) `shouldBe` Left SecondsNotFinite
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat (1 / 0))) `shouldBe` Left SecondsNotFinite
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat (-1 / 0))) `shouldBe` Left SecondsNotFinite
      cadenceOf Presentation (withUpdate FieldAbsent (FieldOther "string")) `shouldBe` Left (SecondsNotNumber (FieldOther "string"))

    it "rounds a positive sub-nanosecond input upward to one nanosecond, never to zero" $ do
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 1.0e-10))) `shouldBe` Right (Just 1)
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 5.0e-324))) `shouldBe` Right (Just 1)
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 1.0e-9))) `shouldSatisfy` (`elem` [Right (Just 1), Right (Just 2)])

    it "converts the exact value the number represents, rounded upward, and not the literal or a floating product" $ do
      -- The nearest double to a tenth is slightly above it: its exact value times
      -- 1e9 is just over a hundred million, which rounds upward.
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 0.1))) `shouldBe` Right (Just 100000001)
      -- A dyadic fraction is exact, and rounds to nothing.
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 0.25))) `shouldBe` Right (Just 250000000)
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 1.5e-9))) `shouldBe` oracle 1.5e-9

    it "refuses what does not fit a positive 64-bit count of nanoseconds, with no wrapping or saturation" $ do
      nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger 18446744073))) `shouldBe` Right (Just 18446744073000000000)
      cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger 18446744074)) `shouldBe` Left SecondsTooLarge
      cadenceOf Presentation (withUpdate FieldAbsent (FieldInteger maxBound)) `shouldBe` Left SecondsTooLarge
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 18446744074)) `shouldBe` Left SecondsTooLarge
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 1.0e300)) `shouldBe` Left SecondsTooLarge
      cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat 1.7976931348623157e308)) `shouldBe` Left SecondsTooLarge

    it "agrees with exact integer arithmetic on both sides of the largest count, over the doubles neighbours it" $ do
      let boundary = 18446744073.709551616 ∷ Double
          step by = castWord64ToDouble (fromIntegral (toInteger (castDoubleToWord64 boundary) + by))
          neighbours = [step by | by ← [-3 .. 3]]
      [nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat number))) | number ← neighbours]
        `shouldBe` map oracle neighbours
      -- The test is not vacuous: both outcomes occur among them.
      let outcomes = map oracle neighbours
      outcomes `shouldSatisfy` any (either (const False) (const True))
      outcomes `shouldSatisfy` any (either (const True) (const False))

    it "agrees with exact integer arithmetic across a spread of magnitudes" $ do
      let numbers = [10 ^^ e * m | e ← [-12 .. 10 ∷ Int], m ← [1, 1.1, 2.5, 3.3333333333333335, 9.999999999999998]] ∷ [Double]
      [nanosecondsOf (cadenceOf Presentation (withUpdate FieldAbsent (FieldFloat number))) | number ← numbers]
        `shouldBe` map oracle numbers

  describe "a behavior without an update hook" $ do
    it "has no cadence, and refuses either field on it" $ do
      cadenceOf Gameplay (withoutUpdate FieldAbsent FieldAbsent) `shouldBe` Right Nothing
      cadenceOf Presentation (withoutUpdate FieldAbsent FieldAbsent) `shouldBe` Right Nothing
      cadenceOf Gameplay (withoutUpdate (FieldInteger 1) FieldAbsent) `shouldBe` Left (CadenceWithoutUpdate EveryTicks)
      cadenceOf Presentation (withoutUpdate FieldAbsent (FieldFloat 0.5)) `shouldBe` Left (CadenceWithoutUpdate EverySeconds)
      cadenceOf Gameplay (withoutUpdate FieldAbsent (FieldInteger 1)) `shouldBe` Left (CadenceWithoutUpdate EverySeconds)
      cadenceOf Presentation (withoutUpdate (FieldInteger 1) FieldAbsent) `shouldBe` Left (CadenceWithoutUpdate EveryTicks)

  describe "the request" $ do
    it "carries the role's field, the injected facade and the role's rule, applied to what a table read as" $ do
      let request = behaviorRequest Presentation (ExportIdentity "root/main.lua") "main.lua" (FacadeData (VText "facade")) (Just "ui") OrdinaryClass
      behaviorSelect request `shouldBe` "presentation"
      behaviorFacade request `shouldBe` FacadeData (VText "facade")
      behaviorExport request `shouldBe` ExportIdentity "root/main.lua"
      behaviorName request `shouldBe` Just "ui"
      fmap (fmap (\interval → case interval of ElapsedEvery duration → durationNanoseconds duration; _ → 0)) (behaviorCadence request (withUpdate FieldAbsent (FieldFloat 0.5)))
        `shouldBe` Right (Just 500000000)
      behaviorCadence request (withUpdate (FieldInteger 1) FieldAbsent) `shouldSatisfy` either (const True) (const False)
