-- | The profile installs before source loads, refuses when it cannot, and the
-- forbidden native operations are refused.
--
-- Requirements 2 and 3 of the issue. The denial examples read the trial child's
-- own report rather than launching one each: that report is a single ordered
-- record of one child's life, and asking the same question of four different
-- children would be four answers about four processes rather than one answer
-- about the profile.
--
-- Every denial example checks the same operation in four places -- native
-- helper code before source loads, a thread that existed before the filter
-- did, a thread the runtime started after it, and Lua once the source loaded --
-- because a denial that held in only one of them would not be a property of
-- this process. The two threads are the halves of the filter's whole-child
-- claim: @TSYNC@ reaches the ones already running, and inheritance reaches the
-- ones started later.
module Test.Confinement.Profile (spec) where

import Test.Confinement.Support
  ( Availability
  , Controls (controlModule)
  , Ledger
  , Observation (observationKind)
  , Refusal (refusedErrno, refusedLayer)
  , admittedOwners
  , announce
  , describeRefusal
  , fieldIn
  , launchFor
  , observationFor
  , reportedLines
  , reportedObservations
  , whenAvailable
  , withLaunch
  )
import Test.Hspec
  ( Expectation
  , Spec
  , describe
  , expectationFailure
  , it
  , shouldBe
  , shouldNotBe
  )

spec ∷ Ledger → Controls → [FilePath] → Availability → Spec
spec ledger available sentinels installed = describe "profile" $ do
  it "installs the confinement profile before any mod source is loaded" $
    whenAvailable installed "confinement-installed" $ do
      let reported = reportedObservations installed
      case [entry | entry ← reported, observationKind entry == "PROFILE"] of
        [] → expectationFailure "the child reported no profile line"
        (profile : _) → do
          fieldIn "sealed" profile `shouldBe` "yes"
          -- The order is the claim, and the report is ordered: every native
          -- observation is printed before the line that says source loaded.
          sourceLoadedLast installed
          -- And the controls hold, so the denials beside them are about the
          -- kernel rather than about a fixture that never worked.
          allowed reported "control" "read-own-sentinel"
          allowed reported "control" "open-unix-socket"
          allowed reported "control" "bind-own-endpoint"
          allowed reported "control" "connect-own-endpoint"
          announce
            ( "PROVED confinement-installed layers="
                <> fieldIn "layers" profile
                <> " before-source=yes controls=allowed"
            )

  it "refuses the launch with a typed reason when a prerequisite is withheld" $ do
    -- A real prerequisite, really withheld: the private root is the one layer
    -- whose input the parent supplies, so naming a directory that does not
    -- exist withholds it exactly as an unavailable controller would. Nothing
    -- here simulates a refusal.
    let absent = "/nonexistent/hetoimasia-withheld-private-root"
    withLaunch ledger (launchFor "report" absent available sentinels "hetoimasia-withheld") $
      \outcome → case outcome of
        Right _ →
          expectationFailure
            "a launch whose private root does not exist started a child anyway"
        Left refusal → do
          refusedLayer refusal `shouldNotBe` "none"
          refusedErrno refusal `shouldNotBe` 0
          owners ← admittedOwners ledger
          owners `shouldBe` []
          announce
            ( "PROVED typed-refusal "
                <> describeRefusal refusal
                <> " admitted-owners=0 unconfined-child=never-started"
            )

  denial
    installed
    "reading a host file outside its view"
    ("read-outside-sentinel:" <> firstSentinel)
    "probe_read_outside_sentinel"

  denial installed "opening a network socket" "open-inet-socket" "probe_open_inet_socket"

  denial installed "executing another program" "execute-program" "probe_execute_program"

  denial installed "loading a native module" "load-native-module" "probe_load_native_module"

  it "refuses a file-backed executable mapping while allowing the same file unmapped" $
    whenAvailable installed "executable-file-mapping" $ do
      let reported = reportedObservations installed
      allowed reported "control" "map-own-file"
      denied reported "native" "map-own-file-executable"
      announce
        ( "PROVED executable-file-mapping mechanism="
            <> mechanismFor "map-own-file-executable"
            <> " control=allowed errno="
            <> errnoOf reported "native" "map-own-file-executable"
        )

  it "names the native module its denial is about, and loads it here first" $
    case controlModule available of
      Nothing →
        announce
          "BLOCKED experiment=native-module-control unproven-here: this machine offered no loadable module"
      Just name → announce ("CONTROL native-module=" <> name <> " loaded-by-parent=yes")
  where
    firstSentinel = case sentinels of
      (path : _) → path
      [] → ""

