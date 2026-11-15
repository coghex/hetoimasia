-- | The storage seam the terrain storage examples (TRA-23) inject: the production terrain service and its storage backend, whose
-- native calls pass through rules and gates this fixture holds. A rule replaces the answer of a matching native call (a failed
-- reservation, a failed or short transfer) as the platform would give it; a gate holds the storage worker that reaches a matching
-- call until the example opens it, so an example decides which side of a window it is on by what it does, never by time.
--
-- It is this suite's own fixture over the terrain service's public test seam ("Hetoimasia.Terrain.Runtime.Testing"); it imports no
-- module of another suite.
module Test.LuaEngine.Terrain.Seam
  ( Faults
  , newFaults
  , seamPort
  , Act (..)
  , addRule
  , clearRules
  , SeamGate
  , addSeamGate
  , addSeamGateOnce
  , addSeamGateAfter
  , awaitSeamGate
  , openSeamGate
  , nativeOps
  , isReserve
  , isRead
  , isWrite
  , isSetLength
  , isCreate
  , isStatFs
  ) where

import Control.Concurrent.STM
import Data.ByteString (ByteString)
import Hetoimasia.Foundation.Worker (WorkerGroup)
import Hetoimasia.Terrain.Runtime (StoragePort)
import Hetoimasia.Terrain.Runtime.Storage (StorageConfig)
import Hetoimasia.Terrain.Runtime.Testing
import Test.Support.Bounded (bounded)

-- | What a rule does to the call it matches.
data Act
  = -- | Fail the call with this errno, without making it.
    FailWith !Int
  | -- | Answer zero bytes without making the call: a page that ended inside itself.
    ZeroBytes
  | -- | Answer this filesystem name from a filesystem query (the call is made).
    FilesystemIs !ByteString

-- | A rule: what it matches, what it does, and how many more times (negative: every time).
data Rule = Rule (NativeOp → Bool) Act Int

-- | A gate: armed until opened; the workers that reached it are counted. It holds a worker before the call, or after it returns; and
-- it catches every matching call, or only the first.
data SeamGate = SeamGate {sgMatch ∷ NativeOp → Bool, sgReached ∷ TVar Int, sgOpen ∷ TVar Bool, sgAfter ∷ Bool, sgOnce ∷ Bool}

-- | The fixture's state: its rules, its gates and every native operation the workers reached, newest first.
data Faults = Faults
  { fRules ∷ TVar [Rule]
  , fGates ∷ TVar [SeamGate]
  , fLog ∷ TVar [NativeOp]
  }

newFaults ∷ IO Faults
newFaults = Faults <$> newTVarIO [] <*> newTVarIO [] <*> newTVarIO []

-- | The port of a rig whose backend's native calls pass through this fixture.
seamPort ∷ Faults → WorkerGroup → StorageConfig → ByteString → StoragePort
seamPort faults group config directory = storagePortWithSeam group config directory (seamOf faults)

