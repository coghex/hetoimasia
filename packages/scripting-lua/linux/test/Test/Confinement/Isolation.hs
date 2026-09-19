-- | Two confined children at once, and what neither can reach of the other.
--
-- Requirement 4. The pair is launched together and held together: each child
-- stops at its handshake and waits for the parent, so both are alive at the
-- same instant and every question either answers is a question about a living
-- sibling rather than about a name nothing holds.
--
-- The pair is held twice, and the first hold is what makes the endpoint
-- question mean anything. Binding a name and asking whether a sibling's is
-- reachable are two events in two processes and nothing orders them, so each
-- child stops once it has bound its own and waits for the parent to say that
-- its sibling has bound one too.
--
-- The endpoint question is the sharp one. Each child binds an abstract
-- @AF_UNIX@ name and then tries both its own and its sibling's. Abstract names
-- are scoped to a network namespace, so in a shared namespace both would
-- connect and in separate ones each reaches only its own: the control and the
-- probe are the same operation on the same kind of name, differing only in
-- whose namespace the name lives in. Nothing about that depends on the host,
-- which is why it is the isolation evidence this suite leans on.
module Test.Confinement.Isolation (spec) where

import Test.Confinement.Support
  ( Availability
  , Environment
  , Confined (confinedPid)
  , Controls
  , Launch (launchEndpoint, launchOutside, launchPeerEndpoint, launchRoot, launchStateDirectory)
  , Ledger
  , Observation
  , admittedOwners
  , announce
  , awaitLine
  , awaitReady
  , collect
  , fieldIn
  , forceStop
  , instruct
  , launchFor
  , observationFor
  , observationsIn
  , releaseAfter
  , stillRunning
  , whenAvailable
  , withLaunch
  , withRoot
  )
import Data.List (isPrefixOf)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)

spec ∷ Ledger → Controls → [FilePath] → Environment → Availability → Spec
spec ledger available sentinels machine installed = describe "isolation" $ do
  it "gives two simultaneous instances distinct owners that cannot reach each other" $
    whenAvailable machine installed "two-instance-isolation" $
      withPair ledger available sentinels $ \alpha beta → do
        let first = instanceChild alpha
            second = instanceChild beta
        confinedPid first `shouldNotBe` confinedPid second
        owners ← admittedOwners ledger
        length owners `shouldBe` 2

        -- Both bound before either asks about the other. A peer probe that ran
        -- first would be refused because the name did not exist yet, which is
        -- a refusal about timing rather than about namespaces.
        --
        -- Each child's report arrives in two batches either side of that hold,
        -- and the controls are in the first: the endpoint a child connects to
        -- is the one it bound before saying so.
        firstBound ← awaitLine "BOUND" first
        secondBound ← awaitLine "BOUND" second
        -- Each is told where its sibling is on the host. It could not have
        -- found that out, and being handed it is what turns "cannot reach the
        -- sibling" from an absence of knowledge into a refusal by the kernel.
        releaseNaming first second
        releaseNaming second first

        firstLines ← (firstBound <>) <$> awaitReady first
        secondLines ← (secondBound <>) <$> awaitReady second
        let firstReport = observationsIn firstLines
            secondReport = observationsIn secondLines

        -- Each read its own state and only its own. The path is the same in
        -- both children and the bytes are not, so a pair that had somehow
        -- shared a view would report the same token twice.
        tokenIn firstLines `shouldBe` Just (instanceToken alpha)
        tokenIn secondLines `shouldBe` Just (instanceToken beta)
        tokenIn firstLines `shouldNotBe` tokenIn secondLines

        -- And neither could read the other's, by the host path it really has.
        outcomeOf firstReport "native" (outsideName (peerStateOf beta))
          `shouldBe` Just "denied"
        outcomeOf secondReport "native" (outsideName (peerStateOf alpha))
          `shouldBe` Just "denied"

        -- Each reaches its own endpoint and not the other's. Both halves
        -- matter: without the first this would be a report about a socket
        -- that never worked.
        outcomeOf firstReport "control" "connect-own-endpoint" `shouldBe` Just "allowed"
        outcomeOf secondReport "control" "connect-own-endpoint" `shouldBe` Just "allowed"
        outcomeOf firstReport "native" "connect-peer-endpoint" `shouldBe` Just "denied"
        outcomeOf secondReport "native" "connect-peer-endpoint" `shouldBe` Just "denied"

        -- And neither can reach the other as a process, having been told
        -- exactly where it is.
        outcomeOf firstReport "native" "signal-peer-process" `shouldBe` Just "denied"
        outcomeOf secondReport "native" "signal-peer-process" `shouldBe` Just "denied"

        -- And the host fixtures neither of them owns stay unreadable too.
        peerSentinelDenied firstReport sentinels
        peerSentinelDenied secondReport sentinels

        announce
          ( "PROVED two-instance-isolation owners="
              <> show (map (\child → toInteger (confinedPid child)) [first, second])
              <> " peer-endpoint=denied peer-state=denied peer-process=denied"
              <> " own-state="
              <> instanceToken alpha
              <> "|"
              <> instanceToken beta
              <> " own-endpoint=allowed"
          )

  it "lets the parent end one instance without disturbing the other" $
    whenAvailable machine installed "independent-termination" $
      withPair ledger available sentinels $ \alpha beta → do
        let first = instanceChild alpha
            second = instanceChild beta
        _ ← awaitLine "BOUND" first
        _ ← awaitLine "BOUND" second
        releaseNaming first second
        releaseNaming second first
        _ ← awaitReady first
        _ ← awaitReady second

        forceStop first
        ended ← releaseAfter ledger first
        surviving ← stillRunning second
        surviving `shouldBe` True

        -- The survivor is not merely alive: it still answers its endpoint,
        -- which is what says the termination reached one instance only.
        instruct second "proceed"
        rest ← collect second
        finished ← releaseAfter ledger second
        owners ← admittedOwners ledger
        owners `shouldBe` []
        if any (("DONE mode=paired" ==) . take 16) rest
          then pure ()
          else expectationFailure "the surviving instance never finished its own work"
        announce
          ( "PROVED independent-termination ended="
              <> show ended
              <> " survivor-finished="
              <> show finished
              <> " admitted-owners=0"
          )

