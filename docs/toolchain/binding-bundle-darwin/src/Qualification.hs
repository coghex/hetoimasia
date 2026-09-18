-- | Enough of the binding to prove it resolved, compiled, and linked against a
-- real loader. It initializes nothing and calls no driver.
module Qualification (qualifiedStructure) where

import Vulkan.Core10 (ApplicationInfo)

-- Importing the utility module for its instances alone still makes its
-- Template Haskell run, and that is what loads the compiled binding — and
-- through it the loader — at compile time. A binding that resolves but cannot
-- find the loader fails here rather than in the first slice that uses it.
import Vulkan.Utils.Initialization ()

-- | Names a generated structure, so this module cannot compile unless the
-- binding's generated interface is really present.
qualifiedStructure ∷ Maybe ApplicationInfo
qualifiedStructure = Nothing
