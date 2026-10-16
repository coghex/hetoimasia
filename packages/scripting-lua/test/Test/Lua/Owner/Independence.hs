-- | Any number of independent owners (D-15).
--
-- Ten owners are live at once, each on a thread of its own and each over its own
-- VM, created together and closed in a scrambled order. One owner fails, one is
-- cancelled and one is closed with a failing finalizer, and every other owner is
-- checked from inside its own VM, before and after: its globals are its own and
-- none of the others', it still answers, and it ends with no failure and no
-- evidence. Closing, failing or cancelling one owner leaves the rest exactly as
-- they were.
--
-- Every wait is on an @MVar@ the example controls, so the order the owners end
-- in is the order written here and not an accident of scheduling.
module Test.Lua.Owner.Independence (spec) where

import Control.Concurrent (ThreadId, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (UserInterrupt), annotateIO, throwIO)
import Control.Monad (forM, forM_)
import Data.ByteString (ByteString)
import Data.List (nub)
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Scripting.Lua.Bridge (Library (LibraryBase), chunkName)
import Hetoimasia.Scripting.Lua.Internal.Callback (installCallback)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerAfterLibraries, ownerAllowlist, ownerChunks)
  , defaultOwnerConfig
  , evalOwned
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Owner.Support
import Test.Lua.Support (Recorder, newRecorder, recorded, recordingCallback)
import Test.Support.Bounded (bounded)

-- | How an owner is made to end.
data Role
  = -- | Its body fails.
    Fails
  | -- | It is cancelled while its body waits.
    Cancelled
  | -- | Its close fails in a finalizer's callback.
    FailingFinalizer
  | -- | It ends normally.
    Normal
  deriving (Eq, Show)

-- | One owner of the ten: what it is, what it checked, and how to reach it.
data Member = Member
  { memberRole ∷ !Role
  , memberChecks ∷ !Recorder
  , memberReady ∷ !(MVar ())
  , memberGo ∷ !(MVar ())
  , memberThread ∷ !ThreadId
  , memberOutcome ∷ !(MVar (Outcome ()))
  }

owners ∷ Int
owners = 10

roleOf ∷ Int → Role
roleOf = \case
  0 → Fails
  1 → Cancelled
  2 → FailingFinalizer
  _ → Normal

-- | The order the owners end in: not the order they were made in, and with the
-- failing, cancelled and failing-finalizer owners among the others.
endingOrder ∷ [Int]
endingOrder = [6, 0, 4, 1, 9, 2, 8, 3, 7, 5]

-- | The chunk that makes a VM this owner's: its own marker, and a @check@ that
-- reports from inside the VM whether that is so, and whether any other owner's
-- marker is present.
identityChunk ∷ Int → ByteString
identityChunk index =
  Text.encodeUtf8 . Text.pack . unlines $
    [ "owner_value = " <> show index
    , "only_in_" <> show index <> " = true"
    , "function check()"
    , "  if owner_value ~= " <> show index <> " or only_in_" <> show index <> " ~= true then bad() return end"
    , "  for other = 0, " <> show (owners - 1) <> " do"
    , "    if other ~= " <> show index <> " and _G['only_in_' .. other] ~= nil then bad() return end"
    , "  end"
    , "  ok()"
    , "end"
    ]

-- | The owner's configuration: the checks it reports to, a callback its close
-- can fail in, and a guard that calls it when the owner is the failing one.
configFor ∷ Int → Recorder → OwnerConfig
configFor index checks =
  (defaultOwnerConfig [LibraryBase])
    { ownerAllowlist = Set.fromList ["boom"]
    , ownerAfterLibraries = \vm → do
        recordingCallback vm checks "ok"
        recordingCallback vm checks "bad"
        installCallback
          vm
          "boom"
          (annotateIO (Marker (show index)) (throwIO (CloseBroke ("owner " <> show index))))
          (pure ())
    , ownerChunks =
        [(chunkName "identity", identityChunk index)]
          <> [ (chunkName "guard", "guard = setmetatable({}, {__gc = function() boom() end})")
             | roleOf index == FailingFinalizer
             ]
    }

startMember ∷ Int → IO Member
startMember index = do
  checks ← newRecorder
  ready ← newEmptyMVar
  go ← newEmptyMVar
  (thread, outcome) ← ownerThread (configFor index checks) $ \owned → do
    evalOwned owned (chunkName "before") "check()"
    putMVar ready ()
    takeMVar go
    evalOwned owned (chunkName "after") "check()"
    case roleOf index of
      Fails → throwIO (BodyBroke ("owner " <> show index))
      _ → pure ()
  pure (Member (roleOf index) checks ready go thread outcome)

-- | End one owner the way its role says, and wait for it to finish.
end ∷ Member → IO (Outcome ())
end member = do
  case memberRole member of
    Cancelled → throwTo (memberThread member) UserInterrupt
    _ → putMVar (memberGo member) ()
  bounded (takeMVar (memberOutcome member))

spec ∷ Spec
spec = describe "any number of independent owners" $
  it "keeps every owner's state and evidence unchanged while the others close, fail, are cancelled or close with a failing finalizer" $ do
    members ← forM [0 .. owners - 1] startMember
    -- All ten are live at once, on ten threads, each having checked its own VM.
    forM_ members (bounded . takeMVar . memberReady)
    length (nub (map memberThread members)) `shouldBe` owners
    forM_ endingOrder $ \index → do
      let member = members !! index
      outcome ← end member
      checked ← recorded (memberChecks member)
      case (memberRole member, outcome) of
        (Normal, Right ()) → checked `shouldBe` ["ok", "ok"]
        (Normal, Left failure) → expectationFailure ("owner " <> show index <> " failed: " <> show (causeOf failure ∷ Maybe BodyBroke))
        (Fails, Left failure) → do
          causeOf failure `shouldBe` Just (BodyBroke "owner 0")
          evidenceLabels failure `shouldBe` []
          checked `shouldBe` ["ok", "ok"]
        (Cancelled, Left failure) → do
          causeOf failure `shouldBe` Just UserInterrupt
          asyncCancellation failure `shouldBe` True
          evidenceLabels failure `shouldBe` []
          -- It never left its first check.
          checked `shouldBe` ["ok"]
        (FailingFinalizer, Left failure) → do
          causeOf failure `shouldBe` Just (CloseBroke "owner 2")
          evidenceLabels failure `shouldBe` ["lua finalizer"]
          evidenceMarkers failure `shouldBe` [["2"]]
          checked `shouldBe` ["ok", "ok"]
        (role, Right ()) → expectationFailure ("owner " <> show index <> " (" <> show role <> ") ended without its failure")
