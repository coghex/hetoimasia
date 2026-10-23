{-# LANGUAGE OverloadedStrings #-}

-- | The raw-data provider's contract through real Lua instances: the exact bytes a script receives,
-- the codes and attribution of an expected failure, the required and optional policy, and that
-- nothing is cached, decoded or leased.
module Test.LuaEngine.Data.Contract (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (statusReserved))
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Admission (ProviderDefect)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import System.Directory (createDirectory, removeFile)
import System.IO.Error (isPermissionError, tryIOError)
import System.Posix.Files (setFileMode)
import Test.Hspec
import Test.LuaEngine.Data.Support

spec ∷ Spec
spec = describe "the raw-data provider" $ do
  exactBytes
  failures
  policy

hexOf ∷ ByteString → Text
hexOf = Text.pack . concatMap (\byte → let h = "0123456789abcdef" in [h !! fromIntegral (byte `div` 16), h !! fromIntegral (byte `mod` 16)]) . BS.unpack

-- | The line a take of this content prints.
success ∷ ByteString → Text
success bytes = "{status=success,value=bytes(" <> Text.pack (show (BS.length bytes)) <> ")=" <> hexOf (BS.take 24 bytes) <> "}"

samples ∷ [(FilePath, ByteString)]
samples =
  [ ("empty.bin", "")
  , ("nul.bin", BS.pack [0x61, 0x00, 0x62, 0x00])
  , ("not-utf8.bin", BS.pack [0xff, 0xfe, 0x80, 0xc0, 0xaf])
  , ("bom.txt", BS.pack [0xef, 0xbb, 0xbf] <> "hi")
  , ("lines.txt", "a\r\nb\rc\nd\n\r")
  , ("dir/nested.bin", "nested")
  ]

exactBytes ∷ Spec
exactBytes = describe "the bytes a script receives" $ do
  it "are the exact file for empty, NUL, non-UTF-8, BOM and line-ending content, taken once" $
    withSession fixedM1Profile (2, 8) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "exact" OnArrival
      admitDriver session vm "i"
      mapM_
        ( \(index, (path, bytes)) → do
            let key = "k" <> Text.pack (show (index ∷ Int))
            commandWith session vm "i" "start" key (Just (fetch (Text.pack path)))
            awaitNote session ("cmd start " <> key <> " started")
            command session vm "i" "wait_take" key
            awaitNote session ("cmd wait_take " <> key <> " " <> success bytes)
            -- The handle is spent by the take.
            command session vm "i" "ptake" key
            line ← lineStarting session ("cmd ptake " <> key <> " error")
            line `shouldSatisfy` Text.isInfixOf "request.take"
        )
        (zip [1 ..] samples)
      -- Everything came back: no bank holds anything, no place is held.
      awaitCharged vm 0
      awaitVmDiagnostic vm (\d → rdHeld d == 0)

  it "repeat the read for every request of the same path: no cache, no shared load" $
    withSession fixedM1Profile (2, 8) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "repeat" OnArrival
      admitDriver session vm "i"
      mapM_
        ( \key → do
            commandWith session vm "i" "start" key (Just (fetch "nul.bin"))
            awaitNote session ("cmd start " <> key <> " started")
        )
        ["a", "b", "c"]
      mapM_
        ( \key → do
            command session vm "i" "wait_take" key
            awaitNote session ("cmd wait_take " <> key <> " " <> success (BS.pack [0x61, 0x00, 0x62, 0x00]))
        )
        ["a", "b", "c"]
      readsStarted (ssProbe session) `shouldReturn` 3

  it "stay usable in Lua after the request and its provider have retired, with no release operation" $
    withSession fixedM1Profile (2, 8) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "kept" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "nul.bin"))
      awaitNote session "cmd start a started"
      command session vm "i" "wait" "a"
      awaitNote session "cmd wait a 0"
      command session vm "i" "keep" "a"
      awaitNote session ("cmd keep a " <> success (BS.pack [0x61, 0x00, 0x62, 0x00]))
      -- The request retired: nothing of it is held and the bank is empty.
      awaitVmDiagnostic vm (\d → rdHeld d == 0)
      awaitCharged vm 0
      command session vm "i" "kept" "a"
      awaitNote session "cmd kept a bytes(4)=61006200"

  it "involve no parser, evaluator or Lua resource lease: the ask carries no lease and only a byte and a queue credit" $
    withSession fixedM1Profile (1, 2) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "plain" OnArrival
      let asked = dataAsk (vmService vm) (DataRequest (key' session "nul.bin") RequiredRequest Nothing)
      fmap (const ()) (askLease asked) `shouldBe` Nothing
      map creditName (askCredits asked) `shouldBe` ["data bytes", "io queue"]
      askCodes asked `shouldBe` ["not_found", "content_changed", "io_error", "too_large"]

failures ∷ Spec
failures = describe "an expected failure" $ do
  it "is not_found for a path that is not an inventoried file, with its root and path, and for a file added after the scan" $
    withSession fixedM1Profile (1, 4) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "missing" OnArrival
      admitDriver session vm "i"
      rewrite session "late.bin" "added after the scan"
      mapM_
        ( \(key, path) → do
            commandWith session vm "i" "start" key (Just (fetch path) {fetchOptional = True})
            awaitNote session ("cmd start " <> key <> " started")
            command session vm "i" "wait_take" key
            line ← lineStarting session ("cmd wait_take " <> key)
            line `shouldBe` ("cmd wait_take " <> key <> " {error={code=not_found,message=the path is not an inventoried file,path=" <> path <> ",root=data-test},status=failure}")
        )
        [("a", "gone.bin"), ("b", "late.bin"), ("c", "NUL.BIN"), ("d", "dir")]
      -- No worker ran, no file was opened, and nothing was reserved.
      readsStarted (ssProbe session) `shouldReturn` 0
      awaitCharged vm 0
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0

  it "is content_changed for a same-size edit, a changed length, a removed file and a file replaced by a directory, with no bytes delivered" $
    withSession fixedM1Profile (1, 4) realReader (Layout [("same.bin", "aaaa"), ("grown.bin", "aaaa"), ("gone.bin", "aaaa"), ("typed.bin", "aaaa")]) $ \session _ runtime → do
      vm ← startVm session runtime "changed" OnArrival
      admitDriver session vm "i"
      rewrite session "same.bin" "aaab"
      rewrite session "grown.bin" "aaaaa"
      removeFile (contentPath session "gone.bin")
      removeFile (contentPath session "typed.bin")
      createDirectory (contentPath session "typed.bin")
      mapM_
        ( \(key, path, why) → do
            commandWith session vm "i" "start" key (Just (fetch path) {fetchOptional = True})
            awaitNote session ("cmd start " <> key <> " started")
            command session vm "i" "wait_take" key
            line ← lineStarting session ("cmd wait_take " <> key)
            line `shouldSatisfy` Text.isInfixOf ("code=content_changed,message=" <> why)
            line `shouldSatisfy` Text.isInfixOf ("path=" <> path <> ",root=data-test")
            line `shouldSatisfy` (not . Text.isInfixOf "bytes(")
        )
        [ ("a", "same.bin", "the bytes are not the ones the inventory pinned")
        , ("b", "grown.bin", "the length changed from 4 to 5")
        , ("c", "gone.bin", "the file is gone")
        , ("d", "typed.bin", "the path no longer names a regular file")
        ]
      awaitCharged vm 0

  it "is io_error when the read reports an access failure (injected: the reader answers it, no filesystem produced it)" $
    withSession fixedM1Profile (1, 4) (injectedIoError ["nul.bin"]) (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "io-injected" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "nul.bin") {fetchOptional = True})
      awaitNote session "cmd start a started"
      command session vm "i" "wait_take" "a"
      line ← lineStarting session "cmd wait_take a"
      line `shouldBe` "cmd wait_take a {error={code=io_error,message=the file could not be read: Unreadable 5,path=nul.bin,root=data-test},status=failure}"
      awaitCharged vm 0

  it "is io_error when the file really cannot be opened (a mode 000 file; pending where the process can read it anyway)" $
    withSession fixedM1Profile (1, 4) realReader (Layout samples) $ \session _ runtime → do
      -- The scan read the file while it was readable; only then is it made unreadable.
      setFileMode (contentPath session "nul.bin") 0
      opened ← tryIOError (BS.readFile (contentPath session "nul.bin"))
      case opened of
        Right _ → pendingWith "the process can read a mode 000 file (it is running as root): the injected example above covers io_error"
        Left denied -> do
          isPermissionError denied `shouldBe` True
          vm ← startVm session runtime "io-real" OnArrival
          admitDriver session vm "i"
          commandWith session vm "i" "start" "a" (Just (fetch "nul.bin") {fetchOptional = True})
          awaitNote session "cmd start a started"
          command session vm "i" "wait_take" "a"
          line ← lineStarting session "cmd wait_take a"
          line `shouldSatisfy` Text.isInfixOf "code=io_error"
          line `shouldSatisfy` Text.isInfixOf "path=nul.bin,root=data-test"

  it "is a provider defect, never an optional failure, when the reader raises (injected): the owner fails whatever the request's policy" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (1, 4) (injectedDefect ["nul.bin"] (userError "injected reader defect")) (Layout samples) $ \session control runtime → do
      vm ← startVm session runtime "defect" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "nul.bin") {fetchOptional = True})
      awaitNote session "cmd start a started"
      _ ← awaitEnd control vm
      pure ()
    (fromException failure ∷ Maybe ProviderDefect) `shouldSatisfy` (/= Nothing)

