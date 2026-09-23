-- | The confined side of the macOS probe: the profile, its installation, and
-- the access attempts that decide whether installing it meant anything.
--
-- The order here is the contract. 'installConfinement' runs before anything
-- reads mod source, and 'verifyConfinement' runs immediately after it, because
-- a mechanism that returns success is not evidence that it enforced anything --
-- the SPI this profile is installed through is absent from the active SDK, so
-- a future system could export a stub and still succeed. A helper that cannot
-- confirm a forbidden access was refused stops with 'ConfinementNotEnforced'
-- rather than continuing as a plain child.
module Hetoimasia.Scripting.Lua.Internal.MacOS.Confine
  ( -- * The profile
    Confinement (..)
  , helperProfile
  , profileParameters

    -- * Installing and verifying it
  , confinementAvailable
  , installConfinement
  , verifyConfinement

    -- * Attempted accesses
  , Attempt (..)
  , attemptReadFile
  , attemptConnectUnix
  , attemptExecute
  , attemptLoadModule

    -- * What the probe calls each access
  , probeHomeSentinel
  , probePeerSentinel
  , probeOwnEndpoint
  , probePeerEndpoint
  , probeExecuteProgram
  , probeNativeModule

    -- * Accounting
  , readFootprint
  , addressSpaceFloor
  , openDescriptors

    -- * The approved module source
  , probeModuleSource
  , probePrelude
  ) where

import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (withArray0)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)

import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Outcome (..), Refusal (..))

-- | Everything the helper needs to confine itself, resolved by the parent.
--
-- Every path is already canonical. The sandbox matches profile literals against
-- the resolved path, so a profile written in terms of @\/tmp@ on a system where
-- that is a symlink to @\/private\/tmp@ denies the very directory it meant to
-- allow -- which looks exactly like successful confinement and is not.
data Confinement = Confinement
  { confinementSelfBinary ∷ FilePath
  -- ^ The helper's own executable.
  , confinementPrivateDirectory ∷ FilePath
  -- ^ This instance's private working area. It holds its approved module
  -- source and nothing belonging to the host or to another instance.
  , confinementEndpoint ∷ FilePath
  -- ^ This instance's own IPC endpoint, and no other instance's.
  }
  deriving (Eq, Show)

-- | The profile the helper installs on itself.
--
-- @deny default@ with @system.sb@ imported is the smallest thing a threaded
-- Haskell child actually starts under. What follows re-denies the three classes
-- the proof is about and then hands back exactly one instance's own view:
--
-- * @process-exec@ of the helper's own image only. Denying it outright is not
--   an option for a self-confining helper -- but every other program, including
--   the one the Lua probe reaches for through @os.execute@, is refused.
-- * @network-outbound@ to this instance's own endpoint only, so a peer's
--   endpoint is refused by the same rule that permits its own.
-- * read and write inside this instance's private directory only.
--
-- Later rules win, so the allowances below the denials are the whole grant.
helperProfile ∷ Text
helperProfile =
  Text.unlines
    [ "(version 1)"
    , "(deny default)"
    , "(import \"system.sb\")"
    , "(deny network*)"
    , "(deny file-write*)"
    , "(deny process-exec*)"
    , "(allow process-exec (literal (param \"SELFBIN\")))"
    , "(allow file-read* (literal (param \"SELFBIN\")))"
    , "(allow file-read* file-write* (subpath (param \"PRIVATE\")))"
    , "(allow network-outbound (literal (param \"ENDPOINT\")))"
    ]

-- | The profile's parameters, in the flat key/value order the SPI takes.
profileParameters ∷ Confinement → [String]
profileParameters confinement =
  [ "SELFBIN"
  , confinementSelfBinary confinement
  , "PRIVATE"
  , confinementPrivateDirectory confinement
  , "ENDPOINT"
  , confinementEndpoint confinement
  ]

-- | Is the confinement mechanism exported by this system at all?
confinementAvailable ∷ IO Bool
confinementAvailable = (/= 0) <$> c_confine_available

-- | Install the profile on the calling process.
--
-- 'Left' carries the refusal the caller reports and exits on; it never means
-- "proceed unconfined".
installConfinement ∷ Text → Confinement → IO (Either (Refusal, Text) ())
installConfinement profile confinement = do
  available ← confinementAvailable
  if not available
    then
      pure
        ( Left
            ( ConfinementUnavailable
            , "sandbox_init_with_parameters is not exported by this system"
            )
        )
    else withCString (Text.unpack profile) $ \profileText →
      withCStrings (profileParameters confinement) $ \parameters →
        with nullPtr $ \errorOut → do
          result ← c_confine profileText parameters errorOut
          if result == 0
            then pure (Right ())
            else do
              raw ← peek errorOut
              detail ←
                if raw == nullPtr
                  then pure "sandbox_init_with_parameters failed"
                  else do
                    text ← peekCString raw
                    c_confine_free raw
                    pure (Text.pack text)
              pure (Left (ConfinementFailed, detail))

