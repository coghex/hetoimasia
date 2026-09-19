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
  ( Environment
  , Controls (controlInheritedDescriptor, controlModule)
  , Ledger
  , Observation (observationKind)
  , Availability (Blocked, Installs)
  , Refusal (refusedErrno, refusedLayer)
  , admittedOwners
  , announce
  , describeRefusal
  , expectedRefusal
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

spec ∷ Ledger → Controls → [FilePath] → Environment → Availability → Spec
spec ledger available sentinels machine installed = describe "profile" $ do
  it "installs the confinement profile before any mod source is loaded" $
    whenAvailable machine installed "confinement-installed" $ do
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
          -- Which layer refuses depends on how far this machine gets. Where
          -- the profile installs, a root that does not exist must be refused
          -- by the private root itself and by nothing earlier; where it does
          -- not, the refusal is the machine's own obstacle and must still be
          -- the one its record explains. Either way the layer is asserted
          -- rather than merely non-empty.
          case installed of
            Installs _ → do
              refusedLayer refusal `shouldBe` "private-root"
              refusedErrno refusal `shouldBe` noSuchFileErrno
            Blocked _ → expectedRefusal machine refusal
          owners ← admittedOwners ledger
          owners `shouldBe` []
          announce
            ( "PROVED typed-refusal "
                <> describeRefusal refusal
                <> " admitted-owners=0 unconfined-child=never-started"
            )

  denial
    machine
    installed
    "reading a host file outside its view"
    ("read-outside-sentinel:" <> firstSentinel)
    (Just "probe_read_outside_sentinel")

  denial machine installed "opening a network socket" "open-inet-socket" (Just "probe_open_inet_socket")

  denial machine installed "executing another program" "execute-program" (Just "probe_execute_program")

  denial machine installed "loading a native module" "load-native-module" (Just "probe_load_native_module")

  it "runs as the first process of a namespace that holds nothing else" $
    whenAvailable machine installed "pid-namespace" $ do
      let reported = reportedObservations installed
      case [entry | entry ← reported, observationKind entry == "PROFILE"] of
        [] → expectationFailure "the child reported no profile line"
        (profile : _) → do
          -- One is what a PID namespace's init is, and nothing else can be:
          -- a child sharing the host's numbering would report its host pid.
          fieldIn "pid" profile `shouldBe` "1"
          announce ("PROVED pid-namespace child-pid=" <> fieldIn "pid" profile)

  denial
    machine
    installed
    "signalling a process outside its namespace"
    "signal-outside-process"
    Nothing

  it "cannot see a descriptor the parent left open above any swept range" $
    whenAvailable machine installed "inherited-descriptor" $ do
      let reported = reportedObservations installed
      denied reported "native" "see-inherited-descriptor"
      denied reported "existing-thread" "see-inherited-descriptor"
      denied reported "started-thread" "see-inherited-descriptor"
      announce
        ( "PROVED inherited-descriptor number="
            <> show (controlInheritedDescriptor available)
            <> " visible-in-child=no mechanism="
            <> mechanismFor "see-inherited-descriptor"
            <> " errno="
            <> errnoOf reported "native" "see-inherited-descriptor"
        )

  it "refuses a file-backed executable mapping while allowing the same file unmapped" $
    whenAvailable machine installed "executable-file-mapping" $ do
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

-- | One forbidden operation, refused everywhere it is attempted.
--
-- The Lua name is optional because not every operation has a binding: the ones
-- a mod could reach are published to it, and the ones only the launcher can
-- get wrong -- an inherited descriptor, a process outside the namespace -- are
-- observed from native code alone. Where there is no binding, saying so is
-- better than publishing one for the sake of symmetry.
denial ∷ Environment → Availability → String → String → Maybe String → Spec
denial machine installed subject nativeName luaName =
  it ("is refused " <> subject <> ", and names what refused it") $
    whenAvailable machine installed nativeName $ do
      let reported = reportedObservations installed
      denied reported "native" nativeName
      denied reported "existing-thread" nativeName
      denied reported "started-thread" nativeName
      mapM_ (denied reported "lua") luaName
      announce
        ( "PROVED "
            <> nativeName
            <> " denied-in=native,existing-thread,started-thread"
            <> maybe "" (const ",lua") luaName
            <> " errno="
            <> errnoOf reported "native" nativeName
            <> " mechanism="
            <> mechanismFor nativeName
        )

-- | @ENOENT@, which is what a path that is not there answers.
noSuchFileErrno ∷ Int
noSuchFileErrno = 2

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
  | name == "see-inherited-descriptor" =
      "launcher:every descriptor above the four it is given is closed before the exec"
  | name == "signal-outside-process" =
      "pid-namespace:no process outside it has a number in here"
  | name == "signal-peer-process" =
      "pid-namespace:the sibling has no number in this namespace"
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
