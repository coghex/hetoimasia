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

The catalog is a JSON object. Keys are fixed; an unknown key is an error.

| Key | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | Must be `1`. |
| `policy_version` | integer | The selection policy revision, recorded in every plan. |
| `policy_inputs` | array of strings | Paths whose change invalidates selection policy itself. They are an input of *every* group, so a planner, catalog, runner, aggregate, or workflow edit widens non-optional coverage conservatively and still marks an optional group's inputs changed when its own definition moved — without ever selecting an optional group, since selection reaches those only through a request. |
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

The registered policy inputs are the planner, the catalog, the runner, the
aggregate, their shared evidence contract, and `.github/workflows/`. All of them
decide what a result means rather than what a group tests, so a change to any of
them has to reach every group. Classifying the workflows here is also what keeps
a CI edit from arriving as an *unknown* path: the conservative coverage is the
same either way, but an explained widening is auditable and an unclassified one
is only a warning.

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

`inputs_changed` is independent of selection, because CI-3 consumes it to decide
whether earlier evidence still applies:

- floor membership or a request alone leaves it `false`;
- a changed relevant input makes it `true`;
- unknown-input fallback marks every non-optional group's inputs changed, so
  uncertainty can never reach a consumer as equivalence;
- an optional group still reports `true` when its own inputs changed or its own
  catalog definition moved, even though it stays unselected.

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
| `schema_version`, `policy_version` | Plan format and catalog policy revisions. |
| `catalog` | The resolved catalog source and its group count. |
| `base`, `head` | Each revision's name with its resolved `commit` and `tree`. |
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

The job uploads `plan.json` as an artifact and publishes the selected group IDs
as job outputs. A planner error fails the job with the planner's own diagnostic.

### Workers

Two workers run in parallel, each with a 45-minute timeout, each pinned to
GHC 9.12.2 and Cabal 3.16.1.0, and each **skipped entirely** when the plan
selected none of the groups it owns:

| Job | Groups, in order |
| --- | --- |
| `haskell-engine` | `build.all`, `test.engine`, `smoke.console` |
| `haskell-workflow` | `test.workflow` |

A worker runs every selected group it owns and continues past a failure, so the
aggregate sees a receipt for each of them rather than inferring the rest from
the first one that failed. It uploads its receipts whatever happened, then fails
if any of its groups failed.

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
| `--executed-commit`, `--executed-tree` | Override the executed revision recorded in the receipt. Defaults to the checkout's `HEAD`. |
| `--toolchain NAME=VERSION` | A toolchain version to record. Repeatable; the runner always records its own Python version. |

Fixture catalogs reach the runner through the plan: resolve one with
`plan.py --catalog <fixture>`, then run against that plan. A group the plan
explained away is refused rather than executed, and leaves no receipt.

The receipt records the group, the exact command, the outcome, the exit status,
start and end timestamps, the duration, the declared timeout, the plan identity,
the pull request's head commit, the commit and tree that actually executed, the
runner's OS and architecture, and the toolchain versions. The head and the
executed revision are recorded separately because a pull request is validated on
an integration candidate that is neither endpoint; a receipt must not imply that
the head itself ran.

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
how: the plan and policy revisions, both endpoints' commits and trees, the
normalized request, and every group's selection, reason, command, and timeout.
It deliberately omits the catalog and request *paths*, which are run-local
filenames rather than contract, and the changed-path listing, which explains a
selection without being able to alter it.

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
| `--worker NAME=RESULT:GROUP[,GROUP...]` | A worker job, its result, and the groups it owns. Repeatable. |
| `--expect-head`, `--expect-base` | The pull request's current head and merge base. |
| `--expect-request-file` | A file holding the pull request's current body. |
| `--summary` | A Markdown file the verdict table is appended to. |

A selected group passes only when a well-formed receipt says it passed, names
this plan's identity, names this plan's head, and records the command the plan
selected. A group the plan explained away as `unaffected` or
`optional-unrequested` needs no receipt and is reported as an omission rather
than a failure. Everything else fails: a missing receipt, a failed or timed-out
one, a malformed one, one belonging to another plan or head, and **any worker
that did not conclude `success` while its groups were selected**. A selected
gate nothing vouched for has not been satisfied, however green the rest of the
run looks.

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
reads the pull request's current head, the pushed commits' trees, and the
current labels, then answers with an action.

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
- it compares the **trees** of the push's before and after commits — a re-pushed
  identical tree changes nothing a reviewer read, and an unavailable starting
  point counts as a change, because an unreadable comparison cannot establish
  that nothing moved;
- it asks for removal only when the push changed tracked files and the label is
  actually attached.

`dismiss-stale-approval` holds the only write permission in this repository's
workflows. It re-reads the head **again, immediately before mutating** rather
than trusting the read the decision was made from: the decision job's own API
calls take time, and a push landing in that window would leave a superseded run
stripping an approval that belongs to a head it never examined. That guard is
`review_gate.py apply`, and `review_gate.py confirm` then checks that a removal
took — the drainer reads this job's success together with the label, so a
removal that did not take must not look like one that did, and an unreadable
label state is not a confirmed one.

Both guards are tested helpers rather than inline shell, which is why this job
takes a **sparse checkout of `tools/validation` alone**, with credentials not
persisted. The amended contract keeps the write-scoped token away from
contributor-authored code, and that is what the sparse path preserves: the token
never sits beside the project's build and test tooling, which is the code a
worker would run. The alternative was an untested guard on the only mutation
either workflow performs.

This slice never keeps an approval across a content-changing push. Carrying
review through a clean base merge is a later slice's work.

`review-approved` waits for that decision on every event and then answers from
current state through `review_gate.py verdict`, which refuses to
publish when the head has been superseded (exit 3) or when a push's invalidation
did not succeed (exit 4), withholds approval when the label is absent (exit 1),
and publishes it when the label is attached at the current head (exit 0). The
verdict is never read from the event payload: a `synchronize` run exists because
the head moved, and the same push starts the decision that may be about to
remove the label, so answering from the payload would report the label state
from before that decision.

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
of the command's descendants, the head and executed revision being recorded
separately, a selected group with no receipt, receipts belonging to another plan
or another head, malformed receipts and malformed plans, omitted `unaffected`
and `optional-unrequested` groups passing without receipts, one failing group
failing the verdict while others passed, a worker cancelled or unexpectedly
skipped while its groups were selected, a worker that concluded `failure` while
every receipt it left behind passed, a worker legitimately skipped because
nothing it owns was selected, a plan that registers no groups or whose
`selected` list contradicts its own flags, a request edited or a head advanced
after the plan was resolved, the planner's own failure leaving no plan, an
unfinished job's timings reported as unavailable, and every review-gate
decision: the keep, remove, absent, and unreadable-starting-point cases, a
delayed run refusing to touch a newer head's approval, a decision that was
correct when made and is stopped at write time because the head advanced, a
removal that did not take, a label read that failed, a failed, cancelled, or
unexpectedly skipped invalidation, and an absent label.

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