-- | Confirm the installed profile actually refuses something.
--
-- The accesses checked here are the ones the parent has separately proven are
-- reachable without confinement, so an allowed result is the mechanism having
-- done nothing rather than a fixture that was never available.
verifyConfinement ∷ [(Text, Attempt)] → Either (Refusal, Text) ()
verifyConfinement attempts = case [name | (name, attempt) ← attempts, attemptOutcome attempt == Allowed] of
  [] → Right ()
  allowed →
    Left
      ( ConfinementNotEnforced
      , "forbidden access succeeded after installation: " <> Text.intercalate "," allowed
      )

-- | One attempted access and the mechanism that decided it.
data Attempt = Attempt
  { attemptOutcome ∷ Outcome
  , attemptMechanism ∷ Text
  }
  deriving (Eq, Show)

-- | Read a file's first byte. A denial is reported with its errno.
attemptReadFile ∷ FilePath → IO Attempt
attemptReadFile path = fromErrno =<< withCString path c_probe_read_file

-- | Connect to a Unix-domain endpoint.
attemptConnectUnix ∷ FilePath → IO Attempt
attemptConnectUnix path = fromErrno =<< withCString path c_probe_connect_unix

-- | Run another program.
attemptExecute ∷ FilePath → IO Attempt
attemptExecute path = fromErrno =<< withCString path c_probe_exec

-- | Load a native module.
--
-- @dlopen@ sets no errno, so the mechanism is dyld's own message, which names
-- the sandbox when the sandbox is what refused.
attemptLoadModule ∷ FilePath → IO Attempt
attemptLoadModule path =
  withCString path $ \target →
    allocaBytes messageLimit $ \message → do
      result ← c_probe_dlopen target message (fromIntegral messageLimit)
      if result == 0
        then pure (Attempt Allowed "loaded")
        else Attempt Denied . Text.pack <$> peekCString message

-- | The name each attempted access is reported under.
probeHomeSentinel, probePeerSentinel, probeOwnEndpoint ∷ Text
probeHomeSentinel = "home-sentinel"
probePeerSentinel = "peer-sentinel"
probeOwnEndpoint = "own-endpoint"

probePeerEndpoint, probeExecuteProgram, probeNativeModule ∷ Text
probePeerEndpoint = "peer-endpoint"
probeExecuteProgram = "execute-program"
probeNativeModule = "native-module"

-- | Descriptors above stderr, how many are sockets, and a census of them.
--
-- What the process actually holds, rather than what its profile says it may
-- reach: a peer endpoint inherited across the spawn is a live handle no path
-- rule is ever consulted about.
openDescriptors ∷ IO (Int, Int, Text)
openDescriptors =
  with 0 $ \socketsOut →
    allocaBytes messageLimit $ \census → do
      extra ← c_open_descriptors socketsOut census (fromIntegral messageLimit)
      sockets ← peek socketsOut
      summary ← peekCString census
      pure (fromIntegral extra, fromIntegral sockets, Text.pack summary)

-- | The process's physical footprint and virtual size, in bytes.
--
-- Both, because the memory row turns on their difference: the threaded RTS
-- reserves an address range far larger than anything a mod budget would allow,
-- and a limit that counted it could never be installed.
readFootprint ∷ IO (Maybe (Word64, Word64))
readFootprint =
  with 0 $ \footprintOut →
    with 0 $ \virtualOut → do
      result ← c_footprint footprintOut virtualOut
      if result /= 0
        then pure Nothing
        else do
          footprint ← peek footprintOut
          virtualSize ← peek virtualOut
          pure (Just (fromIntegral footprint, fromIntegral virtualSize))

-- | The smallest @RLIMIT_AS@ this process can install, and the errno that
-- rejected the next step below it.
--
-- The search restores the limit it found, so the experiments that follow are
-- not quietly running under a bound this measurement left behind.
addressSpaceFloor ∷ IO (Maybe (Word64, Int))
addressSpaceFloor =
  with 0 $ \floorOut →
    with 0 $ \errnoOut → do
      result ← c_rlimit_as_floor floorOut errnoOut
      if result /= 0
        then pure Nothing
        else do
          bytes ← peek floorOut
          code ← peek errnoOut
          pure (Just (fromIntegral bytes, fromIntegral code))

messageLimit ∷ Int
messageLimit = 1024

fromErrno ∷ CInt → IO Attempt
fromErrno code
  | code == 0 = pure (Attempt Allowed "no-error")
  | otherwise = allocaBytes messageLimit $ \message → do
      c_errno_text code message (fromIntegral messageLimit)
      Attempt Denied . Text.pack <$> peekCString message

