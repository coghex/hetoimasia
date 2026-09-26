-- | Examples proving that the resource family's implementation modules stay
-- inside the foundation package while its two public modules keep every name
-- they export.
--
-- "Hetoimasia.Foundation.Resource" and
-- "Hetoimasia.Foundation.Resource.Collection" re-export what clients may use
-- from modules no client can import: four hidden modules of the package's
-- private @internal@ sublibrary behind the package-private facade
-- "Hetoimasia.Foundation.Resource.Internal", and one hidden module of the main
-- library. An example in this suite cannot observe that boundary, so these
-- examples compile separate single-module clients with the harness from
-- "Test.Support.ExternalClient", exposing @base@, @text@, and
-- @hetoimasia-foundation@ and hiding everything else, as the resource opacity
-- examples do.
--
-- One client must be accepted: it imports, by name, every name the two public
-- modules export, with exactly the constructors each exports. Every other
-- client must be rejected with @GHC-87110@ against the unit that holds the
-- module it imported, which tells a hidden module apart from a missing module
-- or an unresolvable package.
module Test.Foundation.Resources.Visibility (spec) where

import Control.Monad (forM_)
import Data.IORef (newIORef, readIORef, writeIORef)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec
  ( Spec
  , describe
  , expectationFailure
  , it
  , shouldContain
  , shouldNotContain
  )
import Test.Support.ExternalClient (Client (..), Mode (..), withPackageClient)

spec ∷ Spec
spec = describe "Resource module visibility across the package boundary" $ do
  it "accepts a client that imports every public resource and collection name" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ( "the supported client must compile, but the compiler exited with "
                <> show status
                <> ":\n"
                <> clientOutput outcome
            )

  forM_ privateModules $ \hidden →
    it ("rejects a client that imports the private module " <> hidden) $ do
      output ← refusedAsHidden hidden
      output `shouldContain` "hetoimasia-foundation-0.1.0.0:internal"

  it ("rejects a client that imports the hidden module " <> collectionTypes) $ do
    output ← refusedAsHidden collectionTypes
    -- The main library's unit, which the private sublibrary's name extends.
    output `shouldContain` "hetoimasia-foundation-0.1.0.0"
    output `shouldNotContain` "hetoimasia-foundation-0.1.0.0:internal"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withPackageClient ["base", "text", "hetoimasia-foundation"] "Client.hs"

-- | Compile a client importing @hidden@, require the compiler to have found it
-- and refused it as hidden, and return what the compiler said so the caller
-- can check which unit it was found in.
refusedAsHidden ∷ String → IO String
refusedAsHidden hidden = do
  said ← newIORef ""
  withClient (importClient hidden) $ \compile → do
    outcome ← compile Typecheck
    case clientStatus outcome of
      ExitFailure _ → pure ()
      ExitSuccess →
        expectationFailure ("the client compiled, so " <> hidden <> " is reachable:\n" <> clientOutput outcome)
    clientOutput outcome `shouldContain` "GHC-87110"
    clientOutput outcome `shouldNotContain` "cannot satisfy"
    clientOutput outcome `shouldNotContain` "Could not find module"
    writeIORef said (clientOutput outcome)
  readIORef said

-- | The resource modules hidden inside the private sublibrary, behind its
-- facade.
privateModules ∷ [String]
privateModules =
  [ "Hetoimasia.Foundation.Resource.Types"
  , "Hetoimasia.Foundation.Resource.Scoped"
  , "Hetoimasia.Foundation.Resource.Cleanup"
  , "Hetoimasia.Foundation.Resource.Assembly"
  ]

-- | The collection representations, hidden in the main library.
collectionTypes ∷ String
collectionTypes = "Hetoimasia.Foundation.Resource.Collection.Types"

importClient ∷ String → String
importClient hidden = unlines ["module Client () where", "", "import " <> hidden]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client () where"
    , ""
    , "import Hetoimasia.Foundation.Resource"
    , "  ( withResource"
    , "  , withResourceLabelled"
    , "  , withComposite"
    , "  , Assembly"
    , "  , acquirePart"
    , "  , restoredStep"
    , "  , ReleaseRank"
    , "  , releaseRank"
    , "  , Scoped"
    , "  , withScoped"
    , "  , allocResource"
    , "  , allocComposite"
    , "  , locally"
    , "  , CleanupFailure"
    , "  , cleanupFailureId"
    , "  , cleanupFailureLabel"
    , "  , cleanupFailureException"
    , "  , CleanupFailureId"
    , "  , displayCleanupFailure"
    , "  , cleanupFailures"
    , "  , cleanupFailuresInContext"
    , "  )"
    , "import Hetoimasia.Foundation.Resource.Collection"
    , "  ( Collection"
    , "  , allocCollection"
    , "  , liveMemberCount"
    , "  , Member"
    , "  , acquireMember"
    , "  , acquireMemberThen"
    , "  , withMember"
    , "  , retireMember"
    , "  , Retirement (Retired, AlreadyRetired, RetirementInUse)"
    , "  , memberStatus"
    , "  , MemberStatus (MemberLive, MemberRetired, MemberRetirementFailed)"
    , "  , CollectionError"
    , "      ( InvalidMemberLimit"
    , "      , NotOwnerThread"
    , "      , ForeignMember"
    , "      , CollectionReentered"
    , "      , CollectionClosed"
    , "      , MemberLimitReached"
    , "      , CollectionPoisoned"
    , "      , MemberNotLive"
    , "      )"
    , "  , Activity (Acquiring, Borrowing, Retiring, Closing)"
    , "  )"
    ]