-- | Launch two children that each name the other, and hold both alive.
--
-- Each gets its own private root, its own abstract endpoint, and the other's
-- endpoint and sentinel as the things it must not reach.
withPair
  ∷ Ledger
  → Controls
  → [FilePath]
  → (Instance → Instance → Expectation)
  → Expectation
withPair ledger available sentinels body =
  withSystemTempDirectory "hetoimasia-confine-state" $ \estate → do
    alpha ← stateFor estate "alpha"
    beta ← stateFor estate "beta"
    -- The parent can read both, which is what makes each child's refusal of
    -- the other's a statement about the child rather than about the file.
    alphaHere ← readFile (stateFile alpha)
    betaHere ← readFile (stateFile beta)
    alphaHere `shouldNotBe` betaHere
    withRoot $ \firstRoot →
      withRoot $ \secondRoot → do
        let pairing root endpoint peer own peerState =
              (launchFor "paired" root available sentinels endpoint)
                { launchRoot = root
                , launchEndpoint = endpoint
                , launchPeerEndpoint = peer
                , launchStateDirectory = own
                , -- Its sibling's own state, by the host path it really has.
                  launchOutside = sentinels <> [stateFile peerState]
                }
        withLaunch ledger (pairing firstRoot alphaEndpoint betaEndpoint alpha beta) $
          \startedFirst →
            withLaunch ledger (pairing secondRoot betaEndpoint alphaEndpoint beta alpha) $
              \startedSecond → case (startedFirst, startedSecond) of
                (Right first, Right second) →
                  body
                    Instance {instanceChild = first, instanceState = alpha, instanceToken = token alphaHere}
                    Instance {instanceChild = second, instanceState = beta, instanceToken = token betaHere}
                _ →
                  expectationFailure
                    "the profile installed for the trial child but refused one of the pair"
  where
    alphaEndpoint = "hetoimasia-confine-alpha"
    betaEndpoint = "hetoimasia-confine-beta"
    token = takeWhile (/= '\n')
    stateFor directory name = do
      let own = directory </> name
      createDirectoryIfMissing True own
      writeFile (own </> "sentinel") ("state owned by " <> name <> " alone\n")
      pure own
    stateFile directory = directory </> "sentinel"

-- | One confined instance, and the state only it can read.
data Instance = Instance
  { instanceChild ∷ !Confined
  , instanceState ∷ !FilePath
  , instanceToken ∷ !String
  }

-- | The @STATE@ line's token, which is what that instance read of its own.
tokenIn ∷ [String] → Maybe String
tokenIn reported =
  case [drop (length marker) line | line ← reported, marker `isPrefixOf` line] of
    (value : _) → Just (filter (/= '"') value)
    [] → Nothing
  where
    marker = "STATE token="

-- | The name a host path is reported under when it is one of the forbidden
-- reads.
outsideName ∷ FilePath → String
outsideName path = "read-outside-sentinel:" <> path

-- | Where an instance's own state lives on the host.
peerStateOf ∷ Instance → FilePath
peerStateOf owner = instanceState owner <> "/sentinel"

-- | Release one child, naming its sibling's identity on the host.
releaseNaming ∷ Confined → Confined → IO ()
releaseNaming child sibling =
  instruct child ("probe " <> show (toInteger (confinedPid sibling)))

outcomeOf ∷ [Observation] → String → String → Maybe String
outcomeOf reported phase name = fieldIn "outcome" <$> observationFor phase name reported

-- | Every host sentinel this run made, refused.
--
-- The pair share the sentinel list, so one child's list contains the other's:
-- refusing all of them is refusing the sibling's.
peerSentinelDenied ∷ [Observation] → [FilePath] → Expectation
peerSentinelDenied reported sentinels =
  if all (== Just "denied") outcomes && not (null outcomes)
    then pure ()
    else
      expectationFailure
        ("a host sentinel was not refused inside the child: " <> show outcomes)
  where
    outcomes =
      [outcomeOf reported "native" ("read-outside-sentinel:" <> path) | path ← sentinels]
