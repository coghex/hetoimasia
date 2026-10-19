-- | Registered once, exposed per owner, nothing shared (requirement 3; D-14, D-15, P-2).
module Test.Domains.Exposure (spec) where

import Data.List (intersect, sort)
import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configExtensions, configGameplaySource, configUiSource)
  , Extension (extensionNamespace)
  , defaultConfig
  )
import Hetoimasia.Sample.LuaDomains.Bounds (defaultBounds)
import Hetoimasia.Sample.LuaDomains.Registration (allNamespaces, gameplayNamespaces, sampleRegistration, uiNamespaces)
import Hetoimasia.Sample.LuaDomains.Shared (newShared, scriptedInputs)
import Hetoimasia.Scripting.Lua.Registration
  ( bindingArguments
  , bindingName
  , bindingResults
  , namespaceBindings
  , namespaceName
  , registrationCapabilityTypes
  , registrationNamespaces
  )
import Hetoimasia.Scripting.Lua.Value (Schema (..))
import Test.Domains.Support
import Test.Hspec

-- | A probe in each VM: which of the sample's namespaces its globals hold, what the other VM's
-- global reads as, and the global it sets for the other VM to look for.
probe ∷ String → String → String → [String]
probe own other value =
  [ own <> "_global = '" <> value <> "'"
  , "function init(self, api)"
  , "  local seen = {}"
  , "  for _, name in ipairs({'view', 'intent_raw', 'intent', 'input', 'ui', 'world', 'staging', 'rand', 'fx'}) do"
  , "    if _G[name] ~= nil then seen[#seen + 1] = name end"
  , "  end"
  , "  fx.record('" <> own <> " sees ' .. table.concat(seen, ','))"
  , "  fx.record('" <> own <> " reads the other global ' .. tostring(" <> other <> "_global))"
  , "end"
  , "function update(self, dt) " <> (if own == "ui" then "ui.updated() " else "staging.finish() ") <> "end"
  ]

spec ∷ Spec
spec = describe "exposure" $ do
  it "shows each owner only its own namespaces, and leaves a global one VM sets unreadable in the other" $
    withSample
      (\config → config {configGameplaySource = luaLinesOf (probe "gameplay" "ui" "from gameplay"), configUiSource = luaLinesOf (probe "ui" "gameplay" "from the UI")})
      $ \fx _ _ → do
        fxLines fx
          `shouldReturn` [ "gameplay sees world,staging,rand,fx"
                         , "gameplay reads the other global nil"
                         , "ui sees view,intent,input,ui,fx"
                         , "ui reads the other global nil"
                         ]

  it "registers every binding once, names disjoint namespaces for the two policies, and no hook for tests" $ do
    shared ← newShared defaultBounds 1 1 Nothing scriptedInputs
    registered ← either (fail . show) pure (sampleRegistration shared (map extensionNamespace (configExtensions defaultConfig shared)))
    sort (map namespaceName (registrationNamespaces registered)) `shouldBe` sort allNamespaces
    uiNamespaces `intersect` gameplayNamespaces `shouldBe` []
    sort (uiNamespaces <> gameplayNamespaces) `shouldBe` sort allNamespaces
    map namespaceName (registrationNamespaces registered) `shouldNotContain` ["fx"]
    length (configExtensions defaultConfig shared) `shouldBe` 0

  it "gives neither VM a handle into the other: no capability type and no binding mentions one" $ do
    shared ← newShared defaultBounds 1 1 Nothing scriptedInputs
    registered ← either (fail . show) pure (sampleRegistration shared [])
    length (registrationCapabilityTypes registered) `shouldBe` 0
    [ namespaceName space <> "." <> bindingName binding
      | space ← registrationNamespaces registered
      , binding ← namespaceBindings space
      , any mentionsCapability (bindingArguments binding <> bindingResults binding)
      ]
      `shouldBe` []
  where
    luaLinesOf = luaLines . map Text.pack

mentionsCapability ∷ Schema → Bool
mentionsCapability = \case
  SCapability _ → True
  SList inner → mentionsCapability inner
  SOptional inner → mentionsCapability inner
  SRecord fields → any (mentionsCapability . snd) fields
  _ → False
