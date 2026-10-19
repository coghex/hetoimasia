-- | The one registration both owners are created from, and what each owner's policy exposes of it
-- (requirement 3; D-14, D-15, P-2).
--
-- Every binding is defined once, here, over the sample's 'Shared' state. An owner's @vmPolicy@
-- names the namespaces its VM may see, and a namespace outside it is absent from that VM's
-- globals:
--
-- +------------+------------+-----------------------------------------------------------------+
-- | Namespace  | Exposed to | Bindings                                                        |
-- +============+============+=================================================================+
-- | @view@     | UI         | @tick@, @session@, @count@, @entity@: snapshot queries         |
-- |            |            | answered from the segment's one capture                         |
-- +------------+------------+-----------------------------------------------------------------+
-- | @intent_raw@ | UI       | @submit@, the typed intention binding, and @malformed@; the UI's|
-- |            |            | initial chunk removes the namespace and offers @intent.submit@  |
-- +------------+------------+-----------------------------------------------------------------+
-- | @input@    | UI         | @poll@: the fixed fake input source                             |
-- +------------+------------+-----------------------------------------------------------------+
-- | @ui@       | UI         | @updated@: one update completed                                 |
-- +------------+------------+-----------------------------------------------------------------+
-- | @world@    | gameplay   | @tick@, @session@, @count@, @entity@ over the tick's candidate  |
-- +------------+------------+-----------------------------------------------------------------+
-- | @staging@  | gameplay   | @move@ into the bounded batch, @finish@                         |
-- +------------+------------+-----------------------------------------------------------------+
-- | @rand@     | gameplay   | @below@: a draw from the application-owned stream               |
-- +------------+------------+-----------------------------------------------------------------+
--
-- No binding takes or returns a capability, and the registration declares no capability type, so
-- nothing one VM holds names anything in the other. The production registration contains exactly
-- these namespaces: a test that needs a binding of its own passes it in 'sampleRegistration''s
-- argument, and the production configuration passes none.
module Hetoimasia.Sample.LuaDomains.Registration
  ( sampleRegistration
  , uiNamespaces
  , gameplayNamespaces
  , allNamespaces
  ) where

import Data.Int (Int64)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains.Candidate (Move (..))
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (..), answerReason)
import Hetoimasia.Sample.LuaDomains.Shared
  ( ScriptedInput (..)
  , Shared
  , StageAnswer (..)
  , currentView
  , gameplayDraw
  , gameplayFinish
  , gameplayStage
  , gameplayWorld
  , noteMalformed
  , noteUpdate
  , pollInput
  , submit
  )
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot (..))
import Hetoimasia.Sample.LuaDomains.World (Entity (..), World (..), entityAt)
import Hetoimasia.Scripting.Lua.Registration hiding (CommandResult (..))
import qualified Hetoimasia.Scripting.Lua.Registration as Reg
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..))

-- | The namespaces the UI's policy names.
uiNamespaces ∷ [Text]
uiNamespaces = ["view", "intent_raw", "input", "ui"]

-- | The namespaces gameplay's policy names.
gameplayNamespaces ∷ [Text]
gameplayNamespaces = ["world", "staging", "rand"]

-- | Every namespace of the production registration.
allNamespaces ∷ [Text]
allNamespaces = uiNamespaces <> gameplayNamespaces

-- | The registration over this state, with these namespaces beside the sample's own.
sampleRegistration ∷ Shared → [Namespace] → Either RegistrationRefusal Registration
sampleRegistration shared extra =
  registration
    []
    ( [viewNamespace shared, intentNamespace shared, inputNamespace shared, uiNamespace shared]
        <> [worldNamespace shared, stagingNamespace shared, randNamespace shared]
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
    ]
  where
    (<&>) = flip fmap

uiNamespace ∷ Shared → Namespace
uiNamespace shared =
  namespace
    "ui"
    [stateOperation "updated" [] [] $ \_ → [] <$ noteUpdate shared]

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