policy ∷ Spec
policy = describe "the required and optional policy" $ do
  it "fails the instance of a required request at its settlement even if never read, naming the data request" $
    withSession fixedM1Profile (1, 4) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "required" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "gone.bin"))
      awaitNote session "cmd start a started"
      failure ← awaitFailure session "i"
      requestFailureOf failure `shouldBe` Just ("data", "(data gone.bin) not_found: the path is not an inventoried file")

  it "is a result for the script when optional, and the instance goes on" $
    withSession fixedM1Profile (1, 4) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "optional" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "gone.bin") {fetchOptional = True})
      awaitNote session "cmd start a started"
      command session vm "i" "wait_take" "a"
      awaitNote session "cmd wait_take a {error={code=not_found,message=the path is not an inventoried file,path=gone.bin,root=data-test},status=failure}"
      d ← vmDiagnostics vm
      rdLatched d `shouldBe` 0

  it "refuses a malformed address as an ordinary Lua error before any admission, not as a content failure" $
    withSession fixedM1Profile (1, 4) realReader (Layout samples) $ \session _ runtime → do
      vm ← startVm session runtime "malformed" OnArrival
      admitDriver session vm "i"
      commandWith session vm "i" "pstart" "a" (Just (fetch "../escape.bin"))
      line ← lineStarting session "cmd pstart a error"
      line `shouldSatisfy` Text.isInfixOf "address refused"
      d ← vmDiagnostics vm
      (rdAdmitted d, rdBusy d) `shouldBe` (0, 0)
      awaitCharged vm 0
      readsStarted (ssProbe session) `shouldReturn` 0
