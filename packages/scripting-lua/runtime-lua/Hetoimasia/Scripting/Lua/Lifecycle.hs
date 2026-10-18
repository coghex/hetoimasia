-- | Lifecycle control and inspection granted to a script across owners (LUA-23).
--
-- A script instance's code can ask, through bindings the application registers, that
-- an instance pause, resume or stop, and can read snapshots of instances. It can do so
-- only where its owner was /granted/ it: a 'LifecycleGrant' given to the owner when it
-- is created names the owners it covers and what each permits. The grant is the whole of
-- the authority. An owner created with none keeps the not-yet-supported refusal every
-- lifecycle operation answered before this slice, with its action never run, whichever
-- registration it was given.
--
-- = One registration, many grants
--
-- The bindings ('lifecycleBindings') are registered once, in one 'Registration', which any
-- number of owners with different grants share. Each owner is handed its own state
-- through the host library's 'Hetoimasia.Scripting.Lua.Registration.LifecycleContext',
-- which the engine reads from the owner's configuration on every call: the caller's
-- owner, its grant and its receipts are the engine's knowledge of who is calling, and
-- no value a script passes names or changes them. The calling instance is the one whose
-- Lua the owner is running, never a field of an argument.
--
-- = Authority and refusals
--
-- A target is named by an instance identity (a TID, see below). Routing is by the
-- identity's numbers alone, never by an owner's label, and every refusal is an answer,
-- never a fault. They are decided in this order, and the order is the contract:
--
-- 1. @unauthorized@: the target's owner is not one the grant covers, or the grant does
--    not permit the operation there. Nothing is tested of the target, so the answer
--    says nothing of whether it exists: an owner outside the grant, a foreign runtime's
--    identity and an identity that was never issued answer alike.
-- 2. For a target that admits logically, @unassigned@: the application is asked for the
--    request's place once the grant has passed it, and gave none.
-- 3. @full@: the caller already holds as many receipts as its grant allows.
-- 4. @closed@: the target's owner is not taking requests (it is stopping or has exited).
-- 5. @unknown_target@: within the authorized owner, no live instance has the identity:
--    ended, stale or never issued.
-- 6. For a target that admits logically, @late@ (the tick is one the owner has begun) and
--    @duplicate@ (the place is taken).
-- 7. @full@: the target's owner holds as many result reservations as it allows.
--
-- Inspection is refused as @unauthorized@, @closed@ and @unknown_target@ in that order.
--
-- = Requests and receipts
--
-- @pause@, @resume@ and @stop@ never block. An accepted request holds a reservation at
-- the target for its result and a receipt at the caller, and answers a receipt number.
-- The receipt is read with @result@: @pending@ until the request settles, then exactly
-- one of @applied@, @already_in_state@ and @no_longer_applicable@ (an instance that
-- ended first, a stop that superseded it, an owner that exited first). Reading a settled
-- receipt consumes it and gives the reservation back, once; any later read answers
-- @unknown_receipt@, as does a number the caller never held. @forget@ abandons interest
-- in a result and gives the reservation back when the request settles. A receipt is read
-- only by the instance that made the request; the engine keeps no other history of
-- results, so what is held is bounded by the grant's receipt bound.
--
-- Abandonment never undoes an accepted request. An instance that ends abandons the
-- receipts it holds, and an owner's exit abandons all of its owner's: the requests
-- already accepted are still applied or settled by their targets, and only the interest in
-- their results is released. Every accepted request settles exactly once whatever happens
-- to its target: applied, overtaken by the target's stop, failure or cancellation, or by
-- its owner's retirement.
--
-- = Self-control and ordering
--
-- An instance may ask for its own control. The request is not applied inside the segment
-- that made it: the target's owner applies requests at its safe boundaries, so a segment
-- always returns or yields first. Where the target admits logically, it is applied at the
-- boundary of the tick it was assigned, before that tick's ordinary work. A stop takes
-- precedence over ordinary work as it does for the Haskell API, which is unchanged.
--
-- = Logical admission
--
-- A target configured to admit controls logically ('AdmitLogically') applies each request
-- at the logical boundary of the tick the application assigned it, in the order of
-- (tick, sequence), whatever order requests arrived in. The grant carries an
-- 'AssignControl' for such a target, and the engine asks it for every request that passes
-- the grant, with the caller, the calling instance, the target and the operation, all the
-- engine's own knowledge: it answers the place or declines. A request assigned a tick
-- that has begun is refused as @late@, one assigned a place taken as @duplicate@, and
-- never applied at another boundary. Admission reads the tick and enqueues in one
-- transaction, so a request accepted for a tick is always in the queue before that tick
-- is visible. Identical tick-assigned inputs give an identical sequence of controls, and
-- so of effects, however the threads that made them interleave.
--
-- = Inspection
--
-- @inspect@ answers one instance's snapshot and @inspect_owner@ the instances of one
-- covered owner, each read in one transaction so an owner's snapshot is coherent, in the
-- order of identity. A snapshot holds the TID, the owner's label, the instance's name and
-- its status: @initializing@, @active@, @paused@, @stopping@, @completed@, @stopped@ or
-- @failed@. They never borrow a Lua table. The count is bounded by the grant's snapshot
-- bound and the size by the owner's value limits: a list that would not fit is cut, and
-- says so (@truncated@).
--
-- = Identities in Lua
--
-- A TID is the record @{runtime, owner, id}@ and an owner reference the record
-- @{runtime, owner}@, all integers. They name and grant nothing: a script can forge any
-- number it likes and reach exactly what its grant covers.
module Hetoimasia.Scripting.Lua.Lifecycle
  ( -- * Granting
    LifecycleGrant (..)
  , lifecycleGrant
  , GrantTarget (..)
  , GrantedOwner (..)
  , Permit (..)
  , defaultReceiptBound
  , defaultSnapshotBound
  , maxGrantTargets

    -- * Assigning places
  , AssignControl
  , ControlRequestInfo (..)

    -- * Refusing a grant
  , LifecycleRefused (..)
  , LifecycleViolation (..)

    -- * What a script calls
  , lifecycleBindings
  , lifecycleNamespace
  , instanceIdValue
  , ownerRefValue

    -- * For the scheduled owner
  , resolveGrant
  , newLifecycleState
  , lifecycleContextOf
  ) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception)
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Unique (hashUnique)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Instance.State (Gate (gateOpen), admitControl, forgetReceipt, inspectInstance, inspectInstances, observeReceipt)
import Hetoimasia.Scripting.Lua.Instance.Run (gateOf)
import Hetoimasia.Scripting.Lua.Instance.Types
  ( ControlAdmission (..)
  , InstanceControl (..)
  , InstanceControlAnswer (..)
  , InstanceId (..)
  , InstancePhase (..)
  , InstanceSnapshot (..)
  , Instances (insAdmission)
  )
