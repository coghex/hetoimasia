-- | The multi-capability pass's setting and guard, which live in "Test.Support.Capabilities" (@hetoimasia-test-support@) because
-- more than one suite runs such a pass; re-exported under this suite's name so its modules keep their imports.
module Test.TerrainRuntime.Capabilities (module Test.Support.Capabilities) where

import Test.Support.Capabilities
