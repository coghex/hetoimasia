{-# LANGUAGE OverloadedStrings #-}

-- | Stopping, failing and racing: a VM's stop closes admission and gives back what its jobs held at
-- the moment each is really over, one VM ending leaves its peer whole, a defect of the engine is
-- fatal whatever waits, and a late or duplicate callback changes nothing.
module Test.LuaEngine.Modules.Lifecycle (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, fromException, rethrowIO, throwIO, tryWithContext)
import Control.Monad (forM_, void)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (statusLive, statusReserved))
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Provider (Completion (..), ProviderDiagnostics (rdOutstanding), RequestEndpoint (..), Submission (..))
import Test.Hspec
import Test.LuaEngine.Modules.Support

layout ∷ Layout
layout =
  Layout
    [ ("m.lua", "fx.record('eval m') fx.block('m') return { id = 'm' }")
    , ("a.lua", "fx.record('eval a') return { id = 'a' }")
    , ("b.lua", "fx.record('eval b') return { id = 'b' }")
    , ("c.lua", "fx.record('eval c') return { id = 'c' }")
    , ("boom.lua", "return { id = 'boom' }")
    , ("bad.lua", "this is not lua")
    , ("g1.lua", "return { id = 'g1' }")
    , ("g2.lua", "return { id = 'g2' }")
    ]

evalsOf ∷ Session → IO [Text.Text]
evalsOf session = filter (Text.isPrefixOf "eval") <$> history session

spec ∷ Spec
spec = describe "stop, failure and races" $ do
  stopping
  peers
  defects
  callbacks