import Hetoimasia.Scripting.Lua.Internal.Value (checkLimits)
import Hetoimasia.Scripting.Lua.Lifecycle.State
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , LifecycleContext
  , Namespace
  , fromLifecycleContext
  , lifecycleContext
  , lifecycleOperationIn
  , namespace
  )
import Hetoimasia.Scripting.Lua.Runtime.Types (OwnerId (..), ownerSequence)
import Hetoimasia.Scripting.Lua.Scheduled.Types (Control (..), ScheduledEndpoint (..))
import Hetoimasia.Scripting.Lua.Scheduler (ControlResult (..))
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..), ValueLimits)

-- | The owners an owner's scripts may reach, and the bounds on what they hold.
data LifecycleGrant = LifecycleGrant
  { grantTargets ∷ [GrantTarget]
    -- ^ The covered owners, each once.
  , grantReceiptBound ∷ !Int
    -- ^ How many receipts the owner's scripts hold at once. At least one.
  , grantSnapshotBound ∷ !Int
    -- ^ The most instances one inspection answers. At least one.
  }

-- | A grant of these targets, with the default bounds.
lifecycleGrant ∷ [GrantTarget] → LifecycleGrant
lifecycleGrant targets = LifecycleGrant targets defaultReceiptBound defaultSnapshotBound