-- | One forbidden operation, refused in all three places it is attempted.
denial ∷ Availability → String → String → String → Spec
denial installed subject nativeName luaName =
  it ("is refused " <> subject <> ", and names what refused it") $
    whenAvailable installed nativeName $ do
      let reported = reportedObservations installed
      denied reported "native" nativeName
      denied reported "existing-thread" nativeName
      denied reported "started-thread" nativeName
      denied reported "lua" luaName
      announce
        ( "PROVED "
            <> nativeName
            <> " denied-in=native,existing-thread,started-thread,lua errno="
            <> errnoOf reported "native" nativeName
            <> " mechanism="
            <> mechanismFor nativeName
        )

-- | Which layer of the profile is the one that refuses each operation.
--
-- Named rather than inferred, because requirement 3 asks for the mechanism and
-- an @errno@ alone does not name one: @ENOENT@ for a path that exists on the
-- host is the mount namespace, and @EACCES@ on a socket is the filter.
mechanismFor ∷ String → String
mechanismFor name
  | take (length outsidePrefix) name == outsidePrefix =
      "mount-namespace:the path is not in the private root"
  | name == "open-inet-socket" = "seccomp-filter:socket refused outside AF_UNIX"
  | name == "execute-program" = "seccomp-filter:execve refused"
  | name == "load-native-module" = "seccomp-filter:file-backed PROT_EXEC mapping refused"
  | name == "map-own-file-executable" = "seccomp-filter:file-backed PROT_EXEC mapping refused"
  | name == "connect-peer-endpoint" =
      "network-namespace:the peer's abstract name is not in this namespace"
  | otherwise = "unclassified"
  where
    outsidePrefix = "read-outside-sentinel:"

denied ∷ [Observation] → String → String → Expectation
denied reported phase name = case observationFor phase name reported of
  Nothing → expectationFailure ("the child reported no " <> phase <> " attempt at " <> name)
  Just entry → do
    fieldIn "outcome" entry `shouldBe` "denied"
    fieldIn "errno" entry `shouldNotBe` "0"

allowed ∷ [Observation] → String → String → Expectation
allowed reported phase name = case observationFor phase name reported of
  Nothing → expectationFailure ("the child reported no " <> phase <> " attempt at " <> name)
  Just entry → fieldIn "outcome" entry `shouldBe` "allowed"

errnoOf ∷ [Observation] → String → String → String
errnoOf reported phase name =
  maybe "unreported" (fieldIn "errno") (observationFor phase name reported)

-- | That the child sealed, then probed, then loaded source, in that order.
--
-- The report is written in order by one process, so position in it is when a
-- thing happened. This is the only check in the suite that reads the report as
-- a sequence rather than as a set, and it is the one that has to.
sourceLoadedLast ∷ Availability → Expectation
sourceLoadedLast installed =
  case (firstAt "PROFILE", firstAt "OBSERVED phase=native", firstAt "SOURCE") of
    (Just sealedAt, Just probedAt, Just loadedAt)
      | sealedAt < probedAt && probedAt < loadedAt → pure ()
      | otherwise →
          expectationFailure
            "the child sealed, probed, and loaded source out of the order the contract fixes"
    _ → expectationFailure "the child's report is missing one of its three phases"
  where
    numbered = zip [0 ∷ Int ..] (reportedLines installed)
    firstAt prefix =
      case [index | (index, line) ← numbered, take (length prefix) line == prefix] of
        (index : _) → Just index
        [] → Nothing
