{-# LANGUAGE OverloadedStrings #-}

-- | @api.terrain.open@, @attach@, @cell@, @column@, @surface@, @remove@ and @release@: the terrain calls of the M1 facade
-- (TRA-5), bound over the terrain operations a composition injects ('TerrainServices').
--
-- = What this module decides, and what it leaves to the service
--
-- Everything a script can get wrong is decided here, before any service is asked, as an ordinary Lua error: the host's
-- own arity, type, table and integer-subtype rules first (no authored metamethod runs, a float is not an integer, a list
-- is contiguous, a record has exactly its fields, nothing is copied past the bounds); then the caller (an instance of this
-- facade, never a module's top level and never another instance's captured facade), its phase (acquisition and queries are
-- refused in @shutdown@), the session's admission (a stopping or closed session takes no new work, and that is an error, never
-- @busy@); then the decode of the copied values: names and material identifiers (length), coordinate and shape ranges, and the
-- one place each interval endpoint may sit. Only then are the injected checks asked for the service's own permanent facts (a
-- foreign, wrong-kind, forged or released handle, an ended owner).
--
-- == The decode layer and the validator
--
-- A check made here is classified here, and the layer that runs first wins: every rejection of the copy or the decode is an
-- ordinary error raised before admission, with no request, arena or credit left behind. They are: wrong arity or fields, a
-- sparse list, a metatable, a cycle, a function, a value of the wrong type or of the float subtype, an invalid UTF-8 string, an
-- arena name that is empty or over 128 characters, a material identifier that is empty or over 64 bytes, a cell coordinate outside
-- @[-2^62, 2^62 - 1]@, a lower interval endpoint outside it, an upper endpoint above @2^62@, a shape outside @0..15@, and a copy
-- over the bounds of 'argumentLimits'. What is left to the terrain validator, and is the expected @definition@ failure when it
-- refuses a definition that decoded completely: an empty or inverted interval, overlapping or unordered layers, overlapping
-- patches, a material no layer declares, a duplicate material identifier, a material identifier with a control character, and a
-- definition over the validator's 256 KiB or 8,192 authored runs.
--
-- Nothing here is a service locator: every operation is a field of the one facade's 'TerrainServices', reached by a closure
-- built over that facade. The requests these calls return are read, taken, cancelled and waited for through the common request
-- operations ("Hetoimasia.LuaEngine.Facade.Request"), whose kinds this module adds.
module Hetoimasia.LuaEngine.Facade.Terrain
  ( terrainBindings
  , terrainHandleTypes
  , decodeDefinition
  , decodeCell
  , argumentLimits
  ) where

import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller (Caller (..), Stage (..), requireInstance, whoIsCalling)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Request (m1HandleType, m1StartResults, m1StartSchemas)
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , CapabilityType
  , RequestContext
  , asynchronousNativeRequestIn
  , recoverableRefusals
  , refuseOrdinarily
  , releaseOperation
  , withArgumentCheck
  , withArgumentLimits
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..), ValueLimits, capabilityKey, defaultValueLimits, valueLimits)

-- | The request handle types this VM's terrain requests are returned under, for the facade's registration.
terrainHandleTypes ∷ Facade → [CapabilityType]
terrainHandleTypes facade =
  [ m1HandleType (fcRequests facade) kind
  | kind ←
      [ terrainArenaRequestType
      , terrainCellRequestType
      , terrainColumnRequestType
      , terrainSurfaceRequestType
      , terrainRemoveRequestType
      ]
  ]

-- | What a definition's copy may hold: the most bytes of its encoding. The terrain validator accepts at most 256 KiB of
-- accounted definition and 8,192 authored runs, which is far below this in copied bytes; the depth and the elements stay the
-- profile's (the host narrows them by it), so the tighter of the two bounds applies to each.
argumentLimits ∷ ValueLimits
argumentLimits = either (const defaultValueLimits) id (valueLimits (2 * 1024 * 1024) 8 1048576)

-- The schemas ---------------------------------------------------------------------------------------