-- | Thirty-two receipts.
defaultReceiptBound ∷ Int
defaultReceiptBound = 32

-- | Sixty-four snapshots.
defaultSnapshotBound ∷ Int
defaultSnapshotBound = 64

-- | The most owners one grant covers.
maxGrantTargets ∷ Int
maxGrantTargets = 256

-- | What a grant permits of one owner.
data GrantTarget = GrantTarget
  { grantOwner ∷ !GrantedOwner
  , grantPermits ∷ [Permit]
    -- ^ At least one, and not repeated.
  , grantAssign ∷ !(Maybe AssignControl)
    -- ^ Where the target admits logically and the grant permits control, how a request is
    -- given its place; required there, and refused anywhere else.
  }

-- | An owner a grant covers.
data GrantedOwner
  = -- | Another owner of the same runtime, created earlier.
    GrantedEndpoint !ScheduledEndpoint
  | -- | The owner the grant is given to.
    GrantedSelf

-- | Why a grant was refused.
data LifecycleViolation
  = -- | A bound below one: which, and its value.
    GrantBoundBelowOne !Text !Int
  | GrantTooManyTargets !Int
  | -- | The same owner named twice.
    GrantDuplicateTarget !Text
  | GrantNoPermits !Text
  | GrantRepeatedPermit !Text
  | -- | An owner of another runtime.
    GrantForeignRuntime !Text
  | -- | An owner that hosts no instances, which has nothing to inspect or control.
    GrantHostsNoInstances !Text
  | -- | A permitted control of an owner that admits logically, with no assignment.
    GrantNeedsAssignment !Text
  | -- | An assignment for an owner that does not admit logically, or no control permit.
    GrantAssignsNothing !Text
  deriving (Eq, Show)

-- | Raised, before anything starts, for a grant that is refused.
newtype LifecycleRefused = LifecycleRefused (NonEmpty LifecycleViolation)
  deriving (Show)

instance Exception LifecycleRefused

-- | The targets of a grant, resolved for the owner it is given to, or every reason it is
-- refused. The owner's own gate is only passed along, never forced, so it may be the one
-- of the owner being built.
resolveGrant ∷ OwnerId → Text → Maybe (Instances, Gate) → LifecycleGrant → Either (NonEmpty LifecycleViolation) [Target]
resolveGrant owner label own grant =
  case NonEmpty.nonEmpty (boundProblems <> concatMap problems resolved <> duplicates) of
    Just problem → Left problem
    Nothing → Right [target | (_, Just target, _) ← resolved]
  where
    OwnerId scope _ = owner
    boundProblems =
      [GrantBoundBelowOne "receipt bound" (grantReceiptBound grant) | grantReceiptBound grant < 1]
        <> [GrantBoundBelowOne "snapshot bound" (grantSnapshotBound grant) | grantSnapshotBound grant < 1]
        <> [GrantTooManyTargets (length (grantTargets grant)) | length (grantTargets grant) > maxGrantTargets]
    resolved = map resolve (grantTargets grant)
    resolve granted = case grantOwner granted of
      GrantedSelf → case own of
        Just (instances, gate) → (granted, Just (Target owner label instances gate (permits granted) (grantAssign granted)), label)
        Nothing → (granted, Nothing, label)
      GrantedEndpoint (ScheduledEndpoint scheduled) → case controlInstances scheduled of
        Just instances → (granted, Just (Target (controlOwner scheduled) (controlLabel scheduled) instances (gateOf scheduled) (permits granted) (grantAssign granted)), controlLabel scheduled)
        Nothing → (granted, Nothing, controlLabel scheduled)
    permits = Set.fromList . grantPermits
    problems (granted, found, name) =
      [GrantNoPermits name | null (grantPermits granted)]
        <> [GrantRepeatedPermit name | length (nub (grantPermits granted)) /= length (grantPermits granted)]
        <> case (grantOwner granted, found) of
          (GrantedEndpoint (ScheduledEndpoint scheduled), _)
            | OwnerId other _ ← controlOwner scheduled, other /= scope → [GrantForeignRuntime name]
          (_, Nothing) → [GrantHostsNoInstances name]
          (_, Just target) →
            let logical = insAdmission (targetInstances target) == AdmitLogically
                controls = PermitControl `Set.member` targetPermits target
             in [GrantNeedsAssignment name | logical, controls, Nothing <- [grantAssign granted]]
                  <> [GrantAssignsNothing name | Just _ ← [grantAssign granted], not (logical && controls)]
    duplicates =
      [ GrantDuplicateTarget name
      | (index, (_, Just target, name)) ← zip [0 ∷ Int ..] resolved
      , any (\(_, other, _) → fmap targetOwner other == Just (targetOwner target)) (take index resolved)
      ]

