-- | The owner prepares, outside every transaction, what an arbitration would otherwise compute inside one: an open's
-- palette (its source's materials interned) and a staged answer's settlement (its host's pure work on the answer). A
-- transaction that a host's own commits keep restarting no longer grows with the definition or the answer.
--
-- The preparation is observed, not timed: a counter ticks as the interning (or the host's preparation) is actually
-- evaluated, and it is read at the owner's points. 'PointPrepared' is reported after the preparation and before the staging
-- transaction that makes the work visible to the chooser and the arbitration; 'PointBeforeCommit' before each arbitration.
-- Every race is ordered by the host's eligibility or by a gate at 'PointBeforeCommit', never by a delay.
--
-- THE LARGE DEFINITIONS ARE BUILT IN THE EXAMPLE THAT USES THEM AND ARE GARBAGE AFTER IT: a definition held at the top level
-- stays live for the rest of the process (several megabytes as 'String'), and every later example that forces major
-- collections (the storage backend's live-heap readings) copies it each time. Full laziness is off in this module so that
-- the compiler does not float a definition back to the top level.
{-# OPTIONS_GHC -fno-full-laziness #-}
module Test.TerrainRuntime.Preparation (spec) where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (void, when)
import Data.IORef
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Cell (Cell (..), zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Palette (Palette, PaletteError (..), emptyPalette, internMaterial, paletteMaterials)
import Hetoimasia.Terrain.Query (Run (..))
import Hetoimasia.Terrain.Residency (RequestId, Revision (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..), definitionHeaderBytes, layerRecordBytes, materialRecordBytes)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

-- ---------------------------------------------------------------------------
-- Definitions

-- | A definition of @n@ materials whose identifiers are @bytes@ long (at least the decimal index and a letter), with one
-- layer of the first.
definitionOf ∷ Int → Int → SourceSpec
definitionOf n bytes =
  SourceSpec
    { specMaterials = materials
    , specLayers = [LayerSpec {layerMin = Just 0, layerMax = Just 2, layerMaterial = first, layerShape = 0} | first ← take 1 materials]
    , specPatches = []
    }
  where
    materials = [let s = 'm' : show i in s <> replicate (bytes - length s) 'x' | i ← [0 .. n - 1]]

-- | The most materials named by 64 bytes that a definition of one layer may hold within the validator's 256 KiB, by its own
-- byte accounting.
wideMaterials ∷ Int
wideMaterials = last (takeWhile ((<= 256 * 1024) . accounted) [0 .. 4095])
  where
    accounted n = definitionHeaderBytes + layerRecordBytes + n * (materialRecordBytes + 64)

-- | The 256 KiB definition's shape, built afresh for the example that calls it.
wide ∷ () → SourceSpec
wide () = definitionOf wideMaterials 64

-- ---------------------------------------------------------------------------
-- Observing evaluation

-- | One tick of a counter, when the value it returns is evaluated. NOINLINE so that each application is its own thunk.
{-# NOINLINE ticked #-}
ticked ∷ IORef Int → a → a
ticked counter value = unsafePerformIO (atomicModifyIORef' counter (\n → (n + 1, ())) >> pure value)

-- | The interning, observed: the palette is interned again from the prepared one, each material passing through 'ticked'
-- as it is interned. The counter reaches the number of materials only once the interning has been evaluated; it never moves
-- when a lazy result is merely built or handed on.
countingInterning ∷ IORef Int → Either PaletteError Palette → Either PaletteError Palette
countingInterning counter = \case
  Left why → Left why
  Right palette → foldl (\acc m → acc >>= \p → snd <$> internMaterial (ticked counter m) p) (Right emptyPalette) (paletteMaterials palette)

-- | What the owner had done when it reached each point of one request: the counter's value at it, and the host's
-- readiness (how many times its work was staged) at it.
data Seen = Seen
  { seenPrepared ∷ [(Int, Int)]
  , seenBeforeCommit ∷ [(Int, Int)]
  }

-- | A probe that records the counter and the host's readiness at 'PointPrepared' and 'PointBeforeCommit' of every request,
-- with the interning given.
recording ∷ IORef Int → Host → (Either PaletteError Palette → Either PaletteError Palette) → IO (Probe, IO (Map.Map RequestId Seen))
recording counter host interning = do
  seen ← newIORef Map.empty
  let note rid f = do
        n ← readIORef counter
        r ← readTVarIO (hostReady host)
        atomicModifyIORef' seen (\m → (Map.alter (Just . f (n, r) . maybe (Seen [] []) id) rid m, ()))
      point = \case
        PointPrepared rid → note rid (\x s → s {seenPrepared = seenPrepared s <> [x]})
        PointBeforeCommit rid → note rid (\x s → s {seenBeforeCommit = seenBeforeCommit s <> [x]})
        _ → pure ()
  pure (ProbeWith point interning, readIORef seen)

-- | The one request a run recorded.
onlyRequest ∷ Map.Map RequestId Seen → IO Seen
onlyRequest seen = case Map.elems seen of
  [one] → pure one
  other → expectationFailure ("expected one request at the points, got " <> show (length other)) >> fail "unreachable"

-- | A host's endpoint whose settlement of an answer is prepared through a counter: the counter ticks when the prepared
-- value is evaluated, and @runs@ counts the prepared settlements the arbitration ran.
preparedHost ∷ Service → Host → IORef Int → TVar Int → Endpoint
preparedHost svc host evaluations runs =
  base {endpointPrepare = Just (\answer → PreparedSettlement (ticked evaluations answer) (\a → modifyTVar' runs (+ 1) >> endpointSettle base (Succeeded a)))}
  where
    base = hostEndpoint svc Nothing host

-- | The open's lease, once settled.
leaseOf ∷ Host → IO ArenaLease
leaseOf host =
  settledOf host >>= \case
    [Succeeded (AOpened lease)] → pure lease
    other → expectationFailure ("expected one opened lease, got " <> show other) >> fail "unreachable"

-- | The open has given everything back: no request, no arena, and the compile account holds nothing of it.
retired ∷ Service → IO ()
retired svc = do
  waitFor $ do
    census ← inspectCensusSTM svc
    (use, _) ← inspectCompileSTM svc
    check (null (censusRequests census) && null (censusArenas census) && use == 0)
  settleChecks svc

-- ---------------------------------------------------------------------------
-- The examples

spec ∷ Spec
spec = describe "Preparation outside the arbitration" $ do
  describe "an open's palette (requirement 3)" $ do
    let interned name materials bytes =
          it ("interns " <> name <> " before the open is staged and never in the chooser's or the arbitration's transaction") $ do
            let source = definitionOf materials bytes
            counter ← newIORef 0
            host ← newHost True
            (probe, seen) ← recording counter host (countingInterning counter)
            withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
              client ← okOf (registerClient svc)
              _ ← okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "main" source)
              waitFor (readTVar (hostSettled host) >>= check . not . null)
              _ ← leaseOf host
              s ← seen >>= onlyRequest
              -- evaluated in full before the staging transaction made it visible (the host not yet told) ...
              seenPrepared s `shouldBe` [(materials, 0)]
              -- ... and nothing of it evaluated again by the chooser or by any attempt of the arbitration
              seenBeforeCommit s `shouldBe` [(materials, 1)]
              readIORef counter `shouldReturn` materials
              settleChecks svc
    interned "the 256 KiB definition's materials of 64 bytes" wideMaterials 64
    interned "the 4,095 materials" 4095 6

  describe "a staged answer's settlement (requirement 3, the column's commit)" $
    it "evaluates the host's preparation of a read's answer before it is staged, and the arbitration runs only the prepared settlement" $ do
      counter ← newIORef 0
      host ← newHost True
      (probe, seen) ← recording counter host id
      withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
        (_, lease) ← openMain svc "main"
        runs ← newTVarIO 0
        _ ← okOf (columnWith svc (preparedHost svc host counter runs) lease (column 0 0) (range (-10) 50))
        waitFor (readTVar (hostSettled host) >>= check . not . null)
        settledOf host >>= \case
          [Succeeded (AColumn answer)] → length (columnAnswerRuns answer) `shouldSatisfy` (> 1)
          other → expectationFailure ("expected a column, got " <> show other)
        -- the column is the later request (the open's own preparation is its palette)
        s ← seen >>= maybe (expectationFailure "no request at the points" >> fail "unreachable") (pure . snd) . Map.lookupMax
        seenPrepared s `shouldBe` [(1, 0)]
        seenBeforeCommit s `shouldBe` [(1, 1)]
        readIORef counter `shouldReturn` 1
        readTVarIO runs `shouldReturn` 1
        settleChecks svc

  describe "the arbitration around an open's preparation (requirement 4)" $ do
    it "keeps an open whose eligibility is withdrawn after its preparation pending, publishing nothing, and commits the same prepared palette when it is granted again" $ do
      counter ← newIORef 0
      arrivals ← newTVarIO (0 ∷ Int)
      release ← newEmptyMVar
      host ← newHost True
      atSecond ← newEmptyMVar
      -- how many times an arbitration or the chooser found the host not eligible (the owner alone reads it)
      refusals ← newTVarIO (0 ∷ Int)
      let point = \case
            PointBeforeCommit _ → do
              n ← atomically (modifyTVar' arrivals (+ 1) >> readTVar arrivals)
              if n == 1
                then readMVar release
                else do
                  -- the second arbitration: the first decided nothing, so nothing was settled or published
                  settled ← readTVarIO (hostSettled host)
                  ticks ← readIORef counter
                  putMVar atSecond (length settled, ticks)
            _ → pure ()
      withServiceUsing defaultConfig alwaysAdmitting (ProbeWith point (countingInterning counter)) $ \svc → (do
        client ← okOf (registerClient svc)
        let base = hostEndpoint svc Nothing host
            counted = base {endpointEligible = endpointEligible base >>= \e → e <$ when (not e) (modifyTVar' refusals (+ 1))}
        _ ← okOf (openArenaWith svc counted client "main" (wide ()))
        waitFor (readTVar arrivals >>= check . (>= 1))
        -- after the preparation, before the arbitration: the host withdraws its grant
        atomically (writeTVar (hostEligible host) False)
        putMVar release ()
        -- the held arbitration found it not eligible and decided nothing (the owner was held before it, so it is the first to read
        -- the withdrawn grant); it is offered again only once it is granted again
        waitFor (readTVar refusals >>= check . (>= 1))
        grant host
        (settledThen, ticksThen) ← bounded (takeMVar atSecond)
        settledThen `shouldBe` 0
        ticksThen `shouldBe` wideMaterials
        waitFor (readTVar (hostSettled host) >>= check . not . null)
        _ ← leaseOf host
        -- the same prepared palette was installed: nothing was interned again
        readIORef counter `shouldReturn` wideMaterials
        settleChecks svc) `finally` void (tryPutMVar release ())

    let terminal name end expected =
          it ("settles an open whose " <> name <> " after its preparation and before its arbitration once, publishing nothing, and retires what it reserved once") $ do
            counter ← newIORef 0
            open ← newTVarIO True
            gate ← newGate
            host ← newHost True
            let probe = ProbeWith (probePoint (gatedProbe (\case PointBeforeCommit _ → True; _ → False) gate)) (countingInterning counter)
            withServiceUsing defaultConfig (SessionAdmission (readTVar open)) probe $ \svc → (do
              client ← okOf (registerClient svc)
              request ← okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "main" (wide ()))
              awaitReached gate
              readIORef counter `shouldReturn` wideMaterials
              _ ← end svc open request
              openGate gate
              waitFor (readTVar (hostSettled host) >>= check . not . null)
              settledOf host `shouldReturn` [expected]
              retired svc
              -- never interned again
              readIORef counter `shouldReturn` wideMaterials) `finally` openGate gate
    terminal "request is cancelled" (\svc _ request → cancel svc request >>= (`shouldBe` CancelWon)) Cancelled
    terminal "session ends" (\_ open _ → atomically (writeTVar open False)) Cancelled
    terminal "service closes" (\svc _ _ → closeService svc) Cancelled

    it "settles an open whose preparation fails to intern as a definition failure, as before, publishing nothing and retiring its reservation" $ do
      host ← newHost True
      let probe = ProbeWith (\_ → pure ()) (const (Left PaletteFull))
      withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
        client ← okOf (registerClient svc)
        _ ← okOf (openArenaWith svc (hostEndpoint svc Nothing host) client "main" soilOverStone)
        waitFor (readTVar (hostSettled host) >>= check . not . null)
        settledOf host `shouldReturn` [Failed (SourceFailure "PaletteFull")]
        retired svc

  describe "the arbitration around a staged answer's prepared settlement" $ do
    -- the read is a second client's, on the arena the creator opened
    let staged svc host counter runs = do
          (creator, lease) ← openMain svc "main"
          other ← okOf (registerClient svc)
          attached ← okOf (attachArena svc other "main") >>= await svc >>= expectSuccess
          request ← okOf (columnWith svc (preparedHost svc host counter runs) attached (column 0 0) (range (-10) 50))
          waitFor (readTVar (hostReady host) >>= check . (>= 1))
          readIORef counter `shouldReturn` 1
          pure (creator, lease, request)
    it "recomputes and prepares again an answer whose arena's revision moved between its preparation and its arbitration, never settling the old one" $ do
      counter ← newIORef 0
      host ← newHost False
      withService defaultConfig $ \svc → do
        runs ← newTVarIO 0
        (_, lease, _) ← staged svc host counter runs
        earlier ← maybe (Revision 0) viewRevision <$> inspectArena svc lease
        removed ← removeCell' svc lease (tile 0 0 0)
        removeRevision removed `shouldSatisfy` (> earlier)
        -- staged again, at the new revision, with a new preparation
        waitFor (readTVar (hostReady host) >>= check . (>= 2))
        readIORef counter `shouldReturn` 2
        grant host
        waitFor (readTVar (hostSettled host) >>= check . not . null)
        settledOf host >>= \case
          [Succeeded (AColumn answer)] → do
            columnRevision answer `shouldBe` removeRevision removed
            -- the removed cell is air in the answer that settled
            [cell | Run r cell ← columnAnswerRuns answer, zRangeLo r <= 0, 0 < zRangeHi r] `shouldBe` [Air]
          other → expectationFailure ("expected a column, got " <> show other)
        readTVarIO runs `shouldReturn` 1
        settleChecks svc

    let ended name end expected =
          it ("settles a staged answer whose " <> name <> " before its arbitration once, never running its prepared settlement") $ do
            counter ← newIORef 0
            host ← newHost False
            withService defaultConfig $ \svc → do
              runs ← newTVarIO 0
              (creator, _, request) ← staged svc host counter runs
              _ ← end svc creator request
              grant host
              waitFor (readTVar (hostSettled host) >>= check . not . null)
              settledOf host `shouldReturn` [expected]
              readTVarIO runs `shouldReturn` 0
              waitFor (inspectCensusSTM svc >>= check . null . censusRequests)
              settleChecks svc
    ended "arena closes" (\svc creator _ → endClient svc creator) (Failed ArenaClosed)
    ended "request is cancelled" (\svc _ request → cancel svc request >>= (`shouldBe` CancelWon)) Cancelled
