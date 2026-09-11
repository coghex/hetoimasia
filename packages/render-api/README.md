# Rendering API — planned

Reserved component; no Cabal library or implementation exists yet.

Will define backend-independent rendering contracts and opaque resource handles.
It must not import Vulkan, Lua, runtime state, or a concrete game. Design the
smallest contract needed by the first rendered scene before adding types here.
See [the foundation design](../../docs/engine_foundation_design.md).
