# Module organization and mathematical foundations

Owner direction settled on 2026-09-26. These conventions apply to new code and
deliberate refactors. They guide cohesive ownership and dependency direction;
they do not require a repository-wide rename or invalidate already approved
work. The math package boundary below is accepted direction, not an implemented
package or a complete numerical API design.

## Organize by responsibility and dependency

Shared definitions belong at the lowest layer that can express their contract.
Higher layers may depend on them; those definitions must not depend back on
their consumers. Keep one authoritative representation and ownership ledger
when splitting a state machine. Module extraction does not create another
manager, worker or copy of the state.

Use these names as defaults within a subsystem, not as mandatory containers:

| Module | Responsibility and allowed dependencies |
| --- | --- |
| `Base` | Elementary shared types and their instances. Standard-library and third-party dependencies are normal; designated low-level local contracts, such as independent vector types, are also allowed. It does not import the subsystem's composite state or behavior. |
| `Types` | Shared composite structures built from `Base` and lower-level contracts. It does not import the subsystem's lifecycle or orchestration implementation. |
| A dedicated type module | A substantial type together with its operations, instances, validation and invariants; for example `Vector3`, `Matrix4`, `Identity` or `Budget`. This is a normal alternative to putting it in `Base` or `Types`. |
| A domain module | Cohesive operations such as scheduling, completion, disposal or geometry. Dependencies name the contracts those operations actually need. |
| A public facade | Deliberate supported exports. Implementation modules import the owning internal modules rather than their own public facade. |

Authorship does not determine the layer. An engine-authored vector can be a
foundational datatype if its dependencies are appropriately low-level. A type
being small or pure does not alone make it foundational: it may still encode
renderer or application policy. Identify any less-obvious permitted local
dependency and its rationale in the owning module or package's documentation;
ordinary choices within these boundaries need no separate approval ceremony.

Do not create empty `Base` or `Types` modules, scatter every tiny private type
into its own file, or relocate an existing cohesive type module merely for the
name. Keep validated constructors and their invariants together. Preserve
constructor privacy when definitions move: private implementation modules may
share representations without widening public access.

Owner clarification on 2026-09-26: types specific to a module belong beneath
that module's name. For `Camera.hs`, use `Camera/Base.hs` and `Camera/Types.hs`,
not a package-wide type collection. A cohesive dedicated type module such as
`Camera/Vertex.hs` is equally valid. Subcomponents may have their own nested
`Types` or `Base` modules; choose the narrowest common owner for definitions
shared by sibling subcomponents. Dedicated type modules can keep the type's
operations, instances and invariants together. Directory placement expresses
ownership, not whether Cabal exposes a module to clients.

Keep new or refactored `Base` and `Types` modules below approximately 600
physical lines, including documentation. Plan below that boundary rather than
filling it. When one grows beyond it, review the responsibilities and extract
a coherent component into its own `Types` module or a dedicated type module;
do not split into arbitrary numbered files or compress the formatting.

Prefer specific names such as `Accounting`, `Eligibility` and `Scheduling` to
growing `Common`, `Utils` or `Core` collections. Preserve distinct contracts
even where functions look similar. If behavior depends in both directions,
use explicit inputs/results, a narrow supplied operation or higher-level
composition; moving all shared code into a generic module is not a sufficient
design by itself. Refactors should establish an acyclic implementation graph
rather than conceal a new cycle through boot files.

Haskell files over 600 physical lines are refactoring candidates. A specific
issue can require a 600-line ceiling for its affected files; this convention
does not itself introduce a repository-wide build failure. Preserve readable
formatting and useful Haddocks. Explicit exports, package-private internals
and documented state ownership remain required by [AGENTS](../AGENTS.md).
Small import-boundary checks are appropriate when implementing a protected
layer; no such new checker is claimed by this document.

## An independent math package

The accepted location is `packages/math`, as the Cabal package
`hetoimasia-math` in this repository. Other engine packages and separate
projects can depend on it as a normal Haskell library. It is separate from
foundation, whose current services cover logging, failures, resources,
workers, messaging and time. This decision creates neither a new repository
nor a requirement to publish a package release now.

The math library imports **no other local package and no graphics package**.
Its modules may import each other in an acyclic graph, along with appropriate
standard-library and third-party dependencies. In particular it has no
foundation, runtime, Vulkan, GLFW, renderer or game dependency, and no
graphics initialization, ambient engine state or native graphics calls.
That boundary makes its public types suitable low-level dependencies for a
consumer's `Base` module. A consumer still declares the package dependency
explicitly; there is no universal prelude or implicit engine-wide import.

Math includes structures and algorithms as well as arithmetic. Candidate
capabilities include vectors, matrices, quaternions, coordinates and points,
linear algebra, abstract geometry and topology, set algebra, and mathematically
defined operations on sequences or other collections. A specialized 3D vector
operation remains math. A capability does not need several consumers before
it can live here when its mathematical contract and actual need are clear.
Reuse suitable standard/library operations rather than duplicating them simply
to collect every list helper under one namespace.

The contract, not the word in the type's name, determines placement:

| Capability | Owner |
| --- | --- |
| Vector and matrix operations, coordinate transforms, abstract geometric vertices and connectivity | Math |
| Pure projective transformation with explicit mathematical parameters and documented conventions | Math |
| Camera policy, viewport state, choice/adaptation of graphics API clip or depth conventions | Renderer or graphics integration |
| GPU vertex layout, shader attributes, buffer packing for a backend, graphics API matrix setters | Renderer or native backend |
| Game-specific spatial rules and domain policy | Their game or subsystem |

A rendering API's perspective/viewport operation does not belong in math.
A reusable mathematical transformation can belong there even when graphics
motivates it; the consumer selects its conventions and applies its result.
An abstract vertex is different from a record whose contract is a GPU vertex
format. Math must not import such records to reuse their coordinate fields.

Use focused modules for vectors, matrices and other structures, with small
explicit public interfaces. Do not rebuild a global `Math.hs` collection or
`UPrelude` inside the new package. Internal implementation details remain
private where appropriate; mathematical types need not all be opaque when
their contracts permit direct construction.

## Delivery and choices still to settle

The package boundary and flexible module conventions are settled. Concrete
math APIs, scalar precision, representation, coordinate/matrix conventions,
degenerate/non-finite behavior, and any storage or interoperability guarantees
still need design with the first concrete consumer. No vector implementation,
Synarchy port, numerical policy, package scaffold or new dependency is selected
by this document. Native storage adapters stay outside the math contract.

Owner sequencing decision on 2026-09-26: first refactor existing code to establish
the flexible `Base`/`Types` dependency layers, preserving cohesive dedicated
type modules. The GPU-model `State.hs` decomposition follows that foundational
refactor; it is not the first vehicle for introducing the conventions. Keep
public APIs, constructor privacy and behavior unchanged during structural moves.
The exact package scope and delivery slices still need an implementation plan.
Required implementation docs, tests and evidence belong in each refactor's own PR.

Implementation of `packages/math` is deferred. Its accepted dependency boundary
remains recorded above, but neither the `Base`/`Types` refactor nor the later
`State.hs` decomposition depends on creating the package.

Owner priority on 2026-09-26 is to settle these conventions and finish the
structural refactors before returning to the feature backlog. This policy
document does not change tracker specifications or readiness labels. Guide
coverage advances only when the merged work is actually reviewed.