-- | The state of an owner's lifecycle services, empty.
newLifecycleState ∷ OwnerId → Text → ValueLimits → Maybe Instances → [Target] → LifecycleGrant → IO LifecycleState
newLifecycleState owner label limits own targets grant = do
  receipts ← newTVarIO Map.empty
  next ← newTVarIO 0
  closed ← newTVarIO False
  running ← newTVarIO Nothing
  pure
    LifecycleState
      { lifeOwner = owner
      , lifeLabel = label
      , lifeLimits = limits
      , lifeInstances = own
      , lifeTargets = targets
      , lifeReceiptBound = grantReceiptBound grant
      , lifeSnapshotBound = grantSnapshotBound grant
      , lifeReceipts = receipts
      , lifeNext = next
      , lifeTask = running
      , lifeClosed = closed
      }

-- | What the owner's configuration carries so the host delivers its lifecycle operations.
lifecycleContextOf ∷ LifecycleState → LifecycleContext
lifecycleContextOf = lifecycleContext

-- Values ----------------------------------------------------------------------------------

-- | The value a script holds for an instance.
instanceIdValue ∷ InstanceId → Value
instanceIdValue (InstanceId owner local) =
  VRecord
    [ ("runtime", VInteger (fromIntegral (runtimeNumber owner)))
    , ("owner", VInteger (fromIntegral (ownerSequence owner)))
    , ("id", VInteger (fromIntegral local))
    ]

-- | The value a script holds for an owner.
ownerRefValue ∷ OwnerId → Value
ownerRefValue owner =
  VRecord
    [ ("runtime", VInteger (fromIntegral (runtimeNumber owner)))
    , ("owner", VInteger (fromIntegral (ownerSequence owner)))
    ]

runtimeNumber ∷ OwnerId → Int
runtimeNumber (OwnerId scope _) = hashUnique scope

tidSchema ∷ Schema
tidSchema = SRecord [("runtime", SInteger), ("owner", SInteger), ("id", SInteger)]

ownerSchema ∷ Schema
ownerSchema = SRecord [("runtime", SInteger), ("owner", SInteger)]

-- | The numbers a script gave for an instance.
readTid ∷ Value → Maybe (Int, Word64, Word64)
readTid = \case
  VRecord fields
    | Just (VInteger runtime) ← lookup "runtime" fields
    , Just (VInteger owner) ← lookup "owner" fields
    , Just (VInteger local) ← lookup "id" fields →
        Just (fromIntegral runtime, fromIntegral owner, fromIntegral local)
  _ → Nothing

readOwnerRef ∷ Value → Maybe (Int, Word64)
readOwnerRef = \case
  VRecord fields
    | Just (VInteger runtime) ← lookup "runtime" fields
    , Just (VInteger owner) ← lookup "owner" fields →
        Just (fromIntegral runtime, fromIntegral owner)
  _ → Nothing

