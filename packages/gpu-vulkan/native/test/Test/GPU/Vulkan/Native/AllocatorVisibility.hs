-- | Examples proving that no VMA type is reachable from the native backend's
-- public modules (GRS-11, D-38): VMA is confined to the package's private
-- shim module, and the allocator a client can see is the engine's own record
-- of calls over 64-bit handles.
--
-- As the recording's visibility examples do, these compile separate
-- single-module clients against this build's package database, exposing only
-- @base@ and this package's main library unit. One client must be accepted: it
-- imports every name the public allocator modules export. Every other must be
-- rejected: the private shim module and the allocation protocol are hidden
-- (@GHC-87110@), and the Hackage VMA binding the package links for its
-- compiled VMA is not a package the client can see at all.
module Test.GPU.Vulkan.Native.AllocatorVisibility (spec) where

import Control.Monad (forM_)
import Data.List (intercalate)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain, shouldNotContain)
import Test.Support.ExternalClient (Client (..), Mode (..), withStorePackageClient)

spec ∷ Spec
spec = describe "Allocator visibility across the package boundary" $ do
  it "accepts a client importing every public allocator name, none of which is VMA's" $
    withClient supportedClient $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitSuccess → pure ()
        status →
          expectationFailure
            ("the supported allocator imports did not compile (" <> show status <> "):\n" <> clientOutput outcome)

  describe "rejects a client importing a private allocator module" $
    forM_ privateModules $ \name →
      it name $
        withClient (importing name) $ \compile → do
          outcome ← compile Typecheck
          case clientStatus outcome of
            ExitFailure _ → pure ()
            ExitSuccess →
              expectationFailure ("the client compiled, so " <> name <> " is reachable:\n" <> clientOutput outcome)
          clientOutput outcome `shouldContain` "GHC-87110"
          clientOutput outcome `shouldContain` name
          clientOutput outcome `shouldContain` "hetoimasia-gpu-vulkan-native-0.1.0.0"
          clientOutput outcome `shouldNotContain` "cannot satisfy"

  it "rejects a client importing the VMA binding the package links, which is not exposed to it" $
    withClient (importing "VulkanMemoryAllocator") $ \compile → do
      outcome ← compile Typecheck
      case clientStatus outcome of
        ExitFailure _ → pure ()
        ExitSuccess → expectationFailure ("the client compiled, so VMA's binding is reachable:\n" <> clientOutput outcome)
      clientOutput outcome `shouldContain` "VulkanMemoryAllocator"

withClient ∷ String → ((Mode → IO Client) → IO ()) → IO ()
withClient = withStorePackageClient ["base", "hetoimasia-gpu-vulkan-native-0.1.0.0-inplace"] "Client.hs"

privateModules ∷ [String]
privateModules =
  [ "Hetoimasia.GPU.Vulkan.Native.Internal.Vma"
  , "Hetoimasia.GPU.Vulkan.Native.Internal.Allocation"
  ]

supportedClient ∷ String
supportedClient =
  unlines
    [ "module Client (supported) where"
    , ""
    , "import Hetoimasia.GPU.Vulkan.Native.Allocator"
    , "  ( " <> intercalate "\n  , " publicNames
    , "  )"
    , "import Hetoimasia.GPU.Vulkan.Native.Allocator.Vulkan (memoryTypeOffers, vmaAllocatorOps)"
    , ""
    , "supported = (vmaAllocatorOps, memoryTypeOffers, chooseMemoryType, usageProperties, preferredBlockSize, reservationBound, noMemoryEvents, largeHeapBlockSize, smallHeapLimit)"
    ]
  where
    publicNames =
      [ "AllocatorOps (..)"
      , "BufferRequest (..)"
      , "MemoryRequirements (..)"
      , "Placement (..)"
      , "MemoryEvents (..)"
      , "noMemoryEvents"
      , "BufferMemory (..)"
      , "MemoryProperty (..)"
      , "MemoryTypeOffer (..)"
      , "MemoryUsage (..)"
      , "usageProperties"
      , "chooseMemoryType"
      , "MemoryTypeRefused (..)"
      , "AllocatorAccountingDefect (..)"
      , "largeHeapBlockSize"
      , "smallHeapLimit"
      , "preferredBlockSize"
      , "reservationBound"
      ]

importing ∷ String → String
importing name =
  unlines
    [ "module Client () where"
    , ""
    , "import " <> name <> " ()"
    ]
