-- | The bounded revalidation an explicit retry performs (requirement 9): the pages a pause
-- recorded are read again through the storage backend, one at a time, as a resumable state
-- machine. An integrity pause is certified gone only by reading its recorded pages back VALID
-- (a successful scratch read elsewhere certifies nothing); an I/O pause by reading its recorded
-- places back without an error. A pause that recorded no page cannot be certified and stays.
--
-- State, owner, thread, lifetime: as "Hetoimasia.Terrain.Runtime.Backed.Gather": the terrain
-- owner's, on its one thread; it holds no pin (it reads places, not records).
module Hetoimasia.Terrain.Runtime.Backed.Probe
  ( PageProbe
  , startProbe
  , stepProbe
  , cancelProbe
  , probeDraining
  , PProgress (..)
  ) where

import Control.Concurrent.STM (STM, atomically)
import Hetoimasia.Terrain.Runtime.Backed.Backend
import Hetoimasia.Terrain.Runtime.Backed.Gather (lostTicket)
import Hetoimasia.Terrain.Runtime.Backed.Txn (Io (..))
import Hetoimasia.Terrain.Runtime.Storage.Internal.Service
  ( ReadMode (..)
  , Ticket
  , awaitTicket
  , cancelTicket
  , discardTicket
  , pollTicket
  , submitRead
  , withOutcome
  )
import Hetoimasia.Terrain.Runtime.Store.Internal.Format (PageNo)
import Hetoimasia.Terrain.Runtime.Store.Internal.State (StoreConfig)

-- | The pages still to read, each with the mode it must read back in, and the read in flight.
data PageProbe = PageProbe
  { ppPages ∷ ![(PageNo, ReadMode)]
  , ppFetch ∷ !(Maybe Ticket)
  , ppDraining ∷ !Bool
  }

data PProgress
  = PMore
  | PBlocked !(STM ())
  | -- | Every page read back as it must.
    PPassed
  | -- | A page did not: the cause persists.
    PFailedWith !Handling
  | PDrained

startProbe ∷ [(PageNo, ReadMode)] → PageProbe
startProbe pages = PageProbe pages Nothing False

probeDraining ∷ PageProbe → Bool
probeDraining = ppDraining

-- | One step: take the read in flight's outcome, or submit the next page's read. Called masked.
stepProbe ∷ Io → Closing → StoreConfig → PageProbe → IO (PageProbe, PProgress)
stepProbe io closing cfg p = case (ppFetch p, ppPages p) of
  (Just ticket, _) → do
    finished ← atomically (pollTicket (ioService io) ticket)
    if not finished
      then pure (p, PBlocked (awaitTicket (ioService io) ticket))
      else
        if ppDraining p
          then discardTicket (ioService io) ticket >> pure (p {ppFetch = Nothing}, PDrained)
          else
            withOutcome (ioService io) ticket (\outcome → pure $! reactTo closing JkRead outcome) >>= \case
              Nothing → (\handling → (p {ppFetch = Nothing}, PFailedWith handling)) <$> lostTicket closing io
              Just (GotPages _) → pure (p {ppFetch = Nothing, ppPages = drop 1 (ppPages p)}, PMore)
              Just (GotFailure handling _) → pure (p {ppFetch = Nothing}, PFailedWith handling)
              Just (GotCancelled _) → pure (p {ppFetch = Nothing}, PFailedWith (classifyUnaskedCancel closing))
              Just (GotMismatch why) → pure (p {ppFetch = Nothing}, PFailedWith (HandleDefect why))
              Just _ → pure (p {ppFetch = Nothing}, PFailedWith (HandleDefect "a probe read answered with another kind of outcome"))
  (Nothing, [])
    | ppDraining p → pure (p, PDrained)
    | otherwise → pure (p, PPassed)
  (Nothing, (page, mode) : _)
    | ppDraining p → pure (p, PDrained)
    | otherwise →
        submitRead (ioService io) (ioBacking io) (ioClass io) cfg page 1 mode >>= \case
          Left failure → pure (p, PFailedWith (classifyFailure closing JkRead failure))
          Right ticket → pure (p {ppFetch = Just ticket}, PBlocked (awaitTicket (ioService io) ticket))

-- | The owner no longer wants the probe: a read in flight is withdrawn or drained. Called masked.
cancelProbe ∷ Io → PageProbe → IO (PageProbe, PProgress)
cancelProbe io p = case ppFetch p of
  Nothing → pure (p {ppDraining = True}, PDrained)
  Just ticket
    | ppDraining p → do
        finished ← atomically (pollTicket (ioService io) ticket)
        if finished
          then discardTicket (ioService io) ticket >> pure (p {ppFetch = Nothing}, PDrained)
          else pure (p, PBlocked (awaitTicket (ioService io) ticket))
    | otherwise →
        cancelTicket (ioService io) ticket >>= \result → case reactToCancel result of
          CancelWithdrawn → discardTicket (ioService io) ticket >> pure (p {ppFetch = Nothing, ppDraining = True}, PDrained)
          CancelOutcomeStands → discardTicket (ioService io) ticket >> pure (p {ppFetch = Nothing, ppDraining = True}, PDrained)
          CancelWaitsForDrain → pure (p {ppDraining = True}, PBlocked (awaitTicket (ioService io) ticket))
          CancelDefect why → pure (p {ppFetch = Nothing, ppDraining = True}, PFailedWith (HandleDefect why))