-- | The covered owner a script's numbers name, if the grant covers it. Routing is by the
-- numbers; an owner outside the grant is never found, whatever else is true of it.
covered ∷ LifecycleState → Int → Word64 → Maybe Target
covered state runtime owner =
  find (\target → runtimeNumber (targetOwner target) == runtime && ownerSequence (targetOwner target) == owner) (lifeTargets state)

-- Bindings --------------------------------------------------------------------------------

refusalSchema ∷ [(Text, Schema)]
refusalSchema = [("accepted", SBoolean), ("receipt", SOptional SInteger), ("refusal", SOptional SText)]

-- | The namespace of 'lifecycleBindings', named by the application.
lifecycleNamespace ∷ Text → Namespace
lifecycleNamespace name = namespace name lifecycleBindings

-- | The lifecycle bindings a script calls. A call from an owner with no grant is refused
-- as not yet supported and runs nothing.
lifecycleBindings ∷ [Binding]
lifecycleBindings =
  [ lifecycleOperationIn "pause" [tidSchema] [SRecord refusalSchema] (control InstancePause)
  , lifecycleOperationIn "resume" [tidSchema] [SRecord refusalSchema] (control InstanceResume)
  , lifecycleOperationIn "stop" [tidSchema] [SRecord refusalSchema] (control InstanceStop)
  , lifecycleOperationIn "result" [SInteger] [SText] result
  , lifecycleOperationIn "forget" [SInteger] [SBoolean] forget
  , lifecycleOperationIn "inspect" [tidSchema] [SRecord inspectSchema] inspect
  , lifecycleOperationIn "inspect_owner" [ownerSchema] [SRecord inspectOwnerSchema] inspectOwner
  , lifecycleOperationIn "owners" [] [SRecord [("owners", SList (SRecord ownersEntry))]] owners
  , lifecycleOperationIn "self" [] [SOptional tidSchema] self
  ]
  where
    inspectSchema = [("ok", SBoolean), ("refusal", SOptional SText), ("snapshot", SOptional snapshotSchema)]
    inspectOwnerSchema = [("ok", SBoolean), ("refusal", SOptional SText), ("instances", SList snapshotSchema), ("truncated", SBoolean)]
    ownersEntry = [("runtime", SInteger), ("owner", SInteger), ("label", SText), ("inspect", SBoolean), ("control", SBoolean)]

snapshotSchema ∷ Schema
snapshotSchema = SRecord [("tid", tidSchema), ("owner", SText), ("name", SOptional SText), ("status", SText)]

withState ∷ LifecycleContext → a → (LifecycleState → IO a) → IO a
withState context fallback run = maybe (pure fallback) run (fromLifecycleContext context)

-- | How a refusal reads to a script.
data Refusal
  = Unauthorized
  | Unknown
  | Full
  | Closed
  | Late
  | Duplicate
  | Unassigned

refusalText ∷ Refusal → Text
refusalText = \case
  Unauthorized → "unauthorized"
  Unknown → "unknown_target"
  Full → "full"
  Closed → "closed"
  Late → "late"
  Duplicate → "duplicate"
  Unassigned → "unassigned"

refused ∷ Refusal → [Value]
refused why = [VRecord [("accepted", VBoolean False), ("refusal", VText (refusalText why))]]

accepted ∷ Word64 → [Value]
accepted number = [VRecord [("accepted", VBoolean True), ("receipt", VInteger (fromIntegral number))]]

