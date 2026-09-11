# Validation catalog and test selection

Every validation group this repository runs is declared once, in
`tools/validation/catalog.json`. The planner at `tools/validation/plan.py`
reads that catalog, compares two revisions, and reports which groups a change
requires and why. It needs Python 3 and Git only: no GHC, no Cabal, and no
`dist-newstyle/`.

The selection policy is the one settled in
[the CI validation design](ci_validation_design.md):

```text
required work = the mandatory floor
              + affected non-optional groups
              + explicitly requested groups
```

Optional groups are never reached by affected-path selection or by conservative
fallback. An unrequested optional group is an explained omission, not a failure.

## Running the planner

```bash
python3 tools/validation/plan.py --base origin/master --head HEAD
python3 tools/validation/plan.py --base origin/master --head HEAD --json
python3 tools/validation/plan.py --catalog-check
```

| Option | Meaning |
| --- | --- |
| `--base`, `--head` | The two revisions to compare. Both are required unless `--catalog-check` is used. |
| `--request-file` | A file holding a pull-request body; its `validation-request` block is read from there. |
| `--catalog` | A catalog path read from the filesystem instead of the default. Fixture catalogs use this, with planning and with `--catalog-check` alike. |
| `--repo-root` | The repository to plan for. Defaults to the enclosing checkout. |
| `--catalog-check` | Validate the catalog and exit; takes no revisions and no request. |
| `--json` | Emit the plan as JSON rather than prose. |

Every planner run validates the catalog first and exits non-zero with a specific
diagnostic naming the offending group before producing any plan.

The catalog is read from the **head revision** when planning, so a plan never
depends on uncommitted working-tree contents. `--catalog-check` has no revision
and therefore reads the working tree. Invalid revisions and unreadable package
metadata are diagnostics, never a successful unchanged-input plan. A base
revision that predates the catalog or the package graph is supported: the plan
records `base_package_metadata: "absent"` and derives inputs from the head alone.

## Catalog schema

The catalog is a JSON object. Keys are fixed; an unknown key is an error.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Must be `1`. |
| `policy_version` | integer | The selection policy revision, recorded in every plan. |
| `policy_inputs` | array of strings | Paths whose change invalidates selection policy itself. They are treated as an input of every non-optional group, so a planner or catalog edit conservatively widens non-optional coverage without ever selecting an optional group. |
| `non_affecting_paths` | array of strings | Declared harmless classes (see below). |
| `floor` | array of strings | The mandatory floor. Every entry must name a registered, non-optional group. |
| `groups` | array of objects | The registered groups, in canonical order. |

Each group declares:

| Key | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable dotted lowercase identifier, e.g. `test.engine`. Unique. |
| `description` | string | What the group covers. |
| `command` | array of strings | The exact command, already split into arguments. |
| `component` | string or null | `null`, the reserved value `"all"`, or `"package:kind:name"` with `kind` one of `lib`, `exe`, `test`. It must resolve in the local package graph. |
| `inputs` | array of strings | Explicit non-Haskell inputs. An entry ending in `/` is a directory prefix; any other entry is an exact repository-relative path. |
| `framework` | string | `hspec` or `none`. Hspec membership is declared here, independently of `optional`, so `all-hspec` never infers it from an identifier or a command substring. |
| `runner` | string | `cpu`. |
| `timeout_seconds` | integer | Positive. |
| `category` | string | `build`, `test`, `smoke`, or `probe`. |
| `optional` | boolean | Required. An optional group runs only when explicitly requested. |

Observed durations and pass/fail history are deliberately absent: the catalog
declares what a group is, not how it has behaved.

Groups are emitted in catalog order everywhere, so catalog order is the
canonical order of a plan. `changed_paths` is sorted by path, and the request's
identifier lists are sorted.

### The registered groups

| ID | Command | Optional | In the floor |
| --- | --- | --- | --- |
| `build.all` | `cabal build all` | no | yes |
| `test.engine` | `cabal test hetoimasia-tests --test-show-details=direct` | no | yes |
| `smoke.console` | `cabal run exe:hetoimasia -- --smoke` | no | yes |
| `test.workflow` | `cabal test workflow-tests --test-show-details=direct` | no | no |

`test.workflow` runs only when affected or requested. No optional group is
registered yet; optional handling is proven with fixture catalogs in
`workflow-tests`.

## How a group's inputs are derived

A group's inputs are the union of:

- its declared `inputs`;
- for a non-optional group, the catalog's `policy_inputs`;
- the Cabal closure of its `component`: each component's `hs-source-dirs` (as
  directory prefixes), its `main-is`, the owning package's `.cabal` file, and
  `cabal.project`, followed transitively across local `build-depends` and
  `build-tool-depends`. `"all"` starts from every component of every local
  package.

