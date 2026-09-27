-- | The one component identity every messaging failure names as its origin.
--
-- __Ownership.__ The foundation's messaging modules share one component,
-- @foundation.messaging@, and this hidden module of the foundation's main
-- library is its only definition. "Hetoimasia.Foundation.Messaging.Channel"
-- names it for a rejected capacity and
-- "Hetoimasia.Foundation.Messaging.Snapshot" for a foreign cursor; both
-- re-export it, so a client that imports either module sees the same value.
--
-- __Dependencies.__ This module imports only the private component contract,
-- "Hetoimasia.Foundation.Log.Component", and nothing from either messaging
-- implementation, so neither of them imports the other for the identity.
--
-- __State.__ The module owns none.
module Hetoimasia.Foundation.Messaging.Component
  ( messagingComponent
  ) where

import Hetoimasia.Foundation.Log.Component (Component, unsafeComponent)

-- | The component every messaging failure names as its origin.
messagingComponent ∷ Component
messagingComponent = unsafeComponent "foundation.messaging"