definitionSchema ∷ Schema
definitionSchema =
  SRecord
    [ ("materials", SList SText)
    , ("layers", SList layerSchema)
    , ("patches", SOptional (SList patchSchema))
    ]
  where
    layerSchema = SRecord [("z_min", SOptional SInteger), ("z_max", SOptional SInteger), ("material", SText), ("shape", SInteger)]
    patchSchema =
      SRecord
        [ ("x", SInteger)
        , ("y", SInteger)
        , ("z_min", SInteger)
        , ("z_max", SInteger)
        , ("value", SRecord [("air", SOptional SBoolean), ("material", SOptional SText), ("shape", SOptional SInteger)])
        ]

cellSchema, columnSchema, surfaceSchema ∷ Schema
cellSchema = SRecord [("x", SInteger), ("y", SInteger), ("z", SInteger)]
columnSchema = SRecord [("x", SInteger), ("y", SInteger), ("z_min", SInteger), ("z_max", SInteger)]
surfaceSchema = SRecord [("x", SInteger), ("y", SInteger)]

-- The decode -------------------------------------------------------------------------------------------

-- | The most levels one column request may span: the service's limit, which is a permanent fact of the request and so an ordinary
-- error here, decided before any temporary bank is asked.
terrainColumnLevels ∷ Int
terrainColumnLevels = 8192

-- | A field a record may leave out: absent, or nil.
optionalField ∷ Text → [(Text, Value)] → Maybe Value
optionalField name fields = case lookup name fields of
  Just VNil → Nothing
  other → other

requiredField ∷ Text → [(Text, Value)] → Either Text Value
requiredField name fields = maybe (Left ("the field " <> name <> " is required")) Right (optionalField name fields)

integer ∷ Text → Value → Either Text Int64
integer name = \case
  VInteger found → Right found
  _ → Left (name <> " must be an integer")

-- | A cell coordinate: an integer in @[-2^62, 2^62 - 1]@. Never converted through a float.
coordinate ∷ Text → Value → Either Text Int64
coordinate name value = do
  found ← integer name value
  if found < terrainCellLow || found > terrainCellHigh
    then Left (name <> " is outside the supported range -2^62 .. 2^62 - 1")
    else Right found

-- | An interval's lower end: a supported level.
lowerEnd ∷ Text → Value → Either Text Int64
lowerEnd = coordinate

-- | An interval's exclusive upper end: at most one past the highest supported level. Its relation to the lower end (empty or
-- inverted) is a property of the interval and the validator's.
upperEnd ∷ Text → Value → Either Text Int64
upperEnd name value = do
  found ← integer name value
  if found > terrainEndpointHigh
    then Left (name <> " is above 2^62, one past the highest supported level")
    else Right found

shapeId ∷ Text → Value → Either Text Int64
shapeId name value = do
  found ← integer name value
  if found < 0 || found > 15 then Left (name <> " must be a shape identity 0 .. 15") else Right found

materialId ∷ Text → Value → Either Text Text
materialId name = \case
  VText found
    | Text.null found → Left (name <> " is empty")
    | ByteString.length (Text.encodeUtf8 found) > terrainMaterialBytesLimit → Left (name <> " is longer than " <> Text.pack (show terrainMaterialBytesLimit) <> " bytes")
    | otherwise → Right found
  _ → Left (name <> " must be text")

arenaName ∷ Value → Either Text Text
arenaName = \case
  VText found
    | Text.null found → Left "an arena name is empty"
    | Text.compareLength found terrainNameLimit == GT → Left ("an arena name is longer than " <> Text.pack (show terrainNameLimit) <> " characters")
    | otherwise → Right found
  _ → Left "an arena name must be text"

