# hetoimasia-test-support

A test-only library for what more than one independently built test suite
needs. Only `test-suite` components depend on it; no library or executable
does.

- `Test.Support.ExternalClient` compiles a separate single-module client with
  the `ghc` on `PATH`, required to match the suite's own compiler, against the
  package database found by walking up from the running test executable. It
  passes `-package-env -` and `-hide-all-packages`, exposes exactly the packages
  an example names, and exposes an `-inplace` unit id with `-package-id`.
  `rejectedBecause` requires a rejection to name its intended cause and never an
  environment failure such as a missing package or module.
- `Test.Support.Bounded` bounds a call that must return, so a stuck example
  fails instead of hanging the run.

## What belongs here

A utility belongs here only when it is already used by examples that will be
owned by different suites, and it is neutral: it registers no Hspec examples,
depends on no `hetoimasia-*` package, initializes nothing native, holds no
mutable global fixture, and offers no production service API. Keep sources in
`src/` alone; no other component may list this directory in `hs-source-dirs`.

Everything else stays beside its owning suite. Domain fixtures — a logger
collector and fixed metadata, a supervision gate or trace, a native session —
are built by the suite that asserts on them through the public API of the
package under test, even when that repeats a few simple values another suite
also defines. Do not import a helper from another component's spec module, and
do not grow this library into a generic fixture framework to remove trivial
duplication.
