# GLFW upgrade and backport retirement

Capture the owner's approved direction: retain PR #235's working backport for
that repair, then qualify a current upstream GLFW release and remove the
temporary backport. This report may remain in the backlog; it does not block
#235 or authorize implementation.

Status legend: `[ ]` unprocessed · `[#N]` filed as issue N · `[no-issue]`
reviewed and deliberately never to be filed · `[deferred]` blocked on a
concrete precondition

## Methodology

Inspected master `07b982a` and PR #235 at `b3d227b544674764130e683e9756664efd31a3b8`,
including provisioning, package bounds, patch handling, Hspec coverage and
native-session checks. The owner reports the backport works; this report adds
no new native qualification or PR approval. Release information was checked on
2026-09-20. Rechecked on 2026-09-22 at `master@da81087`: PR #235 is merged,
the backport remains in the native recipe, and upstream still lists 3.5.1.
Tracker deduplication and disposition remain for `process-report`.

## Status

- [ ] GLFW-UP-1. Upgrade GLFW and retire the temporary no-seat backport

---

## Dependency maintenance

### GLFW-UP-1. Upgrade GLFW and retire the temporary no-seat backport

The project pins GLFW 3.4. PR #235 applies upstream commit
`3573c5a890b4878bb7357f71daaf49260c6fef15` to fix initialization when a Wayland
compositor advertises no seat. Retaining that repair is useful now, but carrying
a patched older release indefinitely adds maintenance and misses other
upstream fixes.

GLFW 3.5.1 is the current stable release at this report's baseline. It includes
the no-seat fix, additional Wayland event/input fixes, and a new Cocoa
QuartzCore link dependency. It is a candidate, not a permanent target:
recheck upstream when processing and again when solving.
Sources: [GLFW downloads](https://www.glfw.org/download.html) and
[version history](https://www.glfw.org/changelog.html).

**Evidence:** Paths below refer to the inspected PR head.

- `tools/native/glfw.pin:5` pins 3.4.
- `tools/native/patches/0001-wayland-fix-segfault-when-there-is-no-seat.patch:3`
  identifies the upstream backport.
- `tools/native/native.py:52` introduces patch handling; discovery, fingerprinting,
  native identity and application appear at lines 137, 158, 296 and 586.
- `hetoimasia.cabal:52` includes the patch in source distributions;
  `tools/test/CiImage.hs:120` begins its dedicated workflow tests.
- `packages/glfw/hetoimasia-glfw.cabal:84` excludes GLFW 3.5; line 89 declares
  the current macOS frameworks.
- `packages/glfw/native-tests/Test/GLFW/Native/Session.hs:59` covers native
  Wayland selection and the unavailable X11 check helpers. Those behavior
  checks remain valuable after the patch disappears.

**Handoff context:**

- **Target and timing:** Recheck master and #235's disposition first. Qualify the
  newest upstream release against the project's supported platforms, following
  its existing release-candidate policy where applicable; pin the selected
  version and source checksum. Do not use a floating development branch or
  silently retain 3.5.1 if a newer suitable release exists.
- **Complete removal:** Verify the selected upstream source contains the fix.
  Remove the backport file, its packaging entry, and all code, identity fields,
  comments, fixtures and tests introduced solely to discover, apply or account
  for it. Preserve native regression coverage and general provenance checks.
  If later work gives that machinery another active consumer, explicitly
  reconcile its ownership rather than deleting unrelated patches or leaving
  this backport's scaffolding unexplained.
- **Reproducible provisioning:** Update bounds, generated-link checks and actual
  platform dependencies. Rebuild the private prefixes and cached public Linux
  image; commit the verified descriptor. Old patched archives, linked products
  and test receipts must not qualify the new configuration. Preserve current
  provisioning changes, including any Vulkan inputs added meanwhile. Coordinate
  the recipe/image changes with [#208](https://github.com/coghex/hetoimasia/issues/208)
  and retain the evidence identity needed by
  [Wayland #207](https://github.com/coghex/hetoimasia/issues/207);
  these are shared-input coordination concerns, not a
  requirement to finish the entire Vulkan or Wayland arcs before upgrading.
- **Qualification:** Run affected headless Hspec/workflow groups and real Linux
  X11 and isolated Wayland checks, including no-seat session entry and helper
  behavior. Run relevant Cocoa checks locally with explicit human approval
  before desktop disruption (superseded on 2026-09-26: the owner gave standing approval for desktop-disrupting native runs an issue or pull request needs; see [AGENTS.md](../AGENTS.md)). Request necessary optional groups explicitly;
  unavailable evidence is not success. Recheck any delivered Vulkan/GLFW bridge
  affected by the upgrade. Keep remote CI Linux-only and Windows deferred.
- **Contract reconciliation:** Audit version-dependent capabilities, native shim
  assumptions and current comments/docs against the selected source. Preserve
  main-thread GLFW ownership, explicit backend selection and lifetime rules.
  Historical measurements retain their original version labels. A newer GLFW
  alone proves neither complete Wayland support nor Cocoa modal-loop progress.
- **Delivery:** Prefer one focused code-and-documentation PR if qualification
  stays bounded. Let processing choose a larger design only if refreshed
  evidence warrants it. Required evidence and documentation belong in that PR.
- **Remaining uncertainty:** The release available when work begins, intervening
  provisioning changes, and platform qualification results. No upgrade was
  implemented or tested by this report.