-- | The definition a copied value is, or the first reason it is not.
decodeDefinition ∷ Value → Either Text TerrainDefinition
decodeDefinition = \case
  VRecord fields → do
    materialsValue ← requiredField "materials" fields
    layersValue ← requiredField "layers" fields
    materials ← case materialsValue of
      VList found → traverse (materialId "a material identifier") found
      _ → Left "materials must be a list"
    layers ← case layersValue of
      VList found → traverse decodeLayer found
      _ → Left "layers must be a list"
    patches ← case optionalField "patches" fields of
      Nothing → Right []
      Just (VList found) → traverse decodePatch found
      Just _ → Left "patches must be a list"
    Right (TerrainDefinition materials layers patches)
  _ → Left "a definition must be a table"
  where
    decodeLayer = \case
      VRecord fields → do
        lo ← traverse (lowerEnd "a layer's z_min") (optionalField "z_min" fields)
        hi ← traverse (upperEnd "a layer's z_max") (optionalField "z_max" fields)
        material ← requiredField "material" fields >>= materialId "a layer's material"
        shape ← requiredField "shape" fields >>= shapeId "a layer's shape"
        Right (TerrainLayer lo hi material shape)
      _ → Left "a layer must be a table"
    decodePatch = \case
      VRecord fields → do
        x ← requiredField "x" fields >>= coordinate "a patch's x"
        y ← requiredField "y" fields >>= coordinate "a patch's y"
        lo ← requiredField "z_min" fields >>= lowerEnd "a patch's z_min"
        hi ← requiredField "z_max" fields >>= upperEnd "a patch's z_max"
        value ← requiredField "value" fields >>= decodePatchValue
        Right (TerrainPatch x y lo hi value)
      _ → Left "a patch must be a table"
    -- A value is air (@{air = true}@) or a solid (@{material = TEXT, shape = INTEGER}@): never both, never neither, and
    -- @air = false@ with no material is neither.
    decodePatchValue = \case
      VRecord fields → case (optionalField "air" fields, optionalField "material" fields, optionalField "shape" fields) of
        (Just (VBoolean True), Nothing, Nothing) → Right PatchAir
        (Just (VBoolean True), _, _) → Left "a patch value that is air carries no material or shape"
        (air, Just material, Just shape)
          | air == Nothing || air == Just (VBoolean False) → PatchSolid <$> materialId "a patch's material" material <*> shapeId "a patch's shape" shape
          | otherwise → Left "a patch value is air or a material with a shape"
        _ → Left "a patch value is {air = true} or {material = TEXT, shape = INTEGER}"
      _ → Left "a patch value must be a table"

-- | A cell: three checked coordinates.
decodeCell ∷ Value → Either Text TerrainCell
decodeCell = \case
  VRecord fields → do
    x ← requiredField "x" fields >>= coordinate "x"
    y ← requiredField "y" fields >>= coordinate "y"
    z ← requiredField "z" fields >>= coordinate "z"
    Right (TerrainCell x y z)
  _ → Left "a cell must be a table with x, y and z"

-- | A column request: the column and a valid half-open range of levels.
decodeColumn ∷ Value → Either Text TerrainColumnAsk
decodeColumn = \case
  VRecord fields → do
    x ← requiredField "x" fields >>= coordinate "x"
    y ← requiredField "y" fields >>= coordinate "y"
    lo ← requiredField "z_min" fields >>= lowerEnd "z_min"
    hi ← requiredField "z_max" fields >>= upperEnd "z_max"
    if hi <= lo
      then Left "z_max must be greater than z_min"
      else
        if toInteger hi - toInteger lo > toInteger terrainColumnLevels
          then Left ("a column range spans at most " <> Text.pack (show terrainColumnLevels) <> " levels")
          else Right (TerrainColumnAsk x y lo hi)
  _ → Left "a column must be a table with x, y, z_min and z_max"

decodeSurface ∷ Value → Either Text (Int64, Int64)
decodeSurface = \case
  VRecord fields → do
    x ← requiredField "x" fields >>= coordinate "x"
    y ← requiredField "y" fields >>= coordinate "y"
    Right (x, y)
  _ → Left "a surface column must be a table with x and y"

-- The bindings ------------------------------------------------------------------------------------------

