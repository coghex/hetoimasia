-- | The one registration both owners are created from, and what each owner's policy exposes of it
-- (#498 requirement 3, extended by #499 requirements 10 and 12; D-14, D-15, P-2).
--
-- Every binding is defined once, here, over the sample's 'Shared' state. An owner's @vmPolicy@
-- names the namespaces its VM may see, and a namespace outside it is absent from that VM's
-- globals:
--
-- +--------------+------------+-----------------------------------------------------------------+
-- | Namespace    | Exposed to | Bindings                                                        |
-- +==============+============+=================================================================+
-- | @view@       | UI         | @tick@, @session@, @count@, @entity@, @status@, @gameplay_tid@: |
-- |              |            | snapshot queries answered from the segment's one capture        |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @intent_raw@ | UI         | @submit@, the typed intention binding, and @malformed@; the UI's|
-- |              |            | initial chunk removes the namespace and offers @intent.submit@  |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @input@      | UI         | @poll@: the fixed fake input source; @scenario@: its name       |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @ui@         | UI         | @updated@, @busy@, @retried@, @saw@: what the behavior did      |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @control_raw@| UI         | @begin@, @finish@, @note@, @settled@: the bookkeeping of a      |
-- |              |            | control request; removed by the initial chunk                   |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @lifecycle_raw@ | UI      | the library's lifecycle bindings, over the grant the UI owner   |
-- |              |            | has for the gameplay owner; removed by the initial chunk, which |
-- |              |            | offers @control.pause@, @control.resume@ and @control.settle@   |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @world@      | gameplay   | @tick@, @session@, @count@, @entity@ over the tick's candidate  |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @staging@    | gameplay   | @move@ into the bounded batch, @finish@                         |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @rand@       | gameplay   | @below@: a draw from the application-owned stream               |
-- +--------------+------------+-----------------------------------------------------------------+
-- | @workspace@  | gameplay   | @open@, @note@, @read@: a per-instance workspace, leased        |
-- +--------------+------------+-----------------------------------------------------------------+
--
-- The one capability type is the gameplay workspace's handle, issued by the gameplay VM for the instance that
-- opened it, and no binding the UI is exposed to takes or returns one, so nothing one VM holds names anything
-- in the other. The production registration contains exactly these namespaces: a test that needs a binding of
-- its own passes it in 'sampleRegistration''s arguments, and the production configuration passes none.
module Hetoimasia.Sample.LuaDomains.Registration
  ( sampleRegistration
  , uiNamespaces
  , gameplayNamespaces
  , allNamespaces
  , workspaceType
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains.Candidate (Move (..))
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (..), answerReason)
import Hetoimasia.Sample.LuaDomains.Shared
  ( ScriptedInput (..)
  , Shared (..)
  , StageAnswer (..)
  , Workspace
  , controlBegin
  , controlFinish
  , controlNote
  , controlSettled
  , currentView
  , gameplayDraw
  , gameplayBegan
  , gameplayFinish
  , gameplayStage
  , gameplayWorld
  , noteBusy
  , noteMalformed
  , noteRetry
  , noteSaw
  , noteUpdate
  , openWorkspace
  , pollInput
  , readWorkspace
  , submit
  , writeWorkspace
  )
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot (..), statusWord)
import Hetoimasia.Sample.LuaDomains.World (Entity (..), World (..), entityAt)
import Hetoimasia.Scripting.Lua.Lease (leaseCapabilityType, leaseHandle, withLease)
import Hetoimasia.Scripting.Lua.Lifecycle (lifecycleNamespace)
import Hetoimasia.Scripting.Lua.Registration hiding (CommandResult (..))
import qualified Hetoimasia.Scripting.Lua.Registration as Reg
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..), capabilityKey)

-- | The namespaces the UI's policy names.
uiNamespaces ∷ [Text]
uiNamespaces = ["view", "intent_raw", "input", "ui", "control_raw", "lifecycle_raw"]

-- | The namespaces gameplay's policy names.
gameplayNamespaces ∷ [Text]
gameplayNamespaces = ["world", "staging", "rand", "workspace"]

-- | Every namespace of the production registration.
allNamespaces ∷ [Text]
allNamespaces = uiNamespaces <> gameplayNamespaces

-- | The name of the workspace handle's capability type.
workspaceType ∷ Text
workspaceType = "workspace"

