-- | The transcript the proof writes as it runs.
--
-- The typed findings in "Test.Vulkan.Proof.Findings" are what the Hspec
-- examples assert over; this is what a reader sees. They are kept apart on
-- purpose: a proof that stops at its fourth step still has to say what its
-- first three observed, and a record built only from a successful result
-- cannot. Every line here is written before the step that produced it can
-- fail. A private-roots child's journal ('newEchoingJournal') also echoes
-- each line to standard error as it is written, so a child terminated at its
-- deadline — which never writes its record — still leaves in its output how
-- far it got.
module Test.Vulkan.Proof.Journal
  ( Journal
  , newJournal
  , newEchoingJournal
  , note
  , heading
  , entries
  ) where

import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text.IO as Text
import System.IO (hFlush, stderr)

-- | Lines in reverse order, so a note is a constant-time prepend, and
-- whether each is echoed.
data Journal = Journal (IORef [Text]) Bool

newJournal ∷ IO Journal
newJournal = (`Journal` False) <$> newIORef []

-- | A journal that also echoes every line to standard error as it is written.
newEchoingJournal ∷ IO Journal
newEchoingJournal = (`Journal` True) <$> newIORef []

-- | Record one observation.
note ∷ Journal → Text → IO ()
note (Journal ref echo) line = do
  atomicModifyIORef' ref (\existing → (line : existing, ()))
  when echo $ do
    Text.hPutStrLn stderr ("journal: " <> line)
    hFlush stderr

-- | Start a section. Blank-line separation is the reader's, not the record
-- format's: the record renderer decides how a heading is shown.
heading ∷ Journal → Text → IO ()
heading journal text = note journal ("## " <> text)

entries ∷ Journal → IO [Text]
entries (Journal ref _) = reverse <$> readIORef ref
