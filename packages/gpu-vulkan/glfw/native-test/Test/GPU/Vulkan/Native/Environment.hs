-- | The Vulkan environment every native session of this suite runs in, shared
-- or private, established once at the start of the process.
--
-- The provisioned native prefix selects exactly one driver and one layer
-- directory (@VK_DRIVER_FILES@, @VK_LAYER_PATH@), and a machine can override
-- either from its ambient environment without anything saying so. So before
-- any Vulkan call this clears every discovery override it finds and records
-- which, disables implicit layers, and takes the validation layer's own
-- settings out of the environment's hands: every @VK_LAYER_*@ setting but the
-- layer path and every @VK_KHRONOS_VALIDATION_*@ one is cleared, and the
-- layer's settings file is pointed at an empty one, so a machine's settings
-- can neither switch synchronization validation off nor switch anything else
-- on. What is validated is then decided by each instance's own create info
-- and nothing else — 'validationFeatures', chained by the production roots and
-- by the proof sessions alike.
--
-- A child process inherits the environment its parent established and
-- establishes it again, which changes nothing.
module Test.GPU.Vulkan.Native.Environment
  ( establishEnvironment
  , clearConflictingOverrides
  , applyImplicitLayerPolicy
  , validationFeatures
  , validationFeaturesVariable
  , checkValidationFeatures
  ) where

import Control.Monad (forM)
import Data.List (intercalate, isPrefixOf, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)

import Hetoimasia.GPU.Vulkan.GLFW (ValidationFeature (..))

-- | The validation features every validation-enabled instance this suite
-- creates turns on through its own create info.
validationFeatures ∷ [ValidationFeature]
validationFeatures = [SynchronizationValidation]

-- | Where the native prefix says which validation features its layer is pinned
-- to run with (@tools/native/vulkan.pin@).
validationFeaturesVariable ∷ String
validationFeaturesVariable = "HETOIMASIA_VULKAN_VALIDATION_FEATURES"

-- | Hold 'validationFeatures' to the ones the provisioned layer is pinned to.
--
-- The variable enables nothing; it is what the receipt's toolchain identity
-- names. A run that enabled another set would be evidence about a
-- configuration its receipt does not describe, so it is refused.
checkValidationFeatures ∷ IO (Either Text ())
checkValidationFeatures = do
  pinned ← lookupEnv validationFeaturesVariable
  let compiled = sort (map pinName validationFeatures)
  pure $ case pinned of
    Nothing →
      Left
        ( Text.pack validationFeaturesVariable
            <> " is not set, so nothing says which validation features the provisioned layer is pinned to; run through bash tools/vulkan/run.sh"
        )
    Just value
      | sort (filter (not . null) (splitOn ',' value)) == compiled → Right ()
      | otherwise →
          Left
            ( "the provisioned layer is pinned to the validation features "
                <> Text.pack (show value)
                <> ", but this suite enables "
                <> Text.pack (show (intercalate "," compiled))
            )
  where
    pinName SynchronizationValidation = "synchronization"

splitOn ∷ Char → String → [String]
splitOn separator value = case break (== separator) value of
  (before, []) → [before]
  (before, _ : rest) → before : splitOn separator rest

-- | Everything below, in order, with a line for each thing it did.
establishEnvironment ∷ IO [Text]
establishEnvironment = do
  cleared ← clearConflictingOverrides
  implicit ← applyImplicitLayerPolicy
  settings ← applySettingsPolicy
  pure (map ("cleared a conflicting override: " <>) cleared <> ["implicit-layer policy: " <> implicit, "layer settings: " <> settings])

-- | The ambient overrides that could substitute a driver or a layer, or change
-- what the layer validates.
conflictingOverrides ∷ [String]
conflictingOverrides =
  [ -- Driver discovery and selection.
    "VK_ICD_FILENAMES"
  , "VK_ADD_DRIVER_FILES"
  , "VK_LOADER_DRIVERS_SELECT"
  , "VK_LOADER_DRIVERS_DISABLE"
  , -- Explicit layer discovery, and the legacy list that force-enables layers.
    "VK_ADD_LAYER_PATH"
  , "VK_INSTANCE_LAYERS"
  , -- Implicit layers, which need no request from the application at all and
    -- would otherwise join the chain unrecorded.
    "VK_IMPLICIT_LAYER_PATH"
  , "VK_ADD_IMPLICIT_LAYER_PATH"
  , -- The loader's own layer filters. `DISABLE` is the dangerous one: it can
    -- switch off the validation layer this suite requested, leaving a run that
    -- reported zero validation errors because nothing was validating.
    "VK_LOADER_LAYERS_ENABLE"
  , "VK_LOADER_LAYERS_DISABLE"
  , "VK_LOADER_LAYERS_ALLOW"
  ]

-- | Whether a variable is one of the validation layer's own settings, which it
-- reads from the environment ahead of its settings file. @VK_LAYER_PATH@ is
-- the prefix's selection, not a setting, and is kept; @VK_LAYER_SETTINGS_PATH@
-- is replaced by 'applySettingsPolicy' rather than cleared.
layerSetting ∷ String → Bool
layerSetting name =
  (("VK_LAYER_" `isPrefixOf` name) && name `notElem` ["VK_LAYER_PATH", "VK_LAYER_SETTINGS_PATH"])
    || "VK_KHRONOS_VALIDATION_" `isPrefixOf` name

-- | Clear every conflicting override present, and say which.
clearConflictingOverrides ∷ IO [Text]
clearConflictingOverrides = do
  settings ← filter layerSetting . map fst <$> getEnvironment
  fmap concat . forM (conflictingOverrides <> settings) $ \name → do
    present ← lookupEnv name
    case present of
      Nothing → pure []
      Just value → do
        unsetEnv name
        pure [Text.pack name <> "=" <> Text.pack value]

-- | The loader filter that disables every implicit layer. Scrubbing the ambient
-- overrides only returns the loader to its default implicit-layer search; this
-- switches that search off, so the chain is exactly the explicit layers a
-- session asked for and nothing a machine happened to have installed.
implicitLayerFilter ∷ String
implicitLayerFilter = "VK_LOADER_LAYERS_DISABLE"

implicitLayerPolicy ∷ Text
implicitLayerPolicy = "~implicit~"

-- | Disable implicit layers, after the ambient overrides have been cleared.
-- Returns the policy actually in force, for the record.
applyImplicitLayerPolicy ∷ IO Text
applyImplicitLayerPolicy = do
  setEnv implicitLayerFilter (Text.unpack implicitLayerPolicy)
  pure
    ( Text.pack implicitLayerFilter
        <> "="
        <> implicitLayerPolicy
        <> ", so no implicit layer joins the chain and the explicit layers below are all of it"
    )

-- | Point the validation layer at an empty settings file. Unset, it would look
-- for @vk_layer_settings.txt@ where the process runs and in the user's
-- configuration, either of which a machine could supply.
applySettingsPolicy ∷ IO Text
applySettingsPolicy = do
  setEnv settingsVariable emptySettings
  pure (Text.pack settingsVariable <> "=" <> Text.pack emptySettings <> ", so no settings file decides what the layer validates")
  where
    settingsVariable = "VK_LAYER_SETTINGS_PATH"
    emptySettings = "/dev/null"