-- | The registration over this state, with these capability types and namespaces beside the sample's own.
sampleRegistration ∷ Shared → [CapabilityType] → [Namespace] → Either RegistrationRefusal Registration
sampleRegistration shared capabilities extra =
  registration
    (leaseCapabilityType (sharedLeases shared) workspaceType : capabilities)
    ( [viewNamespace shared, intentNamespace shared, inputNamespace shared, uiNamespace shared, controlNamespace shared, lifecycleNamespace "lifecycle_raw"]
        <> [worldNamespace shared, stagingNamespace shared, randNamespace shared, workspaceNamespace shared]
        <> extra
    )

-- The UI ---------------------------------------------------------------------------

viewNamespace ∷ Shared → Namespace
viewNamespace shared =
  namespace
    "view"
    [ snapshotQuery "tick" [] [SInteger] $ \_ → one . fromIntegral . snapTick <$> currentView shared
    , snapshotQuery "session" [] [SInteger] $ \_ → one . fromIntegral . snapSession <$> currentView shared
    , snapshotQuery "count" [] [SInteger] $ \_ → one . fromIntegral . length . worldEntities . snapWorld <$> currentView shared
    , snapshotQuery "entity" [SInteger] [SBoolean, SInteger, SInteger, SInteger] $ \arguments → do
        view ← currentView shared
        pure (entityValues (snapWorld view) arguments)
    , -- The session's status as one word: running, paused, failed or stopped.
      snapshotQuery "status" [] [SText] $ \_ → (\view → [VText (statusWord (snapStatus view))]) <$> currentView shared
    , -- Whether the snapshot names the gameplay behavior, and its identity as a script holds one.
      snapshotQuery "gameplay_tid" [] [SBoolean, SInteger, SInteger, SInteger] $ \_ → do
        view ← currentView shared
        pure $ case snapGameplay view of
          Just (runtime, owner, identity) → [VBoolean True, VInteger runtime, VInteger owner, VInteger identity]
          Nothing → [VBoolean False, VInteger 0, VInteger 0, VInteger 0]
    ]

intentNamespace ∷ Shared → Namespace
intentNamespace shared =
  namespace
    "intent_raw"
    [ -- The typed binding: six integers, the application's bounds answered as data.
      commandIntention "submit" (replicate 6 SInteger) $ \case
        [VInteger session, VInteger tick, VInteger entity, VInteger version, VInteger dx, VInteger dy] →
          toCommand <$> submit shared (Submitted session tick entity version dx dy)
        _ → pure (Reg.Rejected "malformed")
    , stateOperation "malformed" [] [] $ \_ → [] <$ noteMalformed shared
    ]
  where
    toCommand answer = maybe Reg.Accepted Reg.Rejected (answerReason answer)

inputNamespace ∷ Shared → Namespace
inputNamespace shared =
  namespace
    "input"
    [ stateOperation "poll" [] [SBoolean, SInteger, SInteger, SInteger] $ \_ →
        pollInput shared <&> \case
          Just (ScriptedInput entity dx dy) → [VBoolean True, VInteger entity, VInteger dx, VInteger dy]
          Nothing → [VBoolean False, VInteger 0, VInteger 0, VInteger 0]
    , -- The scenario's name, which decides what the behavior does besides offering the input.
      stateOperation "scenario" [] [SText] $ \_ → pure [VText (sharedScenario shared)]
    ]
  where
    (<&>) = flip fmap

uiNamespace ∷ Shared → Namespace
uiNamespace shared =
  namespace
    "ui"
    [ stateOperation "updated" [] [] $ \_ → [] <$ noteUpdate shared
    , stateOperation "busy" [] [] $ \_ → [] <$ noteBusy shared
    , stateOperation "retried" [] [] $ \_ → [] <$ noteRetry shared
    , stateOperation "saw" [SText] [] $ \case
        [VText status] → [] <$ noteSaw shared status
        _ → pure []
    ]

