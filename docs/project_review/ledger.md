# Project review ledger

Machine-owned state for the `project-review` workflow: one row per merged pull
request, per repository, with its title, when it merged, its status, the commit
a completed review verified it against, when that review completed, the report
it produced, and the evidence the row rests on. A checkmark means a clean review
against the commit beside it; `[legacy]` means coverage established by a
document that predates this ledger, with no date and no commit invented for it.
A title and a merge time are the listing's to supply, so a row that no merged-PR
listing has named yet carries neither rather than a guess.

Written by `project_review_ledger.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next invocation instead of being ignored.

## coghex/hetoimasia

| PR | Title | Merged (UTC) | Status | Verified at | Completed (UTC) | Report | Evidence |
| ---: | --- | --- | --- | --- | --- | --- | --- |
| #180 | Mark GLFW wake and stall warning failures as diagnostic failures | 2026-09-19T23:09:45Z | ✓ clean | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-19T23:29:05Z | — | — |
| #179 | Model bounded script tasks and execution protocols | 2026-09-19T21:36:08Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-19T23:44:23Z | [docs/project_review/179.md](179.md) | — |
| #178 | Let inspected waiting retirements permit the idle wait again | 2026-09-19T20:47:16Z | ✓ clean | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-19T23:50:08Z | — | — |
| #177 | Prove Linux confinement and resource-limit feasibility | 2026-09-19T19:16:26Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-19T23:58:14Z | [docs/project_review/177.md](177.md) | — |
| #176 | Prove what macOS confinement costs, and say what it is built on | 2026-09-19T18:28:17Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:08:17Z | [docs/project_review/176.md](176.md) | — |
| #175 | Model GPU retention and frame ownership as a pure backend contract | 2026-09-19T15:05:25Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:22:28Z | [docs/project_review/175.md](175.md) | — |
| #174 | Prove the native Vulkan compatibility and completion profile | 2026-09-19T01:33:00Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:35:12Z | [docs/project_review/174.md](174.md) | — |
| #173 | Establish the Lua binding and foreign-call boundary | 2026-09-18T22:28:00Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:42:50Z | [docs/project_review/173.md](173.md) | — |
| #172 | Revive a withdrawn retirement path on owner-thread certification of new evidence | 2026-09-18T17:48:22Z | ✓ clean | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:47:20Z | — | — |
| #171 | Qualify GHC 9.14.1 and pin the Vulkan binding the later slices inherit | 2026-09-18T16:52:10Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T00:56:27Z | [docs/project_review/171.md](171.md) | — |
| #170 | Demand an attachment protocol's declarations where they can still be answered | 2026-09-18T14:12:20Z | findings | `38388f8c0d6353167c7867bdfa05bf58516b34f4` | 2026-09-20T01:02:57Z | [docs/project_review/170.md](170.md) | — |
| #165 | Expose exclusive attachments with independent dynamic retirement | 2026-09-18T11:34:53Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #164 | Compose per-window render demand with application simulation | 2026-09-18T03:06:24Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #163 | Establish the protected host retirement boundary | 2026-09-18T01:39:52Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #162 | Pace owner turns from ready work and absolute deadlines | 2026-09-17T22:28:38Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #161 | Connect admitted commands and published demand to native wake | 2026-09-17T21:36:59Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #159 | Add bounded variable and fixed-step update policies | 2026-09-17T18:02:08Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #156 | Model exclusive window attachments and retirement evidence | 2026-09-17T17:50:50Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #154 | Compose managed dependency lifetimes around application supervision | 2026-09-17T17:29:56Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #153 | Own a cross-thread native wake capability with the GLFW session | 2026-09-17T17:13:43Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #152 | Add the monotonic time and deadline boundary | 2026-09-17T16:35:23Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #151 | Move GLFW headless coverage into a GLFW-owned test suite | 2026-09-17T16:21:48Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #150 | Move runtime contracts into a runtime-owned test suite | 2026-09-17T16:04:53Z | [legacy] | — | — | [docs/project_review_165-150.md](../project_review_165-150.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_165-150.md (operator-confirmed) |
| #137 | Move foundation contracts into a foundation-owned test suite | 2026-09-17T14:03:49Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #132 | Extract the external-client compiler harness into a neutral test-support library | 2026-09-17T13:34:19Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #128 | Require explicit per-run consent before the native suite touches a desktop | 2026-09-17T13:21:44Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #126 | Follow a borderless window's confirmed move when keeping disconnect recovery | 2026-09-17T12:56:03Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #122 | Keep shared native fixture resources alive during repeated cancellation | 2026-09-16T19:34:13Z | [legacy] | — | — | [docs/project_review_122-119.md](../project_review_122-119.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_122-119.md (operator-confirmed) |
| #121 | Preserve the last windowed geometry through partial mode departures | 2026-09-16T17:45:34Z | [legacy] | — | — | [docs/project_review_122-119.md](../project_review_122-119.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_122-119.md (operator-confirmed) |
| #120 | Preserve monitor-disconnect recovery across window observations | 2026-09-16T16:42:23Z | [legacy] | — | — | [docs/project_review_122-119.md](../project_review_122-119.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_122-119.md (operator-confirmed) |
| #119 | Propagate a window-construction failure whose rollback failed | 2026-09-16T15:55:37Z | [legacy] | — | — | [docs/project_review_122-119.md](../project_review_122-119.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_122-119.md (operator-confirmed) |
| #114 | Connect native input callbacks to window feeds | 2026-09-16T00:44:48Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #113 | Implement monitor-aware window modes with claims and safe fallback | 2026-09-15T22:11:25Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #112 | Implement bounded input feeds and acknowledged resets | 2026-09-15T18:57:49Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #111 | Implement ordinary window manipulation with honest outcomes | 2026-09-15T18:25:09Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #110 | Support independent dynamic window lifetimes | 2026-09-15T16:56:26Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #109 | Publish monitor inventory with disconnect-safe identities | 2026-09-15T15:11:59Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #108 | Run window commands and native events from a supervised owner loop | 2026-09-15T13:49:10Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #107 | Establish the shared native Hspec fixture and platform gates | 2026-09-15T05:21:56Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #106 | Establish bounded window command admission and completion | 2026-09-15T02:21:19Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #105 | Own scoped windows and publish coherent observations | 2026-09-15T01:39:17Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #104 | Quiesce application services before supervised worker drain | 2026-09-14T23:20:19Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #103 | Establish the GLFW native binding and main-thread session boundary | 2026-09-14T22:23:09Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #102 | Supply the cached native toolchain and reusable Linux CI image | 2026-09-14T21:06:50Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #101 | Add an owner-thread scoped resource collection with early release | 2026-09-14T21:02:01Z | [legacy] | — | — | [docs/project_review_114-101.md](../project_review_114-101.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_114-101.md (operator-confirmed) |
| #85 | Finish inbox services through an acknowledged drain | 2026-09-14T06:23:17Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #84 | Own supervised inbox startup and stopping | 2026-09-14T05:57:36Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #83 | Publish coherent snapshots with checked cursors | 2026-09-14T05:15:11Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #82 | Add bounded FIFO channels with terminal state and telemetry | 2026-09-14T04:54:41Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #81 | Preserve structured failure origins inside STM | 2026-09-14T04:29:58Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #80 | Prepare immutable payloads before publication | 2026-09-14T03:55:27Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #72 | Make supervised worker handles opaque to record updates | 2026-09-13T23:31:17Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #71 | Preserve supervised failure evidence across nested supervision invocations | 2026-09-13T23:19:09Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #68 | Integrate application startup, availability, and shutdown | 2026-09-13T20:53:03Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #67 | Supervise worker outcomes through checkpoints and supervised waits | 2026-09-13T20:20:12Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #66 | Own borrowed logging lifetime and final flush | 2026-09-13T19:13:48Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #65 | Establish scoped worker startup, cancellation, and joining | 2026-09-13T18:44:03Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #64 | Compose component contexts and scoped initialization | 2026-09-13T17:55:59Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #63 | Report recovery outcomes and terminal failures through the logger | 2026-09-13T17:11:07Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #62 | Add bounded recovery around complete owned operations | 2026-09-13T16:30:50Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #61 | Preserve typed failures with structured origin and operation context | 2026-09-13T15:50:48Z | [legacy] | — | — | [docs/project_review_68-61.md](../project_review_68-61.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_68-61.md (operator-confirmed) |
| #51 | Split the headless engine suite into component specs | 2026-09-13T00:13:20Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #48 | Close the retained cleanup failure representation | 2026-09-12T21:14:47Z | [legacy] | — | — | — | cursor:docs/project_review_boundaries.md |
| #46 | Preserve a reporting cancellation's own context | 2026-09-12T20:26:50Z | [legacy] | — | — | [docs/project_review_46-43.md](../project_review_46-43.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_46-43.md (operator-confirmed) |
| #45 | Expand each retained cleanup failure once while inspecting | 2026-09-12T20:09:35Z | [legacy] | — | — | [docs/project_review_46-43.md](../project_review_46-43.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_46-43.md (operator-confirmed) |
| #44 | Close the Scoped continuation to record updates from public exports | 2026-09-12T19:08:24Z | [legacy] | — | — | [docs/project_review_46-43.md](../project_review_46-43.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_46-43.md (operator-confirmed) |
| #43 | Validate composite part metadata before acquiring the part | 2026-09-12T18:38:53Z | [legacy] | — | — | [docs/project_review_46-43.md](../project_review_46-43.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_46-43.md (operator-confirmed) |
| #38 | Exercise owned resources through the console runtime | 2026-09-12T15:32:33Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #37 | Add allocResource and nested continuation scopes | 2026-09-12T14:52:45Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #36 | Protect composite resource construction and cleanup ordering | 2026-09-12T14:37:01Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #35 | Keep a scope's own failure and its cleanup failures together | 2026-09-12T14:03:24Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #34 | Ship every file the workflow suite reads to run | 2026-09-12T13:25:45Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #33 | Keep timing collection failures out of the required validation verdict | 2026-09-12T05:22:55Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #32 | Refuse to certify a plan from a checkout that is not its candidate | 2026-09-12T05:03:24Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #31 | Bind an inherited approval to a proven approved revision | 2026-09-12T00:37:53Z | [legacy] | — | — | [docs/project_review_38-31.md](../project_review_38-31.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_38-31.md (operator-confirmed) |
| #21 | Carry a review through the base merge it was asked for | 2026-09-11T20:19:01Z | [legacy] | — | — | [docs/project_review_21-15.md](../project_review_21-15.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_21-15.md (operator-confirmed) |
| #20 | Let a prose-only candidate inherit code evidence | 2026-09-11T19:34:23Z | [legacy] | — | — | [docs/project_review_21-15.md](../project_review_21-15.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_21-15.md (operator-confirmed) |
| #16 | Run selected validation through stable GitHub checks and wire the review gate | 2026-09-11T17:42:01Z | [legacy] | — | — | [docs/project_review_21-15.md](../project_review_21-15.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_21-15.md (operator-confirmed) |
| #15 | Define the shared validation catalog and explainable test selection | 2026-09-11T14:07:57Z | [legacy] | — | — | [docs/project_review_21-15.md](../project_review_21-15.md) | cursor:docs/project_review_boundaries.md; report:docs/project_review_21-15.md (operator-confirmed) |
| #14 | Preserve cancellation and primary failures in the worker example | 2026-09-11T13:26:55Z | never reviewed | — | — | — | — |
| #7 | Integrate startup configuration and the module authoring guide | 2026-09-11T03:17:21Z | never reviewed | — | — | — | — |
| #6 | Implement deterministic output and safe sink ownership | 2026-09-11T02:52:54Z | never reviewed | — | — | — | — |
| #5 | Establish structured logging, filtering, and scoped context | 2026-09-11T02:09:34Z | never reviewed | — | — | — | — |

- Migrated from the cursor-v2 record.

<!-- project-review:ledger:v1 -->

```json
{
  "repositories": {
    "coghex/hetoimasia": {
      "direct": {
        "endpoint": null,
        "reviewed": []
      },
      "excluded": {
        "commits": [],
        "prs": []
      },
      "lease_defaults": null,
      "migration": {
        "boundary": null,
        "source": "cursor-v2",
        "withheld_boundary": null
      },
      "rows": {
        "101": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-14T21:02:01Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Add an owner-thread scoped resource collection with early release"
        },
        "102": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-14T21:06:50Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Supply the cached native toolchain and reusable Linux CI image"
        },
        "103": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-14T22:23:09Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Establish the GLFW native binding and main-thread session boundary"
        },
        "104": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-14T23:20:19Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Quiesce application services before supervised worker drain"
        },
        "105": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T01:39:17Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Own scoped windows and publish coherent observations"
        },
        "106": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T02:21:19Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Establish bounded window command admission and completion"
        },
        "107": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T05:21:56Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Establish the shared native Hspec fixture and platform gates"
        },
        "108": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T13:49:10Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Run window commands and native events from a supervised owner loop"
        },
        "109": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T15:11:59Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Publish monitor inventory with disconnect-safe identities"
        },
        "110": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T16:56:26Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Support independent dynamic window lifetimes"
        },
        "111": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T18:25:09Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Implement ordinary window manipulation with honest outcomes"
        },
        "112": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T18:57:49Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Implement bounded input feeds and acknowledged resets"
        },
        "113": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-15T22:11:25Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Implement monitor-aware window modes with claims and safe fallback"
        },
        "114": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_114-101.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-16T00:44:48Z",
          "report": "docs/project_review_114-101.md",
          "status": "legacy",
          "title": "Connect native input callbacks to window feeds"
        },
        "119": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_122-119.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-16T15:55:37Z",
          "report": "docs/project_review_122-119.md",
          "status": "legacy",
          "title": "Propagate a window-construction failure whose rollback failed"
        },
        "120": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_122-119.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-16T16:42:23Z",
          "report": "docs/project_review_122-119.md",
          "status": "legacy",
          "title": "Preserve monitor-disconnect recovery across window observations"
        },
        "121": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_122-119.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-16T17:45:34Z",
          "report": "docs/project_review_122-119.md",
          "status": "legacy",
          "title": "Preserve the last windowed geometry through partial mode departures"
        },
        "122": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_122-119.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-16T19:34:13Z",
          "report": "docs/project_review_122-119.md",
          "status": "legacy",
          "title": "Keep shared native fixture resources alive during repeated cancellation"
        },
        "126": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-17T12:56:03Z",
          "report": null,
          "status": "legacy",
          "title": "Follow a borderless window's confirmed move when keeping disconnect recovery"
        },
        "128": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-17T13:21:44Z",
          "report": null,
          "status": "legacy",
          "title": "Require explicit per-run consent before the native suite touches a desktop"
        },
        "132": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-17T13:34:19Z",
          "report": null,
          "status": "legacy",
          "title": "Extract the external-client compiler harness into a neutral test-support library"
        },
        "137": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-17T14:03:49Z",
          "report": null,
          "status": "legacy",
          "title": "Move foundation contracts into a foundation-owned test suite"
        },
        "14": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [],
          "history": [],
          "merged_at": "2026-09-11T13:26:55Z",
          "report": null,
          "status": "never-reviewed",
          "title": "Preserve cancellation and primary failures in the worker example"
        },
        "15": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_21-15.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-11T14:07:57Z",
          "report": "docs/project_review_21-15.md",
          "status": "legacy",
          "title": "Define the shared validation catalog and explainable test selection"
        },
        "150": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T16:04:53Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Move runtime contracts into a runtime-owned test suite"
        },
        "151": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T16:21:48Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Move GLFW headless coverage into a GLFW-owned test suite"
        },
        "152": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T16:35:23Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Add the monotonic time and deadline boundary"
        },
        "153": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T17:13:43Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Own a cross-thread native wake capability with the GLFW session"
        },
        "154": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T17:29:56Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Compose managed dependency lifetimes around application supervision"
        },
        "156": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T17:50:50Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Model exclusive window attachments and retirement evidence"
        },
        "159": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T18:02:08Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Add bounded variable and fixed-step update policies"
        },
        "16": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_21-15.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-11T17:42:01Z",
          "report": "docs/project_review_21-15.md",
          "status": "legacy",
          "title": "Run selected validation through stable GitHub checks and wire the review gate"
        },
        "161": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T21:36:59Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Connect admitted commands and published demand to native wake"
        },
        "162": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-17T22:28:38Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Pace owner turns from ready work and absolute deadlines"
        },
        "163": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-18T01:39:52Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Establish the protected host retirement boundary"
        },
        "164": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-18T03:06:24Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Compose per-window render demand with application simulation"
        },
        "165": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_165-150.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-18T11:34:53Z",
          "report": "docs/project_review_165-150.md",
          "status": "legacy",
          "title": "Expose exclusive attachments with independent dynamic retirement"
        },
        "170": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T01:02:57Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T01:01:37.888776Z",
              "kind": "allocation",
              "report": "docs/project_review/170.md",
              "token": "91a24dacd03e33695e70cce6a67ff0e6"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T01:02:57Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "1f82210864e8c7dc8c0c7a4e86b0a49dbe2487da",
                  "pr": 170,
                  "report": "docs/project_review_165-150.md"
                }
              ],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/170.md",
              "token": "91a24dacd03e33695e70cce6a67ff0e6"
            }
          ],
          "merged_at": "2026-09-18T14:12:20Z",
          "report": "docs/project_review/170.md",
          "status": "findings",
          "title": "Demand an attachment protocol's declarations where they can still be answered"
        },
        "171": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:56:27Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T00:55:04.969959Z",
              "kind": "allocation",
              "report": "docs/project_review/171.md",
              "token": "e7d0ef708730d10e88973155b8aeb17f"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:56:27Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/171.md",
              "token": "e7d0ef708730d10e88973155b8aeb17f"
            }
          ],
          "merged_at": "2026-09-18T16:52:10Z",
          "report": "docs/project_review/171.md",
          "status": "findings",
          "title": "Qualify GHC 9.14.1 and pin the Vulkan binding the later slices inherit"
        },
        "172": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:47:20Z",
          "evidence": [],
          "history": [
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:47:20Z",
              "fixes": [
                {
                  "key": "PRR-2",
                  "merge_commit": "a597912dc0df09d44c1a74f4cc1d8609b94a341b",
                  "pr": 172,
                  "report": "docs/project_review_165-150.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "4406993c54c1176bab6321cbfdabd421"
            }
          ],
          "merged_at": "2026-09-18T17:48:22Z",
          "report": null,
          "status": "clean",
          "title": "Revive a withdrawn retirement path on owner-thread certification of new evidence"
        },
        "173": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:42:50Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T00:41:06.223377Z",
              "kind": "allocation",
              "report": "docs/project_review/173.md",
              "token": "d46cac35926ab662d4d466d04f42bcc9"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:42:50Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/173.md",
              "token": "d46cac35926ab662d4d466d04f42bcc9"
            }
          ],
          "merged_at": "2026-09-18T22:28:00Z",
          "report": "docs/project_review/173.md",
          "status": "findings",
          "title": "Establish the Lua binding and foreign-call boundary"
        },
        "174": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:35:12Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T00:30:14.011654Z",
              "kind": "allocation",
              "report": "docs/project_review/174.md",
              "token": "3a17286830059700c342ef45dca2dc04"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:35:12Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/174.md",
              "token": "3a17286830059700c342ef45dca2dc04"
            }
          ],
          "merged_at": "2026-09-19T01:33:00Z",
          "report": "docs/project_review/174.md",
          "status": "findings",
          "title": "Prove the native Vulkan compatibility and completion profile"
        },
        "175": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:22:28Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T00:19:51.274658Z",
              "kind": "allocation",
              "report": "docs/project_review/175.md",
              "token": "966de8b9b7a8a7fecd08c9399f5f1b76"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:22:28Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/175.md",
              "token": "966de8b9b7a8a7fecd08c9399f5f1b76"
            }
          ],
          "merged_at": "2026-09-19T15:05:25Z",
          "report": "docs/project_review/175.md",
          "status": "findings",
          "title": "Model GPU retention and frame ownership as a pure backend contract"
        },
        "176": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-20T00:08:17Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T00:06:46.109717Z",
              "kind": "allocation",
              "report": "docs/project_review/176.md",
              "token": "11f86dd5f0af7f2037f643c3d5314b62"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-20T00:08:17Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/176.md",
              "token": "11f86dd5f0af7f2037f643c3d5314b62"
            }
          ],
          "merged_at": "2026-09-19T18:28:17Z",
          "report": "docs/project_review/176.md",
          "status": "findings",
          "title": "Prove what macOS confinement costs, and say what it is built on"
        },
        "177": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-19T23:58:14Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-19T23:56:31.128650Z",
              "kind": "allocation",
              "report": "docs/project_review/177.md",
              "token": "9380a52d28502983df2f9c91df48964a"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-19T23:58:14Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/177.md",
              "token": "9380a52d28502983df2f9c91df48964a"
            }
          ],
          "merged_at": "2026-09-19T19:16:26Z",
          "report": "docs/project_review/177.md",
          "status": "findings",
          "title": "Prove Linux confinement and resource-limit feasibility"
        },
        "178": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-19T23:50:08Z",
          "evidence": [],
          "history": [
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-19T23:50:08Z",
              "fixes": [
                {
                  "key": "PRR-3",
                  "merge_commit": "bb3d61acf81ce526e3f2008e23d372b2a3f2d0f9",
                  "pr": 178,
                  "report": "docs/project_review_165-150.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "6985e3bb095ad6aa31b39bb30bc82ab7"
            }
          ],
          "merged_at": "2026-09-19T20:47:16Z",
          "report": null,
          "status": "clean",
          "title": "Let inspected waiting retirements permit the idle wait again"
        },
        "179": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-19T23:44:23Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-19T23:42:17.227071Z",
              "kind": "allocation",
              "report": "docs/project_review/179.md",
              "token": "1b1a0787d8d803e5cd5320f3e2db0e36"
            },
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-19T23:44:23Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/179.md",
              "token": "1b1a0787d8d803e5cd5320f3e2db0e36"
            }
          ],
          "merged_at": "2026-09-19T21:36:08Z",
          "report": "docs/project_review/179.md",
          "status": "findings",
          "title": "Model bounded script tasks and execution protocols"
        },
        "180": {
          "claim": null,
          "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
          "completed_at": "2026-09-19T23:29:05Z",
          "evidence": [],
          "history": [
            {
              "commit": "38388f8c0d6353167c7867bdfa05bf58516b34f4",
              "completed_at": "2026-09-19T23:29:05Z",
              "fixes": [
                {
                  "key": "PRR-4",
                  "merge_commit": "3a2e0a7043ed6a96fc99aa050c173db4e480eb29",
                  "pr": 180,
                  "report": "docs/project_review_165-150.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "f5032b21e48568fa4c2860bbee58e4f4"
            }
          ],
          "merged_at": "2026-09-19T23:09:45Z",
          "report": null,
          "status": "clean",
          "title": "Mark GLFW wake and stall warning failures as diagnostic failures"
        },
        "20": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_21-15.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-11T19:34:23Z",
          "report": "docs/project_review_21-15.md",
          "status": "legacy",
          "title": "Let a prose-only candidate inherit code evidence"
        },
        "21": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_21-15.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-11T20:19:01Z",
          "report": "docs/project_review_21-15.md",
          "status": "legacy",
          "title": "Carry a review through the base merge it was asked for"
        },
        "31": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T00:37:53Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Bind an inherited approval to a proven approved revision"
        },
        "32": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T05:03:24Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Refuse to certify a plan from a checkout that is not its candidate"
        },
        "33": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T05:22:55Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Keep timing collection failures out of the required validation verdict"
        },
        "34": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T13:25:45Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Ship every file the workflow suite reads to run"
        },
        "35": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T14:03:24Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Keep a scope's own failure and its cleanup failures together"
        },
        "36": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T14:37:01Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Protect composite resource construction and cleanup ordering"
        },
        "37": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T14:52:45Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Add allocResource and nested continuation scopes"
        },
        "38": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_38-31.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T15:32:33Z",
          "report": "docs/project_review_38-31.md",
          "status": "legacy",
          "title": "Exercise owned resources through the console runtime"
        },
        "43": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_46-43.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T18:38:53Z",
          "report": "docs/project_review_46-43.md",
          "status": "legacy",
          "title": "Validate composite part metadata before acquiring the part"
        },
        "44": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_46-43.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T19:08:24Z",
          "report": "docs/project_review_46-43.md",
          "status": "legacy",
          "title": "Close the Scoped continuation to record updates from public exports"
        },
        "45": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_46-43.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T20:09:35Z",
          "report": "docs/project_review_46-43.md",
          "status": "legacy",
          "title": "Expand each retained cleanup failure once while inspecting"
        },
        "46": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_46-43.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-12T20:26:50Z",
          "report": "docs/project_review_46-43.md",
          "status": "legacy",
          "title": "Preserve a reporting cancellation's own context"
        },
        "48": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-12T21:14:47Z",
          "report": null,
          "status": "legacy",
          "title": "Close the retained cleanup failure representation"
        },
        "5": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [],
          "history": [],
          "merged_at": "2026-09-11T02:09:34Z",
          "report": null,
          "status": "never-reviewed",
          "title": "Establish structured logging, filtering, and scoped context"
        },
        "51": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-13T00:13:20Z",
          "report": null,
          "status": "legacy",
          "title": "Split the headless engine suite into component specs"
        },
        "6": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [],
          "history": [],
          "merged_at": "2026-09-11T02:52:54Z",
          "report": null,
          "status": "never-reviewed",
          "title": "Implement deterministic output and safe sink ownership"
        },
        "61": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T15:50:48Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Preserve typed failures with structured origin and operation context"
        },
        "62": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T16:30:50Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Add bounded recovery around complete owned operations"
        },
        "63": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T17:11:07Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Report recovery outcomes and terminal failures through the logger"
        },
        "64": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T17:55:59Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Compose component contexts and scoped initialization"
        },
        "65": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T18:44:03Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Establish scoped worker startup, cancellation, and joining"
        },
        "66": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T19:13:48Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Own borrowed logging lifetime and final flush"
        },
        "67": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T20:20:12Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Supervise worker outcomes through checkpoints and supervised waits"
        },
        "68": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md",
            "report:docs/project_review_68-61.md (operator-confirmed)"
          ],
          "history": [],
          "merged_at": "2026-09-13T20:53:03Z",
          "report": "docs/project_review_68-61.md",
          "status": "legacy",
          "title": "Integrate application startup, availability, and shutdown"
        },
        "7": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [],
          "history": [],
          "merged_at": "2026-09-11T03:17:21Z",
          "report": null,
          "status": "never-reviewed",
          "title": "Integrate startup configuration and the module authoring guide"
        },
        "71": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-13T23:19:09Z",
          "report": null,
          "status": "legacy",
          "title": "Preserve supervised failure evidence across nested supervision invocations"
        },
        "72": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-13T23:31:17Z",
          "report": null,
          "status": "legacy",
          "title": "Make supervised worker handles opaque to record updates"
        },
        "80": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T03:55:27Z",
          "report": null,
          "status": "legacy",
          "title": "Prepare immutable payloads before publication"
        },
        "81": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T04:29:58Z",
          "report": null,
          "status": "legacy",
          "title": "Preserve structured failure origins inside STM"
        },
        "82": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T04:54:41Z",
          "report": null,
          "status": "legacy",
          "title": "Add bounded FIFO channels with terminal state and telemetry"
        },
        "83": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T05:15:11Z",
          "report": null,
          "status": "legacy",
          "title": "Publish coherent snapshots with checked cursors"
        },
        "84": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T05:57:36Z",
          "report": null,
          "status": "legacy",
          "title": "Own supervised inbox startup and stopping"
        },
        "85": {
          "claim": null,
          "commit": null,
          "completed_at": null,
          "evidence": [
            "cursor:docs/project_review_boundaries.md"
          ],
          "history": [],
          "merged_at": "2026-09-14T06:23:17Z",
          "report": null,
          "status": "legacy",
          "title": "Finish inbox services through an acknowledged drain"
        }
      }
    }
  },
  "version": 3
}
```
