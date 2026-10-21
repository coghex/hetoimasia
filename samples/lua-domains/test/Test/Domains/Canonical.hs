-- | The canonical encoding of the authoritative state, its digest and the digest trace (#500 requirements 1 and 2).
--
-- The encoding and the two golden digests are pinned to values computed apart from the code (a short script that
-- writes the documented layout byte for byte and hashes it), so a change to the layout fails here before it changes a
-- digest anyone compares. They are the only golden digests: no whole-run digest is committed, because the claim is the
-- same build and platform and not a value across platforms.
module Test.Domains.Canonical (spec) where

import qualified Data.ByteString as ByteString
import Data.Foldable (toList)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import Control.Concurrent.STM (atomically, readTVarIO)
import Control.Exception (try)
import Control.Monad (forM_)
import Numeric (showHex)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsShared)
  , DomainsConfig (configGameplaySource, configStopAfter, configTicks)
  , GameSnapshot (..)
  , SessionReport (..)
  , SessionStatus (..)
  , defaultBounds
  , runSession
  , scenarioGameplay
  , scenarioStopAfter
  )
import Hetoimasia.Sample.LuaDomains.Canonical
import Hetoimasia.Sample.LuaDomains.Intention (Dispositions (..), Intention (..), Placement (..), Stale (..), StaleReason (..), noDispositions)
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Failure, Stop))
import Hetoimasia.Sample.LuaDomains.Shared (AdmissionDefect, Shared (sharedTrace), appendTrace, traceBound)
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (..), SessionFailure (..), initialSnapshot)
import Hetoimasia.Sample.LuaDomains.World (Entity (..), World (..), initialWorld)
import Test.Domains.Support
import Test.Hspec

-- | A state with two entities and nothing else: the first golden.
stateA ∷ GameSnapshot
stateA =
  GameSnapshot
    { snapSession = 7
    , snapTick = 3
    , snapWorld = World {worldSession = 7, worldTick = 3, worldEntities = Seq.fromList [Entity 1 (-2) 0, Entity 0 5 2], worldRandom = 5}
    , snapDispositions = noDispositions
    , snapStatus = Running
    , snapGameplay = Nothing
    }

-- | A failed session with every list in use: the second golden.
stateB ∷ GameSnapshot
stateB =
  GameSnapshot
    { snapSession = 99
    , snapTick = 9
    , snapWorld =
        World
          { worldSession = 99
          , worldTick = 9
          , worldEntities = Seq.fromList [Entity (-1000000000) 1000000000 7, Entity 0 0 0, Entity 4 1 maxBound]
          , worldRandom = maxBound
          }
    , snapDispositions =
        Dispositions
          { dispApplied = [Placement 9 0, Placement 9 2]
          , dispStale = [Stale (Placement 9 1) (Intention 99 4 2 3 (-4) 5) StaleVersion]
          , dispStaleOmitted = 1
          , dispInvalidated = [Placement 10 0, Placement 11 3]
          , dispInvalidatedOmitted = 2
          , dispDiscarded = [Placement 12 1]
          , dispDiscardedOmitted = 0
          }
    , snapStatus = Failed (FailureEvidence (SessionFailure "gameplay" "active" "update" 10 "script error" "boom") 2)
    , snapGameplay = Just (1, 2, 3)
    }

goldenA, goldenB ∷ Text
goldenA = "484c4453000100000000000000030000000000000005000000020000000000000001fffffffffffffffe00000000000000000000000000000000000000000000000500000000000000020000000000000000000000000000000000000000000000000000000000"
goldenB = "484c445300010000000000000009ffffffffffffffff00000003ffffffffc4653600000000003b9aca00000000000000000700000000000000000000000000000000000000000000000000000000000000040000000000000001ffffffffffffffff02000000000000000a02000000020000000000000009000000000000000000000009000000020000000100000000000000090000000101000000020000000000000003fffffffffffffffc00000000000000050000000100000002000000000000000a00000000000000000000000b000000030000000200000001000000000000000c0000000100000000"

digestA, digestB ∷ Text
digestA = "31e4c09f6f348b06a602b4c52ecf93ae84d7f26d9a030220e3200713c1279cea"
digestB = "175d5c0e4f5fc4d0a9e8647d2e813267d5d4d14581963ae899f2968c370adf0a"

hexOf ∷ ByteString.ByteString → Text
hexOf = Text.pack . concatMap (\byte → (if byte < 16 then "0" else "") <> showHex byte "") . ByteString.unpack

