-- | The continuation type behind "Hetoimasia.Foundation.Resource"'s scoped
-- allocations, its instances, and its only runner.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Resource.Internal" re-exports
-- it for the rest of the package, so that a scoped constructor defined in
-- another foundation module can build a 'Scoped' value while the public module
-- exports the type closed. It imports no other resource module: a scope's
-- release discipline belongs to the allocators that build one, not to the
-- continuation type.
module Hetoimasia.Foundation.Resource.Scoped
  ( Scoped (..)
  , withScoped
  ) where

import Control.Monad.IO.Class (MonadIO (liftIO))

-- | A scoped allocation, composed in @do@ notation.
--
-- A 'Scoped' value is a scope that has not been entered yet: it knows how to
-- acquire something, lend it to a continuation, and release it afterwards.
-- Binding two of them nests the second scope inside the first, so an
-- allocation reads as one line of a @do@ block rather than one more level of
-- callback indentation, and the lifetimes are exactly the ones the nested
-- callbacks would have given.
--
-- The representation is closed to clients: "Hetoimasia.Foundation.Resource"
-- exports the type without its constructor, the module defining it is hidden,
-- and the continuation is not a record field, so no field label reaches a
-- client either. A client of the package cannot build a 'Scoped' from a
-- continuation of its own and cannot rewrite the continuation of one it was
-- given, because record construction and record-update syntax both need a
-- field label in scope and this type declares none. There is therefore no way
-- to resume a scope's continuation, to take a scope apart, or to install
-- cleanup for a resource acquired elsewhere; a scope is built with
-- 'allocResource', 'allocComposite', 'locally', 'pure', 'liftIO', and the
-- instances below, and it is consumed by running it with 'withScoped', the
-- only runner.
--
-- Nothing here counts entries or rejects a second one at run time. The
-- guarantee is the absence of a way to express the rewrite, checked when the
-- client is compiled.
newtype Scoped a = Scoped (∀ r. (a → IO r) → IO r)

-- | Enter the scope, run the continuation with what it allocated, and release
-- everything it allocated when that continuation returns or throws.
--
-- This is an ordinary function over the closed representation rather than a
-- field selector, so it reads a scope without also giving a client a way to
-- write one. Its name and type are unchanged by that: it is still applied to a
-- scope and a continuation, and still the only runner.
--
-- The continuation borrows the values under the borrowing rules of
-- 'withResource'. Running a scope with 'pure' as the continuation is the
-- documented misuse: it returns a handle whose cleanup has already run. Return
-- ordinary, fully evaluated results instead.
withScoped ∷ Scoped a → ∀ r. (a → IO r) → IO r
withScoped (Scoped enter) = enter

instance Functor Scoped where
  fmap change scope = Scoped (\continue → withScoped scope (continue . change))

instance Applicative Scoped where
  -- A scope that allocates nothing: the continuation runs directly, so there
  -- is no release and no masking to impose.
  pure value = Scoped (\continue → continue value)
  change <*> scope =
    Scoped $ \continue →
      withScoped change (\apply → withScoped scope (continue . apply))

instance Monad Scoped where
  -- The rest of the block runs inside the first scope, which is what makes the
  -- release point the end of the enclosing continuation rather than the end of
  -- this bind, and what unwinds the allocations of one scope in reverse.
  scope >>= rest =
    Scoped $ \continue →
      withScoped scope (\value → withScoped (rest value) continue)

instance MonadIO Scoped where
  -- An ordinary action in the middle of a block. It owns nothing, so a failure
  -- here unwinds the allocations made before it and runs no later acquisition.
  liftIO action = Scoped (\continue → action >>= continue)