-- | Add a rule: the next @n@ matching calls (every one, for a negative @n@) are answered by it.
addRule ∷ Faults → Int → (NativeOp → Bool) → Act → IO ()
addRule faults n match act = atomically (modifyTVar' (fRules faults) (<> [Rule match act n]))

-- | Remove every rule: the platform answers again.
clearRules ∷ Faults → IO ()
clearRules faults = atomically (writeTVar (fRules faults) [])

-- | A gate that holds every worker reaching a matching call, before it is made, until the gate is opened.
addSeamGate ∷ Faults → (NativeOp → Bool) → IO SeamGate
addSeamGate faults match = gateWith faults match False False

-- | A gate that holds only the first worker reaching a matching call, before it is made.
addSeamGateOnce ∷ Faults → (NativeOp → Bool) → IO SeamGate
addSeamGateOnce faults match = gateWith faults match False True

-- | A gate that holds the first worker whose matching call has returned, before the call's result is used.
addSeamGateAfter ∷ Faults → (NativeOp → Bool) → IO SeamGate
addSeamGateAfter faults match = gateWith faults match True True

gateWith ∷ Faults → (NativeOp → Bool) → Bool → Bool → IO SeamGate
gateWith faults match after once = do
  gate ← (\reached opened → SeamGate match reached opened after once) <$> newTVarIO 0 <*> newTVarIO False
  atomically (modifyTVar' (fGates faults) (gate :))
  pure gate

-- | Wait, bounded, until a worker is held at the gate.
awaitSeamGate ∷ SeamGate → IO ()
awaitSeamGate gate = bounded (atomically (readTVar (sgReached gate) >>= check . (> 0)))

-- | Let every held and later worker through. Idempotent.
openSeamGate ∷ SeamGate → IO ()
openSeamGate gate = atomically (writeTVar (sgOpen gate) True)

-- | The native operations the workers reached, oldest first.
nativeOps ∷ Faults → IO [NativeOp]
nativeOps faults = reverse <$> readTVarIO (fLog faults)

isReserve, isRead, isWrite, isSetLength, isCreate, isStatFs ∷ NativeOp → Bool
isReserve = \case OpReserveRange {} → True; _ → False
isRead = \case OpReadAt {} → True; _ → False
isWrite = \case OpWriteAt {} → True; _ → False
isSetLength = \case OpSetFileLength {} → True; _ → False
isCreate = \case OpCreateFile → True; _ → False
isStatFs = \case OpStatFilesystem → True; _ → False

-- | Take the first rule matching the call, counting it down.
takeRule ∷ Faults → NativeOp → IO (Maybe Act)
takeRule faults op = atomically $ do
  rules ← readTVar (fRules faults)
  case break (\(Rule match _ _) → match op) rules of
    (before, Rule match act n : after) → do
      writeTVar (fRules faults) (before <> [Rule match act (n - 1) | n /= 1] <> after)
      pure (Just act)
    _ → pure Nothing

seamOf ∷ Faults → Seam
seamOf faults = Seam native (\op → atomically (modifyTVar' (fLog faults) (op :)) >> holdAt False op) (holdAt True)
  where
    real = posixNative
    holdAt after op = do
      caught ← atomically $ do
        gates ← filter (\g → sgMatch g op && sgAfter g == after) <$> readTVar (fGates faults)
        held ← fmap concat . mapM (\g → do
          opened ← readTVar (sgOpen g)
          reached ← readTVar (sgReached g)
          if opened || (sgOnce g && reached > 0)
            then pure []
            else [g] <$ writeTVar (sgReached g) (reached + 1)) $ gates
        pure held
      mapM_ (\g → atomically (readTVar (sgOpen g) >>= check)) caught
    native =
      real
        { nativeReserve = \fd off len →
            takeRule faults (OpReserveRange off len) >>= \case
              Just (FailWith e) → pure (Left (Errno e))
              _ → nativeReserve real fd off len
        , nativeSetLength = \fd len →
            takeRule faults (OpSetFileLength len) >>= \case
              Just (FailWith e) → pure (Left (Errno e))
              _ → nativeSetLength real fd len
        , nativePread = \fd ptr n off →
            takeRule faults (OpReadAt off n) >>= \case
              Just (FailWith e) → pure (Left (Errno e))
              Just ZeroBytes → pure (Right 0)
              _ → nativePread real fd ptr n off
        , nativePwrite = \fd ptr n off →
            takeRule faults (OpWriteAt off n) >>= \case
              Just (FailWith e) → pure (Left (Errno e))
              Just ZeroBytes → pure (Right 0)
              _ → nativePwrite real fd ptr n off
        , nativeStatFs = \fd →
            takeRule faults OpStatFilesystem >>= \case
              Just (FilesystemIs name) → fmap (\fs → fs {nfTypeName = name}) <$> nativeStatFs real fd
              Just (FailWith e) → pure (Left (Errno e))
              _ → nativeStatFs real fd
        }