-- | Marshal a list of strings as one NUL-terminated array of C strings.
withCStrings ∷ [String] → (Ptr CString → IO a) → IO a
withCStrings values action = go values []
 where
  go [] acc = withArray0 nullPtr (reverse acc) action
  go (value : rest) acc = withCString value (\pointer → go rest (pointer : acc))

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_confine_available"
  c_confine_available ∷ IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_confine"
  c_confine ∷ CString → Ptr CString → Ptr CString → IO CInt

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_confine_free"
  c_confine_free ∷ CString → IO ()

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_probe_read_file"
  c_probe_read_file ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_probe_connect_unix"
  c_probe_connect_unix ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_probe_exec"
  c_probe_exec ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_probe_dlopen"
  c_probe_dlopen ∷ CString → CString → CSize → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_open_descriptors"
  c_open_descriptors ∷ Ptr CInt → CString → CSize → IO CInt

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_footprint"
  c_footprint ∷ Ptr Word64 → Ptr Word64 → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_rlimit_as_floor"
  c_rlimit_as_floor ∷ Ptr Word64 → Ptr CInt → IO CInt

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_errno_text"
  c_errno_text ∷ CInt → CString → CSize → IO ()

-- | The approved module source the probe admits, as Lua.
--
-- It is deliberately written against @io@, @os@, and @package@, which the
-- probe's VM opens on purpose. Requirement 4 asks for denials observed from
-- Lua, and a VM built without those libraries would produce "attempt to index a
-- nil value" for every row -- the Lua library allowlist refusing, not the
-- operating system. Opening them is how the Lua-side denials become evidence
-- about confinement instead of evidence about 'Library'.
--
-- Its fixture paths arrive as globals from 'probePrelude'; there is no path
-- literal in here.
probeModuleSource ∷ Text
probeModuleSource =
  Text.unlines
    [ "local function emit(name, allowed, mechanism)"
    , "  local verdict = allowed and \"allowed\" or \"denied\""
    , "  io.stdout:write(\"hmp/1 access lua \" .. name .. \" \" .. verdict"
    , "    .. \" \" .. mechanism .. \"\\n\")"
    , "  io.stdout:flush()"
    , "end"
    , ""
    , "local function flatten(value)"
    , "  return (tostring(value):gsub(\"%s+\", \" \"))"
    , "end"
    , ""
    , "local function read_probe(name, path)"
    , "  local handle, message = io.open(path, \"r\")"
    , "  if handle then"
    , "    handle:read(1)"
    , "    handle:close()"
    , "    emit(name, true, \"io.open-returned-a-handle\")"
    , "  else"
    , "    emit(name, false, \"io.open \" .. flatten(message))"
    , "  end"
    , "end"
    , ""
    , "read_probe(\"home-sentinel\", HMP_HOME_SENTINEL)"
    , "read_probe(\"peer-sentinel\", HMP_PEER_SENTINEL)"
    , ""
    , "local ran, kind, code = os.execute(HMP_EXEC_TARGET)"
    , "if ran == true then"
    , "  emit(\"execute-program\", true, \"os.execute-returned-true\")"
    , "else"
    , "  emit(\"execute-program\", false,"
    , "    \"os.execute \" .. flatten(ran) .. \" \" .. flatten(kind) .. \" \" .. flatten(code))"
    , "end"
    , ""
    , "local loaded, reason = package.loadlib(HMP_NATIVE_MODULE, \"*\")"
    , "if loaded then"
    , "  emit(\"native-module\", true, \"package.loadlib-returned-a-loader\")"
    , "else"
    , "  emit(\"native-module\", false, \"package.loadlib \" .. flatten(reason))"
    , "end"
    , ""
    , "-- The workload the memory and execution experiments drive. Neither runs"
    , "-- unless the parent calls it, and neither yields on its own."
    , "-- hmp_grow_step keeps one 8388608-byte string. That is the Lua half of"
    , "-- one memory-workload step; the helper retains a native buffer of the"
    , "-- same size beside it and accounts for the two separately."
    , "HMP_HELD = {}"
    , "function hmp_grow_step()"
    , "  HMP_HELD[#HMP_HELD + 1] = string.rep(\"m\", 1024 * 1024 * 8)"
    , "end"
    , "function hmp_spin()"
    , "  local total = 0"
    , "  while true do"
    , "    total = total + 1"
    , "    if total >= math.maxinteger then total = 0 end"
    , "  end"
    , "end"
    ]

-- | The globals the module source reads its fixture paths from.
--
-- The helper evaluates this before the module source, so the source itself
-- carries no path and the parent decides every target it reaches for.
probePrelude ∷ [(Text, FilePath)] → Text
probePrelude bindings =
  Text.unlines [name <> " = " <> luaString (Text.pack value) | (name, value) ← bindings]

-- | A Lua string literal. Only the two characters that could end the literal or
-- start an escape are special; a fixture path contains neither, and quoting
-- them anyway is what keeps that true if one ever does.
luaString ∷ Text → Text
luaString value = "\"" <> Text.concatMap escape value <> "\""
 where
  escape = \case
    '\\' → "\\\\"
    '"' → "\\\""
    '\n' → "\\n"
    character → Text.singleton character
