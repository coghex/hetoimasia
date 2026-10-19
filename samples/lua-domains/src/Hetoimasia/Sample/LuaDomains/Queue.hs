-- | Gameplay's bounded intention queue and the admission seam in front of it (requirements 6, 7
-- and 8).
--
-- = Ownership
--
-- The queue is one transactional variable. Its writers are the producers of intentions, from any
-- thread — the UI's binding action in production, a test's threads in the examples — and the
-- driver, which alone seals a tick and alone settles one. Nothing in it is a Lua value, and no
-- thread waits on it: every operation is one transaction that answers at once.
--
-- = The seam
--
-- 'admitAt' takes the tick an intention is for and its order within the tick explicitly, so a
-- later slice can feed it an input log whose places were assigned beforehand. 'admitNext' is the
-- UI's path: it reads the next /unstarted/ tick and takes the next free place in it in the one
-- transaction.
--
-- = Why assignment cannot race the tick
--
-- A tick /starts/ when the driver 'seal's it, and that transaction also advances the next
-- unstarted tick. An admission for a tick and the sealing of that tick are transactions on the one
-- variable, so one precedes the other: an admission that came first is in the sealed batch, and
-- one that came after read the advanced tick. An accepted intention is therefore never for a tick
-- that has started, and the UI's path has no \"late\" answer. The driver grants the tick only after
-- sealing it.
--
-- = Reservation
--
-- The bound counts accepted intentions not yet /settled/: from acceptance until the commit of the
-- tick they were accepted for. A sealed tick's intentions hold their reservations while its work
-- runs, and 'settle' gives them back in the transaction that commits the tick, so a producer can
-- never fill the queue beyond what the commit has not yet disposed of.
--
-- = Closing and draining
--
-- 'closeQueue' ends admission for good: the session closes it first when it fails, is stopped or is
-- retired, so nothing is accepted for a tick that will never run. 'drain' then takes what no commit
-- settled, so that each such intention gets exactly one terminal disposition, invalidated or
-- discarded, and the reservations come back.
--
-- = A finite session
--
-- A queue made for a session of @n@ ticks answers 'Closed' for an intention whose tick is beyond
-- @n@, which is every UI-path admission once tick @n@ has been sealed. Everything accepted before
-- that is for a tick up to @n@, and is settled by the commit of its tick.
module Hetoimasia.Sample.LuaDomains.Queue
  ( Queue
  , newQueue
  , queueBounds
  , admitAt
  , admitNext
  , seal
  , settle
  , closeQueue
  , isClosed
  , drain
  , reserved
  , nextUnstarted
  , AdmitAt (..)
  ) where

import Control.Concurrent.STM (STM, TVar, newTVarIO, readTVar, writeTVar)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Word (Word32, Word64)
import Hetoimasia.Sample.LuaDomains.Bounds (Bounds (boundPlaces, boundQueue))
import Hetoimasia.Sample.LuaDomains.Intention (Intention, Placement (..))

-- | What the queue holds.
data State = State
  { stateNext ∷ !Word64
    -- ^ The next tick that has not started. The first is 1.
  , stateOpen ∷ !(Map Word64 (Map Word32 Intention))
    -- ^ The intentions accepted for ticks that have not started, by tick and place.
  , stateSealed ∷ !(Map Word64 [(Placement, Intention)])
    -- ^ The intentions each started tick holds a reservation for until its commit, in the order
    -- of their places.
  , statePending ∷ !Int
    -- ^ Accepted and not settled: the sum of both tables above.
  , stateClosed ∷ !Bool
    -- ^ Admission has ended, because the session is being retired.
  }

-- | The bounded queue, owned as the module header says.
data Queue = Queue
  { queueBounds ∷ !Bounds
  , queueFinal ∷ !(Maybe Word64)
    -- ^ The last tick of a finite session.
  , queueState ∷ !(TVar State)
  }

-- | An empty queue whose first unstarted tick is 1, for a session of this many ticks if it is
-- finite.
newQueue ∷ Bounds → Maybe Word64 → IO Queue
newQueue bounds final = Queue bounds final <$> newTVarIO (State 1 Map.empty Map.empty 0 False)

-- | What admitting at an explicit place answered.
data AdmitAt
  = AdmittedAt !Placement
  | -- | The queue's bound is reached. Nothing changed.
    AtFullQueue
  | -- | The tick's places are all taken. Nothing changed.
    AtFullPlaces
  | -- | The tick is beyond the finite session's last. Nothing changed.
    AtClosed
  | -- | The tick has started, so it can take nothing more. Nothing changed.
    AtLate
  | -- | Another intention holds the place. Nothing changed.
    AtDuplicate
  deriving (Eq, Show)

