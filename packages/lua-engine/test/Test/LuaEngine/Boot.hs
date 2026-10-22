{-# LANGUAGE OverloadedStrings #-}

-- | The manifest and entry boot checkpoint, composed with the generic content
-- inventory over real temporary folders the example owns. No Lua, window or GPU
-- is involved: the checkpoint evaluates nothing.
--
-- Evidence is native throughout (real files, a real anchored root and a real
-- scan), through the packages' public interfaces alone. The reader the
-- checkpoint takes is a narrow service, so an example can hold it at a gate,
-- make it throw, or have it return other bytes than the scan pinned, without a
-- private seam.
module Test.LuaEngine.Boot (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, throwIO, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Either (isRight)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Hetoimasia.Content
  ( ContentRoot
  , limitPathDepth
  , limitReadChunk
  , withContentRoot
  )
import Hetoimasia.Content.Identity (ContentKey, parseReference, rootKey)
import Hetoimasia.Content.Inventory
import Hetoimasia.LuaEngine.Boot
import Hetoimasia.LuaEngine.Manifest
import Hetoimasia.LuaEngine.Profile
import System.Directory (createDirectory, createDirectoryIfMissing, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.Process (proc, readCreateProcessWithExitCode)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.Support.ExternalClient (Client (..), Mode (..), withStorePackageClient)

-- | A smaller profile that keeps every relation, with a tiny manifest, a tiny
-- inventory and tiny hashing bounds.
smallProfile ∷ Profile
smallProfile =
  either (error . ("the small test profile is invalid: " <>) . show) id . validateProfile $
    setBytes ManifestBytes 256
      . setBytes ModuleSourceBytes 2048
      . setBytes HashFileBytes 4096
      . setBytes HashRootBytes 16384
      . setBytes HashBufferBytes 32
      . setBytes PathBytes 64
      . setBytes PathSegmentBytes 24
      . setCount InventoryEntries 20
      . setCount PathSegments 6
      $ profileSpec fixedM1Profile

setBytes ∷ ByteLimit → Integer → ProfileSpec → ProfileSpec
setBytes target value base = base {specBytes = \limit → if limit == target then Bytes (fromInteger value) else specBytes base limit}

setCount ∷ CountLimit → Integer → ProfileSpec → ProfileSpec
setCount target value base = base {specCounts = \limit → if limit == target then Count (fromInteger value) else specCounts base limit}

-- | A folder holding these files, beneath a temporary directory.
withFolder ∷ [(FilePath, ByteString)] → (FilePath → FilePath → IO a) → IO a
withFolder files use =
  withSystemTempDirectory "hetoimasia-lua-engine" $ \tree → do
    let folder = tree </> "root"
    createDirectory folder
    forM_ files $ \(path, bytes) →
      if last path == '/'
        then createDirectoryIfMissing True (folder </> init path)
        else do
          createDirectoryIfMissing True (takeDirectory (folder </> path))
          ByteString.writeFile (folder </> path) bytes
    use tree folder

-- | Open the folder as the profile configures the content layer, scan it, and
-- run the body. The scope is bounded, so a borrow that was leaked fails the
-- example instead of holding the process.
scannedWith ∷ Profile → FilePath → (ContentRoot → Inventory → IO a) → IO a
scannedWith profile folder use = do
  configuration ← either (fail . show) pure (contentConfiguration profile)
  key ← either (fail . show) pure (rootKey "boot-test")
  bounded . withContentRoot (configContentLimits configuration) folder $ \root →
    scanInventory (configInventoryLimits configuration) key root >>= \case
      Left refusal → fail ("the scan was refused: " <> show refusal)
      Right inventory → use root inventory

withBooted ∷ Profile → [(FilePath, ByteString)] → (FilePath → ContentRoot → Inventory → IO a) → IO a
withBooted profile files use = withFolder files $ \_ folder → scannedWith profile folder (use folder)

keyOf ∷ Inventory → ByteString → ContentKey
keyOf inventory reference =
  either
    (error . ("invalid fixture reference: " <>) . show)
    id
    (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) (inventoryRootKey inventory) reference)

refusalOf ∷ Either BootRefusal a → Maybe BootRefusal
refusalOf = either Just (const Nothing)

-- | UTF-8 bytes of a string, for fixtures that carry non-ASCII text.
utf8 ∷ String → ByteString
utf8 = Encoding.encodeUtf8 . Text.pack

-- | A valid manifest of exactly this many bytes: the document padded with
-- trailing whitespace.
padded ∷ Int → ByteString → ByteString
padded size document = document <> Char8.replicate (size - ByteString.length document) ' '

both, gameplayOnly, presentationOnly, separate ∷ ByteString
both = "{\"format\":1,\"id\":\"demo\",\"entry\":\"main.lua\",\"tick_seconds\":\"0.1\"}"
gameplayOnly = "{\"format\":1,\"id\":\"demo\",\"tick_seconds\":\"1\",\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\",\"entry\":\"game.lua\"}]}"
presentationOnly = "{\"format\":1,\"id\":\"demo\",\"entry\":\"ui.lua\",\"vms\":[{\"role\":\"presentation\",\"clock\":\"elapsed\"}]}"
separate = "{\"format\":1,\"id\":\"demo\",\"entry\":\"common.lua\",\"tick_seconds\":\"0.5\",\"vms\":[{\"role\":\"gameplay\",\"clock\":\"logical\",\"entry\":\"game.lua\"},{\"role\":\"presentation\",\"clock\":\"elapsed\",\"entry\":\"ui.lua\"}]}"

checkpointOf ∷ ContentRoot → Inventory → IO (Either BootRefusal Checkpoint)
checkpointOf root inventory = bootCheckpointFrom fixedM1Profile root inventory

spec ∷ Spec
spec = describe "the boot checkpoint" $ do
  describe "the content configuration" $ do
    it "derives the fixed M1 numbers from the profile, and they are the approved ones" $ do
      configuration ← either (fail . show) pure (contentConfiguration fixedM1Profile)
      let limits = configInventoryLimits configuration
      (inventoryEntries limits, inventorySegments limits, inventoryPathBytes limits, inventorySegmentBytes limits) `shouldBe` (10000, 32, 1024, 255)
      (inventoryFileBytes limits, inventoryRootBytes limits, inventoryBufferBytes limits) `shouldBe` (64 * 1024 * 1024, 1024 * 1024 * 1024, 64 * 1024)
      (limitPathDepth (configContentLimits configuration), limitReadChunk (configContentLimits configuration)) `shouldBe` (32, 64 * 1024)

    it "derives smaller numbers from a validated smaller profile" $ do
      configuration ← either (fail . show) pure (contentConfiguration smallProfile)
      let limits = configInventoryLimits configuration
      (inventoryEntries limits, inventorySegments limits, inventoryPathBytes limits, inventorySegmentBytes limits) `shouldBe` (20, 6, 64, 24)
      (inventoryFileBytes limits, inventoryRootBytes limits, inventoryBufferBytes limits) `shouldBe` (4096, 16384, 32)

  describe "a folder that can boot" $ do
    it "returns the manifest, every declared entry and the entry each role loads, for a common entry" $
      withBooted fixedM1Profile [("hetoimasia.json", both), ("main.lua", "-- never evaluated")] $ \_ root inventory → do
        Right checkpoint ← checkpointOf root inventory
        contentIdText (manifestId (checkpointManifest checkpoint)) `shouldBe` "demo"
        manifestBytes (checkpointManifest checkpoint) `shouldBe` both
        map (\entry → (resolvedSlot entry, resolvedText entry, resolvedLength entry)) (checkpointEntries checkpoint)
          `shouldBe` [(CommonSlot, "main.lua", 18)]
        checkpointRoleEntries checkpoint `shouldBe` [(Gameplay, keyOf inventory "main.lua"), (Presentation, keyOf inventory "main.lua")]
        checkpointManifestKey checkpoint `shouldBe` keyOf inventory "hetoimasia.json"

    it "checks a common entry that every role overrides, and returns each role's own" $
      withBooted fixedM1Profile [("hetoimasia.json", separate), ("common.lua", "c"), ("game.lua", "g"), ("ui.lua", "u")] $ \_ root inventory → do
        Right checkpoint ← checkpointOf root inventory
        map (\entry → (resolvedSlot entry, resolvedText entry)) (checkpointEntries checkpoint)
          `shouldBe` [(CommonSlot, "common.lua"), (RoleSlot Gameplay, "game.lua"), (RoleSlot Presentation, "ui.lua")]
        checkpointRoleEntries checkpoint `shouldBe` [(Gameplay, keyOf inventory "game.lua"), (Presentation, keyOf inventory "ui.lua")]

    it "refuses a fully overridden common entry that names nothing" $
      withBooted fixedM1Profile [("hetoimasia.json", separate), ("game.lua", "g"), ("ui.lua", "u")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just (EntryAbsent CommonSlot (keyOf inventory "common.lua"))

    it "serves a gameplay-only folder with its own entry, and a presentation-only folder with the common one" $ do
      withBooted fixedM1Profile [("hetoimasia.json", gameplayOnly), ("game.lua", "g")] $ \_ root inventory → do
        Right checkpoint ← checkpointOf root inventory
        checkpointRoleEntries checkpoint `shouldBe` [(Gameplay, keyOf inventory "game.lua")]
        map resolvedSlot (checkpointEntries checkpoint) `shouldBe` [RoleSlot Gameplay]
      withBooted fixedM1Profile [("hetoimasia.json", presentationOnly), ("ui.lua", "u")] $ \_ root inventory → do
        Right checkpoint ← checkpointOf root inventory
        checkpointRoleEntries checkpoint `shouldBe` [(Presentation, keyOf inventory "ui.lua")]
        map resolvedSlot (checkpointEntries checkpoint) `shouldBe` [CommonSlot]

    it "does not evaluate or decode an entry, and accepts unused hidden files beside it" $
      withBooted fixedM1Profile [("hetoimasia.json", both), ("main.lua", "this is not ((( valid lua"), (".hidden/unused.png", "not a png")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        outcome `shouldSatisfy` isRight

  describe "a declared entry that cannot boot" $ do
    let entryManifest path = "{\"format\":1,\"id\":\"demo\",\"entry\":\"" <> path <> "\",\"tick_seconds\":\"0.1\"}"

    forM_ ["/abs.lua", "lua//main.lua", "lua/", "../main.lua", "./main.lua", "lua\\\\main.lua", "c:main.lua", ""] $ \path →
      it ("refuses the entry text " <> show path <> " as an invalid reference, before any file is consulted") $
        withBooted fixedM1Profile [("hetoimasia.json", entryManifest path), ("main.lua", "x")] $ \_ root inventory → do
          outcome ← checkpointOf root inventory
          case refusalOf outcome of
            Just (EntryReferenceRefused CommonSlot _) → pure ()
            other → expectationFailure ("expected an invalid reference, got " <> show other)

    it "refuses an entry that names nothing, and one whose case differs, as absent" $ do
      withBooted fixedM1Profile [("hetoimasia.json", entryManifest "missing.lua")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just (EntryAbsent CommonSlot (keyOf inventory "missing.lua"))
      withBooted fixedM1Profile [("hetoimasia.json", entryManifest "Main.lua"), ("main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just (EntryAbsent CommonSlot (keyOf inventory "Main.lua"))

    it "refuses an entry that names a directory" $
      withBooted fixedM1Profile [("hetoimasia.json", entryManifest "lua"), ("lua/main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just (EntryNotAFile CommonSlot (keyOf inventory "lua"))

    it "validates an entry of a nested directory, and a composed spelling names a decomposed file" $
      withBooted fixedM1Profile [("hetoimasia.json", entryManifest (utf8 "lua/caf\233.lua")), ("lua/cafe\769.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        outcome `shouldSatisfy` isRight

  describe "the manifest file" $ do
    it "accepts a manifest of exactly the 64 KiB limit and refuses one byte more before reading it" $ do
      withBooted fixedM1Profile [("hetoimasia.json", padded 65536 both), ("main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        outcome `shouldSatisfy` isRight
      withBooted fixedM1Profile [("hetoimasia.json", padded 65537 both), ("main.lua", "x")] $ \_ root inventory → do
        readCounter ← newIORef (0 ∷ Int)
        let counting key ceiling' = atomicModifyIORef' readCounter (\n → (n + 1, ())) >> readVerified inventory root key ceiling'
        outcome ← bootCheckpoint fixedM1Profile inventory counting
        refusalOf outcome `shouldBe` Just (ManifestOverLimit 65537 65536)
        readIORef readCounter `shouldReturn` 0

    it "holds the same edges under a smaller profile" $ do
      withBooted smallProfile [("hetoimasia.json", padded 256 both), ("main.lua", "x")] $ \_ root inventory → do
        outcome <- bootCheckpointFrom smallProfile root inventory
        outcome `shouldSatisfy` isRight
      withBooted smallProfile [("hetoimasia.json", padded 257 both), ("main.lua", "x")] $ \_ root inventory → do
        outcome <- bootCheckpointFrom smallProfile root inventory
        refusalOf outcome `shouldBe` Just (ManifestOverLimit 257 256)

    it "fails when there is no manifest, and when the only one differs in case, searching nothing else" $ do
      withBooted fixedM1Profile [("main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just ManifestAbsent
      withBooted fixedM1Profile [("Hetoimasia.json", both), ("main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just ManifestAbsent
      withFolder [("main.lua", "x")] $ \tree folder → do
        -- a valid manifest in the parent folder is never consulted
        ByteString.writeFile (tree </> "hetoimasia.json") both
        scannedWith fixedM1Profile folder $ \root inventory → do
          outcome ← checkpointOf root inventory
          refusalOf outcome `shouldBe` Just ManifestAbsent

    it "fails when the manifest's name is a directory" $
      withBooted fixedM1Profile [("hetoimasia.json/inner", both), ("main.lua", "x")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        refusalOf outcome `shouldBe` Just ManifestNotAFile

    it "reports an invalid manifest as a manifest refusal, with the entry check never reached" $
      withBooted fixedM1Profile [("hetoimasia.json", "{\"format\":2}")] $ \_ root inventory → do
        outcome ← checkpointOf root inventory
        case refusalOf outcome of
          Just (ManifestRefused _) → pure ()
          other → expectationFailure ("expected a manifest refusal, got " <> show other)

  describe "the manifest bytes that were parsed are the bytes the scan pinned" $ do
    let revisionA = "{\"format\":1,\"id\":\"aaaa\",\"entry\":\"main.lua\",\"tick_seconds\":\"1\"}"
        revisionB = "{\"format\":1,\"id\":\"bbbb\",\"entry\":\"main.lua\",\"tick_seconds\":\"1\"}"
        equivalent = "{ \"format\" : 1, \"id\":\"aaaa\", \"entry\":\"main.lua\", \"tick_seconds\":\"1\" }"

    it "refuses a manifest parsed from revision A when the scan pinned a valid revision B of the same length" $
      withFolder [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \_ folder → do
        parsedA ← either (fail . show) pure (parseManifest revisionA)
        ByteString.writeFile (folder </> "hetoimasia.json") revisionB
        scannedWith fixedM1Profile folder $ \_ inventory ->
          checkManifestPinned inventory parsedA `shouldBe` Left ManifestNotPinned

    it "refuses it even when revision B parses to an equivalent configuration" $
      withFolder [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \_ folder → do
        parsedA ← either (fail . show) pure (parseManifest revisionA)
        ByteString.writeFile (folder </> "hetoimasia.json") equivalent
        parsedEquivalent ← either (fail . show) pure (parseManifest equivalent)
        (manifestId parsedEquivalent, manifestRoles parsedEquivalent) `shouldBe` (manifestId parsedA, manifestRoles parsedA)
        scannedWith fixedM1Profile folder $ \_ inventory ->
          checkManifestPinned inventory parsedA `shouldBe` Left ManifestNotPinned

    it "accepts the same supplied bytes" $
      withFolder [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \_ folder → do
        parsedA ← either (fail . show) pure (parseManifest revisionA)
        scannedWith fixedM1Profile folder $ \_ inventory ->
          checkManifestPinned inventory parsedA `shouldBe` Right ()

    it "refuses a manifest replaced between the scan and the checkpoint, valid or not, at any length" $
      forM_ [revisionB, equivalent, "{\"format\":2}", ""] $ \replacement →
        withFolder [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \_ folder →
          scannedWith fixedM1Profile folder $ \root inventory → do
            ByteString.writeFile (folder </> "hetoimasia.json") replacement
            outcome ← checkpointOf root inventory
            case refusalOf outcome of
              Just (ManifestReadRefused _) → pure ()
              other → expectationFailure ("expected a refused read of the replaced manifest, got " <> show other)

    it "refuses bytes from the reader that are not the pinned ones, and accepts the pinned ones" $
      withBooted fixedM1Profile [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \_ root inventory → do
        wrong ← bootCheckpoint fixedM1Profile inventory (\_ _ → pure (Right revisionB))
        refusalOf wrong `shouldBe` Just ManifestNotPinned
        right ← bootCheckpoint fixedM1Profile inventory (\_ _ → pure (Right revisionA))
        right `shouldSatisfy` isRight
        void (pure root)

    it "does not use a manifest that was deleted after the scan" $
      withBooted fixedM1Profile [("hetoimasia.json", revisionA), ("main.lua", "x")] $ \folder root inventory → do
        removeFile (folder </> "hetoimasia.json")
        outcome ← checkpointOf root inventory
        case refusalOf outcome of
          Just (ManifestReadRefused _) → pure ()
          other → expectationFailure ("expected a refused read, got " <> show other)

  describe "cancellation and failure around the manifest comparison" $ do
    it "leaves nothing behind when cancelled while holding the manifest read, and the root still closes" $
      withBooted fixedM1Profile [("hetoimasia.json", both), ("main.lua", "x")] $ \_ root inventory → do
        reached ← newEmptyMVar
        hold ← newEmptyMVar
        finished ← newEmptyMVar
        let gated key ceiling' = do
              result ← readVerified inventory root key ceiling'
              putMVar reached ()
              takeMVar hold
              pure result
        thread ← forkIO (try (bootCheckpoint fixedM1Profile inventory gated) >>= putMVar finished)
        bounded (takeMVar reached)
        killThread thread
        outcome ← bounded (takeMVar finished) ∷ IO (Either SomeException (Either BootRefusal Checkpoint))
        either (\exception → fromException exception `shouldBe` Just ThreadKilled) (const (expectationFailure "the cancelled checkpoint returned")) outcome
        -- no usable partial result: a fresh checkpoint over the same inventory is whole
        again ← checkpointOf root inventory
        again `shouldSatisfy` isRight

    it "propagates a failure of the reader as the failure it is, never as a refusal" $
      withBooted fixedM1Profile [("hetoimasia.json", both), ("main.lua", "x")] $ \_ _ inventory → do
        outcome ← try (bootCheckpoint fixedM1Profile inventory (\_ _ → throwIO (userError "reader failed")))
        case outcome of
          Left exception → show (exception ∷ SomeException) `shouldContain` "reader failed"
          Right _ → expectationFailure "a failing reader was reported as a value"

  describe "composition from outside the packages" $ do
    it "lets a separately compiled client open a root, scan it and run the checkpoint through public modules alone" $
      withSystemTempDirectory "hetoimasia-lua-engine-client" $ \tree →
        withStorePackageClient ["base", "bytestring", "hetoimasia-content-0.1.0.0-inplace", "hetoimasia-lua-engine-0.1.0.0-inplace"] "Main.hs" scopedClient $ \compile → do
          outcome ← compile Link
          case clientStatus outcome of
            ExitSuccess → pure ()
            status → expectationFailure ("the client must compile, but the compiler exited with " <> show status <> ":\n" <> clientOutput outcome)
          createDirectory (tree </> "root")
          ByteString.writeFile (tree </> "root" </> "hetoimasia.json") both
          ByteString.writeFile (tree </> "root" </> "main.lua") "-- not evaluated"
          (status, out, err) ← readCreateProcessWithExitCode (proc (clientDirectory outcome </> "client") [tree </> "root"]) ""
          (status, out, err) `shouldBe` (ExitSuccess, "Gameplay\nPresentation\n", "")

  describe "two folders" $ do
    it "boot independently, each against its own inventory" $
      withBooted fixedM1Profile [("hetoimasia.json", both), ("main.lua", "one")] $ \_ rootOne inventoryOne →
        withBooted fixedM1Profile [("hetoimasia.json", gameplayOnly), ("game.lua", "two")] $ \_ rootTwo inventoryTwo → do
          Right one ← checkpointOf rootOne inventoryOne
          Right two ← checkpointOf rootTwo inventoryTwo
          map fst (checkpointRoleEntries one) `shouldBe` [Gameplay, Presentation]
          map fst (checkpointRoleEntries two) `shouldBe` [Gameplay]

-- | A client that opens a root, scans it and runs the checkpoint, naming only
-- public modules.
scopedClient ∷ String
scopedClient =
  unlines
    [ "module Main (main) where"
    , ""
    , "import qualified Data.ByteString.Char8 as BC"
    , "import Hetoimasia.Content"
    , "import Hetoimasia.Content.Identity (rootKey)"
    , "import Hetoimasia.Content.Inventory"
    , "import Hetoimasia.LuaEngine.Boot"
    , "import Hetoimasia.LuaEngine.Profile (fixedM1Profile)"
    , "import System.Environment (getArgs)"
    , ""
    , "main ∷ IO ()"
    , "main = do"
    , "  [directory] ← getArgs"
    , "  configuration ← either (fail . show) pure (contentConfiguration fixedM1Profile)"
    , "  key ← either (fail . show) pure (rootKey (BC.pack \"client\"))"
    , "  withContentRoot (configContentLimits configuration) directory $ \\root → do"
    , "    inventory ← scanInventory (configInventoryLimits configuration) key root >>= either (fail . show) pure"
    , "    bootCheckpointFrom fixedM1Profile root inventory >>= \\case"
    , "      Right checkpoint → mapM_ (print . fst) (checkpointRoleEntries checkpoint)"
    , "      Left refusal → putStrLn (\"refused: \" <> show refusal)"
    ]
