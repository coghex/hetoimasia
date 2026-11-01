# Lua-first M1 (epic #514): coverage of the completion conditions and the 28 delivery slices

Written for LFE-25 ([#540](https://github.com/coghex/hetoimasia/issues/540)), the last slice, and retained with [its evidence](README.md). This document **does not declare
the epic complete**. It says what each completion condition rests on, which slices delivered it, what kind of proof each
slice has (headless, offscreen or native), which prerequisites are merged and which part is this slice's own pending
pull request, and what is still owed. Tracker closure belongs to the authorized manager and owner. A filed issue, a merged
slice or an all-green headless run is not evidence of a displayed quad: only the native rows below are.

Three kinds of proof are kept apart throughout:

* **headless**: the real Lua, content, request, texture-pipeline and window-provider code over stand-ins for the device, the
  windows and the host, with explicit synchronization (the package suites and `test.vulkan-headless`);
* **offscreen**: the real device rendering Lua-authored scenes into a managed target whose pixels are read back after the
  batch's own completion (LFE-24, [the evidence](../lfe24-offscreen-pixels/README.md)); no window, no screen;
* **native**: real windows on a real display with the device, through the built command or the public composition
  (LFE-22's smoke cases, the adapter's native suite, and LFE-25's `Lua native milestone`). Only the Linux isolated-X11 captures
  and the owner's macOS confirmations show what a window presented.

## The 28 delivery slices

The design's processing checklist lists LFE-1 to LFE-28 (LFE-26 was inserted after LFE-13, LFE-27 before LFE-24 and LFE-28
before LFE-25). Merged prerequisites are separate from this pull request.

| Slice | Title | Issue | Merged as | Proof class |
| --- | --- | --- | --- | --- |
| LFE-1 | Install the explicit filtered M1 library profile | #515 | PR #541 `16f6d63f` | headless |
| LFE-2 | Add opt-in recoverable binding validation and refusal | #516 | PR #542 `4b8dbc38` | headless |
| LFE-3 | Parse the strict manifest and validate the fixed M1 profile | #517 | PR #543 `e61d657e` | headless |
| LFE-4 | Own anchored native content roots and no-follow reads | #518 | PR #544 `f0146060` | headless |
| LFE-5 | Validate literal Unicode content identities | #519 | PR #546 `91baf8a3` | headless |
| LFE-6 | Build and verify the bounded whole-folder inventory | #520 | PR #550 `849581e9` | headless |
| LFE-7 | Reserve M1 requests and results atomically | #521 | PR #548 `a737fa85` | headless |
| LFE-8 | Retain VM-local module exports and captured behaviors | #522 | PR #547 `bf9cbd84` | headless |
| LFE-9 | Resume ordered module import chains on their VM owner | #523 | PR #551 `4bde0c9b` | headless |
| LFE-10 | Load raw data through owned bounded file workers | #524 | PR #553 `ad173c17` | headless |
| LFE-11 | Join shared module jobs and deliver them at assigned positions | #525 | PR #561 `61db59dc` | headless |
| LFE-12 | Bind per-instance content, request, time and output APIs | #526 | PR #566 `965140ba` | headless |
| LFE-13 | Coordinate role startup gates, failure policy and session stop | #527 | PR #567 `976d5356` | headless |
| LFE-26 | Expose UI status, quit and the unavailable-state guard | #528 | PR #571 `8a3b187c` | headless |
| LFE-14 | Preflight static PNG structure and bounded inflation | #529 | PR #545 `8c6b19cf` | headless |
| LFE-15 | Decode the approved PNG variants within accounted workspace | #530 | PR #549 `ad559cf7` | headless |
| LFE-16 | Own texture pipeline lanes, leases and byte reservations | #531 | PR #560 `a4b8b911` | headless |
| LFE-17 | Finish texture requests through real GPU readiness | #532 | PR #565 `8339d4b7` | headless, and real device in the adapter's native suite (`test.vulkan-lua-engine-native`) |
| LFE-18 | Create and retire instance-owned windows asynchronously | #533 | PR #570 `5b45863b` | headless, and real windows in the adapter's native suite (`test.vulkan-lua-engine-native`) |
| LFE-19 | Validate and copy the fixed M1 scene schema | #534 | PR #564 `ec5660f3` | headless |
| LFE-20 | Publish scenes with completion-safe texture retention | #535 | PR #572 `13d2a133` | headless, and real device in the adapter's native suite (`test.vulkan-lua-engine-native`) |
| LFE-21 | Expose the complete UI-only graphics facade | #536 | PR #573 `f9ef4038` | headless, and real device in the adapter's native suite (`test.vulkan-lua-engine-native`) |
| LFE-22 | Assemble the generic run command and Lua quad content | #537 | PR #574 `868d82e1` | headless, and native launch/lifetime smoke of the built command (`test.vulkan-run-native`) |
| LFE-23 | Qualify integrated failure and two-instance ownership headlessly | #538 | PR #575 `342e11ac` | headless integrated qualification |
| LFE-27 | Give a surface-free scene target the host's scene barrier, ledger identity and adopt/release lifecycle | #576 | PR #577 `941f0e88` | headless host cases, and one real-device case that renders no window |
| LFE-24 | Verify Lua-authored output through offscreen pixels | #539 | PR #578 `b7822bbd` | **offscreen**: real pixels read back from a managed target on a real device (`test.vulkan-lua-engine-native`); no window |
| LFE-28 | Select optional Vulkan validation for `hetoimasia run` and record what actually loaded | #579 | PR #580 `7597eb5f` | device-free plan examples, and native cases of the built command (`test.vulkan-run-native`) |
| LFE-25 | Qualify native windows, independent retirement and quit | #540 | **merged** (#582, `4f5c3b40`) | **native**: Linux isolated-X11 captures and the actual command's close (CI receipt); macOS unattended receipt; macOS owner confirmations **confirmed** ([record](macos-owner-confirmations-record.md)) |

## The completion conditions of #514 (Required M1 behavior)

| # | Condition | Delivered by | Proof and where |
| --- | --- | --- | --- |
| 1 | Trusted, filtered execution | LFE-1, LFE-2 | headless; the confinement of hostile code is deferred and not claimed |
| 2 | Boot and content identity (strict manifest, anchored root, literal identities, whole-folder hash) | LFE-3 to LFE-6, LFE-22 | headless; the actual command prepares the shipped folder in every native case (the `content root resolved` barrier) |
| 3 | Modules and hooks | LFE-8, LFE-9, LFE-11, LFE-12 | headless |
| 4 | Clocks, startup and failure | LFE-12, LFE-13, LFE-26 | headless (LFE-23 `Integrated endings`); native: a logical failure leaves the UI on the exact red clear until the close, and the command exits 1 (LFE-25) |
| 5 | Bounded asynchronous services | LFE-7, LFE-10, LFE-11, LFE-16, LFE-17 | headless; native: the same PNG requested by two instances is two independent allocations (LFE-25) |
| 6 | UI-only graphics (window, texture, scene, retention) | LFE-14 to LFE-21, LFE-27 | headless; offscreen pixels (LFE-24); native: quad, resize clipping without stretching or re-centring, restore, independent retirement (LFE-25) |
| 7 | Status, output and quit (0, 1, 2, 130) | LFE-13, LFE-22, LFE-26 | headless; native: Lua quit exits 0, a genuine native close exits 0, an orderly SIGTERM exits 130 (LFE-22), a native close of either harness window is one session quit (LFE-25) |
| 8 | Concrete accounting (the fixed profile) | LFE-3, LFE-7, LFE-14 to LFE-16, LFE-19 | headless; the native cases run under the fixed profile unchanged |

## What LFE-25 adds (this pull request, pending merge)

* A named, nonempty `Lua native milestone` subgroup in `run-native-tests`, selected by `--match 'Lua native milestone'` and part of the
  catalog group's `--complete` profile (`test.vulkan-run-native`), with a test-only isolated-X11 window helper
  (`tools/x11-window/x11_window.py`, no product interface, no VK-19 change) whose device-free examples run in `test.workflow`.
* Real-device **two-instance** cases (one UI VM, two engine-owned instances of the shipped content, an independent logical
  owner with its own VM and an owned exact-tick pump whose status the UI reads from its real instance, one PNG path requested by both) over a host the suite composes with the validation layer and synchronization validation, judged
  by a diagnostic verdict that fails on any issue; instance ended with its accepted scene referencing a released texture; ended
  with its texture read held and with its window creation outcome withheld; peer kept live and correct; user close of either window is one
  session quit; an injected (labelled) clean refusal beside a live peer; the initial empty window observed while its read is held and then
  the quad in the same window; and machine-readable lifecycle records (texture identities from the scene ledger; each disposal of a window's graphics placed among the host's frame events and
  judged against the submissions and presentations that preceded it) asserted at each disposal.
* The **actual command** (`run --vulkan-validation`) as an owned child: native close by `WM_DELETE_WINDOW` to its exact window (exit 0),
  the logical-failure red clear (exit 1), Lua quit (exit 0), each judging the validation record, the layer's announcement and the
  absence of lost-records warnings.
* View adaptation with an unchanged published scene (smaller, larger, minimize, restore) with the metrics actually reported.

## Still owed, and limits

* **macOS owner visual confirmations** (the quad in both windows, resize clipping, peer survival, the actual command's quad and
  close) are **confirmed** (all six, once, at the approved head `f7ffd77a`, run by the manager with the owner present). The pull request
  carried [the pending entries](macos-owner-confirmations.md); [the confirmation record](macos-owner-confirmations-record.md) supersedes them.
* The **native zero-area framebuffer row is unexercised** on both receipts' platforms (a minimized window's framebuffer was not reported with zero area); the controlled zero-metrics coverage belongs to LFE-18, LFE-20 and the host's suspended-target cases and is not
  claimed here as native.
* A restored window once stayed undrawn on macOS until something sampled it again ([#581](https://github.com/coghex/hetoimasia/issues/581), fixed in `bb163cfa`); the restore case is now its regression check.
* The exit status of a session that meets a *real* window-creation failure is the owning slices' (a labelled injected clean refusal is
  used here); device loss and out-of-memory are not induced.
* No new Wayland, hardware-support or performance claim.

## Deferred by the epic and not implemented

Mods and activation, a gameplay-state store and replay, hot swap, hostile-code confinement (the seven #145 confinement slices),
general input, widgets and fonts, audio and 3D, and the broader services beyond the fixed M1 profile.