-- | Admit an intention at an explicit tick and place.
--
-- The checks, in order: admission is open and the tick is within the session ('AtClosed'), the tick has not started
-- ('AtLate'), the place is free ('AtDuplicate'), and neither the tick's places nor the queue's
-- bound are exhausted ('AtFullPlaces', then 'AtFullQueue'). A place at or beyond the bound on places is full.
admitAt ∷ Queue → Placement → Intention → STM AdmitAt
admitAt queue place@(Placement tick order) intention = do
  state ← readTVar (queueState queue)
  let taken = Map.findWithDefault Map.empty tick (stateOpen state)
      refused
        | stateClosed state || maybe False (tick >) (queueFinal queue) = Just AtClosed
        | tick < stateNext state = Just AtLate
        | Map.member order taken = Just AtDuplicate
        | fromIntegral order >= boundPlaces (queueBounds queue) = Just AtFullPlaces
        | statePending state >= boundQueue (queueBounds queue) = Just AtFullQueue
        | otherwise = Nothing
  case refused of
    Just answer → pure answer
    Nothing → do
      writeTVar
        (queueState queue)
        state
          { stateOpen = Map.insert tick (Map.insert order intention taken) (stateOpen state)
          , statePending = statePending state + 1
          }
      pure (AdmittedAt place)

-- | End admission: every later admission answers 'AtClosed'. What was accepted stays held, and a
-- tick that has begun is still sealed and settled as usual. The session closes the queue first when
-- it is retired, as an owner closes its admission first when it stops.
closeQueue ∷ Queue → STM ()
closeQueue queue = do
  state ← readTVar (queueState queue)
  writeTVar (queueState queue) state {stateClosed = True}

-- | Whether admission has ended.
isClosed ∷ Queue → STM Bool
isClosed queue = stateClosed <$> readTVar (queueState queue)

-- | The UI's path: admit for the next tick that has not started, at the next free place in it. It
-- reads the tick and takes the place in one transaction, so it cannot be late or a duplicate.
admitNext ∷ Queue → Intention → STM AdmitAt
admitNext queue intention = do
  state ← readTVar (queueState queue)
  let tick = stateNext state
      taken = Map.findWithDefault Map.empty tick (stateOpen state)
      order = maybe 0 ((+ 1) . fst) (Map.lookupMax taken)
  admitAt queue (Placement tick order) intention

-- | Start the next tick: take everything accepted for it, in the order of the places, and advance
-- the next unstarted tick. The tick's reservations are kept until 'settle'. The driver calls this
-- once per tick, before it grants the tick.
seal ∷ Queue → STM (Word64, [(Placement, Intention)])
seal queue = do
  state ← readTVar (queueState queue)
  let tick = stateNext state
      taken = Map.findWithDefault Map.empty tick (stateOpen state)
      placed = [(Placement tick order, intention) | (order, intention) ← Map.toAscList taken]
  writeTVar
    (queueState queue)
    state
      { stateNext = tick + 1
      , stateOpen = Map.delete tick (stateOpen state)
      , stateSealed = Map.insert tick placed (stateSealed state)
      }
  pure (tick, placed)

-- | Give back the reservations of a started tick, once its disposition is committed. Settling a
-- tick that holds none, or twice, changes nothing.
settle ∷ Queue → Word64 → STM ()
settle queue tick = do
  state ← readTVar (queueState queue)
  case Map.lookup tick (stateSealed state) of
    Nothing → pure ()
    Just held →
      writeTVar
        (queueState queue)
        state {stateSealed = Map.delete tick (stateSealed state), statePending = statePending state - length held}

-- | Take every intention that has no committed terminal disposition: the sealed ticks' that were not
-- settled, then those accepted for ticks that never began, each in the order of its tick and place.
-- Their reservations are given back, so a drained queue holds nothing. The session calls it once,
-- when a failure or a stop ends it, after admission has closed, and reports exactly these as
-- invalidated or discarded.
drain ∷ Queue → STM [(Placement, Intention)]
drain queue = do
  state ← readTVar (queueState queue)
  let sealed = concat (Map.elems (stateSealed state))
      open = [(Placement tick order, intention) | (tick, taken) ← Map.toAscList (stateOpen state), (order, intention) ← Map.toAscList taken]
  writeTVar (queueState queue) state {stateOpen = Map.empty, stateSealed = Map.empty, statePending = 0}
  pure (sealed <> open)

-- | How many intentions are accepted and not yet settled by a commit.
reserved ∷ Queue → STM Int
reserved queue = statePending <$> readTVar (queueState queue)

-- | The next tick that has not started.
nextUnstarted ∷ Queue → STM Word64
nextUnstarted queue = stateNext <$> readTVar (queueState queue)