stopping ∷ Spec
stopping = describe "stopping a VM" $ do
  it "withdraws a read nobody has taken at once and gives its slot back, and lets a late job of a stopped VM change nothing" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions OnArrival) $ \vm →
        withVm session runtime "neighbour" (defaultOptions OnArrival) $ \other → do
          admitDriver session vm "x"
          admitDriver session other "o"
          forM_ ["g1.lua", "g2.lua"] (closeGate (ssProbe session))
          -- The neighbour holds both workers; the stopping VM's read waits in the queue.
          command session other "o" "start" "k1" [] (Just (fetch "g1.lua"))
          command session other "o" "start" "k2" [] (Just (fetch "g2.lua"))
          awaitStarted (ssProbe session) 2
          command session vm "x" "start" "k3" [] (Just (fetch "a.lua"))
          awaitNote session "x start k3 started"
          reading ← poolReading session
          statusLive reading `shouldSatisfy` (>= 3)
          retireVm control vm
          -- Withdrawn without a file being opened, and every slot the stopped VM held is the pool's
          -- again; the other VM's own stay with it.
          awaitDrained' vm
          readsStarted (ssProbe session) >>= (`shouldBe` 2)
          counts vm >>= \c → (jobsStopped c, bytesOrdinary c, slotsHeld c, phaseNow c) `shouldBe` (1, 0, 0, Closed)
          vmDiagnostics vm >>= \d → rdOutstanding d `shouldBe` 0
          openEverything session
          awaitCounts other (\c → jobsReady c == 2)
          evalsOf session >>= (`shouldBe` [])

  it "lets a read a worker holds finish, drops its bytes and returns its slot, and never evaluates it" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "a.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "a.lua"))
        awaitNote session "x start k1 started"
        awaitStarted (ssProbe session) 1
        retireVm control vm
        -- The read is in a worker's hands: it is still charged, and the slot is still held.
        counts vm >>= \c → (phaseNow c, bytesOrdinary c > 0, slotsHeld c) `shouldBe` (Closed, True, 1)
        openGate (ssProbe session) "a.lua"
        awaitDrained' vm
        counts vm >>= \c → (bytesOrdinary c, slotsHeld c, jobsReady c, jobsStopped c) `shouldBe` (0, 0, 0, 1)
        evalsOf session >>= (`shouldBe` [])
        poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "drops the bytes of a source that arrived and waits for a position far ahead, returning its charge and its slot" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions AtAssignedTick) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetchAt 50 "a.lua"))
        awaitNote session "x start k1 started"
        awaitFinished (ssProbe session) 1
        counts vm >>= \c → (bytesOrdinary c > 0, slotsHeld c) `shouldBe` (True, 4)
        retireVm control vm
        awaitDrained' vm
        counts vm >>= \c → (bytesOrdinary c, slotsHeld c, jobsStopped c, jobsReady c) `shouldBe` (0, 0, 1, 0)
        evalsOf session >>= (`shouldBe` [])
        poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "starts no deferred read once it has stopped, whatever room frees" $
    withSession (withSource 100 100 200) (2, 8) realReader smallLayout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "s1.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "s1.lua"))
        command session vm "x" "start" "k2" [] (Just (fetch "s2.lua"))
        awaitNote session "x start k2 started"
        awaitStarted (ssProbe session) 1
        counts vm >>= \c → readsDeferred c `shouldBe` 1
        retireVm control vm
        openGate (ssProbe session) "s1.lua"
        awaitDrained' vm
        readsStarted (ssProbe session) >>= (`shouldBe` 1)
        counts vm >>= \c → (bytesOrdinary c, slotsHeld c) `shouldBe` (0, 0)

  it "is idempotent: closing and retiring again change nothing and raise nothing, a ready module stays readable and nothing new is admitted" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "a.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        retireVm control vm
        awaitDrained' vm
        forM_ [1 .. 3 ∷ Int] (const (closeModuleCoordinator (vmCoordinator vm)))
        retireVm control vm
        counts vm >>= \c → (jobsReady c, phaseNow c, slotsHeld c) `shouldBe` (1, Closed, 0)
        found ← atomically (lookupImmediate (vmCoordinator vm) (moduleIdentity (key' session "a.lua")))
        case found of
          ImmediateReady _ → pure ()
          _ → expectationFailure "a ready module should stay readable after the stop"
        refused ← bootModule (vmCoordinator vm) (key' session "b.lua")
        either (`shouldBe` BootClosed) (const (expectationFailure "a closed coordinator should take no boot load")) refused

  it "stops while a module is running: the module is not preempted, nothing resumes, and everything is given back" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "stopping" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "m.lua"))
        awaitNote session "x start k1 started"
        awaitGate session "m"
        askRetire vm
        releaseGate session "m"
        void (awaitEnd control vm)
        awaitDrained' vm
        counts vm >>= \c → (bytesOrdinary c, slotsHeld c, waitersHeld c) `shouldBe` (0, 0, 0)
        vmDiagnostics vm >>= \d → rdOutstanding d `shouldBe` 0
  where
    smallLayout =
      Layout
        [ ("s1.lua", "return { id = 's1' } -- padding padding padding padding padding padding padding")
        , ("s2.lua", "return { id = 's2' } -- padding padding padding padding padding padding padding")
        ]

peers ∷ Spec
peers = describe "peers" $
  it "leave one VM whole when another ends, in either order, and share the pool's workers until each ends" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "first" (defaultOptions OnArrival) $ \first →
        withVm session runtime "second" (defaultOptions OnArrival) $ \second → do
          admitDriver session first "x"
          admitDriver session second "y"
          closeGate (ssProbe session) "b.lua"
          command session first "x" "start" "k1" [] (Just (fetch "a.lua"))
          command session second "y" "start" "k2" [] (Just (fetch "b.lua"))
          awaitNote session "y start k2 started"
          awaitCounts first (\c → jobsReady c == 1)
          retireVm control first
          awaitDrained' first
          -- The first has gone; the second's job is untouched and finishes.
          counts second >>= \c → (jobsLive c, phaseNow c) `shouldBe` (1, Open)
          openGate (ssProbe session) "b.lua"
          awaitCounts second (\c → jobsReady c == 1)
          command session second "y" "settled_take" "k2" [] Nothing
          awaitNote session "y take k2 {status=success,value=table(b)}"
          retireVm control second
          awaitDrained' second
          poolReading session >>= \reading → statusReserved reading `shouldBe` 0

defects ∷ Spec
defects = describe "a defect" $ do
  it "of the pool's reader is fatal whether or not anything waits for the job" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (2, 8) (injectedDefect ["boom.lua"] (userError "the disk exploded")) layout $ \session control runtime →
      withVm session runtime "defective" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "boom.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "boom.lua"))
        awaitNote session "x start k1 started"
        awaitStarted (ssProbe session) 1
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 cancelled"
        openGate (ssProbe session) "boom.lua"
        ended ← tryWithContext @SomeException (awaitEnd control vm)
        either rethrowIO (const (expectationFailure "the owner should have ended in a failure")) ended
    (fromException failure ∷ Maybe ModuleDefect) `shouldSatisfy` isJust

  it "of the reader that is an expected I/O failure is the request's failure and nothing else's" $
    withSession fixedM1Profile (2, 8) (injectedIoError ["boom.lua"]) layout $ \session _ runtime →
      withVm session runtime "io" (defaultOptions OnArrival) $ \vm → do
        admitDriver session vm "x"
        admitDriver session vm "y"
        command session vm "x" "start" "k1" [] (Just (fetch "boom.lua"))
        failure ← awaitFailure session "x"
        fmap snd (requestFailureOf failure) `shouldSatisfy` maybe False (Text.isInfixOf "io_error")
        -- Another instance of the same VM is unaffected.
        command session vm "y" "start" "k2" [] (Just (fetch "a.lua"))
        awaitCounts vm (\c → jobsReady c == 1)

  it "of the diagnostic sink is fatal, and the VM still gives back what it held" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "logging" (defaultOptions OnArrival) {optLogger = Just (failingLogger "the sink broke")} $ \vm → do
        admitDriver session vm "x"
        closeGate (ssProbe session) "bad.lua"
        command session vm "x" "start" "k1" [] (Just (fetch "bad.lua"))
        awaitNote session "x start k1 started"
        awaitStarted (ssProbe session) 1
        command session vm "x" "cancel" "k1" [] Nothing
        awaitNote session "x cancel k1 cancelled"
        openGate (ssProbe session) "bad.lua"
        ended ← tryWithContext @SomeException (awaitEnd control vm)
        either rethrowIO (const (expectationFailure "the owner should have ended in a failure")) ended
    show failure `shouldSatisfy` ("the sink broke" `isInfixOfString`)

callbacks ∷ Spec
callbacks = describe "completions" $ do
  it "may be duplicated by the provider's own wrapper: the second is evidence about the provider, and settles nothing twice" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime →
      withVm session runtime "twice" (defaultOptions OnArrival) {optWrap = duplicated} $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "a.lua"))
        awaitCounts vm (\c → jobsReady c == 1)
        command session vm "x" "settled_take" "k1" [] Nothing
        awaitNote session "x take k1 {status=success,value=table(a)}"
        vmDiagnostics vm >>= \d → rdOutstanding d `shouldBe` 0

  it "of a handoff that fails takes the admission back whole: no identity stays reserved, no job is made, and the failure is the engine's" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "refusing" (defaultOptions OnArrival) {optWrap = refusing} $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "a.lua"))
        ended ← tryWithContext @SomeException (awaitEnd control vm)
        counts vm >>= \c → (promisedHeld c, jobsHeld c, waitersHeld c, readsBegun c) `shouldBe` (0, 0, 0, 0)
        either rethrowIO (const (expectationFailure "the owner should have ended in a failure")) ended
    show failure `shouldSatisfy` ("the handoff broke" `isInfixOfString`)

  it "that fail are the engine's failure, and the VM stops cleanly" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (2, 8) realReader layout $ \session control runtime →
      withVm session runtime "failing" (defaultOptions OnArrival) {optWrap = failing} $ \vm → do
        admitDriver session vm "x"
        command session vm "x" "start" "k1" [] (Just (fetch "a.lua"))
        ended ← tryWithContext @SomeException (awaitEnd control vm)
        either rethrowIO (const (expectationFailure "the owner should have ended in a failure")) ended
    show failure `shouldSatisfy` ("the completion broke" `isInfixOfString`)
  where
    duplicated endpoint =
      endpoint
        { endpointSubmit = \submission →
            endpointSubmit
              endpoint
              submission
                { submissionCompletion =
                    Completion (\reply → completeRequest (submissionCompletion submission) reply >> completeRequest (submissionCompletion submission) reply)
                }
        }
    refusing endpoint = endpoint {endpointSubmit = \_ → throwIO (userError "the handoff broke")}
    failing endpoint =
      endpoint
        { endpointSubmit = \submission →
            endpointSubmit
              endpoint
              submission {submissionCompletion = Completion (\_ → throwIO (userError "the completion broke"))}
        }

awaitDrained' ∷ Vm → IO ()
awaitDrained' vm = atomically (awaitDrained (vmCoordinator vm))

isInfixOfString ∷ String → String → Bool
isInfixOfString needle haystack = Text.isInfixOf (Text.pack needle) (Text.pack haystack)