The closure is derived from **both** revisions and unioned, so a source that was
removed or relocated still counts for the group that used to own it. A change to
`hetoimasia-foundation` therefore selects `test.engine` even when `test/` is
untouched, and a change to `app/Main.hs` selects it through the
`build-tool-depends: hetoimasia:hetoimasia` edge.

There is no hand-maintained module dependency list. Cabal's `extra-doc-files`
and `extra-source-files` are deliberately *not* read as code inputs: listing
prose in a package description must not invalidate compilation evidence. A
document a group genuinely consumes belongs in that group's `inputs`.

Supported Cabal syntax is bounded to what this repository uses: layout-style
stanzas, `common`/`import`, multiline fields, package-relative `hs-source-dirs`,
`main-is`, `build-depends`, and `build-tool-depends`. Conditional (`if`/`else`)
and brace-delimited syntax can change dependencies, so the planner rejects them
with a diagnostic rather than silently omitting a dependency. `cabal.project` is
read for its `packages:` field; a glob entry is rejected for the same reason.

## How a changed path is classified

Renames and deletions count both endpoints as changed. Each changed path is then:

- **consumed** — it matches at least one group's inputs. Those groups become
  affected. An explicitly consumed input outranks a non-affecting class, so a
  test-consumed Markdown file still invalidates its consumers.
- **non-affecting** — it matches a `non_affecting_paths` pattern. A pattern
  containing `/` is anchored at the repository root and its `*` does not cross a
  separator; a pattern without `/` matches any file with that basename. The
  declared classes are Markdown documentation, `.editorconfig`, `.gitignore`,
  license files, and the pull-request template (as Markdown).
- **unknown** — neither. The planner selects every non-optional group with reason
  `unknown-input` and reports the path. Unknown inputs, shared dependencies, and
  harness changes never select an optional group.

## Reasons and `inputs_changed`

Every group appears in the plan with `selected`, `inputs_changed`, and exactly
one reason from `floor`, `affected`, `requested`, `unknown-input`, `unaffected`,
and `optional-unrequested`. When several apply, the first matching rule wins:

1. an optional group that was requested — `requested`;
2. any other optional group — `optional-unrequested`;
3. a non-optional group in the floor — `floor`;
4. a non-optional group with changed inputs — `affected`;
5. a non-optional group that was requested — `requested`;
6. a non-optional group under unknown-input fallback — `unknown-input`;
7. otherwise — `unaffected`.

`inputs_changed` is independent of selection, because CI-3 consumes it to decide
whether earlier evidence still applies:

- floor membership or a request alone leaves it `false`;
- a changed relevant input makes it `true`;
- unknown-input fallback marks every non-optional group's inputs changed, so
  uncertainty can never reach a consumer as equivalence;
- an optional group still reports `true` when its own inputs changed, even
  though it stays unselected.

## Requesting groups from a pull request

A pull-request body may request extra groups in a fenced block whose info string
is `validation-request`, one catalog ID per line:

````markdown
```validation-request
test.workflow
all-hspec
```
````

`all-hspec` selects every group whose `framework` is `hspec`, including optional
ones, because that broader coverage was explicitly asked for. An unknown ID, a
malformed or unterminated block, more than one block, or an `all-hspec` request
matching no Hspec group is an error exit with a diagnostic. A request only ever
adds coverage: it can never remove the floor or an affected group.

Extracting this block from the live pull-request body is CI-2's work. The
planner reads the text from `--request-file`.

## Plan JSON

`--json` emits the plan as a stable object:

| Key | Meaning |
| --- | --- |
| `schema_version`, `policy_version` | Plan format and catalog policy revisions. |
| `catalog` | The resolved catalog source and its group count. |
| `base`, `head` | Each revision's name with its resolved `commit` and `tree`. |
| `base_package_metadata` | `present` or `absent`. |
| `request` | The request `source`, its literal `ids`, its `all_hspec` flag, and the `resolved` identifier set. |
| `changed_paths` | Each path with its Git `status`, its `classification`, and its `consumers`. |
| `unknown_inputs` | The unclassified paths, sorted. |
| `groups` | Every catalog group with `selected`, `inputs_changed`, `reason`, and its declared metadata. |
| `selected` | The selected identifiers, in catalog order. |

## Tests

`workflow-tests` runs the real planner against temporary Git repositories and
fixture catalogs. It covers transitive and build-tool dependency selection,
documentation-only changes, consumed Markdown overriding its prose class,
build-policy changes, renames and deletions, base-revision derivation, unknown
inputs and their `inputs_changed` behaviour, optional exclusion through fallback
and through a shared harness input, request validation and `all-hspec`, the
empty Hspec match, malformed and missing catalogs, unresolvable revisions, and
the explained omissions in the prose output.

Run them with `cabal test workflow-tests --test-show-details=direct`.
