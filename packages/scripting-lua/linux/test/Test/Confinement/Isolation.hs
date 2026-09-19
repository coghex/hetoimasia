-- | Two confined children at once, and what neither can reach of the other.
--
-- Requirement 4. The pair is launched together and held together: each child
-- stops at its handshake and waits for the parent, so both are alive at the
-- same instant and every question either answers is a question about a living
-- sibling rather than about a name nothing holds.
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
  , Confined (confinedPid)
  , Controls
  , Launch (launchEndpoint, launchOutside, launchPeerEndpoint, launchRoot)
  , Ledger
  , Observation
  , admittedOwners
  , announce
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
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)

spec ∷ Ledger → Controls → [FilePath] → Availability → Spec
spec ledger available sentinels installed = describe "isolation" $ do
  it "gives two simultaneous instances distinct owners that cannot reach each other" $
    whenAvailable installed "two-instance-isolation" $
      withPair ledger available sentinels $ \first second → do
        confinedPid first `shouldNotBe` confinedPid second
        owners ← admittedOwners ledger
        length owners `shouldBe` 2

        firstReport ← observationsIn <$> awaitReady first
        secondReport ← observationsIn <$> awaitReady second

        -- Each reaches its own endpoint and not the other's. Both halves
        -- matter: without the first this would be a report about a socket
        -- that never worked.
        outcomeOf firstReport "control" "connect-own-endpoint" `shouldBe` Just "allowed"
        outcomeOf secondReport "control" "connect-own-endpoint" `shouldBe` Just "allowed"
        outcomeOf firstReport "native" "connect-peer-endpoint" `shouldBe` Just "denied"
        outcomeOf secondReport "native" "connect-peer-endpoint" `shouldBe` Just "denied"

        -- And neither reads the other's sentinel, which exists on the host and
        -- which the parent read before either was launched.
        peerSentinelDenied firstReport sentinels
        peerSentinelDenied secondReport sentinels

        announce
          ( "PROVED two-instance-isolation owners="
              <> show (map (\child → toInteger (confinedPid child)) [first, second])
              <> " peer-endpoint=denied peer-sentinel=denied own-endpoint=allowed"
          )

  it "lets the parent end one instance without disturbing the other" $
    whenAvailable installed "independent-termination" $
      withPair ledger available sentinels $ \first second → do
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
  ∷ Ledger → Controls → [FilePath] → (Confined → Confined → Expectation) → Expectation
withPair ledger available sentinels body =
  withRoot $ \firstRoot →
    withRoot $ \secondRoot → do
      let pairing root endpoint peer =
            (launchFor "paired" root available sentinels endpoint)
              { launchRoot = root
              , launchEndpoint = endpoint
              , launchPeerEndpoint = peer
              , launchOutside = sentinels
              }
      withLaunch ledger (pairing firstRoot alphaEndpoint betaEndpoint) $ \startedFirst →
        withLaunch ledger (pairing secondRoot betaEndpoint alphaEndpoint) $ \startedSecond →
          case (startedFirst, startedSecond) of
            (Right first, Right second) → body first second
            _ →
              expectationFailure
                "the profile installed for the trial child but refused one of the pair"
  where
    alphaEndpoint = "hetoimasia-confine-alpha"
    betaEndpoint = "hetoimasia-confine-beta"

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
