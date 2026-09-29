-- | The record every graphics-owner example keeps of what happened, and the
-- application values it runs the owner with.
--
-- The journal holds the independent facts an example asserts the order of.
-- The fake backend and the host rig both write it, which is why it belongs to
-- neither of them. 'Scene' is the application's own payload and 'Scripted' the
-- failure an example scripts an operation to raise.
module Test.GLFW.Owner.Fixture.Journal
  ( Note (..)
  , note
  , journalled
  , ordered
  , Scene (..)
  , Scripted (..)
  ) where

import Control.DeepSeq (NFData (rnf))
import Control.Concurrent.STM (TVar, atomically, modifyTVar', readTVarIO)
import Control.Exception (Exception)
import Data.Text (Text)
import Test.GLFW.Support (unexpected)

-- | The independent facts an example asserts the order of.
data Note
  = OwnerStartup
  | Constructed !Text
  | Stepped
  | TargetRetirement !Text
  | OwnerRetirement
  | OwnerDestruction
  | DestroyRaised !Text
  | WindowGone !Int
    -- ^ The seam's own destroy call, named by the window's creation order.
  | SessionEnded
  deriving (Eq, Show)

note ∷ TVar [Note] → Note → IO ()
note journal entry = atomically (modifyTVar' journal (<> [entry]))

journalled ∷ TVar [Note] → IO [Note]
journalled = readTVarIO

-- | Assert that these notes appear, in this order, among the journal's.
ordered ∷ [Note] → [Note] → IO ()
ordered journal expected = go journal expected
  where
    go _ [] = pure ()
    go [] remaining =
      unexpected
        ("the journal never reached " <> show remaining <> "; it held " <> show journal)
    go (entry : rest) (wanted : remaining)
      | entry == wanted = go rest remaining
      | otherwise = go rest (wanted : remaining)

-- | The scene an example publishes. It is the application's own type, so the
-- owner carries it without knowing anything about it — including how to force
-- it, which is why the application prepares its own payloads.
newtype Scene = Scene Int
  deriving (Eq, Show)

instance NFData Scene where
  rnf (Scene revision) = rnf revision

newtype Scripted = Scripted Text
  deriving (Eq, Show)

instance Exception Scripted