-- | A request to pause, resume or stop an instance.
control ∷ InstanceControl → LifecycleContext → [Value] → IO [Value]
control operation context arguments = withState context (refused Unauthorized) $ \state →
  case arguments of
    [tid] | Just (runtime, owner, local) ← readTid tid → case covered state runtime owner of
      Just target | PermitControl `Set.member` targetPermits target → request state target local
      _ → pure (refused Unauthorized)
    _ → pure (refused Unauthorized)
  where
    request state target local = do
      issuer ← callerOf state
      let identity = InstanceId (targetOwner target) local
          caller = case issuer of
            IssuedByInstance number → Just (InstanceId (lifeOwner state) number)
            _ → Nothing
          info = ControlRequestInfo (lifeOwner state) caller identity operation
      -- The application places a request only once the grant has passed it, and before the
      -- target is looked at: what it answers is the engine's own knowledge, never a script's.
      slot ← case targetAssign target of
        Nothing → pure (Right Nothing)
        Just assign → maybe (Left Unassigned) (Right . Just) <$> assign info
      case slot of
        Left why → pure (refused why)
        Right place → atomically $ do
          closed ← readTVar (lifeClosed state)
          held ← readTVar (lifeReceipts state)
          if closed
            then pure (refused Closed)
            else
              if Map.size held >= lifeReceiptBound state
                then pure (refused Full)
                else
                  admitControl (targetInstances target) (targetGate target) (targetOwner target) identity operation place >>= \case
                    Left answer → pure (refused (refusalOf answer))
                    Right admit →
                      admit >>= \case
                        InstanceControlAccepted receipt → do
                          number ← readTVar (lifeNext state)
                          writeTVar (lifeNext state) (number + 1)
                          writeTVar (lifeReceipts state) (Map.insert number (LuaReceipt issuer receipt) held)
                          pure (accepted number)
                        other → pure (refused (refusalOf other))
    refusalOf = \case
      InstanceControlFull → Full
      InstanceControlClosed → Closed
      InstanceControlUnknown → Unknown
      InstanceControlLate → Late
      InstanceControlDuplicate → Duplicate
      -- A grant is refused when it gives an assignment to an owner that does not admit
      -- logically, so this is never reached from a validated grant.
      InstanceControlNotLogical → Unassigned
      InstanceControlAccepted _ → Unknown

-- | Read a receipt: pending, or its settlement, which consumes it.
result ∷ LifecycleContext → [Value] → IO [Value]
result context arguments = withState context [VText "unknown_receipt"] $ \state → case arguments of
  [VInteger number] → do
    caller ← callerOf state
    atomically $ do
      held ← readTVar (lifeReceipts state)
      case Map.lookup (fromIntegral number) held of
        Just receipt | luaIssuer receipt == caller →
          observeReceipt (luaReceipt receipt) >>= \case
            Nothing → pure [VText "pending"]
            Just settled → do
              writeTVar (lifeReceipts state) (Map.delete (fromIntegral number) held)
              pure [VText (settlementText settled)]
        _ → pure [VText "unknown_receipt"]
  _ → pure [VText "unknown_receipt"]

settlementText ∷ ControlResult → Text
settlementText = \case
  ControlApplied → "applied"
  ControlAlreadyInState → "already_in_state"
  ControlNoLongerApplicable → "no_longer_applicable"

-- | Abandon interest in a receipt's result.
forget ∷ LifecycleContext → [Value] → IO [Value]
forget context arguments = withState context [VBoolean False] $ \state → case arguments of
  [VInteger number] → do
    caller ← callerOf state
    atomically $ do
      held ← readTVar (lifeReceipts state)
      case Map.lookup (fromIntegral number) held of
        Just receipt | luaIssuer receipt == caller → do
          forgetReceipt (luaReceipt receipt)
          writeTVar (lifeReceipts state) (Map.delete (fromIntegral number) held)
          pure [VBoolean True]
        _ → pure [VBoolean False]
  _ → pure [VBoolean False]

statusText ∷ InstancePhase → Text
statusText = \case
  Initializing → "initializing"
  Active → "active"
  Paused → "paused"
  Stopping → "stopping"
  Completed → "completed"
  Stopped → "stopped"
  Failed → "failed"

snapshotValue ∷ InstanceSnapshot → Value
snapshotValue snapshot =
  VRecord $
    [ ("tid", instanceIdValue (snapshotInstance snapshot))
    , ("owner", VText (snapshotOwner snapshot))
    , ("status", VText (statusText (snapshotPhase snapshot)))
    ]
      <> [("name", VText name) | Just name ← [snapshotName snapshot]]