-- | The bindings of the hidden namespace, in their own spellings: @terrain_open@, @terrain_attach@, @terrain_cell@,
-- @terrain_column@, @terrain_surface@, @terrain_remove@ and @terrain_release@. The initial chunk wraps each in the facade's
-- own closure. The services' own extra bindings (a test fixture's) follow.
terrainBindings ∷ Facade → TerrainServices → [Binding]
terrainBindings facade services =
  [ withArgumentLimits argumentLimits . withArgumentCheck openCheck $
      asynchronousNativeRequestIn "terrain_open" [SText, definitionSchema] (m1StartSchemas terrainArenaRequestType) openAct
  , withArgumentCheck attachCheck $
      asynchronousNativeRequestIn "terrain_attach" [SText] (m1StartSchemas terrainArenaRequestType) attachAct
  , withArgumentCheck cellCheck $
      asynchronousNativeRequestIn "terrain_cell" [arena, cellSchema] (m1StartSchemas terrainCellRequestType) cellAct
  , withArgumentCheck columnCheck $
      asynchronousNativeRequestIn "terrain_column" [arena, columnSchema] (m1StartSchemas terrainColumnRequestType) columnAct
  , withArgumentCheck surfaceCheck $
      asynchronousNativeRequestIn "terrain_surface" [arena, surfaceSchema] (m1StartSchemas terrainSurfaceRequestType) surfaceAct
  , withArgumentCheck removeCheck $
      asynchronousNativeRequestIn "terrain_remove" [arena, cellSchema, SOptional (SCapability terrainPickType)] (m1StartSchemas terrainRemoveRequestType) removeAct
  , -- A release is allowed wherever an instance's finite hook runs, shutdown and after a quit included, so the session's
    -- admission is deliberately not read. It never waits and it is never a module's top-level service.
    withPrecondition instanceOnly $
      withArgumentCheck releaseCheck $
        recoverableRefusals (releaseOperation "terrain_release" terrainArenaType [SText] releaseAct)
  ]
    <> tsExtraBindings services
  where
    arena = SCapability terrainArenaType

    instanceOnly owner = do
      calling ← whoIsCalling facade owner
      pure $ case requireInstance calling of
        Left why → Just (clipText 200 why)
        Right _ → Nothing

    identityOf = recordId . callerRecord
    rootOf = recordContent . callerRecord

    -- The rule every acquisition and query meets first: an instance of this facade (no module's top level), not shutdown, and
    -- a session that takes new work. Either role may ask.
    gate ∷ Text → Caller → IO (Maybe Text)
    gate what caller
      | callerStage caller == StageEnding = pure (refuseText (what <> " is not available in shutdown"))
      | otherwise =
          endpointAdmission (fcEndpoints facade) >>= \case
            AdmissionStopping → pure (refuseText "the session is stopping: no new terrain work starts")
            AdmissionClosed → pure (refuseText "the session is closed: no new terrain work starts")
            AdmissionOpen → pure Nothing

    -- A check: the caller, the gate, the decode of the copied values, then the service's own permanent facts.
    checked ∷ Text → ([Value] → Either Text a) → (Caller → a → ArgumentCheck) → ArgumentCheck
    checked what decode serviceCheck owner values = do
      calling ← whoIsCalling facade owner
      case requireInstance calling of
        Left why → pure (refuseText why)
        Right caller →
          gate what caller >>= \case
            Just why → pure (Just why)
            Nothing → case decode values of
              Left why → pure (refuseText why)
              Right found → serviceCheck caller found owner values

    -- An action: the same decode of the same copied values, which the check accepted.
    starting ∷ Text → Text → ([Value] → Either Text a) → (Caller → a → RequestContext → IO TerrainStart) → RequestContext → [Value] → IO [Value]
    starting what handleType decode start context values = do
      calling ← callingIn facade context
      case requireInstance calling of
        Left why → failEngine facade ("a terrain request was made with no instance running: " <> why)
        Right caller → case decode values of
          Left why → failEngine facade (what <> " was valid at its check and is not at its action: " <> why)
          Right found →
            start caller found context >>= \case
              TerrainStarted started → pure (m1StartResults handleType started)
              TerrainRefused why → refuseOrdinarily (clipText 200 why)

    -- open ----------------------------------------------------------------------------------------------
    openTarget = \case
      [name, definition] → (,) <$> arenaName name <*> decodeDefinition definition
      _ → Left "an arena name and a definition are required"
    openCheck = checked "a terrain open" openTarget $ \caller (name, definition) → tsOpenCheck services (identityOf caller) (rootOf caller) name definition
    openAct = starting "a terrain open" terrainArenaRequestType openTarget $ \caller (name, definition) → tsOpenStart services (identityOf caller) (rootOf caller) name definition

    -- attach --------------------------------------------------------------------------------------------
    attachTarget = \case
      [name] → arenaName name
      _ → Left "an arena name is required"
    attachCheck = checked "a terrain attach" attachTarget $ \caller name → tsAttachCheck services (identityOf caller) (rootOf caller) name
    attachAct = starting "a terrain attach" terrainArenaRequestType attachTarget $ \caller name → tsAttachStart services (identityOf caller) (rootOf caller) name

    -- cell, column and surface ----------------------------------------------------------------------------
    cellTarget = \case
      [VCapability handle, cell] → (,) (capabilityKey handle) <$> decodeCell cell
      _ → Left "an arena and a cell are required"
    cellCheck = checked "a terrain cell read" cellTarget $ \caller (key, cell) → tsCellCheck services (identityOf caller) key cell
    cellAct = starting "a terrain cell read" terrainCellRequestType cellTarget $ \caller (key, cell) → tsCellStart services (identityOf caller) key cell

    columnTarget = \case
      [VCapability handle, column] → (,) (capabilityKey handle) <$> decodeColumn column
      _ → Left "an arena and a column are required"
    columnCheck = checked "a terrain column read" columnTarget $ \caller (key, ask) → tsColumnCheck services (identityOf caller) key ask
    columnAct = starting "a terrain column read" terrainColumnRequestType columnTarget $ \caller (key, ask) → tsColumnStart services (identityOf caller) key ask

    surfaceTarget = \case
      [VCapability handle, column] → (\(x, y) → (capabilityKey handle, x, y)) <$> decodeSurface column
      _ → Left "an arena and a column are required"
    surfaceCheck = checked "a terrain surface read" surfaceTarget $ \caller (key, x, y) → tsSurfaceCheck services (identityOf caller) key x y
    surfaceAct = starting "a terrain surface read" terrainSurfaceRequestType surfaceTarget $ \caller (key, x, y) → tsSurfaceStart services (identityOf caller) key x y

    -- remove --------------------------------------------------------------------------------------------
    removeTarget = \case
      [VCapability handle, cell, pick] → do
        found ← decodeCell cell
        authority ← case pick of
          VNil → Right Nothing
          VCapability token → Right (Just (capabilityKey token))
          _ → Left "the pick must be a pick authority"
        Right (capabilityKey handle, found, authority)
      _ → Left "an arena, a cell and an optional pick are required"
    removeCheck = checked "a terrain removal" removeTarget $ \caller (key, cell, pick) → tsRemoveCheck services (identityOf caller) key cell pick
    removeAct = starting "a terrain removal" terrainRemoveRequestType removeTarget $ \caller (key, cell, pick) → tsRemoveStart services (identityOf caller) key cell pick

    -- release -------------------------------------------------------------------------------------------
    -- Another instance's handle and a handle of another kind are ordinary errors before any service is asked; a handle that
    -- has ended is the release path's own to answer.
    releaseCheck ∷ ArgumentCheck
    releaseCheck owner = \case
      [VCapability handle] → do
        calling ← whoIsCalling facade owner
        case requireInstance calling of
          Left why → pure (refuseText why)
          Right caller → fmap (clipText 200) <$> tsReleaseCheck services (identityOf caller) (capabilityKey handle)
      _ → pure Nothing

    releaseAct = \case
      [VCapability handle] → (\word → [VText word]) <$> tsRelease services (capabilityKey handle)
      _ → pure []