-- | The bookkeeping of a control request, made by the UI's facade around the engine's lifecycle call.
controlNamespace ∷ Shared → Namespace
controlNamespace shared =
  namespace
    "control_raw"
    [ stateOperation "begin" [] [] $ \_ → [] <$ controlBegin shared
    , stateOperation "finish" [] [] $ \_ → [] <$ controlFinish shared
    , -- The engine's answer: accepted (an empty reason) or refused for this reason.
      stateOperation "note" [SBoolean, SText] [] $ \case
        [VBoolean True, _] → [] <$ controlNote shared Nothing
        [VBoolean False, VText reason] → [] <$ controlNote shared (Just reason)
        _ → pure []
    , stateOperation "settled" [SText] [] $ \case
        [VText kind] → [] <$ controlSettled shared kind
        _ → pure []
    ]

-- Gameplay ----------------------------------------------------------------------------

worldNamespace ∷ Shared → Namespace
worldNamespace shared =
  namespace
    "world"
    [ snapshotQuery "tick" [] [SInteger] $ \_ → do
        (world, working) ← gameplayWorld shared
        pure (one (fromIntegral (maybe (worldTick world) id working)))
    , snapshotQuery "session" [] [SInteger] $ \_ → one . fromIntegral . worldSession . fst <$> gameplayWorld shared
    , snapshotQuery "count" [] [SInteger] $ \_ → one . fromIntegral . length . worldEntities . fst <$> gameplayWorld shared
    , snapshotQuery "entity" [SInteger] [SBoolean, SInteger, SInteger, SInteger] $ \arguments → do
        (world, _) ← gameplayWorld shared
        pure (entityValues world arguments)
    ]

stagingNamespace ∷ Shared → Namespace
stagingNamespace shared =
  namespace
    "staging"
    [ -- A recoverable answer: false when the batch is full, the entity or the delta is out of
      -- bounds, or no tick is in progress. Nothing is changed by a move; the commit applies it.
      stateOperation "move" [SInteger, SInteger, SInteger] [SBoolean] $ \case
        [VInteger entity, VInteger dx, VInteger dy]
          | entity >= 0 && entity <= fromIntegral (maxBound ∷ Int) →
              (\answer → [VBoolean (answer == Staged)]) <$> gameplayStage shared (Move (fromIntegral entity) dx dy)
        _ → pure [VBoolean False]
    , -- Said by the wrapper every gameplay module's update is given, before the script's own code runs.
      stateOperation "began" [] [] $ \_ → [] <$ gameplayBegan shared
    , stateOperation "finish" [] [] $ \_ → [] <$ gameplayFinish shared
    ]

randNamespace ∷ Shared → Namespace
randNamespace shared =
  namespace
    "rand"
    [ -- A draw from [0, n) for n from 1 to 2^31, and -1, drawing nothing, for any other n.
      stateOperation "below" [SInteger] [SInteger] $ \case
        [VInteger bound] → one . maybe (-1) id <$> gameplayDraw shared bound
        _ → pure [VInteger (-1)]
    ]

-- | The per-instance workspace, leased: the engine releases it whenever the instance that opened it ends,
-- however the script behaves, so the behavior never has to. Opening more than the instance's capacity is
-- refused by the engine and faults the invocation.
workspaceNamespace ∷ Shared → Namespace
workspaceNamespace shared =
  namespace
    "workspace"
    [ stateOperation "open" [] [SCapability workspaceType] $ \_ → do
        lease ← openWorkspace shared
        pure [leaseHandle workspaceType lease]
    , stateOperation "note" [SCapability workspaceType, SInteger] [] $ \case
        [VCapability handle, VInteger value] → [] <$ withLease (sharedLeases shared) (capabilityKey handle) (\w → writeWorkspace (w ∷ Workspace) value)
        _ → pure []
    , stateOperation "read" [SCapability workspaceType] [SInteger] $ \case
        [VCapability handle] → one <$> withLease (sharedLeases shared) (capabilityKey handle) (\w → readWorkspace (w ∷ Workspace))
        _ → pure [VInteger 0]
    ]

-- Helpers ------------------------------------------------------------------------------

one ∷ Int64 → [Value]
one value = [VInteger value]

-- | Whether the entity is there, and its position and version.
entityValues ∷ World → [Value] → [Value]
entityValues world = \case
  [VInteger index]
    | index >= 0 && index <= fromIntegral (maxBound ∷ Int)
    , Just entity ← entityAt world (fromIntegral index) →
        [VBoolean True, VInteger (entityX entity), VInteger (entityY entity), VInteger (fromIntegral (entityVersion entity))]
  _ → [VBoolean False, VInteger 0, VInteger 0, VInteger 0]
