{-# LANGUAGE OverloadedStrings #-}

-- | How a content address becomes a module identity, and back.
--
-- The loader's identity is opaque bytes compared exactly, bounded by
-- 'Hetoimasia.Scripting.Lua.Owner.maxExportIdentityBytes'. For a module it is the root and the
-- path of its checked content key, so that two roots' same-named files are two identities and a
-- supplier asked for an identity can read the file it names without a table of its own: one byte
-- for the length of the root, the root, then the path's NFC bytes. Nothing is searched, joined or
-- normalised here; the key was checked by "Hetoimasia.Content.Identity" before it reached this.
module Hetoimasia.LuaEngine.Modules.Address
  ( moduleIdentity
  , identityKey
  , moduleLabel
  , rootText
  , pathText
  ) where

import qualified Data.ByteString as ByteString
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text.Encoding as Encoding
import qualified Data.Text.Encoding.Error as Encoding
import Hetoimasia.Content.Identity
  ( ContentKey
  , contentKeyPath
  , contentKeyRoot
  , logicalPathBytes
  , parseReference
  , rootKey
  , rootKeyBytes
  )
import Hetoimasia.Content.Inventory (Inventory, inventoryIdentityLimits, inventoryLimitsOf)
import Hetoimasia.Scripting.Lua.Owner (ExportIdentity (ExportIdentity))

-- | The identity of the module a key names: the root's length, the root and the path.
moduleIdentity ∷ ContentKey → ExportIdentity
moduleIdentity key =
  ExportIdentity (ByteString.cons (fromIntegral (ByteString.length root)) (root <> path))
  where
    root = rootKeyBytes (contentKeyRoot key)
    path = logicalPathBytes (contentKeyPath key)

-- | The key an identity names under this inventory's limits, or 'Nothing' for bytes that no
-- 'moduleIdentity' made (a root that is empty, a length that overruns, a path the grammar refuses).
identityKey ∷ Inventory → ExportIdentity → Maybe ContentKey
identityKey inventory (ExportIdentity bytes) = do
  (declared, rest) ← ByteString.uncons bytes
  let (root, path) = ByteString.splitAt (fromIntegral declared) rest
  checkedRoot ← either (const Nothing) Just (rootKey root)
  key ← either (const Nothing) Just (parseReference (inventoryIdentityLimits (inventoryLimitsOf inventory)) checkedRoot path)
  if ByteString.length root == fromIntegral declared then Just key else Nothing

-- | How the module is named in a diagnostic: its root, a colon and its path.
moduleLabel ∷ ContentKey → Text
moduleLabel key = rootText key <> ":" <> pathText key

-- | The root of a key as text, for a diagnostic.
rootText ∷ ContentKey → Text
rootText = decodeLossy . rootKeyBytes . contentKeyRoot

-- | The path of a key as text, for a diagnostic.
pathText ∷ ContentKey → Text
pathText = decodeLossy . logicalPathBytes . contentKeyPath

decodeLossy ∷ ByteString → Text
decodeLossy = Encoding.decodeUtf8With Encoding.lenientDecode
