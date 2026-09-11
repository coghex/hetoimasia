# Lua host — planned

Reserved component; no HsLua dependency or implementation exists yet.

Will own VM lifetime, calls, errors, and registration mechanics. Applications
register game-specific namespaces through explicit interfaces. The VM has one
execution owner; scheduling and cross-thread communication must be specified
before adding workers. No game managers belong in this component.