-- | The failure's evidence of a snapshot that has it.
evidenceOf ∷ GameSnapshot → FailureEvidence
evidenceOf snapshot = case snapStatus snapshot of
  Failed found → found
  _ → error "expected a failed snapshot"

withEvidence ∷ (SessionFailure → SessionFailure) → GameSnapshot → GameSnapshot
withEvidence change snapshot =
  let found = evidenceOf snapshot
   in snapshot {snapStatus = Failed found {evidencePrimary = change (evidencePrimary found)}}

withWorld ∷ (World → World) → GameSnapshot → GameSnapshot
withWorld change snapshot = snapshot {snapWorld = change (snapWorld snapshot)}

withDispositions ∷ (Dispositions → Dispositions) → GameSnapshot → GameSnapshot
withDispositions change snapshot = snapshot {snapDispositions = change (snapDispositions snapshot)}

withEntity ∷ Int → (Entity → Entity) → World → World
withEntity index change world =
  world {worldEntities = Seq.adjust' change index (worldEntities world)}

-- | Each change to one covered field of 'stateB', named.
covered ∷ [(String, GameSnapshot → GameSnapshot)]
covered =
  [ ("the committed tick", \s → withWorld (\w → w {worldTick = worldTick w + 1}) s {snapTick = snapTick s + 1})
  , ("the random stream's state", withWorld (\w → w {worldRandom = worldRandom w - 1}))
  , ("an entity's x", withWorld (withEntity 0 (\e → e {entityX = entityX e + 1})))
  , ("an entity's y", withWorld (withEntity 1 (\e → e {entityY = entityY e + 1})))
  , ("an entity's version", withWorld (withEntity 2 (\e → e {entityVersion = entityVersion e - 1})))
  , ("the number of entities", withWorld (\w → w {worldEntities = worldEntities w Seq.|> Entity 0 0 0}))
  , ("the order of entities", withWorld (\w → w {worldEntities = Seq.reverse (worldEntities w)}))
  , ("the status kind", \s → s {snapStatus = Stopped})
  , ("the failing tick", withEvidence (\f → f {failTick = failTick f + 1}))
  , ("the failing phase's kind", withEvidence (\f → f {failPhase = "paused"}))
  , ("an applied place's tick", withDispositions (\d → d {dispApplied = [Placement 8 0, Placement 9 2]}))
  , ("an applied place's order", withDispositions (\d → d {dispApplied = [Placement 9 1, Placement 9 2]}))
  , ("the order of applied places", withDispositions (\d → d {dispApplied = reverse (dispApplied d)}))
  , ("an applied place dropped", withDispositions (\d → d {dispApplied = take 1 (dispApplied d)}))
  , ("a stale rejection's place", staleChange (\(Stale _ i r) → Stale (Placement 9 3) i r))
  , ("a stale rejection's reason", staleChange (\(Stale p i _) → Stale p i StaleSession))
  , ("a stale rejection's entity", staleChange (\(Stale p i r) → Stale p i {intentEntity = 1} r))
  , ("a stale rejection's version", staleChange (\(Stale p i r) → Stale p i {intentVersion = 4} r))
  , ("a stale rejection's dx", staleChange (\(Stale p i r) → Stale p i {intentDx = intentDx i + 1} r))
  , ("a stale rejection's dy", staleChange (\(Stale p i r) → Stale p i {intentDy = intentDy i + 1} r))
  , ("how many stale rejections did not fit", withDispositions (\d → d {dispStaleOmitted = 2}))
  , ("an invalidated place", withDispositions (\d → d {dispInvalidated = [Placement 10 0, Placement 11 4]}))
  , ("how many invalidated places were not listed", withDispositions (\d → d {dispInvalidatedOmitted = 3}))
  , ("a discarded place", withDispositions (\d → d {dispDiscarded = [Placement 12 2]}))
  , ("how many discarded places were not listed", withDispositions (\d → d {dispDiscardedOmitted = 1}))
  , ("which list a place is in", withDispositions (\d → d {dispInvalidated = [], dispDiscarded = dispInvalidated d <> dispDiscarded d}))
  ]
  where
    staleChange change = withDispositions (\d → d {dispStale = map change (dispStale d)})

-- | Each change to one field the encoding leaves out.
excluded ∷ [(String, GameSnapshot → GameSnapshot)]
excluded =
  [ ("the snapshot's session identity", \s → s {snapSession = 1234})
  , ("the world's session identity", withWorld (\w → w {worldSession = 1234}))
  , ("the gameplay behavior's instance identity", \s → s {snapGameplay = Just (9, 9, 9)})
  , ("the failing instance's name", withEvidence (\f → f {failWho = "someone else entirely"}))
  , ("the failing stage", withEvidence (\f → f {failStage = "shutdown"}))
  , ("the failure's kind", withEvidence (\f → f {failKind = "refused wait"}))
  , ("the failure's message, which a script chose", withEvidence (\f → f {failMessage = "a different message: \1234 and traceback\nstack:\n  ?"}))
  , ("how many later failures there were", \s → s {snapStatus = Failed (evidenceOf s) {evidenceLater = 40}})
  , ("a stale intention's session and the tick of its view", withDispositions (\d → d {dispStale = [Stale p i {intentSession = 5, intentTick = 77} r | Stale p i r ← dispStale d]}))
  ]

spec ∷ Spec
spec = describe "the canonical encoding and the digest trace" $ do
  describe "the encoding" $ do
    it "is pinned to the documented layout, byte for byte, for two hand-built states" $ do
      hexOf (encodeSnapshot stateA) `shouldBe` goldenA
      hexOf (encodeSnapshot stateB) `shouldBe` goldenB

    it "opens with its format tag and version, and the digest is SHA-256 of the encoding" $ do
      ByteString.take 4 (encodeSnapshot stateA) `shouldBe` formatTag
      ByteString.take 2 (ByteString.drop 4 (encodeSnapshot stateA)) `shouldBe` ByteString.pack [0, fromIntegral formatVersion]
      digestHex (digestSnapshot stateA) `shouldBe` digestA
      digestHex (digestSnapshot stateB) `shouldBe` digestB
      digestHex (digestOf (encodeSnapshot stateA)) `shouldBe` digestA
      ByteString.length (digestBytes (digestSnapshot stateA)) `shouldBe` digestLength

    it "gives equal states equal digests, whichever way they were built" $ do
      let rebuilt s = s {snapWorld = (snapWorld s) {worldEntities = Seq.fromList (toList (worldEntities (snapWorld s)))}}
      digestSnapshot (rebuilt stateB) `shouldBe` digestSnapshot stateB
      digestSnapshot (rebuilt stateA) `shouldBe` digestSnapshot stateA

    mapM_
      ( \(field, change) →
          it ("changes the digest when " <> field <> " changes") $ do
            digestSnapshot (change stateB) `shouldNotBe` digestSnapshot stateB
            encodeSnapshot (change stateB) `shouldNotBe` encodeSnapshot stateB
      )
      covered

    it "changes the digest with each status kind" $ do
      let kinds = [Running, Paused, Stopped, snapStatus stateB]
          digests = [digestSnapshot stateA {snapStatus = status} | status ← kinds]
      length (filter id [a /= b | (i, a) ← zip [0 ∷ Int ..] digests, (j, b) ← zip [0 ..] digests, i < j]) `shouldBe` 6

    mapM_
      ( \(field, change) →
          it ("does not change the digest when " <> field <> " changes") $ do
            digestSnapshot (change stateB) `shouldBe` digestSnapshot stateB
            encodeSnapshot (change stateB) `shouldBe` encodeSnapshot stateB
      )
      excluded

    it "tags the failing phases it knows, each differently, and every other phase alike" $ do
      let kind phase = encodeSnapshot (withEvidence (\f → f {failPhase = phase}) stateB)
          known = ["initializing", "active", "paused", "stopping", "completed", "stopped", "failed", "task"]
      length (foldr (\k seen → if k `elem` seen then seen else k : seen) [] (map kind known)) `shouldBe` length known
      kind "something new" `shouldBe` kind "something else"
      kind "something new" `shouldNotBe` kind "active"

  describe "a digest" $ do
    it "is written as 64 lowercase hexadecimal digits, and read back in either case, and nothing else is read" $ do
      let digest = digestSnapshot stateA
      Text.length (digestHex digest) `shouldBe` 64
      parseDigest (Text.unpack (digestHex digest)) `shouldBe` Just digest
      parseDigest (Text.unpack (Text.toUpper (digestHex digest))) `shouldBe` Just digest
      parseDigest "" `shouldBe` Nothing
      parseDigest (replicate 63 'a') `shouldBe` Nothing
      parseDigest (replicate 65 'a') `shouldBe` Nothing
      parseDigest (replicate 63 'a' <> "g") `shouldBe` Nothing
      parseDigest (replicate 63 'a' <> " ") `shouldBe` Nothing

    it "names the first position at which two traces differ" $ do
      let a = digestOf "a"
          b = digestOf "b"
          c = digestOf "c"
      firstDivergence [a, b, c] [a, b, c] `shouldBe` Nothing
      firstDivergence [a, b, c] [a, c, c] `shouldBe` Just 1
      firstDivergence [a, b, c] [b, b, c] `shouldBe` Just 0
      firstDivergence [a, b, c] [a, b] `shouldBe` Just 2
      firstDivergence [a] [a, b] `shouldBe` Just 1
      firstDivergence [] [] `shouldBe` Nothing

  describe "the trace" $ do
    it "holds the digest of the initial state and then of each committed tick, in tick order" $
      withSample id $ \_ _ domains → do
        let initial = digestSnapshot (initialSnapshot (initialWorld defaultBounds 1 1) Nothing)
        traceNow domains `shouldReturn` [initial]
        committedOnes ← mapM (const (stepCommitted domains)) [1 .. 5 ∷ Int]
        traceNow domains `shouldReturn` (initial : map digestSnapshot committedOnes)
        map snapTick committedOnes `shouldBe` [1 .. 5]

    it "adds nothing for a tick that did not commit, and a failed session's trace ends where its committed ticks end" $
      withSample (\config → config {configTicks = Just 10, configGameplaySource = scenarioGameplay Failure}) $ \_ _ domains → do
        report ← generous (runSession domains)
        -- The behavior raises in tick six: ticks one to five committed.
        reportTicks report `shouldBe` 5
        length (reportTrace report) `shouldBe` 6
        traceNow domains `shouldReturn` reportTrace report
        case reportStatus report of
          Failed found → failTick (evidencePrimary found) `shouldBe` 6
          other → expectationFailure ("expected a failed session, found " <> show other)

    it "keeps the trace as it was, and changes only the final digest, when a failure ends the session after the last commit" $
      withSample (\config → config {configTicks = Just 10, configGameplaySource = scenarioGameplay Failure}) $ \_ _ domains → do
        report ← generous (runSession domains)
        (final, _) ← snapshotNow domains
        -- The final digest is of the final published snapshot, status included.
        reportDigest report `shouldBe` digestSnapshot final
        snapStatus final `shouldSatisfy` \case Failed _ → True; _ → False
        -- The failure added no entry and rewrote none: the last entry is the last committed tick's.
        reportDigest report `shouldNotBe` last (reportTrace report)
        -- The same world and tick, as published by the last commit, with its status and dispositions.
        let lastCommitted = final {snapStatus = Running, snapDispositions = noDispositions}
        encodeSnapshot lastCommitted `shouldNotBe` encodeSnapshot final

    it "keeps the trace as it was, and changes only the final digest, when a stop ends the session after the last commit" $
      withSample (\config → config {configTicks = Just 20, configStopAfter = scenarioStopAfter Stop}) $ \_ _ domains → do
        report ← generous (runSession domains)
        reportTicks report `shouldBe` 8
        length (reportTrace report) `shouldBe` 9
        reportStatus report `shouldBe` Stopped
        reportDigest report `shouldNotBe` last (reportTrace report)

    it "ends with the last commit's digest when the session finishes with no failure and no stop" $
      withSample (\config → config {configTicks = Just 6}) $ \_ _ domains → do
        report ← generous (runSession domains)
        length (reportTrace report) `shouldBe` 7
        reportDigest report `shouldBe` last (reportTrace report)

    it "is bounded: the trace of a session of the most ticks fits, and one more entry is refused, never dropped" $ do
      shared ← newSharedFor defaultBounds
      let digest = digestOf "an entry"
      -- The initial entry is there; the most ticks a session may have fill the rest.
      forM_ [1 .. traceBound - 1] (const (atomically (appendTrace shared digest)))
      held ← readTVarIO (sharedTrace shared)
      length held `shouldBe` traceBound
      refused ← try @AdmissionDefect (atomically (appendTrace shared digest))
      refused `shouldSatisfy` either (const True) (const False)
      length <$> readTVarIO (sharedTrace shared) `shouldReturn` traceBound

-- | The trace as the session holds it.
traceNow ∷ Domains → IO [Digest]
traceNow domains = toList <$> readTVarIO (sharedTrace (domainsShared domains))
