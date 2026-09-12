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
| `--candidate` | The integration revision the workers execute. Defaults to the head; CI supplies the commit GitHub resolved for the event, which on a pull request is neither endpoint. |
| `--toolchain NAME=VERSION` | A pinned toolchain version the candidate's identity covers. Repeatable. |
| `--runner-os` | The operating system the workers execute on. Defaults to `RUNNER_OS`, then this machine's. |
| `--request-file` | A file holding a pull-request body; its `validation-request` block is read from there. |
| `--catalog` | A catalog path read from the filesystem instead of the default. Fixture catalogs use this, with planning and with `--catalog-check` alike. |
| `--repo-root` | The repository to plan for. Defaults to the enclosing checkout. |
| `--catalog-check` | Validate the catalog and exit; takes no revisions and no request. |
| `--json` | Emit the plan as JSON rather than prose. |

`tools/validation/range.py` resolves the two revisions CI passes to `--base` and
`--head`; see [Running validation on GitHub](#running-validation-on-github).

Every planner run validates the catalog first and exits non-zero with a specific
diagnostic naming the offending group before producing any plan.

The catalog is read from the **head revision** when planning, so a plan never
depends on uncommitted working-tree contents. `--catalog-check` has no revision
and therefore reads the working tree. Invalid revisions and unreadable package
metadata are diagnostics, never a successful unchanged-input plan. A base
revision that predates the catalog or the package graph is supported: the plan
records `base_package_metadata` and `base_catalog` as `"absent"` and derives
inputs from the head alone. A base catalog that exists but cannot be read is a
diagnostic rather than a silent omission, and every file the planner reads is
decoded as strict UTF-8: metadata that would have to be repaired to parse is
reported, never quietly accepted.

## Catalog schema

The catalog is a JSON object. Keys are fixed; an unknown key is an error, and
every key below is required except where the table says otherwise.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Must be `1`. The catalog's schema is versioned separately from the plan's. |
| `policy_version` | integer | The selection policy revision a person reads, recorded in every plan as `catalog_policy_version`. The plan's own `policy_version` is the digest reuse compares. |
| `policy_inputs` | array of strings | Paths whose change invalidates selection policy itself. They are an input of *every* group, so a planner, catalog, runner, aggregate, or workflow edit widens non-optional coverage conservatively and still marks an optional group's inputs changed when its own definition moved — without ever selecting an optional group, since selection reaches those only through a request. |
| `non_affecting_paths` | array of strings | Declared harmless classes (see below). |
| `generated_paths` | array of strings, optional | Paths a run leaves in a checkout that no execution reads as input: build trees, a run's own plan, applicability document, and receipts, interpreter and editor debris. The [runner's provenance check](#execution-provenance) exempts these and nothing else when deciding whether a checkout is still its candidate; nothing else consults them, so they classify no committed path and can never excuse one. An entry ending in `/` is a directory prefix, an entry with `*` is a class matched the way `non_affecting_paths` are, and any other entry is an exact path. A declaration never outranks an input: a path some group consumes, or that packaging makes an input, is classified normally however it is declared here. Omitting the key exempts nothing. |
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

The registered policy inputs are `tools/validation/` and `.github/workflows/` —
every validation script, the catalog, and every workflow. All of them decide
what a result *means* rather than what a group tests, so a change to any of them
has to reach every group. They are declared as directory prefixes rather than as
a list of filenames deliberately: a new script added to the validation tools is
policy from the moment it exists, and a list would have to be remembered.
Classifying the workflows here is also what keeps a CI edit from arriving as an
*unknown* path: the conservative coverage is the same either way, but an
explained widening is auditable and an unclassified one is only a warning.

The same two prefixes are what [the policy identity](#candidate-identity)
digests, so a classification change never lets a candidate inherit evidence
gathered under the policy it replaced.

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

- its declared `inputs`, unioned with the inputs the same group declared in the
  base revision's catalog;
- the catalog's `policy_inputs`, from both revisions;
- the Cabal closure of its `component`: each component's `hs-source-dirs` (as
  directory prefixes), its `main-is`, the owning package's `.cabal` file, and
  `cabal.project`, followed transitively across local `build-depends` and
  `build-tool-depends`. `"all"` starts from every component of every local
  package.

The closure is derived from **both** revisions and unioned, so a source that was
removed or relocated — or an input a group has since stopped declaring — still
counts for the group that used to own it. A change to
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

`inputs_changed` is independent of selection, and describes the *contribution*:
which groups this change touches relative to the base it is compared against. It
is deliberately **not** what decides whether earlier evidence applies — a code
pull request followed by a prose-only push reports its code as changed against
the merge base while its tree is the one an earlier run already validated. That
question is answered by [candidate identity](#candidate-identity) instead.

- floor membership or a request alone leaves it `false`;
- a changed relevant input makes it `true`;
- unknown-input fallback marks every non-optional group's inputs changed, so
  uncertainty can never reach a consumer as equivalence;
- an optional group still reports `true` when its own inputs changed or its own
  catalog definition moved, even though it stays unselected.

## Candidate identity

Selection answers *what does this contribution touch?* from a two-endpoint diff.
Reuse asks a different question — *is this candidate's content the same content
an earlier execution already proved?* — and a diff cannot answer it. A code pull
request followed by a prose-only push still contains code changes relative to
its merge base while its tree is byte-identical to the one the previous run
validated. So every plan carries two digests taken from the **candidate tree
itself**, without looking at either endpoint:

| Field | What it covers |
| --- | --- |
| `policy_version` | Every path matching the catalog's `policy_inputs` **unioned with `tools/validation/` and `.github/workflows/`**, plus the catalog's schema and declared revision. |
| `input_identity` | Every included path's name, file mode, Git object type, and object id, plus the pinned toolchain and `policy_version`. |

Those two roots are required rather than merely declared. `policy_inputs` is
catalog data and the catalog is one of the files it governs, so a candidate that
dropped them from its own catalog would otherwise rewrite the scripts deciding
what a result means while leaving both digests — and therefore the evidence it
may inherit — unmoved. Declaring more still widens the policy; declaring less
cannot narrow it. The same union is what a group's inputs are checked against
when deciding harmless prose.

The candidate is the tree the workers execute, not the pull request's head. On a
pull request those differ: CI passes the commit GitHub resolved for the event,
so an upstream change merged into the integration candidate reaches the identity
even though the contribution is prose. Locally, `--candidate` defaults to the
head and there is nothing to distinguish.

Commit metadata is deliberately absent. An execution reads a tree, not an author
or a timestamp, so two commits with identical trees are the same candidate. File
modes and object types are present for the opposite reason: a file that becomes
executable, or a path that becomes a submodule, changes what an execution sees
while its content digest stays put. The tree is read NUL-safe, so a path
containing a newline or a quote cannot be silently truncated out of the digest.

### Harmless prose

A path is excluded from `input_identity` only when it is prose no execution
reads. That is exactly:

- Markdown that **no** group declares as an input, and
- the `non_affecting_paths` classes the catalog already declares.

A declared input outranks both, so a test-consumed Markdown file, a fixture, a
shader, Lua, or an asset is never harmless. Neither is `cabal.project` or any
`.cabal` file, which are refused as prose independently of how a catalog
classifies them: packaging decides what is compiled.

The group inputs this rule consults are derived from the **candidate tree
alone**, unlike selection, which unions both revisions so a retired input still
counts for the group that owned it. A fingerprint that depended on the base
would differ between two runs over the very same tree, which is precisely the
equivalence reuse exists to recognize.

The consequence the acceptance criteria name: editing, renaming, or deleting
harmless prose leaves `input_identity` unchanged, while a source, package
description, project file, fixture, consumed document, file mode, catalog, or
workflow change moves it.

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

Fence nesting is honoured, so an example shown inside an outer fenced block — as
in this document — is documentation rather than a live request. The info string
must be the bare word `validation-request`; a fence that starts with that word
and carries anything else is reported as malformed instead of being ignored.

Extracting this block from the live pull-request body is CI-2's work. The
planner reads the text from `--request-file`.

## Plan JSON

`--json` emits the plan as a stable object:

| Key | Meaning |
| --- | --- |
| `schema_version` | The plan format's revision. |
| `policy_version` | The policy identity digest. |
| `catalog_policy_version` | The catalog's declared policy revision, as an integer. |
| `input_identity` | The candidate's input identity digest. |
| `toolchain`, `runner_os` | The pinned platform the identity covers and a reusable receipt must match. |
| `catalog` | The resolved catalog `source` and its group count, plus the classification the runner must reproduce: `override` — the `--catalog` path when a fixture supplied one, `null` otherwise — and `candidate_digest`, a digest of the candidate's catalog document, which binds its contents rather than only its path. |
| `base`, `head`, `candidate` | Each revision's name with its resolved `commit` and `tree`. |
| `base_package_metadata` | `present` or `absent`. |
| `base_catalog` | `present`, `absent`, or `not-applicable` when `--catalog` overrode it. |
| `request` | The request `source`, its literal `ids`, its `all_hspec` flag, and the `resolved` identifier set. |
| `changed_paths` | Each path with its Git `status`, its `classification`, and its `consumers`. |
| `unknown_inputs` | The unclassified paths, sorted. |
| `groups` | Every catalog group with `selected`, `inputs_changed`, `reason`, and its declared metadata. |
| `selected` | The selected identifiers, in catalog order. |

## Running validation on GitHub

`.github/workflows/validation.yml` runs on every `pull_request` that is opened,
reopened, synchronized, or **edited** — the request block lives in the body, so
changing which groups are asked for has to re-plan even though no commit
moved — and on every push to `master`. Its concurrency group is per pull
request and deliberately never cancels: a prose edit must not destroy a code run
that is still the newest useful execution. Freshness is enforced by comparing
the plan against the pull request's current state, not by throwing work away.

The workflow's default permission is `contents: read`, and no job uses a secret.
The `plan` job adds `actions: read` so it can look up an earlier run's receipt
artifacts, and `build-test` already held it for the timings.

The pinned platform is declared once, as workflow-level `env`: the planner folds
those exact values into the candidate's input identity and the workers install
them, so evidence can never be reused across a toolchain the candidate was not
planned for.

### `plan`

The first job needs Python 3 and Git alone — no GHC, no Cabal — so a
documentation candidate never pays for a Haskell image to learn it needs one
job. It times out in five minutes, checks out full history, and resolves the
comparison range through `tools/validation/range.py`:

| Event | Base | Head |
| --- | --- | --- |
| `pull_request` | `git merge-base <base sha> <head sha>` | the pull request's head |
| `push` | the event's own `before` commit | the pushed commit |

The two events ask different questions, and the difference is not cosmetic. A
pull request contributes a merge-base range: upstream commits its branch never
touched are not its work, so comparing against the fork point isolates what it
proposes. A push contributes exactly what it moved the branch by, which is the
range the event names.

The merge base of a push's two endpoints is **not** a conservative stand-in for
that range. When a push replaces history rather than extending it, the common
ancestor can be older than the work being dropped, and a diff taken from there
does not contain the removal at all: a push that reverts a source file by
resetting onto its ancestor would look like whatever else the new tip happens to
add, and the group consuming that source would be reported `unaffected`. So
`before` is used as the event gives it, and a `before` that is absent or
unresolvable — a new branch, or history no longer reachable — is a diagnostic
that fails the job rather than a range guessed from something else.

The pull-request body reaches the planner through a file written from the event
payload's environment variable, never through shell interpolation: it is
contributor-authored text, and the planner's grammar is the only thing that may
interpret it. A push carries no body and therefore no request.

The job then runs [the reuse lookup](#reusing-an-earlier-execution), which needs
the `actions: read` permission and nothing else, and uploads `plan.json` and
`applicability.json` together as one artifact. It publishes the selected group
IDs, the groups that still have to execute, the candidate's input identity, and
one boolean per worker as job outputs. A planner error fails the job with the
planner's own diagnostic; a reuse lookup that fails does not fail the job, it
publishes an applicability document that reuses nothing.

### Workers

Two workers run in parallel, each with a 45-minute timeout, each pinned to
GHC 9.12.2 and Cabal 3.16.1.0, and each **skipped entirely** when the plan
selected none of the groups it owns:

| Job | Groups, in order |
| --- | --- |
| `haskell-engine` | `build.all`, `test.engine`, `smoke.console` |
| `haskell-workflow` | `test.workflow` |

A worker runs every group it still has to execute and continues past a failure,
so the aggregate sees a receipt for each of them rather than inferring the rest
from the first one that failed. It uploads its receipts whatever happened, then
fails if any of its groups failed. A group the plan selected but an earlier
execution already covers is announced as reused rather than as unselected: those
are different facts and the log must not conflate them. A worker every one of
whose groups is covered is skipped as a job.

Each receipt is also uploaded on its own, named
`receipt-<group-id>-<input-identity>`, on pull-request runs and `master` pushes
alike. That is the evidence a later candidate looks up: the identity is in the
name so a lookup asks for evidence about *these* inputs rather than fetching
every receipt a group ever produced and filtering afterwards.

Selection uses the merge-base range, but every job executes one integration
candidate — the commit GitHub resolved for the event. Each worker asserts that
it checked that exact commit out, so two jobs can never report on two trees.

Three caches are restored, all keyed on inputs a Markdown edit cannot change:

| Cache | Key |
| --- | --- |
| `~/.ghcup` | the GHC and Cabal versions |
| the Cabal package store | `cabal.project` (which pins `index-state`) and every `.cabal` file |
| `dist-newstyle` | those, plus every Haskell source, with a restore-keys fallback |

A cache miss costs time and can never change a result.

### Receipts

`tools/validation/run.py` executes one group and writes `<group-id>.json` into
its receipts directory. The resolved plan is its only authority:

```bash
python3 tools/validation/run.py <group-id> --plan plan.json --receipts <dir>
```

| Option | Meaning |
| --- | --- |
| `--plan` | The resolved plan this execution belongs to. Required: a group's command, its timeout, and the plan identity its receipt must name all come from here, so a runner never infers a request-dependent selection from an ID and a checkout. |
| `--receipts` | The directory the receipt is written to. |
| `--repo-root` | The checkout to execute in. Defaults to the working directory. |
| `--toolchain NAME=VERSION` | A toolchain version to record. Repeatable; the runner always records its own Python version. |

There is **no option that sets the executed revision**. The runner reads it from
the checkout and refuses to run at all unless that checkout is the plan's
candidate; see [Execution provenance](#execution-provenance) below.

Fixture catalogs reach the runner through the plan: resolve one with
`plan.py --catalog <fixture>`, then run against that plan. A group the plan
explained away is refused rather than executed, and leaves no receipt.

The receipt records the group, the exact command, the outcome, the exit status,
start and end timestamps, the duration, the declared timeout, the plan identity,
the candidate's input identity and policy identity, the pull request's head
commit, the commit and tree that actually executed, the runner's OS and
architecture, the toolchain versions, and the run it can be read back from. The
head and the executed revision are recorded separately because a pull request is
validated on an integration candidate that is neither endpoint; a receipt must
not imply that the head itself ran.

#### Execution provenance

A receipt names the plan's identity and copies the candidate's input identity,
so the tree that executed has to *be* the candidate. Before anything runs, the
runner checks three things against `plan.candidate` and refuses with exit `2`,
leaving no receipt, when any of them does not hold:

| Check | Why it is a refusal |
| --- | --- |
| `HEAD` is the candidate commit | A receipt records the commit it read. Two commits can share a tree, and an execution of the later one would misdescribe what was validated even where the bytes agreed — so the commit is compared, not only the tree. |
| `HEAD`'s tree is the candidate's tree | The digests the receipt carries are of that tree. |
| No uncommitted change to a relevant input | A working tree the candidate does not contain is not that candidate, whatever `HEAD` says. |

The comparison is against the **candidate**, not the head. A plan resolved with
a `--candidate` that differs from its head still runs from a checkout of that
candidate, and its receipt keeps `head_commit` and `executed_commit` distinct.

Relevance for the third check is **the classification that produced the plan**,
never the working tree's: the candidate commit's package graph, and the catalog
that plan was resolved with — the fixture when `--catalog` supplied one, and the
candidate's own otherwise. An edit must not be able to reclassify itself as
prose on the way past, and a rewritten catalog in the working tree is exactly
the change this notices. The plan records which catalog it used **and what that
catalog said**, so a fixture plan is judged by its fixture's rules rather than
by the candidate's default catalog — and naming the path is not enough on its
own, because a fixture lives on the mutable filesystem and could be rewritten
between planning and execution into one that stops consuming the very path an
edit is about. The runner digests the catalog it reads and refuses a document
that no longer matches the plan's `catalog.candidate_digest`: a classification
the plan was not built from cannot say what a checkout holds.

Staged and unstaged changes are both asked about, because neither implies the
other — a mode change can live only in the index — and additions, deletions,
renames, and mode changes all count. The diagnostic names the paths.

Tracked and added paths are held to the **same** conservative rule: a path is
relevant unless it is [harmless prose](#harmless-prose), the complement
`input_identity` covers. A Markdown file some group declares as an input, a
mandatory policy input, `cabal.project`, or any `.cabal` file is relevant
however it is spelled — and so is a file no group declares at all. A
`cabal.project.local` is the case that makes the point: nothing declares it, and
every Cabal command reads it, so a checkout carrying one is running under flags
the candidate does not describe.

The single exemption is what the candidate's catalog declares in
`generated_paths`: paths a run leaves behind that no execution reads as input —
build trees, a run's own plan, applicability document, and receipts, and
interpreter and editor debris. Entries say what they look like: a trailing `/`
is a directory prefix, an entry containing `*` is one of the basename classes
`non_affecting_paths` already uses, and anything else is an exact
repository-relative path. The field is optional and a catalog that declares none
exempts nothing.

**A declaration never outranks an input.** A path some group consumes, or that
packaging makes an input whatever a catalog says, is answered for by the
ordinary classification even where a `generated_paths` entry would have matched
it. Declaring `plan.json` exempts the plan a run is handed at the repository
root; it does not exempt a `tools/validation/plan.json` inside a mandatory
policy root, and `*.pyc` does not exempt a `__pycache__` there either. The
exemption is for a run's own output, not a way to write into what a group reads.

That declaration is deliberately **catalog data rather than an ignore rule**. No
ignore rule is consulted at all — not the repository's `.gitignore`, not
`.git/info/exclude`, not a machine's global excludes. Any of them could hide a
newly added source, consumed document, or package description from the question
entirely, and two of the three are not part of the candidate. `generated_paths`
lives in the catalog, which sits under a mandatory policy root, so widening it
moves the policy identity and is reviewed alongside the change that widened it.
The repository still ignores the validation artifacts in `.gitignore`, but only
to keep `git status` legible; that grants them nothing here.

For the same reason the validation tools set `sys.dont_write_bytecode`: a
`__pycache__` left beside them sits inside a declared policy input, and a tool
must not create the very file the runner would refuse.

**Nor is the checkout's own index, attributes, or configuration trusted.** A
repository can be told to stop noticing a file (`git update-index
--assume-unchanged`), to stop noticing modes (`core.fileMode=false`), to rewrite
a file's content on the way into Git (a `clean` filter declared in
`.git/info/attributes`, which can simply emit the committed bytes), and to stop
distinguishing a symlink from a regular file (`core.symlinks=false`). Each of
those empties an ordinary `git diff` while the command still reads what is
actually on disk.

So the comparison asks Git for nothing but the recorded trees. Both questions
are answered by comparing modes and object ids directly:

- **the index** against the candidate, path by path, since an unmerged or
  staged entry is what a commit from here would carry; and
- **the working tree** against the candidate, by reading each tracked path's raw
  bytes and `lstat` and computing its Git object id here. A symlink hashes its
  target, a regular file its contents, and a directory or device holds no blob
  at all — so a type change is a change, a mode change is a change, and no
  filter sits between the file and the answer.

A submodule is its own repository's `HEAD`; one this checkout cannot read is one
the run cannot vouch for. A checkout whose filesystem cannot carry an executable
bit is likewise refused by the mode comparison. Both are the right direction for
a gate: such a checkout cannot faithfully hold the candidate either.

This refusal is the whole of the policy. Validating uncommitted work with honest
attribution of its own is not supported: commit it, or plan and run from the
commit you have.

The identity fields are **copied from the plan**, never recomputed: the receipt
has to name the identity the candidate was planned under, and a runner that
derived its own could disagree with the plan it is executing. `toolchain` is
exactly the declaration the workflow passes, because that is what reuse compares
against the candidate's pinned versions; the runner's own interpreter is
recorded beside it as `runner_python` rather than inside it. `source_run_url`
names this run and attempt, from the environment GitHub publishes; an execution
no later run can attribute is not reusable evidence.

`outcome` is `passed`, `failed`, or `timeout`. A timeout is distinct because an
exhausted budget and a disagreeing test are different obstacles. The runner
gives the command its own process group and reaps that whole group on timeout,
so a backgrounded build server or test child cannot outlive the budget it was
launched under. Liveness is probed on the *group*, never inferred from the
process the runner launched: a descendant that ignores `SIGTERM` keeps running
under the same group identifier after the shell that started it has gone, so
anything still there once the grace period expires is killed outright. The runner exits `0` when the group passed, `1` when it failed
or timed out — the receipt is still written — and `2` for a diagnostic that
prevented any execution.

A plan is rejected outright, before any verdict, when it could not honestly
have produced one: an unreadable or non-object document, a schema version this
tool does not read, a missing or mistyped field, a group registered twice, a
non-positive timeout, **no groups at all**, a `selected` list naming a group the
plan does not register or naming one twice, or a `selected` list that disagrees
with the groups' own `selected` flags. The last three matter because a plan
states its decision twice and the workers read one statement while the aggregate
reads the other: a plan that contradicts itself could dispatch a group and then
excuse it, or excuse one and never notice it missing. An empty plan is the same
hazard in its purest form — every worker skips, every group is vacuously
accounted for, and a candidate that ran nothing reports success.

**Plan identity** is a SHA-256 over everything that decides what must run and
how: the plan and policy revisions, the digest of the catalog that classified
the candidate, both endpoints' commits and trees, the normalized request, and
every group's selection, reason, command, and timeout. It deliberately omits the
catalog and request *paths*, which are run-local filenames rather than contract,
and the changed-path listing, which explains a selection without being able to
alter it.

The catalog digest is in it because the runner's own check against that digest
is only self-consistent. A worker holding a rewritten override catalog *and* a
copy of the plan updated to match would satisfy itself and still produce a
receipt the original plan accepted. Binding the digest into the identity is what
makes such a receipt name a different plan, so the aggregate refuses it.

### Reusing an earlier execution

`tools/validation/reuse.py` runs in the `plan` job and asks, for every selected
group, whether some finished run already executed it against byte-identical
inputs. It writes `applicability.json`, which the workers and the aggregate both
read:

```bash
python3 tools/validation/reuse.py --plan plan.json --repo <owner/name> --output applicability.json
```

| Option | Meaning |
| --- | --- |
| `--plan`, `--repo`, `--output` | The resolved plan, the repository to read evidence from, and the applicability document to write. |
| `--workflow` | The workflow whose runs may produce reusable evidence. Defaults to `.github/workflows/validation.yml`. |
| `--worker NAME=GROUP[,GROUP...]` | A worker job and the groups it owns, so the step can report whether that job still has work. Repeatable. |
| `--budget-seconds` | The whole lookup's budget. Defaults to 120. |
| `--gh` | The GitHub CLI executable to read through. |
| `--summary` | A Markdown file the reuse table is appended to. |
| `--offline` | Write a document that reuses nothing, without any lookup. |

Eligibility is **not** gated on `inputs_changed`. A code pull request followed by
a prose-only push still reports its code as changed against the merge base, and
vetoing reuse on that would refuse exactly the case this slice exists for.
Contribution-based selection is preserved unchanged and decides what is
*selected*; identity decides what may be *inherited*.

For each selected group the step lists the artifacts named
`receipt-<group-id>-<input-identity>` and orders **all** of them newest first by
creation time, with the artifact id breaking ties — two artifacts can share a
timestamp, and without a total order the same lookup could prefer different
evidence on two runs. Nothing is filtered out before that ordering, expired
artifacts included: an unusable artifact is not an absent one, and discarding it
first would quietly promote whatever sits behind it. **Only the newest is ever
considered.** Reaching past a newer failure — or a newer expiry — for an older
pass would publish a green verdict while the evidence that actually described
these inputs sat unmentioned one artifact back.

That artifact is accepted only when all of this holds:

- the newest artifact has not expired and names a usable identifier;
- its run belongs to this repository and to `--workflow`;
- its run is `completed` and concluded `success` or `failure` — a run still
  executing has not finished the group, and a cancelled one may have uploaded a
  receipt for work it never completed;
- the archive holds exactly `<group-id>.json`, and that document passes the same
  receipt contract a fresh receipt does;
- the receipt names that same run **and the attempt the run is currently on** —
  a run's generic page always shows its newest attempt, so an upload that
  survived a re-run is not that re-run's evidence and must not stand in for an
  execution nobody has looked at;
- the receipt records the command the plan selected, and matches the
  candidate's `input_identity`, `policy_version`, `toolchain`, and `runner_os`;
- the receipt records `passed` with exit status `0`.

Everything else is an obstacle, never a pass. An expired, missing, malformed,
failed, incompatible, or unreachable receipt returns the group to execution, and
a lookup that exhausts its budget does the same for every group it did not
reach — the budget exists so an unresponsive API leaves the `plan` job time to
dispatch the work inside its five-minute timeout. A refused artifact is recorded
in `rejected` with the run it came from, and `build-test` names that run beside
the execution it forced.

Retention is GitHub's artifact default. Nothing is copied anywhere else, nothing
is pinned, and an artifact deleted through the Actions UI simply stops being
available: the affected groups execute.

In-flight work is never shared. A prose push while a code run is still executing
plans its own run, finds that run incomplete, and executes; neither run cancels
the other, because the workflow's concurrency group deliberately does not.

**Reuse is a claim about declared inputs, not proof against nondeterminism.** It
states that the inputs this repository declares for a group are byte-identical
to the ones an earlier execution ran against, on the same pinned platform, under
the same classification policy. It does not state that the group is
deterministic, that an undeclared input did not move, or that re-running would
agree. Where that matters, the remedy is a declared input, not a narrower
comparison here.

### The aggregate and `build-test`

`build-test` runs after the plan and both workers with `if: always()`, so the
required check reaches a conclusion whatever happened upstream — a skipped
required workflow is not a verdict, and a documentation candidate gets its
status through exactly this path. It downloads the artifacts, writes per-job
queue, setup, and execution timings to the job summary, and decides the verdict:

```bash
python3 tools/validation/aggregate.py --plan plan.json --receipts <dir>
```

| Option | Meaning |
| --- | --- |
| `--plan`, `--receipts` | The plan the verdict is about, and the collected receipts. |
| `--applicability` | The document recording earlier executions that still apply. |
| `--worker NAME=RESULT:GROUP[,GROUP...]` | A worker job, its result, and the groups it owns. Repeatable. |
| `--expect-head`, `--expect-base` | The pull request's current head and merge base. |
| `--expect-request-file` | A file holding the pull request's current body. |
| `--summary` | A Markdown file the verdict table is appended to. |

A selected group passes only when a well-formed receipt says it passed, names
this plan's identity, names this plan's head, records the command the plan
selected, records an execution of **this plan's candidate** commit and tree, and
agrees with the candidate on every compatibility field — `input_identity`,
`policy_version`, `toolchain`, and `runner_os` — that a reused execution is
already held to. A group the plan explained away as `unaffected` or
`optional-unrequested` needs no receipt and is reported as an omission rather
than a failure. Everything else fails: a missing receipt, a failed or timed-out
one, a malformed one, one belonging to another plan, head, or candidate, one
recording inputs or a platform this plan was not resolved for, and **any worker
that did not conclude `success` while its groups were asked to execute**. A
selected gate nothing vouched for has not been satisfied, however green the rest
of the run looks.

The candidate and compatibility questions are asked here as well as by the
runner, and deliberately so. The runner refuses to execute from the wrong
checkout, but a verdict rests on the document in front of it rather than on the
run that is supposed to have produced it, so a receipt claiming an execution
this plan does not describe is refused on its own terms. The diagnostic names
the field that disagreed.

A selected group with no receipt at all is satisfied instead by an applicability
record, and only then. The receipt that record carries is read through the same
contract a fresh one is: a document truncated to the fields the verdict happens
to compare satisfies nothing, and neither does a record whose stored proof or
restated commit, tree, and run disagree with the receipt beside it. The stored
artifact must be named `receipt-<group-id>-<input-identity>` for that record's
own group under this candidate's inputs: the name is where the group and the
identity are kept, so it is also where a record could be made to describe
evidence it did not come from. A fresh receipt always outranks one: a failure that just
happened is never overruled by an older pass. The record is held to the
candidate's compatibility fields rather than to this plan's identity and head,
which belong to the run that executed, and a record resolved for another plan or
another candidate is stale — it satisfies nothing and is reported as an
obstacle. A reused group is reported with outcome `reused`, and the summary
states for each of them that it is an earlier execution and links the run that
produced it. A worker skipped because every group it owns was covered left
nothing unvouched for and is not an obstacle.

`failure` is not excused by receipts, and deliberately so. A job can fail after
its groups passed, or fail before it wrote a receipt at all, so passing evidence
in a sibling artifact says nothing about what that job did. Only `success`
accounts for the groups a worker owns; the receipts then say which of them
failed and where a gap was left.

The `--expect-*` options add the freshness question a published verdict depends
on: does this plan still describe the pull request as it stands now? Matching
receipts to their own plan proves only that one run was internally consistent;
it cannot notice that the body was edited or the head advanced while that run
was still executing. So `build-test` re-reads the pull request's head, base, and
body from GitHub and compares them against the plan. An older run, or a rerun of
an older request on the same commit, fails rather than satisfying the newer one.

The aggregate prints one line per group with its reason and outcome, and exits
`0` for a passing verdict, `1` for a failing one, and `2` for a diagnostic that
prevented a verdict at all.

## The review gate

`.github/workflows/review-gate.yml` publishes `review-approved` on every
`pull_request` that is opened, reopened, synchronized, labeled, or unlabeled.
There is deliberately no concurrency group: queueing these runs would let GitHub
cancel a pending invalidation, and a cancelled decision is indistinguishable
from one that never reached a verdict.

Two jobs run on `synchronize` alone; the copies a label event starts are skipped
rather than allowed to re-decide an untouched head. They are separate on purpose.

`decide-dismissal` holds only read access and checks the candidate out, so the
decision it makes is the one `review_gate.py dismissal` is tested against. It
checks out with full history — the replay below reads the approved head, the
commit the update merged in, and the base's own history, none of which a shallow
clone has — proves the push's starting point from the pull request's comment
feed, reads the pull request's current head, the pushed commits' trees, and the
current labels, then answers with an action.

It checks out and answers for the push's own `after`, not the head named
elsewhere in the payload, and every decision below is refused unless the pull
request still has that head. A run delayed behind a newer push must not represent
its replay as approval of a head it never examined.

Every label read in this workflow is a **tri-state**. A read can fail, and a
failed read is not an absent label: piping `gh pr view` straight into an `if`
condition would hide the difference, because Bash exempts a condition's failure
from `set -e`, and a transient API error would then be read as "no approval to
dismiss" — leaving a stale approval standing on changed code. Each read is
captured into a variable, and a failure becomes `unknown`, which every decision
refuses to act on.

The decision itself:

- it refuses outright when the head has moved on, because removing approval from
  a head it never examined would invalidate someone else's newer review;
- it answers from the newest canonical review of the pushed head itself, when
  there is one, before anything else: an approval keeps the label — that
  approval is a new origin, and neither the push's history nor its starting
  point has anything to say about it — and a denial removes it, however
  proven the starting point and however clean the push;
- otherwise it requires the push's **starting point to be a proven approved
  revision**, as decided by `review_provenance.py` below — an attached label
  proves nothing about the head it was left on, so an unproven starting point
  strips however the trees compare and whatever the replay says;
- it compares the **trees** of the push's before and after commits — a re-pushed
  identical tree changes nothing a reviewer read, and an unavailable starting
  point counts as a change, because an unreadable comparison cannot establish
  that nothing moved;
- it takes the replay verdict described below for a push that did change the
  tree, and carries the approval when that verdict is `keep`;
- it asks for removal only when neither of those holds and the label is actually
  attached.

An absent label is not a third outcome. When nothing is attached there is nothing
to carry, so a replay that would have qualified is reported as *eligibility* and
the summary claims no inheritance.

### Carrying a review through a base update

A branch that falls behind `master` has to be updated before it can merge, and
the drainer asks for exactly that update. Invalidating the approval every time
would charge a full review for a merge nobody authored, so a content-changing
push keeps its approval in one case, proven by
`tools/validation/review_replay.py`:

```text
after is a two-parent merge whose first parent is the approved head,
its second parent is contained in the base,
replaying the approved head onto that second parent merges cleanly,
and the replay's tree is the tree that was actually pushed
=> keep
```

The last line is what makes it a proof rather than a heuristic. Git itself
produces the replay tree with `git merge-tree --write-tree`, including its own
rename detection, so a `keep` means the submitted tree is byte-for-byte the one
that already-reviewed work merges to. An edit amended onto the merge, a conflict
someone resolved by hand, an authored revert, or a rename Git could not carry all
move the tree away from that replay and strip the approval. Path overlap is not
consulted at all: two disjoint edits can still break one test, and no set of
paths proves a tree.

Containment, not equality, decides the second parent. The base tip moves on while
a check runs, and the commit the update actually incorporated stays the one to
judge; requiring the current tip would invalidate an approval nothing about the
candidate changed.

No commit message is read and no revert is detected semantically. A base commit
that itself reverts code is ordinary base history, and inheriting through it is
the rule working. What the rule excludes is a revert or edit authored *into the
update*, which is exactly what the tree comparison catches.

**Every outcome the script can reach is an answer, so it always exits 0.** The
caller removes a label on `strip`, and an unreadable object or a failed Git read
has to produce a conservative `strip`; failing instead would abort the job before
it reached the removal and leave a stale approval standing on precisely the
histories that are least trustworthy. Only a usage error fails. Its decision and
provenance are `key=value` lines appended to `$GITHUB_OUTPUT`:
`replay_decision`, `replay_reason`, `approved_head`, `incorporated_base`,
`replay_tree`, and `resulting_head`.

Run it against a local history the same way the job does:

```bash
python3 tools/validation/review_replay.py \
  --before <the approved head> --after <the merge> --base master
```

`dismiss-stale-approval` publishes those fields as the **provenance** of the
review being carried, never as a review of the new tree. `approved_head` is the
immediately preceding head: repeated clean updates carry one review through a
chain of them, and the revision a reviewer actually read is the *proven origin*
the next section establishes, which the summary names alongside the route the
carry took from it and the plain statement that no reviewer examined the
resulting integration tree. A `strip` records the same fields, with
`not established` where the replay could not reach one, so a decision that never
got as far as merging is distinguishable from one that never ran.

### Proving the starting point

The replay and the tree comparison prove that a push changed nothing a reviewer
read. Neither proves that the *starting point* was ever entitled to the
approval it carries, and the label cannot: a delayed dismissal for an earlier
push refuses to touch a superseded head — correctly, since the newer head is
someone else's to judge — and leaves `reviewed:approve` standing on a head
nobody proved. Left there, the next push inherits it. Push B adds unreviewed
behaviour on top of reviewed head A; before A→B's dismissal runs, push C lands
as Git's clean merge of B with `master`, or as a new commit with exactly B's
tree; A→B exits 3 for the superseded head; B→C sees an attached label, a clean
replay or an identical tree, and keeps it.

`tools/validation/review_provenance.py` closes that gap by proving the
starting point from the pull request's own comment feed. A revision is a
**proven approved revision** when it is

- a head a **canonical review** named: a `pr-review:v2` marker (or the
  drainer's own `pr-review:v1` spelling), naming a reviewer brand this
  pipeline knows, in a comment authored by the repository owner's account —
  the identity the Kanban coordinator and drainer publish under — whose newest
  marker naming that exact head reads `verdict=APPROVE`. The marker is bound
  to this repository and pull request by where it was posted and to the
  revision by its `head=`; a later marker for the same head that requests
  changes withdraws it, and a later approval re-establishes it. Every owner
  comment that opens like a marker (`<!-- pr-review:v`) has to be exactly one
  canonical marker, and every workflow comment that opens like a carry record
  exactly one canonical record: one that is truncated, misspelled, names an
  unknown reviewer, or is duplicated is **malformed evidence**, and the whole
  feed then proves nothing, because skipping a malformed withdrawal would
  leave the approval it withdrew authoritative. Openings are recognised in
  any case, so a differently cased marker is refused rather than overlooked,
  while the marker itself is matched exactly as the coordinator publishes it.
  Prose that merely mentions a marker's name opens nothing; or
- a head reached from such a revision through an **unbroken chain of recorded
  carries**: one `approval-provenance:v1` record per push, authored by this
  repository's own workflow identity (`github-actions[bot]`), naming the
  `before` it carried from, the `after` it carried to, the origin the decision
  traced the carry back to, and the run and attempt that wrote it. The proof
  re-walks the links rather than trusting that origin field.

A record is written by `dismiss-stale-approval` alone — the only job in this
repository's workflows that can — and only after the decision concluded with
the head still current and the label confirmed attached at the pushed head.
It is posted while that job is still running, so it is only as good as the
job's conclusion: for every record it would follow, the proof fetches the jobs
of the named run attempt (which is why `decide-dismissal` holds
`actions: read`) and requires that a `review-gate` run's
`dismiss-stale-approval` concluded `success` at exactly the recorded head. A
job that failed or was cancelled after posting, one that has not finished — a
record another push's decision reads while the job that wrote it is still
running — a listing that could not be fetched, and a run for another head or
another workflow all leave the record unusable. A `before` whose own decision
was superseded, failed, cancelled, or never ran is therefore unproven, and so
is one whose carry the job could not record: a record that fails to post
fails the job rather than leaving the next push to discover the gap.

A revision whose newest canonical verdict is `CHANGES_REQUESTED` is a
**terminal denial**: it is not approved, and no recorded carry into it is
followed, so a head that inherited an approval and was then refused in its
own right ends every chain passing through it — until that exact revision is
approved again. A head a canonical review named itself needs no record, since
the marker is its proof. Nothing else counts: a green `review-approved` check,
an observed label, a successful dismissal that found no label, and every
success of the earlier algorithm that never wrote a record prove no carry. A
pull request approved before this rule existed therefore keeps its label only
until its next push, unless that push's starting point or its own head carries
a canonical marker.

The script always exits 0, for the same reason the replay does: `unproven` is
an answer the caller removes a label on, and a feed that is missing,
unreadable, malformed, not a list of comments, or **incomplete** — any comment
without a usable `id` (a positive integer), `created_at` (exactly GitHub's
`YYYY-MM-DDTHH:MM:SSZ`, the shape whose string order is chronological, and a
real instant that parses and prints back unchanged), `user.login`
(non-blank), or `body`, or with malformed marker or record evidence as
above, since a marker that cannot be ordered
could be taken for older than the verdict it withdrew and one that cannot be
attributed could be taken for the owner's — proves nothing and is reported as `unproven` with the reason — never inferred
`proven` from tree equality or replay eligibility, and never turned into a
failure that would abort the job before the removal it justifies. Its `key=value` lines are
`provenance`, `provenance_reason`, `origin`, `chain` (every revision from the
origin to the starting point, comma-separated), and `head_verdict` — a
tri-state `approved`, `denied`, or `none`, because a canonical denial of the
pushed head is not the absence of an approval of it. A head approved directly
is its own origin: `origin` names it and `chain` is empty whatever the
starting point would have proven, and the mutation job normalises the same
way for an approval it observes, so the summary never credits an earlier
revision for a review this head received itself. The superseded-head and
unreadable-label refusals are unchanged and are answered before provenance is
consulted.

Run it against a feed the same way the job does — `--list-runs` names the run
attempts the records depend on, and each one's jobs listing goes into the
directory `--runs` names as `<run>-<attempt>.json`:

```bash
gh api --paginate --slurp "repos/<owner>/<repo>/issues/<number>/comments?per_page=100" > comments.json
mkdir -p runs
python3 tools/validation/review_provenance.py --list-runs --comments comments.json |
  while read -r run attempt; do
    gh api "repos/<owner>/<repo>/actions/runs/$run/attempts/$attempt/jobs?per_page=100" > "runs/$run-$attempt.json"
  done
python3 tools/validation/review_provenance.py \
  --before <the starting point> --after <the pushed head> \
  --comments comments.json --runs runs --owner <the repository owner>
```

`dismiss-stale-approval` reads the whole comment feed once more **immediately
before acting on either verdict** — before a removal, and before confirming a
keep. The head-equality guard cannot see a canonical verdict reached for this
exact head while the decision was queued, since the head did not move:
stripping past a fresh approval would remove a review somebody just granted to
this very revision, and confirming a keep past a fresh denial would record a
carry a reviewer just refused. That job runs no repository code, so the same
rules are applied inline through the runner's own `jq`, with the same marker
grammar token for token: every comment has to carry the usable fields above,
every owner comment that opens like a marker, in any case, has to be exactly
one canonical marker, and only then does the newest marker naming the event
head decide, in both directions. It is applied to the
provenance the job publishes whether or not it changes the action: a head
approved in its own right is a new origin even when the decision was already
keeping, so no carry is recorded for it, and a denial is reported even when
the removal was already planned. A feed that fails those rules proves nothing
there either: it never reverses a planned removal, and it turns a planned keep
into a removal rather than confirming an approval it cannot read. A read that
fails outright refuses like every other unconfirmed read in that job. Its summary states the starting point's
verdict and reason, the proven origin, and, for a carry, the route from that
origin through every recorded head to the pushed one; for a strip it names the
link that could not be proven — the starting point itself, or the revision an
otherwise recorded chain traced back to without arriving anywhere — or the
denial of the head itself.

Review inheritance decides review, and nothing else. `review-approved` stays
label-only and never reads `build-test`; `build-test` never reads the label. A
clean-merge update that changes code keeps its approval *while* the validation
workflow executes the affected groups on the integrated head, and the drainer
waits for `build-test` before merging — approval alone cannot make integrated
code green.

`dismiss-stale-approval` runs on `always()`, so a push always leaves this check
with a verdict. Without that, a decision job that failed would leave it *skipped*
— and the drainer reads its success together with the label, where a skip is
neither the success that carries an approval nor the failure that is a drainer
error. Running unconditionally costs one explicit guard: a decision that did not
conclude fails this job rather than confirming a verdict from the empty outputs
it would otherwise act on. A label event still skips it, which is the expected
result there.

It holds the only write permission in this repository's
workflows, and it **checks nothing out and runs no repository code** — not even
`review_gate.py`. A helper taken from the pull request's own head would be
executing beside a token that can mutate pull requests, and neither a sparse
checkout nor unpersisted credentials would make that code trusted: the token
reaches it through the environment either way. Its steps are this workflow's own
shell and `gh`, nothing else.

It re-reads the head **immediately before mutating** rather than trusting the
read the decision was made from: the decision job's own API calls take time, and
a push landing in that window would leave a superseded run stripping an approval
that belongs to a head it never examined. It then applies the decision and
confirms a removal by reading the labels back — the drainer reads this job's
success together with the label, so a removal that did not take must not look
like one that did, and a label read that *failed* is not a confirmed one either.

Inline is not a reason to leave it unproven. `workflow-tests` extracts that
step's own `run` body out of `review-gate.yml` and executes it against a stubbed
`gh`, so what is asserted is the shell that actually ships rather than a
restatement of it. The stub is also what makes the races reachable: a head that
advances between the decision and the write, and a label read that fails rather
than returning nothing, do not happen on demand against a real repository.

`review-approved` waits for that decision on every event and then answers from
current state through `review_gate.py verdict`, which refuses to
publish when the head has been superseded (exit 3) or when a push's invalidation
did not succeed (exit 4), withholds approval when the label is absent (exit 1),
and publishes it when the label is attached at the current head (exit 0). The
verdict is never read from the event payload: a `synchronize` run exists because
the head moved, and the same push starts the decision that may be about to
remove the label, so answering from the payload would report the label state
from before that decision.

### The drainer handshake

The installed Kanban drainer, not this repository, decides when a candidate
merges, and the contract between them is three signals and nothing else:

| What the drainer reads | What it means |
| --- | --- |
| `dismiss-stale-approval` succeeded, `reviewed:approve` attached | The approval stands for this head; the update may be carried forward |
| `dismiss-stale-approval` succeeded, label absent | There is no approval; the candidate needs review |
| `dismiss-stale-approval` failed | A drainer error — the decision did not complete, and its absence is never read as either answer |

That is the same contract the previous slices published, and neither the
replay nor the provenance proof changes it: the check name, its success
semantics, and the label's meaning are unchanged, and the job still never adds
the label itself. What changed is only *which* pushes leave the label attached.
The carry records are ordinary comments the drainer does not read, and the
canonical markers the proof reads are the ones the drainer already publishes
and verifies; nothing the proof needs is missing from the installed drainer.

For a candidate GitHub reports `BEHIND`, the drainer requests a branch update
through the `update-branch` API with the expected head, and waits for
`dismiss-stale-approval` on the new head. GitHub's update produces exactly the
two-parent merge the replay recognizes — the approved head first, the base
commit second — so the label survives, `build-test` reruns on the integrated
head, and the drainer waits for it.

If an update ever arrives that the drainer's own handshake cannot express — a
second parent that is not the base tip it recorded, for instance — that is a
Kanban prerequisite with its own owner. Do not edit the installed scripts and do
not reattach the label by hand; a label the workflow did not decide on is
indistinguishable from one it did, which is the confusion this whole gate exists
to prevent.

## Branch protection

A ruleset on `master` requires the `build-test` and `review-approved` status
checks and requires branches to be up to date before merging, so GitHub reports
a behind candidate as `BEHIND` and the installed drainer requests the branch
update that later slices are designed around.

```bash
gh api -X POST repos/coghex/hetoimasia/rulesets --input - <<'JSON'
{
  "name": "master",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/master"], "exclude": []}},
  "bypass_actors": [
    {"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}
  ],
  "rules": [
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          {"context": "build-test"},
          {"context": "review-approved"}
        ]
      }
    }
  ]
}
JSON
```

The active ruleset is `22930055`. Verify it, including each required check, with:

```bash
gh api repos/coghex/hetoimasia/rulesets
gh api repos/coghex/hetoimasia/rulesets/22930055
```

A ruleset's required status checks apply to direct pushes as well as merges: a
commit pushed straight to `master` is rejected because it cannot carry a passing
`build-test` before it exists. That would have retired the standalone
documentation lane through `tools/docs_land.sh`, so the repository Admin role
holds an `always` bypass and the owner keeps that lane.

The bypass makes enforcement advisory for the owner, and therefore for the
drainer, which merges under the owner's identity. That is a deliberate trade,
and it costs less than it appears: the drainer reads `build-test` and
`review-approved` itself and will not merge without them, so the ruleset's job
here is the freshness signal rather than the gate. It still supplies that
signal — an out-of-date candidate reports `mergeStateStatus: BEHIND` with the
bypass in place, which is what makes the drainer request a branch update. A
candidate whose checks have not passed reports `BLOCKED`.

## What the hosted platform cannot cover

Both workers run on GitHub's hosted `ubuntu-latest` runners: headless Linux,
CPU only, with no GPU and no Vulkan loader. Everything currently registered in
the catalog is a CPU build, an Hspec suite, or a console smoke run, so the
hosted platform covers all of it. It cannot cover rendering: once a renderer
exists, its evidence is offscreen capture produced somewhere with a GPU, and a
headless success will not stand in for it. `runner` is declared per group in the
catalog precisely so an unsupported runner becomes a visible requirement rather
than a silently skipped success.

## Tests

`workflow-tests` runs the real planner against temporary Git repositories and
fixture catalogs. It covers transitive and build-tool dependency selection,
documentation-only changes, consumed Markdown overriding its prose class,
build-policy changes, renames and deletions, base-revision derivation, unknown
inputs and their `inputs_changed` behaviour, optional exclusion through fallback
and through a shared harness input, optional and retired catalog definition
changes, request validation, nested and malformed request fences, `all-hspec`,
the empty Hspec match, malformed, missing, and non-UTF-8 catalogs and package
metadata, unresolvable revisions, and the explained omissions in the prose
output.

The same suite drives the real runner, aggregate, timing report, and review
gate against fixture catalogs, plans, and receipt directories. It covers a
failing command's non-zero receipt, the enforced catalog timeout and the reaping
of the command's descendants, a plan whose candidate is not its head executing
from a checkout of that candidate and recording both separately, a selected
group with no receipt, receipts belonging to another plan or another head,
malformed receipts and malformed plans, omitted `unaffected`
and `optional-unrequested` groups passing without receipts, one failing group
failing the verdict while others passed, a worker cancelled or unexpectedly
skipped while its groups were selected, a worker that concluded `failure` while
every receipt it left behind passed, a worker legitimately skipped because
nothing it owns was selected, a plan that registers no groups or whose
`selected` list contradicts its own flags, a request edited or a head advanced
after the plan was resolved, the planner's own failure leaving no plan, an
unfinished job's timings reported as unavailable, and every review-gate
decision: the keep, remove, absent, and unreadable-starting-point cases, a
delayed run refusing to touch a newer head's approval, a failed, cancelled, or
unexpectedly skipped invalidation, and an absent label. The composition that
consumes the replay is covered too: a content-changing push carried by a `keep`,
a `keep` still reported as eligibility rather than inheritance when no label is
attached, a `keep` surviving a before-tree that could not be read, the replay's
own reason reaching the summary unrewritten, and an unrecognized verdict refused
rather than guessed. So is the composition that consumes the provenance
verdict: an unproven starting point stripping through an identical tree and
through a clean replay, a canonical approval of the pushed head keeping through
a `strip`, a canonical denial of it stripping through a proven starting point
and an identical tree, that approval asking for no mutation when no label is
attached, the superseded-head and unreadable-label refusals answered first, and
unrecognized provenance and head-verdict inputs refused.

Execution provenance has its own examples, built on the same fixtures. They
reproduce the regression the contract exists for — a plan whose candidate fails,
executed again from the commit that replaced it — and require the runner to
refuse it and the aggregate to withhold the verdict. They also cover a different
commit that happens to carry the candidate's tree; the absence of any override
that could record a revision the runner did not execute; uncommitted edits,
additions staged and untracked, deletions, renames, mode changes, an edit to
Markdown a group declares as an input, and an edit to the catalog that
classifies the candidate, each refused by name; ordinary execution with prose no
group consumes and with the plan, applicability document, and receipts a run
writes beside itself; a fresh receipt recording an execution of another revision
or another tree; and a fresh receipt disagreeing about each of `input_identity`,
`policy_version`, `toolchain`, and `runner_os` in turn. Three of them are about
the classification itself: a dirty path judged by the fixture catalog its plan
was resolved with rather than the candidate's own; that fixture rewritten after
planning so that it no longer describes the plan it produced; and a worker that
rewrites both the catalog and its own copy of the plan's digest, whose receipt
the originally resolved plan then refuses as another plan's. Six more are
about what a checkout can be told not to report: an addition no group declares
and no catalog calls generated, an edit hidden by
`git update-index --assume-unchanged`, an unstaged mode change hidden by
`core.fileMode=false`, an edit a `clean` filter reports as the committed bytes,
a tracked symlink replaced by a regular file of the same text under
`core.symlinks=false`, and a declared-generated basename sitting under a
consumed input or a mandatory policy root — each refused by name.

The provenance proof is driven against real Git histories and fixture comment
feeds, with the shipped replay, provenance, and gate scripts composed exactly
as the workflow composes them. It reproduces both sequences the rule exists
for — a clean base merge of an unproven intermediate head and an identical-tree
push on top of one, each stripping — and the delayed earlier invalidation
refused for its superseded head before the next push strips; an earlier carry
whose mutation failed or never ran and so recorded nothing; a feed that could
not be read, is not valid JSON, or is not a list of comments, each stripping;
the paged feed the workflow fetches; a comment that cannot be ordered — the
withdrawal without a timestamp, or with an empty, differently written, or
well-shaped but unreal one, that would otherwise sort before the approval it
withdrew — one whose identifier is zero, negative, boolean, or a string, one
that cannot be attributed or whose author is blank, an owner comment whose
marker opening is truncated, names an unknown reviewer, is differently cased,
carries whitespace inside its model token, or is duplicated, and a workflow
comment whose record opening is malformed or differently cased, each
stripping, while prose that merely mentions the marker's name is not
evidence; a review
marker by anyone but the owner
and a carry record by anyone but the workflow, each ignored; a later marker
withdrawing an approval of the same head and a later one re-establishing it; a
fresh canonical approval of the pushed head surviving over an unproven starting
point and named as the origin, the same when the starting point was approved
too — through the shipped step, which credits this head rather than the earlier
one — and a head approved after an earlier strip starting a new chain; an
identical-tree re-push and a clean base merge of a proven head, and three
successive base merges each recorded from the last, proven back to the origin
with the chain named; a chain broken in the middle naming the link that ran
out; a carried head's push that still carries more than the merge; the run a
record names failing, cancelled, or unfinished after posting it, its jobs
unfetched, run for another head, or belonging to another workflow, each
stripping, and the run listing the workflow fetches; a later denial ending
the chain at an inherited head and at a denied head a descendant passes
through, a denial of the pushed head itself stripping past a proven starting
point — present at decision time, and arriving after it and caught by the
shipped mutation step before the keep is confirmed — and a later approval of
that exact head lifting it; and the failing sequence composed end to end —
decision, the shipped mutation step, and the verdict withholding approval.

The replay rule itself is proven against real Git histories in temporary
repositories, because rename detection, conflict resolution, and reachability are
not things a restatement of the rule can assert. It covers the branch update
GitHub's own `update-branch` performs, two additions to one manifest that merge
cleanly, and a base rename Git carries into the approved work; a merge carrying
an edit the replay does not produce, a conflict someone resolved by hand, a
rename Git cannot carry, an ordinary commit pushed on top, a revert, an octopus
merge, a merge made from the base's side, and a second parent the base does not
contain; an incorporated commit the base tip has since moved past, and a base
commit that itself reverts code, both of which keep; and the three ways Git
cannot answer at all — an approved head a force-push left unreachable, an
unreadable pushed head, and a base ref a partial fetch never created. Every one
of those strips exits zero, because the caller has a label to remove and a
failure would abort the job before it got there.

The mutation itself is covered by running the shipped step body: the removal a
content-changing push earns, the write that must not happen when the decision
was to keep, a decision that was correct when made and is stopped at write time
because the head advanced, a removal that did not take, and a label read that
failed rather than returning nothing, and a decision that never concluded
refused rather than confirmed. A canonical approval that arrived after the
decision is covered there too: the removal withheld for an approval naming
this exact head, a keep turned into a removal by a denial naming it, a late
approval taken as the origin of a keep the decision had already reached, an
approval the decision already saw normalised to this head as the origin, and a
late denial reported on a removal already planned, the newest marker for that
head winning, a fresh approval of some other head
ignored, a feed read that failed refused before a removal and before a keep
alike, and the inline feed validation: an older approval of this head followed
by a truncated denial neither reverses a planned removal nor confirms a
planned keep, a differently cased opening and whitespace inside a model token
refused rather than read past, a comment whose timestamp is well-shaped but
unreal treated the same way, and prose mentioning the marker's name left
alone. So is the record
it
writes: a kept approval recorded at the head it was carried to with the link
and the recording run attempt named exactly, no record for a head a canonical
review named itself or when
the label was gone by the time the decision was applied, and a record that
could not be posted or has no proven origin failing the job. The provenance it
publishes is asserted there too — every revision a carried approval was decided
from, the proven origin and the route the carry took from it, the credit to the
earlier review without a claim that anyone read the new tree, the link that
could not be proven named on a strip, eligibility reported instead of
inheritance when no label is attached, and the fields a strip could not
establish recorded rather than omitted.

Candidate identity and reuse are covered against temporary Git repositories and
a stub `gh` answering from canned files. The identity examples assert that a
prose edit, rename, and deletion leave `input_identity` untouched while a
source, package description, project file, fixture, consumed Markdown document,
or file mode change moves it, as do renaming and deleting an included path; that a catalog or workflow edit moves the policy
identity and the input identity with it; that a code change followed by a
prose-only push keeps the identity while selection still reports the code as
affected; and that an upstream change merged into the integration candidate
moves the identity even when the contribution is prose.

They also assert that a catalog which drops the required policy roots from its
own `policy_inputs` still cannot exempt a validation tool or a workflow from the
policy digest.

The reuse examples assert that a finished passing receipt for identical inputs
is accepted, recorded with the earlier run's own commit and attempt-specific run
URL, and removes the worker that owned it; and that a receipt from another
toolchain, another input identity, a non-zero exit, or an attempt the run has
since moved past, an artifact from another workflow, and a run still in progress
or cancelled are each refused. A newer failure standing in front of an older
pass is asserted both ways: the pass is genuine and would have been accepted
alone, and it must stay unused while the failure it hides behind stays named. A
newer *expired* artifact is asserted the same way, because filtering it out
before the ordering would silently promote the pass behind it. A lookup that
cannot answer at all leaves an obstacle and returns every group to execution.

The aggregate examples cover a covered group satisfied and its worker excused, a
selected group with neither an execution nor a record, a record resolved for
another plan, a malformed record, a record whose artifact names other evidence
than its own, a record whose embedded receipt is not a whole receipt, and a
fresh failure standing rather than the older pass behind it.

The stub is what makes those reachable: a run still executing, a newer failure
in front of an older pass, and an API that does not answer do not happen on
demand against a real repository.

It also covers the comparison range: a pull request across its merge base, a
push from the commit it started at, a push whose starting commit is absent or
unresolvable, and a history-replacing push — that last one asserted **both**
ways, so it records that the merge-base range reports the reverted group
`unaffected` while the event's own range reports it `affected`.

Several of those are regressions rather than hypotheticals. The timeout example
starts a descendant that ignores `SIGTERM` under a shell that does not, so it
fails against any cleanup that infers the group's fate from the process it
launched; the worker example supplies a passing receipt alongside a `failure`
result, so it fails against any aggregate that lets receipts vouch for the job
that wrote them.

Run them with `cabal test workflow-tests --test-show-details=direct`.
