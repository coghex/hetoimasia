-- | The runtime suite, composed from its component specs.
--
-- The thin runner, the application lifecycle, the logging lifetime, the
-- recovery and terminal-failure reporting adapter, worker supervision, the
-- supervised inbox adapter and its graceful finish, the supervised and inbox
-- handles' package boundaries, supervised waits on the foundation's channels
-- and snapshots, the resource smoke, and the update policy sit under the @Runtime@ group this
-- module roots, so the paths and @--match@ selectors these examples carried in
-- the root suite still select them here. A new example belongs in the
-- component that owns the behaviour it asserts; this module only composes.
--
-- The console executable's startup and exit examples launch the built
-- executable, so they stay in the root suite's @Console@ group.
module Test.Runtime.Spec (spec) where

import qualified Test.Runtime.Application as Application
import qualified Test.Runtime.Composition as Composition
import qualified Test.Runtime.Inbox as Inbox
import qualified Test.Runtime.InboxFinish as InboxFinish
import qualified Test.Runtime.Lifetime as Lifetime
import qualified Test.Runtime.Messaging as Messaging
import qualified Test.Runtime.Opacity as Opacity
import qualified Test.Runtime.Reporting as Reporting
import qualified Test.Runtime.ResourceSmoke as ResourceSmoke
import qualified Test.Runtime.Supervision as Supervision
import qualified Test.Runtime.UpdatePolicy as UpdatePolicy
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Runtime" $ do
  Application.spec
  Composition.spec
  Inbox.spec
  InboxFinish.spec
  Lifetime.spec
  Opacity.spec
  Reporting.spec
  Supervision.spec
  Messaging.spec
  ResourceSmoke.spec
  UpdatePolicy.spec
