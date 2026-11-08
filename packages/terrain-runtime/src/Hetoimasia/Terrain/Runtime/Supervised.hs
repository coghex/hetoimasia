-- | The application's supervision of the terrain owner.
--
-- 'supervisedOwner' builds the 'Supervisor' the service starts its owner with,
-- from the runtime control the application thread holds. The control is used
-- only on the application thread, to start the owner; the owner worker itself
-- never receives it.
module Hetoimasia.Terrain.Runtime.Supervised
  ( supervisedOwner
  ) where

import Control.Exception (throwIO)
import Hetoimasia.Terrain.Runtime.Internal.Owner (terrainComponent)
import Hetoimasia.Terrain.Runtime.Internal.Types (Supervisor (..))
import Hetoimasia.Runtime.Supervision

-- | Start the owner as a required service of the supervised group: its failure
-- is fatal, and so is an unexpected exit.
supervisedOwner ∷ RuntimeControl → Supervisor
supervisedOwner control = Supervisor $ \definition →
  startSupervised
    control
    WorkerPolicy
      { policyRole = Service
      , policyDisposition = Required
      , policyComponent = terrainComponent
      , policyClassifier = \_ → pure Unrecognized
      }
    definition
    >>= \case
      WorkerStarted _ → pure ()
      WorkerStartUnavailable _ failure → throwIO failure
      WorkerStartRejected → ioError (userError "the supervised boundary closed before the terrain owner started")
