-- | Registration: what is accepted, what is refused when it is built, and what
-- each binding is eligible for.
--
-- Everything here is checked without an interpreter: a registration is plain
-- data and is validated where it is built. The bounds are pinned at the bound
-- and one past it.
module Test.Lua.Boundary.Registration (spec) where

import Data.Either (isRight)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (ok)

-- | A query that does nothing, for a registration to hold.
query ∷ Text → Binding
query name = snapshotQuery name [] [] (const (pure []))

withBinding ∷ Binding → Either RegistrationRefusal Registration
withBinding binding = registration [capabilityType "ticket" (const (pure True))] [namespace "space" [binding]]

refusedWith ∷ Either RegistrationRefusal a → RegistrationRefusal → IO ()
refusedWith built expected = either Just (const Nothing) built `shouldBe` Just expected

nested ∷ Int → Schema
nested 0 = SInteger
nested n = SList (nested (n - 1))

spec ∷ Spec
spec = describe "registration" $ do
  describe "names" $ do
    it "accepts 1 to 64 ASCII letters, digits and underscores, not starting with a digit" $ do
      let named name = registration [] [namespace name [query "b"]]
      named "a" `shouldSatisfy` isRight
      named "_a1_B" `shouldSatisfy` isRight
      named (Text.replicate maxNameLength "n") `shouldSatisfy` isRight
      named (Text.replicate (maxNameLength + 1) "n") `refusedWith` InvalidName NamespaceName (Text.replicate (maxNameLength + 1) "n") (NameTooLong (maxNameLength + 1))
      named "" `refusedWith` InvalidName NamespaceName "" NameEmpty
      named "1a" `refusedWith` InvalidName NamespaceName "1a" NameBadCharacter
      named "a-b" `refusedWith` InvalidName NamespaceName "a-b" NameBadCharacter
      named "a b" `refusedWith` InvalidName NamespaceName "a b" NameBadCharacter
      named "a.b" `refusedWith` InvalidName NamespaceName "a.b" NameBadCharacter
      named "caf\233" `refusedWith` InvalidName NamespaceName "caf\233" NameBadCharacter
      named "end" `refusedWith` InvalidName NamespaceName "end" NameReserved
      named "goto" `refusedWith` InvalidName NamespaceName "goto" NameReserved

    it "applies the same rules to binding and capability type names" $ do
      withBinding (query "ok") `shouldSatisfy` isRight
      withBinding (query "bad name") `refusedWith` InvalidName BindingName "bad name" NameBadCharacter
      withBinding (query (Text.replicate (maxNameLength + 1) "b")) `refusedWith` InvalidName BindingName (Text.replicate (maxNameLength + 1) "b") (NameTooLong (maxNameLength + 1))
      registration [capabilityType "1bad" (const (pure True))] [] `refusedWith` InvalidName CapabilityTypeName "1bad" NameBadCharacter

    it "refuses a namespace that would shadow a global the standard libraries define" $
      mapM_
        ( \name →
            registration [] [namespace name [query "b"]] `refusedWith` InvalidName NamespaceName name NameShadowsStandardLibrary
        )
        standardGlobals

    it "refuses duplicate namespaces, bindings and capability types" $ do
      registration [] [namespace "a" [query "b"], namespace "a" [query "c"]] `refusedWith` DuplicateNamespace "a"
      registration [] [namespace "a" [query "b", query "b"]] `refusedWith` DuplicateBinding "a" "b"
      registration [capabilityType "t" (const (pure True)), capabilityType "t" (const (pure True))] [] `refusedWith` DuplicateCapabilityType "t"
      -- The same binding name in two namespaces is two bindings.
      registration [] [namespace "a" [query "b"], namespace "c" [query "b"]] `shouldSatisfy` isRight

  describe "bounds" $ do
    it "holds at most 64 namespaces" $ do
      let spaces count = [namespace (Text.pack ("n" <> show i)) [] | i ← [1 .. count ∷ Int]]
      registration [] (spaces maxNamespaces) `shouldSatisfy` isRight
      registration [] (spaces (maxNamespaces + 1)) `refusedWith` TooManyNamespaces (maxNamespaces + 1) maxNamespaces

    it "holds at most 256 bindings in a namespace" $ do
      let bindings count = [query (Text.pack ("b" <> show i)) | i ← [1 .. count ∷ Int]]
      registration [] [namespace "a" (bindings maxBindingsPerNamespace)] `shouldSatisfy` isRight
      registration [] [namespace "a" (bindings (maxBindingsPerNamespace + 1))]
        `refusedWith` TooManyBindings "a" (maxBindingsPerNamespace + 1) maxBindingsPerNamespace

    it "holds at most 64 capability types" $ do
      let kinds count = [capabilityType (Text.pack ("t" <> show i)) (const (pure True)) | i ← [1 .. count ∷ Int]]
      registration (kinds maxCapabilityTypes) [] `shouldSatisfy` isRight
      registration (kinds (maxCapabilityTypes + 1)) [] `refusedWith` TooManyCapabilityTypes (maxCapabilityTypes + 1) maxCapabilityTypes

    it "allows at most 16 arguments and 16 results to a binding" $ do
      let arguments count = snapshotQuery "b" (replicate count SInteger) [] (const (pure []))
          results count = snapshotQuery "b" [] (replicate count SInteger) (const (pure []))
      withBinding (arguments maxArity) `shouldSatisfy` isRight
      withBinding (results maxArity) `shouldSatisfy` isRight
      withBinding (arguments (maxArity + 1)) `refusedWith` ArityTooLarge "space.b" "arguments" (maxArity + 1) maxArity
      withBinding (results (maxArity + 1)) `refusedWith` ArityTooLarge "space.b" "results" (maxArity + 1) maxArity

    it "nests a schema at most 8 deep" $ do
      let taking schema = snapshotQuery "b" [schema] [] (const (pure []))
      withBinding (taking (nested maxSchemaDepth)) `shouldSatisfy` isRight
      withBinding (taking (nested (maxSchemaDepth + 1))) `refusedWith` SchemaTooDeep "space.b" (maxSchemaDepth + 1) maxSchemaDepth

    it "gives a record at most 64 fields, none of them twice" $ do
      let fields count = SRecord [(Text.pack ("f" <> show i), SInteger) | i ← [1 .. count ∷ Int]]
          taking schema = snapshotQuery "b" [schema] [] (const (pure []))
      withBinding (taking (fields maxRecordFields)) `shouldSatisfy` isRight
      withBinding (taking (fields (maxRecordFields + 1))) `refusedWith` SchemaTooWide "space.b" (maxRecordFields + 1) maxRecordFields
      withBinding (taking (SRecord [("a", SInteger), ("a", SText)])) `refusedWith` SchemaDuplicateField "space.b" "a"

    it "refuses a schema that names a capability type the registration does not declare" $ do
      withBinding (snapshotQuery "b" [SCapability "ticket"] [] (const (pure []))) `shouldSatisfy` isRight
      withBinding (snapshotQuery "b" [SList (SCapability "missing")] [] (const (pure [])))
        `refusedWith` UnknownCapabilityType "space.b" "missing"

  describe "eligibility" $ do
    it "is eligible for the direct path only, and for no finalizer, by default" $ do
      let binding = query "b"
      bindingDirect binding `shouldBe` True
      bindingConfined binding `shouldBe` False
      bindingFinalizer binding `shouldBe` False
      mapM_
        (\made → (bindingDirect made, bindingConfined made, bindingFinalizer made) `shouldBe` (True, False, False))
        [ snapshotQuery "q" [] [] (const (pure []))
        , stateOperation "s" [] [] (const (pure []))
        , commandIntention "c" [] (const (pure Accepted))
        , asynchronousNativeRequest "a" [] [] (const (pure []))
        , lifecycleOperation "l" [] [] (const (pure []))
        ]

    it "exposes nothing to the confined path in a default registration" $ do
      let built = ok (registration [capabilityType "ticket" (const (pure True))] [namespace "a" [query "b", stateOperation "s" [SInteger] [SText] (const (pure []))]])
      confinedEligibleBindings built `shouldBe` []

    it "records a confined eligibility, and only for bindings whose schemas are plain bounded values" $ do
      let plain = confinedEligible (snapshotQuery "b" [SList SInteger, SRecord [("a", SText)]] [SBytes] (const (pure [])))
          built = ok (withBinding plain)
      confinedEligibleBindings built `shouldBe` [("space", "b")]
      withBinding (confinedEligible (snapshotQuery "b" [SCapability "ticket"] [] (const (pure []))))
        `refusedWith` ConfinedNeedsPlainValues "space.b"
      withBinding (confinedEligible (snapshotQuery "b" [] [SList (SOptional (SCapability "ticket"))] (const (pure []))))
        `refusedWith` ConfinedNeedsPlainValues "space.b"

    it "needs no confined equivalent for a direct-only binding" $ do
      let built = ok (withBinding (query "b"))
      confinedEligibleBindings built `shouldBe` []
      fmap (map bindingName . namespaceBindings) (registrationNamespaces built) `shouldBe` [["b"]]

    it "can take a binding off the direct path" $ do
      bindingDirect (withoutDirectPath (query "b")) `shouldBe` False

    it "never lets a binding that starts asynchronous work run from a finalizer" $ do
      withBinding (finalizerEligible (asynchronousNativeRequest "a" [] [] (const (pure []))))
        `refusedWith` FinalizerCannotStartWork "space.a"
      withBinding (finalizerEligible (stateOperation "s" [] [] (const (pure [])))) `shouldSatisfy` isRight
      withBinding (finalizerEligible (lifecycleOperation "l" [] [] (const (pure [])))) `shouldSatisfy` isRight

    it "answers a command with acceptance or a bounded rejection, fixed by the kind" $ do
      let built = ok (withBinding (commandIntention "c" [SText] (const (pure Accepted))))
      fmap (map bindingResults . namespaceBindings) (registrationNamespaces built) `shouldBe` [[commandResults]]
      fmap (map bindingKind . namespaceBindings) (registrationNamespaces built) `shouldBe` [[CommandOrUiIntention]]