notOk ∷ Refusal → [Value]
notOk why = [VRecord [("ok", VBoolean False), ("refusal", VText (refusalText why))]]

-- | One instance's snapshot.
inspect ∷ LifecycleContext → [Value] → IO [Value]
inspect context arguments = withState context (notOk Unauthorized) $ \state → case arguments of
  [tid] | Just (runtime, owner, local) ← readTid tid → case covered state runtime owner of
    Just target | PermitInspect `Set.member` targetPermits target → atomically $ do
      open ← gateOpen (targetGate target)
      if not open
        then pure (notOk Closed)
        else
          inspectInstance (targetInstances target) (targetGate target) (targetOwner target) (targetLabel target) (InstanceId (targetOwner target) local) >>= \case
            Nothing → pure (notOk Unknown)
            Just snapshot → pure [VRecord [("ok", VBoolean True), ("snapshot", snapshotValue snapshot)]]
    _ → pure (notOk Unauthorized)
  _ → pure (notOk Unauthorized)

-- | The instances of one covered owner, in one transaction, cut to the bounds.
inspectOwner ∷ LifecycleContext → [Value] → IO [Value]
inspectOwner context arguments = withState context (inspected Unauthorized) $ \state → case arguments of
  [reference] | Just (runtime, owner) ← readOwnerRef reference → case covered state runtime owner of
    Just target | PermitInspect `Set.member` targetPermits target → atomically $ do
      open ← gateOpen (targetGate target)
      if not open
        then pure (inspected Closed)
        else do
          snapshots ← inspectInstances (targetInstances target) (targetGate target) (targetOwner target) (targetLabel target)
          let bounded = take (lifeSnapshotBound state) snapshots
              cut = length bounded < length snapshots
          pure (fitted (lifeLimits state) cut (map snapshotValue bounded))
    _ → pure (inspected Unauthorized)
  _ → pure (inspected Unauthorized)
  where
    inspected why = case notOk why of
      [VRecord fields] → [VRecord (fields <> [("instances", VList []), ("truncated", VBoolean False)])]
      other → other

-- | The longest prefix of the snapshots that crosses the boundary within the limits, found
-- by halving: a result that would be refused is cut, and says so.
fitted ∷ ValueLimits → Bool → [Value] → [Value]
fitted limits cut snapshots = [render best (cut || best < length snapshots)]
  where
    render count truncated = VRecord [("ok", VBoolean True), ("instances", VList (take count snapshots)), ("truncated", VBoolean truncated)]
    fits count = either (const False) (const True) (checkLimits limits [render count True])
    best = search 0 (length snapshots)
    -- The largest count in [low, high] that fits, assuming fitting is monotone.
    search low high
      | low >= high = low
      | fits middle = search middle high
      | otherwise = search low (middle - 1)
      where
        middle = (low + high + 1) `div` 2

-- | The owners the grant covers.
owners ∷ LifecycleContext → [Value] → IO [Value]
owners context _ = withState context [VRecord [("owners", VList [])]] $ \state →
  pure
    [ VRecord
        [ ( "owners"
          , VList
              [ VRecord
                  [ ("runtime", VInteger (fromIntegral (runtimeNumber (targetOwner target))))
                  , ("owner", VInteger (fromIntegral (ownerSequence (targetOwner target))))
                  , ("label", VText (targetLabel target))
                  , ("inspect", VBoolean (PermitInspect `Set.member` targetPermits target))
                  , ("control", VBoolean (PermitControl `Set.member` targetPermits target))
                  ]
              | target ← take maxGrantTargets (lifeTargets state)
              ]
          )
        ]
    ]

-- | The instance whose code is calling, if one.
self ∷ LifecycleContext → [Value] → IO [Value]
self context _ = withState context [VNil] $ \state → do
  caller ← callerInstance state
  pure [maybe VNil (instanceIdValue . InstanceId (lifeOwner state)) caller]
