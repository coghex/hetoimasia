-- | The backend-facing view of a material reference: build one from an identity
-- and facts, and read the identity back.
--
-- __Audience.__ The backend that registers materials issues these references,
-- carrying exactly the facts the material was declared with, and a test that
-- stands in for one does the same. Game code imports
-- "Hetoimasia.Render.TwoD.Material" for the type and its readers and does not
-- import this module; a reference it could build would name a material nothing
-- registered, which the recorder refuses, naming it.
--
-- __Pure and total.__ Every identity and set of facts is a reference. Building
-- one performs no registration and starts no lifetime: what an identity means,
-- and whether a reference was issued, belong to the backend. The identity
-- 'defaultMaterialIdentity' is the built-in default's, and the backend issues no
-- other reference with it.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Material.Backend
  ( materialRef
  , materialRefIdentity
  , defaultMaterialIdentity
  ) where

import Data.Word (Word64)
import Hetoimasia.Render.TwoD.Internal.Material
  ( MaterialFacts
  , MaterialRef (..)
  , defaultMaterialIdentity
  )

-- | The reference with this identity and these facts.
materialRef ∷ Word64 → MaterialFacts → MaterialRef
materialRef = MaterialRef
