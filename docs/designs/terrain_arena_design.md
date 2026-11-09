# Terrain arena design

Begin recreating Ecce Homo on Hetoimasia with flat terrain and on-demand
chunk loading as the camera explores an expanding procedural arena. Synarchy's
testing arena is the concrete reference. The owner
chooses behavior in this design conversation; existing Synarchy implementation
choices are evidence, not automatically requirements for the new engine.

Design state: `ready for issue processing`

Atlas update, 2026-11-08 local (D-61/P-17): every texture is an atlas, with a
single image represented by a one-region atlas. TRA-17 owns deterministic
asset packing and region-aware material/picking integration; the authored
96×64 maps remain unchanged. Texture admission follows the merged byte
banks, not a texture-count ceiling. The manager directs the #659 amendment
first, then #645/#646/#647, each with separate tracker sign-off.

Owner-requested face-map amendment opened 2026-11-07 (D-28) and signed off
2026-11-08 (D-60), approving P-16 at `b012fabbfc`. TRA-1–TRA-12 remain filed;
all 11 amendment children, TRA-13–TRA-23, are now filed as [#655], [#656],
[#657], [#658], [#659], [#660], [#661], [#662], [#663], [#665] and [#666].
No unprocessed new children remain; P-16 revisions to existing artifacts
remain. The amendment is ready for issue processing. Each tracker draft still
requires separate sign-off; no tracker mutation, implementation or PR-hold release
is authorized by this design sign-off.

Lighting scope resolved by D-29: expose sun position to the face-map shader
for previewing the tiles; defer the automatic day/night cycle and eventual
moon lighting. D-60 resolves Q-19's delivery/revision plan and fresh readiness
checkpoint. D-55/D-57/D-58 specify
sampling, lighting and cell-quad presentation; D-59 approves the concrete
storage/discovery contract in P-15 and resolves Q-20's specification. P-16
contains the approved follow-up and existing-issue revision plan. Its 11 new
slices are promoted into the dependency-ordered ledger and delivery plan.

Picking scope resolved by D-30: select from the adopted drawn quads in
front-to-back order using matching artwork/face-map coverage. D-49/D-50/D-58
complete Q-16's geometry, emission, cutaway and visual/logical API specification;
the required implementation and visual proof remain outstanding.

D-31 preserves generic blank terrain as gameplay fog of war over undiscovered
underground solids and air gaps, and reaffirms lazy loading with gaps.
D-58/D-59 now complete the fog, discovery and retention specification.

D-32 chooses whole-cavity discovery: unsealing a connected empty space reveals
that space and its newly exposed boundary terrain, including across chunks.
D-51 refines its original exhaustive-loading requirement: retain compressed
whole-space knowledge and load tile detail only on camera or explicit demand.
Work proceeds in bounded steps under the approved P-15 execution/storage contract.

D-33 resolves discovery retention: record revealed state as chunk changes,
retain it on offload and replay it before publishing the reloaded chunk.
Discovery lasts for the arena session while off-screen chunks stream normally.

D-34 resolves connectivity between empty cells: six shared-face neighbors;
edge-only or corner-only contact does not join cavities. Partial openings
around shaped terrain use the approved P-9 geometry and P-15 connectivity.

D-35 requires explicit logical opening rules for ramps/corner slopes: a real
diagonal opening into an unrevealed space must discover it. Whole-air-cell
adjacency alone is insufficient; P-9 specifies the approved per-shape catalog.

D-36 chooses one logical shape authority shared by cavity discovery and
terrain point/ray queries, correcting the existing solid definitions.
Rendering and screen picking retain face-map coverage as their visual authority.

D-37 makes generic blank fog tiles non-interactive and unselectable. They
occlude picks of hidden terrain and produce no player-selectable target.

D-38 makes sky and initially sky-connected cavities discovered from the start,
without requiring their residency. Concurrent openings of a previously sealed
cavity must share safe bounded discovery, never expand across the open sky.

D-39 approves the shared discovery-work mechanism: distinguish unseen,
pending and expanded regions; share overlapping fronts, seed new edit-created
connections and stop only outward branches at known exterior.

D-40 approves temporary per-arena disk backing for retained edits/discovery,
with a bounded RAM cache and asynchronous I/O. The store is session-only and
discarded on arena close/reset; D-59/P-15 specifies quota, failures and lifecycle.

D-41 approves pausing new edits/discovery on storage exhaustion or write
failure, retaining acknowledged changes and unfinished work. D-43 subsequently
selects startup reservation and a hard disk allowance; D-59/P-15 fixes recovery.
D-42 records the manager-relayed CPU budget increase and best-effort camera
demand; it does not select the temporary store's disk quota.

D-43 approves a reserved, configurable disk allowance before arena opening,
including storage overhead, and refusal when it cannot be reserved. Keep the
world expandable; pause new edits/discovery before exceeding the allowance.
The allowance and storage mechanism are specified by D-59/P-15, with proof due.

Additional Q-16 finding: the pinned N/E mask silhouettes fail a cross-facing
unit-cell geometry consistency check. The audit below records a concrete
counterexample. D-44 approves correcting inconsistent masks while preserving
all 16 IDs, conditional on solver-delivered proof. The exact replacement
logical catalog is approved by D-49/P-9; no artwork or code has been changed
in this design turn.

D-45 selects crisp nearest-neighbor sampling for terrain colour artwork and
face maps, with the same alpha cutoff for rendering and screen picking.
D-55/P-11 specifies exact sample/edge conventions, data loading and ownership.

D-46 selects Lua-supplied sun compass direction and elevation, fixed relative
to the world as the camera rotates. D-57/P-13 specifies appearance defaults
and depth effects; no UI or automatic cycle is added.

D-47 keeps both depth darkening and blue haze, adjustable/disableable through
Lua, and requires stronger numerical, offscreen and navigation regression
coverage. The owner reports the reference behavior does not work well; a
specific symptom is now recorded in P-10: expected hazed background terrain
is absent outside the camera loading radius. Source inspection supports a
load/view mismatch; no runtime reproduction is claimed.

D-48 approves viewport-driven terrain demand and view-aware eviction within
the existing budgets. The face-map integration must prove that visible hazed
background terrain is requested and retained when capacity permits.

D-49 approves P-9's illustrated 16-shape catalog: named edges are lowered to
the base; ID 15 is a central half-height peak. The exact table is the logical
target for corrected masks, discovery and queries; solver proof remains required.

D-50 resolves cutaway caps: hide levels above the selected slice, preserve
remaining known tiles' actual shapes/materials, and add no flat caps. Unknown
regions keep generic blank fog; moving the slice does not discover them.

D-51 separates whole-cavern knowledge from detail residency. Discover and
retain the connected space and exposed boundary in compressed form; materialize
tile/render detail on demand. Completion does not require visiting every
boundary tile, and unproved connections remain pending.

D-52 allows explicit Lua requests to increase a live arena's reserved storage
allowance. Reserve the extra space before increasing the cap and resuming
capacity-paused work; failed increases preserve the old cap, state and pause.

D-53 requires bounded exact connectivity preparation before arena opening
succeeds. Build a compact summary from the source recipe without generating
underground tiles; clearly refuse over-budget preparation. The required flat,
gap and shape cases must be supported and proved, not excluded as a shortcut.

D-54 gives ambient illumination its own Lua control. Changing only the sun
position leaves ambient unchanged; future Lua day/night rules may animate
both. D-57/P-13 specifies the approved lighting defaults and equations.

D-55 approves P-11's cutout asset/sampling contract, including bounded
`kind`/`coverage` texture options, shared versioned CPU bitplanes and required
CPU/GPU edge agreement. Q-17 is specified; implementation proof remains due.

D-56 selects surface-normal RGB lighting in the same RGBA cutout texture.
Normals follow the approved shape geometry and world-fixed sun; P-11's
alpha, sampling and ownership contract remains. Exact encoding/equations are
specified by P-13, approved through D-57.

D-57 approves P-13's numerical lighting contract: validated normal encoding,
Lua settings/defaults, world-fixed diffuse/ambient shading, fixed depth range
and linear-light darkening followed by haze. Q-18 is specified; solver
qualification and owner visual acceptance remain required.

D-58 approves P-14's whole-cell emission, complementary ramp/fog masks,
exact ordering, conservative demand/culling and visual picking contract.
Fog stops picking with `no_hit`; unavailable knowledge remains `loading`.
Q-16 is specified. The separate P-15 storage/discovery contract is now
approved by D-59.

D-59 approves P-15's exact compressed connectivity, bounded preparation and
temporary-store transactions, including the configurable 1 GiB reservation,
write-before-acknowledgement, Lua status/growth/retry and failure/teardown
contract. Q-20 is specified; solver qualification remains mandatory.

D-60 records the owner's final amendment sign-off, approves P-16's delivery
boundaries and retains Q-13 as an implementation proof gate. There are no
remaining blocking design choices. PR #654 remains held for manager-coordinated
baseline completion; all later tracker drafts require individual approval.

Owner sign-off: Q-12 approved for `398a58f35c`, relayed by verified
`het-manager` in `#het-terrain` at 2026-11-07T02:13Z (2026-11-06 local),
message `39em862uwqaj3x3t4dn9kipeta`: “i sign off on this”. D-27 records the
scope. Q-13 remains an in-delivery renderer-proof gate, not a readiness blocker.

Migration review disposition: D-23–D-26 separate automatic headroom from
manual cutaway, retain Synarchy's full mask set, explicitly defer later game
integration, and select adaptive sparse storage. Q-12 is resolved by D-27;
Q-13 retains the rendering proof gate.

Status legend: `[ ]` unprocessed · `[#N]` linked to issue N · `[no-issue]`
reviewed and deliberately not tracked separately · `[deferred]` blocked on a
concrete precondition

## Processing status

- [x] EPIC. Establish Ecce Homo's flat terrain with on-demand chunk loading — [#636]
- [x] TRA-1. Define terrain coordinates and shared shape geometry — [#637]
- [x] TRA-2. Implement layered sources and compressed terrain changes — [#638]
- [x] TRA-3. Define bounded horizontal and vertical residency — [#639]
- [x] TRA-4. Implement the transactional terrain service — [#640]
- [x] TRA-5. Expose terrain requests through Lua — [#641]
- [x] TRA-6. Expose ordered window input to Lua — [#642]
- [x] TRA-7. Implement isometric cutaway planning and picking — [#643]
- [x] TRA-8. Qualify terrain materials and depth ordering offscreen — [#644]
- [x] TRA-13. Correct canonical shape geometry and expose exact opening portals — [#655]
- [x] TRA-14. Generate and qualify canonical cutout and normal-map assets — [#656]
- [x] TRA-15. Load validated data maps with shared versioned CPU coverage — [#657]
- [x] TRA-16. Build pure cell-quad planning and coverage-based visual picking — [#658]
- [x] TRA-17. Switch terrain rendering to face-map cutouts and normal lighting — [#659]
- [x] TRA-18. Compile bounded symbolic source connectivity — [#660]
- [x] TRA-19. Model compressed knowledge and resumable discovery after removal — [#661]
- [x] TRA-20. Define bounded copy-on-write store records and transactions — [#662]
- [x] TRA-21. Own reserved backing files and bounded asynchronous storage I/O — [#663]
- [x] TRA-22. Commit terrain edits and discovery through the temporary store — [#665]
- [x] TRA-23. Expose terrain storage status, growth and recovery through Lua — [#666]
- [x] TRA-9. Publish retained terrain views with safe GPU retirement — [#645]
- [x] TRA-10. Expose terrain views and camera controls to Lua — [#646]
- [x] TRA-11. Assemble the authored terrain arena — [#647]
- [x] TRA-12. Qualify the arena and remove the development shortcut — [#648]

D-60 approves the amended delivery plan and readiness. Checked entries mean
already filed, not implemented; their original issue links are preserved.
All 11 amendment children are filed; zero unprocessed new children remain.
P-16 revisions to existing artifacts, including #645–#648 despite their filed
marks, remain separately approved work. Filing does not complete implementation
or the EPIC.

**Amendment EPIC revision applied 2026-11-08:** existing [#636] now carries
revision v1, approved by `het-manager` in `#het-terrain` message
`wwkfu39cnxfmw3ttbhtx22vg7n` (reply to draft `566cjfrmaw8t29thusvzu67vps`).
The exact replacement body was verified after editing; SHA-256:
`d34f0dc7bbab4a54facf05d25d3ca92a4edd9e058be24746e7238f947846c90f`.
Title, labels, state and other issue metadata are unchanged. All existing
child links and ledger markers were preserved; eleven new children remained
unprocessed at that revision. It released no PR hold and granted no readiness review.

**TRA-13 filed 2026-11-08:** [#655], approved by `het-manager` in
`#het-terrain` message `2zkf5xt9zpne5zb3eysywb99ma` (reply to draft
`fma957hskub7y27a2v2sp9e5ba`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`d30d3255ebe0f984c41c7a416eaf2c97f032c4343fd90e62d9153719559eb2ac`.

**TRA-14 filed 2026-11-08:** [#656], approved by `het-manager` in
`#het-terrain` message `vp53iynsdus9phrq5ich77gtba` (reply to draft
`32cfvw7rnwzhieiuamni8asjve`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`ca33bad215e8acf5adfa6338cac121d6877bed69211831acffa1efbe94976632`.

**TRA-15 filed 2026-11-08:** [#657], approved by `het-manager` in
`#het-terrain` message `5tjnrgaxwrhijw4i2crywvjkea` (reply to draft
`wnyhj3phbp8ppqzrgzw69f3jw6`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`c2c5d079cab3ff0cd7682ebff65e9d87e26a6032711a28a84d9d3f5950803153`.

**TRA-16 filed 2026-11-08:** [#658], approved by `het-manager` in
`#het-terrain` message `9at5jrygfpsus7e37zpwgvqdbi` (reply to draft
`up8q7g4j85cdakshhqtme35hde`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`fabca059a16775adf711f46103006330b48a6e9a2fda115f35de2ae92bb29fd6`.

**TRA-17 v2 filed 2026-11-08:** [#659], approved by `het-manager` in
`#het-terrain` message `93xhzsspm6zrw2vfegsjtyjxsw` (reply to draft
`kdfyguuz7igf3zcbmrmjqhveua`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`34e91707f4389d8ea2aa9f492fd46c6799778dd93bf44391bd9130e2b86968b9`.
The v2 draft includes the manager-requested native-CI time constraint from
`docs/vision.md:253`, without amending that limit or raising a watchdog.

**TRA-18 filed 2026-11-08:** [#660], approved by `het-manager` in
`#het-terrain` message `u8vqe9zkryzvkaiz2zfsz58kgw` (reply to draft
`rcxiccqkbaaixeeauv27m2buqe`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`bada9c4e1c9910c2ba35090d7ad26947ec1ea9a7cfc2b9e3ecd3c1a67ec280b2`.

**TRA-19 filed 2026-11-08:** [#661], approved by `het-manager` in
`#het-terrain` message `qcmif2gdremh93tmnz72rydj3s` (reply to draft
`v7ribw2n994bgzxxwdfitaq2h6`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`ccfa78b2b8a9716ce76a6de4e1076a2f29b1af155d74c012f8482c1295aad94f`.

**TRA-20 filed 2026-11-08:** [#662], approved by `het-manager` in
`#het-terrain` message `fpq5gyth4jzfh2ehh2mcr9yfg2` (reply to draft
`xgejcth2ghpz8sjx2qw6tjg5ps`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`251cbd30b6eb6256e9a23ded148a6a3f522d7643ba16cda43e61eeb74bd623e6`.

**TRA-21 filed 2026-11-08:** [#663], approved by `het-manager` in
`#het-terrain` message `ie9dpn2fim377epha74cgwhcc2` (reply to draft
`c63aj65m9ikz8keu2rzehi8jua`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`ad57d8ca975737e2bda988ca088a53ff978619326ee3ab63ff762b36270225d5`.

**TRA-22 filed 2026-11-08:** [#665], approved by `het-manager` in
`#het-terrain` message `p8r8fjsu38z92er2my73q55xh2` (reply to draft
`phgxf72qwkzneb8hirrmds3ig2`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`9e48e5526a130dd92e609623aed926d0423834f4ace05a8f34c18b93ac1f48b5`.

**TRA-23 filed 2026-11-08:** [#666], approved by `het-manager` in
`#het-terrain` message `5uymu8d9jy58dht8ikgrwgi6ea` (reply to draft
`pnfuevnfnmmrvceb2q8dpe85na`). The issue body and EPIC checklist link were
verified after filing; approved body SHA-256:
`4b1d473dfb570a46617b7adcb5f91239b378403c2041590eea2fb7b3c96ea857`.

**TRA-9 amendment revision applied 2026-11-08:** existing [#645] now carries
P-16 revision v1, approved by `het-manager` in `#het-terrain` message
`j4v9ma6x5misrmd92d2qhwifis` (reply to draft `s46k94ntu2z67twigqtd69myki`).
The exact body-only replacement and unchanged tracker metadata were verified;
approved body SHA-256:
`c57fa768f2f962fcd892da31c3c47120d03f2d9905fa4645454eac5a086adb62`.
The manager arranges fresh readiness review; this revision is not implementation
or amended Q-13 qualification.

**TRA-10 amendment revision applied 2026-11-08:** existing [#646] now carries
P-16 revision v1, approved by `het-manager` in `#het-terrain` message
`vvahwinsz8z8ej2yy7qt3439c2` (reply to draft `f973bwphs7ceg22gei9fse6yui`).
The exact body-only replacement and unchanged tracker metadata were verified;
approved body SHA-256:
`72828f2f11e8c5e7cf85a25fad7d417bbbb04ad1131f44309eaf3df2bf862998`.
The manager arranges fresh readiness review; this revision is not implementation
or amended Q-13 qualification.

**TRA-17 atlas amendment v1 applied 2026-11-09:** [#659] now carries the
[owner-decision amendment](https://github.com/coghex/hetoimasia/issues/659#issuecomment-6731497615),
marker `owner-decision:659-atlas-regions-d61-v1`. Verified `het-manager`
sign-off `vq4c36nz8dv9bpm6f3kja3ivew` approved draft SHA-256
`fbadf840d53726857680fc1f1e68468951b18904fa013e425283f7762ced8310`.
The manager's subsequent `request-user-het-terrain-20261106-1838-apply659-prompt.txt`
directs a comment amendment instead of editing the approved body and restores
the docs turn. The comment reproduces that draft verbatim under its scoped
supersession heading; comment SHA-256:
`c7f362568980a864d2a7f583fcfa3076ce2c3b157867e79601d726d0ea56d31f`.
The original body and tracker metadata remain unchanged. This records D-61/P-17
on the issue; the manager arranges fresh re-approval. It proves no implementation
or GPU result, and does not revise #645/#646/#647 by implication.

**TRA-11 amendment revision v2 applied 2026-11-09:** [#647] now carries the
[owner-decision amendment](https://github.com/coghex/hetoimasia/issues/647#issuecomment-6731605899),
marker `owner-decision:647-terrain-amendment-atlas-v2`. Verified `het-manager`
sign-off `4r2qt6345uzpye77pmjzeq5ghw` (reply to draft
`qjyr5xppvuk7i2e5f3569p8tz2`) and the subsequent apply647 dispatch authorize
this exact comment, with the approved issue body and metadata untouched.
Comment SHA-256:
`9ce282b154da0af1dbae667dda757afde32925f795c6029fae55f353c2ac1eab`;
verbatim effective-spec SHA-256:
`9e9b4d0b25e89dbac07dda1f67d3912bc0abdef3958b187c7f6805453ad121c9`.
The post and unchanged body/metadata were verified. This resolves the pending
texture clauses with D-61/P-17 atlases and #672's byte-only admission; the
manager arranges fresh re-approval. Prerequisite implementation and amended
Q-13 remain gates; this record is not implementation or visual qualification.

**TRA-9 amendment revision v2 applied 2026-11-09:** [#645] now carries the
[owner-decision amendment](https://github.com/coghex/hetoimasia/issues/645#issuecomment-6731831183),
marker `owner-decision:645-terrain-atlas-review-v2`. Verified `het-manager`
sign-off `kbi6eg44xay4h4kypzkuzrw256` (reply to draft
`t7jgs3k7vz56zzzqzxcasm3thw`) and the subsequent apply645 dispatch authorize
this exact comment, with the approved issue body and metadata untouched.
Comment SHA-256:
`fa70c693e4677fdf8dfa7baaf43b8787da82bb9582dfa16bb168d698ab7b42c9`;
verbatim effective-spec SHA-256:
`0371a56fa3a88005378b6ab597bd5ec4d9336f98e03390e6e8bbd620fe159770`.
The post and unchanged body/metadata were verified. This resolves the CHANGES
review's texture decision using D-61/P-17 and #672's unchanged byte banks,
and incorporates complete pre-claim parent/coverage checks, host-wide depth
accounting and the separate `--terrain-views-full` qualification command.
Numbered source references were rechecked at `b0e5e35c78`. Requirements 8–9
remain unchanged. The manager arranges re-approval; amended prerequisites and
Q-13 remain implementation/qualification gates.

**TRA-10 amendment revision v2 applied 2026-11-09:** [#646] now carries the
[owner-decision amendment](https://github.com/coghex/hetoimasia/issues/646#issuecomment-6731935937),
marker `owner-decision:646-terrain-atlas-v2`. Verified `het-manager` sign-off
`mnru9r5fb3xhuzgmeuwibd3x6a` (reply to draft
`q55ydyr9fgktedsgs3uszfv8yi`) and the subsequent apply646 dispatch authorize
this exact comment, with the approved issue body and metadata untouched.
Comment SHA-256:
`6d0c7585b2a8151f3af9c4db217aba7ffacd79b7d1d21cdff52d8c6e22137aec`;
verbatim effective-spec SHA-256:
`5e262f23110631edea7ecc6c59e6534dd3e6c269a4c0d8136911bf30140efd78`.
The post and unchanged body/metadata were verified. This carries D-61/P-17's
checked parent/region mapping, shared coverage, region-aware pick authority
and #672's unchanged byte-only admission through the Lua view facade. The
approved qualification alignment extends #645's `--terrain-views-full` mode
with Lua atlas judgments while retaining the required CI limit. Requirements
2, 5, 6 and 8 remain unchanged. The manager arranges re-approval; this is not
implementation or amended Q-13 qualification.

**Amendment processing cursor:** new-child filing is complete. #645 and #646
revision v2, #659's atlas amendment and #647 revision v2 are posted. The
manager's `request-user-het-terrain-20261106-1838-apply646-prompt.txt` directs a
stop after recording/reporting #646: **do not start another artifact until
asked**. #648/other remaining P-16 artifacts remain outstanding unless
separately confirmed. The manager arranges readiness reviews; this cursor
does not mark later artifacts complete or grant implementation/visual
qualification.

## Epic contract

- **Goal:** a real first terrain foundation for Ecce Homo: flat terrain,
  procedurally generated and loaded by camera/query demand as exploration
  extends the arena, using a complete terrain model that includes
  subsurface structure and gaps from the outset, with the engine/game boundary
  preserved. Flat describes the initial terrain source, not a surface-only model.
- **Done when:** the Lua-authored flat arena streams with
  camera and explicit query demand, supports the agreed cutaway/follow modes,
  uses the approved artwork, removes tiles through the Lua API, retains edits
  through horizontal/vertical offload and starts fresh in a new session.
  Authored gaps and slopes agree across queries, picking and captured renders;
  bounded-memory, cancellation and teardown checks pass. The temporary removal
  binding is gone, existing M1 behavior remains intact, and the required docs,
  test catalog entries and retained visual evidence have landed.
- **Users and operators:** the owner developing Ecce Homo, game authors using
  engine services, and later players of the recreated game.
- **Arc label:** None proposed.

**Approved amendment additions to the done condition (D-28–D-59):** the
final path uses canonical cell-quad cutouts and normal lighting, corrected
all-16/four-facing maps, exact shared coverage for screen picking, shaped
cutaways without added caps, and uninteractable fog over unknown solids and
air. Viewport-driven demand includes visible hazed background when capacity
permits. Opening proves bounded source connectivity; discovery retains whole
connected spaces and their exposed boundary without materializing all detail.
Edits/discovery survive offload through the reserved temporary store, with
the approved atomic settlement, pause/growth/retry and teardown behavior.
The final executable proves these contracts under normal operation and
failure, retains the required visual/resource evidence, and removes the
temporary shortcut. These are specification choices, not delivered results;
P-16/D-60 approves their delivery boundaries and the amended Q-13 gate.

## Current state and evidence

Inspected 2026-11-06. Hetoimasia evidence is `origin/master` at
`edd82f8e0aa8fd71edddd183b105dbac413fdeff` in `coghex/hetoimasia`;
Synarchy evidence is its clean current checkout at
`3777d437ea00e1302bf55162ad5693fee4879187`, `~/work/synarchy`.
Prefixes H and S below distinguish those repositories. File:line references
are pinned to these revisions. Synarchy has not been modified or launched.

| Verified current fact | Evidence |
| --- | --- |
| Synarchy contains both its engine and Ecce Homo, a colony/survival game. | S `README.md:3` |
| Terrain chunks contain 16 × 16 vertical columns with material, slope and vegetation data. | S `src/World/Chunk/Types.hs:72–94` |
| One arena generator supplies initial chunks, demand loading and reconstruction. Each base column has twelve granite cells below four loam cells, a flat top and seeded surface vegetation variants; fluids, flora instances and structures begin empty. | S `src/World/Generate/Arena.hs:2–33`, `:126–149`, `:212–232` |
| The default arena starts with 5 × 5 chunks and expands on demand; that startup footprint is not a world boundary. | S `scripts/test_arena.lua:188–207`; `src/World/Generate/Arena.hs:70–104` |
| Arena topology does not wrap. A caller may request finite dimensions; larger finite arenas also load their remaining chunks on demand, with absent cells outside their rectangle. | S `docs/engine_contracts.md:8200–8246` |
| Arena controls include zoom, rotation and vertical slice selection; Hetoimasia's selected behavior is recorded separately in D-12–D-14/D-18/D-22. | S `scripts/test_arena.lua:255–293` |
| Synarchy projects a diamond grid and has four camera facings 90 degrees apart. Camera input includes keyboard panning and middle-button dragging. | S `src/World/Grid.hs:220–236`; `src/Engine/Graphics/Camera.hs:22–37`; `src/Engine/Loop/Camera.hs:116–181` |
| Synarchy routes Shift-scroll to Z-slice input; arena slice input disables automatic Z tracking and increments/decrements the slice. Its inspected `camera.gotoTile` accepts two coordinates, computes a surface-based slice and enables Z tracking; it does not read an optional third Z argument. | S `src/Engine/Input/Thread/Scroll.hs:128–138`; `scripts/test_arena.lua:265–275`; `src/Engine/Scripting/Lua/API/Camera.hs:223–318` |
| Synarchy's renderer follows the terrain beneath the camera while Z tracking is enabled. Arena manual slice input disables tracking, the reset action restores it, and a zoom-map transition can also restore tracking. Rotation preserves the current tracking flag. | S `src/World/Render.hs:282–322`; `scripts/test_arena.lua:265–293`; `src/Engine/Scripting/Lua/API/Camera.hs:325–361` |
| Geological hydrology, settled-terrain processing, chunk composition and runtime fluid simulation are separate stages. Flat generation can avoid the geological work. | S `docs/hydrology_pipeline.md:24–43` |
| Hetoimasia's reusable renderer has world/UI views, cameras, depth, retained chunks and application materials. M1's Lua scene exposes only simple rectangles with a fixed camera, default material and one UI layer. | H `packages/render-2d/README.md:3–17`, `:59–69`; `packages/lua-engine/README.md:941–968`, `:1002–1011` |
| GLFW already supplies ordered input with explicit reset/acknowledgement, but the M1 Lua facade has no input binding. | H `packages/glfw/src/Hetoimasia/GLFW/Input.hs:1–26`; `packages/lua-engine/README.md:1042–1057`, `:1086–1101` |
| Scene acceptance, adoption and GPU completion are separate ownership facts. Terrain residency must not bypass those obligations. | H `packages/lua-engine-graphics/README.md:416–447` |
| Text/fonts are a separately selected future arc; beginning terrain does not automatically activate the full UI system. | H `docs/designs/render_2d_design.md:301–319` |
| M1 supplies no working gameplay-state store. The earlier example leaves schema, initial publication, tick failure, snapshots, ownership, determinism and compatibility open. | H `packages/lua-engine/README.md:1611–1634`; `docs/designs/gameplay_state_design.md:155–212` |

Follow-up inspection, 2026-11-06: H `origin/master` at
`45c54833a2c4ad361c252f92af02ad04f08b20ce`; S remains at the revision above.
The following are specific observed implementation choices, not a general
defect verdict on Synarchy:

- Air gaps already exist in `ColumnTiles`: interior air is stored in a
  contiguous vertical range, with separate material/slope/vegetation arrays
  (S `src/World/Chunk/Types.hs:72–94`).
- A loaded chunk also stores terrain-top and rendered-surface maps
  (S `src/World/Chunk/Types.hs:104–109`). The Lua `getTerrainAt(x,y)` query
  returns those two surface heights, not all solid/empty intervals
  (S `src/Engine/Scripting/Lua/API/WorldQuery/Terrain.hs:29–62`).
- `WeSetCell` writes an arbitrary in-range cell, or grows upward with air
  filling the gap, but returns the unchanged chunk below the stored column
  floor. It then recomputes top surfaces; structures use a separate overlay
  (S `src/World/Edit/Apply.hs:298–343`, `:412–438`). Do not copy those limits
  or overlay semantics without choosing their meaning for the new model.
- Synarchy's procedural column builder chooses its stored lower bound from
  the surface and neighboring elevations (`exposeFrom`), then allocates
  material/slope/vegetation arrays for that exposed range. Its current interior
  air entries still occupy positions in those arrays; this is distinct from
  compressing an entire air interval into a range record
  (S `src/World/Generate/Chunk/Columns.hs:100–115`, `:205–209`;
  `src/World/Chunk/Types.hs:72–80`).
- When newly loaded neighbors expose a deeper cliff face, Synarchy extends
  edge columns downward by repeating the lowest stored material. That is an
  explicit continuation rule, not reconstruction of arbitrary deeper geology
  (S `src/World/Slope/EdgePatch.hs:16–24`, `:95–109`).

Initial tracker overlap check, 2026-11-06: the open issue list contains #446
and #563; an all-state `terrain arena` title/body search returned no match.
No existing open terrain umbrella was found. Repeat at readiness; this is not
final per-slice deduplication. Synarchy's own terrain trackers are references,
not Hetoimasia delivery items.

Completion-pass inspection on 2026-11-06 used H `origin/master` at
`551c768405e0ce7f328e3d247bf131738b942b9d` and the same S revision above.
The open tracker still contains only #446 and #563; the all-state terrain/arena
search still has no match. This is umbrella overlap checking, not child issue
deduplication. No tracker mutation occurred.

- H already supplies bounded instance-owned asynchronous requests and explicit
  cancellation/result variants (`packages/lua-engine/request/Hetoimasia/LuaEngine/Request.hs:1–42`).
- H's session injects narrow services rather than a global environment
  (`packages/lua-engine/README.md:1332–1350`). Its graphics host distinguishes
  acceptance, adoption and actual frame completion
  (`packages/lua-engine-graphics/README.md:416–447`).
- H's renderer is pure and leaves isometric projection/facings/slices to
  adapters (`packages/render-2d/README.md:43–56`). Its material ABI changes
  fragment colour, not the vertex or depth interface
  (`packages/render-2d-vulkan/README.md:325–355`, `:948–953`).
- S's approved texture sources are
  `assets/textures/world/loam/loam.png` and
  `assets/textures/world/granite/granite.png`, loaded by
  `scripts/test_arena.lua:122–132`. Its slope face-map lookup contains 16 mask
  entries (`src/World/Render/Textures.hs:23–57`); this is reference artwork
  machinery, not a selected geometry specification for Hetoimasia.

## Desired experience and scope

**Accepted direction:** begin terrain for Ecce Homo using flat arena terrain
and demand-driven chunk loading. The full terrain model, including gaps,
belongs in the first version (D-4). Procedural elevation generation is deferred.
Compressed columns with demand-driven materialization are the chosen direction
(D-5). Rendering and game queries can both demand terrain; undemanded detail
stays unmaterialized (D-6). The rejected Beacon example is not the consumer.
The arena expands with exploration; camera loading initially materializes only
the top tile of each untouched column. Removal demands newly exposed terrain
without eagerly filling underground depth (D-7).
Development verification uses a temporary mouse-targeted keyboard shortcut
for tile removal, with no UI system or on-screen UI controls (D-8/D-9). Remove
the shortcut by task completion; the Lua removal API remains.
Changes survive chunk offload/reload within the current arena session, but
the arena is not persistent across sessions (D-10).
Depth should also extend on demand, with no designed bottom to the arena
(D-11). P-5 supplies the approved numeric limits and bounded residency contract.
Shift-scroll controls the cutaway level. A camera jump defaults to the
destination's top level unless its Lua command supplies a Z level (D-12).
Normal panning, zooming and rotation automatically follow terrain height
(D-13). Shift-scroll temporarily pins the slice during panning; a camera jump
without explicit Z restores terrain following (D-14).
The initial terrain foundation supports full blocks and slopes; the default
arena remains flat (D-15), with a configurable shallow soil layer above stone
that continues downward on demand (D-16).
Later decisions retain Synarchy's full 16 slope/mask IDs (D-25), separate
automatic headroom from manual cutaway (D-23), defer later-game integration
(D-24), and select adaptive sparse packed storage (D-26).

**P-1, navigation/loading direction accepted by D-7:** a visible terrain arena
that can be navigated, making camera demand and the resulting terrain
observable. Keep the first terrain source simple while designing proper
publication and lifetime. Exact camera controls, coordinate limits, appearance,
temporary key binding and exact Lua APIs are specified in P-5, approved by
Q-12/D-27 with the delivery order below.

**P-2, incorporated into the approved P-5 contract: one authoritative spatial terrain model.** Represent terrain
occupancy and its material/shape at positions in three dimensions, with gaps
and multiple separated solid regions at the same horizontal position. Surface
height, exposed faces and visibility are derived queries/caches with defined
consistency, not substitute terrain authorities. Distinguish known empty space
from unloaded/unknown terrain and outside-world positions. A flat arena fills
this same model procedurally; future elevation generation would populate it
differently.

D-5 and D-15 establish compressed tile columns with full blocks and slopes,
independently of dense physical allocation. This can express cave floors,
ceilings and overhangs. The exact slope set, terrain versus constructed
structures, vertical chunking and exact data representation were separate
decisions, now resolved for this arc in P-5/D-24–D-27 and Q-8/Q-9.

**Owner memory concern, 2026-11-06 — direction addressed by D-5:**

> i initially avoided the 3d cell because i was worried about having too much data, what would you say to that? by compressing airgaps and only holding the top terrain, we only hold in memory the basic structure, not every cell

The logical ability to answer about `(x,y,z)` does not require allocating a
record for each cell. P-2 must not be read as a recommendation for a dense
full-depth voxel allocation. This concern led to P-3 and the owner's subsequent
approval of its direction in D-5; P-5 supplies the physical layout and budgets
approved through Q-12.

**Proposal P-3: compressed vertical spans with bounded materialization.** Keep
columns, but describe solid/material intervals and gaps compactly. An
illustrative column could be stone at z=0–99, air at z=100–119, stone at
z=120–124, then air to the selected world ceiling. This needs a handful of
span boundaries instead of a separate record for each depth; exact integer
boundary conventions and representation are not selected by this example.
Uniform solid interiors can be compact just as air can. Gaps, cave ceilings
and separated spans remain queryable parts of the same model.

D-5 accepts this direction. This layout remains illustrative; P-5 contains the
actual physical representation approved through Q-12/D-27.

Distinguish three questions: what terrain exists, which terrain data is
materialized in memory, and which exposed faces are prepared for rendering.
An exposed-surface cache may be small, but material omitted beneath it needs
an explicit authoritative answer: a compact base definition, a deterministic
source fetched/generated on demand, or an explicit unavailable state. It must
not silently become air or lose a buried edit. D-7 selects a procedural source
for the arena; P-5 resolves its deep-terrain recipe and the eviction/retained-edit
boundary, as recorded in Q-3/Q-6/Q-9.

Span compression favors coherent layers. Highly fragmented materials/shapes
or alternating solid/air can require many spans; queries and edits also need
search/split/merge work. No compression ratio or speed is claimed. Account for
actual resident representations and derived render data when selecting bounds;
a chunk count alone does not establish a memory bound. Compare representative
flat, layered, hollow and fragmented cases before choosing physical storage.

**P-4, direction accepted by D-6: demand follows consumers.** Untouched
underground detail may remain uncomputed and unallocated until needed. A small
terrain definition/source and any retained modifications provide its meaning;
there is no requirement to precompute every underground column's spans. Known
air intervals likewise need no per-cell enumeration. Materialize only the
requested region and whatever bounded neighboring data its query requires.

Rendering is one possible demand producer. A future digging, collision or
other game query can need terrain that is not visible. Such examples explain
the contract; they do not add those systems to this arc. Unloaded terrain must
not be interpreted as air, and revealing or reloading the same terrain must
remain consistent with its source and retained edits. Rendering faces and CPU
terrain detail can have different residency requirements. D-6 selects the
demand-producer rule; exact request APIs, budgets and scheduling are in P-5.

## Decisions

The owner requested a fully filled design on 2026-11-06 and subsequently
approved the complete contract and delivery plan through Q-12/D-27. Earlier
decisions retain their original scope; D-27 supplies the final readiness sign-off.

### D-1. Start with flat terrain for Ecce Homo

Owner, directly in this pane on 2026-11-06:

> ok yes lets begin terrain, take a look at synarchy's terrain generation, it uses chunks that load, procedural elevations, we can skip that though, lets just start with flat terrain, if you look at synarchy it has a testing arena mode, we should implement this, tell me what you think

This selects terrain and the arena reference, deferring procedural elevations.
It does not select every feature of Synarchy's testing tools, its world format,
exact material stack, save compatibility or engine architecture.

The initiating owner request `user-het-terrain-20261106-1838` rejected Beacon
and named Ecce Homo as the game being recreated, with systems open to redesign
or reimplementation. The manager supplied no further design decisions.

### D-2. Demand-driven loading is foundational

Asked whether the first arena should load/unload chunks with camera movement
or keep its entire terrain loaded, the owner answered directly on 2026-11-06:

> loading on demand, that is the foundation

Do not replace this with an all-resident first version. Flat generation is the
initial source of terrain; chunk demand and lifetime belong to the foundation.
The demand source, admission/budgets, loading execution, publication, failure
policy and safe eviction contract still need design. No numeric cache limit,
thread model or unlimited-memory behavior has been approved.

### D-3. Use this document and supersede the earlier example

Owner, directly on 2026-11-06, answered “that is fine” to the explicit proposal
to create `docs/designs/terrain_arena_design.md` and mark the earlier gameplay
example superseded while preserving its unresolved state questions.
[gameplay_state_design.md](gameplay_state_design.md) retains that history.
Its Q-3–Q-9 and inherited decisions are not automatically implementation scope
for terrain; revisit the relevant boundaries as this consumer requires them.

### D-4. Establish the full terrain model, including gaps, immediately

Owner, directly in this pane on 2026-11-06, answering Q-1:

> yes, we need to get the whole terrain model in place from the beginning. including the possibility of gaps, so synarchy does this in a patchwork way, we need to implement correct from the start.

A surface-only first model is rejected. Include subsurface structure and gaps
in the initial terrain model; do not rely on retrofitting those through special
cases after a flat arena is delivered. Flat terrain generation remains the
initial source under D-1, and loading remains on demand under D-2.

The owner's description of Synarchy motivates a coherent replacement; the
inspection above establishes the narrower facts actually checked. This answer
does not select a cell/shape representation, physical storage scheme, numeric
vertical bounds, structural-support simulation or exact editing tools. The
remaining meaning and boundaries of the full model are refined in Q-8 and the
other open questions, rather than silently narrowed to a fixed solid column.

### D-5. Compressed columns with lazy materialization

Owner, directly in this pane on 2026-11-06, answering whether the compressed
column direction matches their intent:

> yes that fits, the thing that i liked that synarchy did was leave all the empty space uncalculated when it was unrendered, then tiles get loaded into memory as they are needed, without any memory loaded in that is underground, is something wrong with that approach?

Accept compressed columns and materializing terrain detail only as needed.
Do not require dense per-cell storage or eager computation of the underground
to satisfy D-4's complete spatial model. The owner specifically values leaving
unneeded space uncalculated. Their question asks whether this is sound; it
does not yet approve a visibility-only demand policy or promise literally zero
memory for the source definition, metadata or retained underground edits.
P-4 recommends the demand rule; Q-8/Q-9 retain representation details.

### D-6. Rendering and game queries can both demand terrain

Owner, directly in this pane on 2026-11-06:

> yes that sounds correct

This answers the recommendation to let rendering and game queries both
request terrain while leaving everything else unmaterialized. Visibility is
not the sole condition for loading: a consumer may request invisible terrain.
Loading the requested region does not require materializing all underlying
depth. An unloaded region is not air, and reloading must preserve the meaning
of the terrain source and any retained modifications. Specific gameplay
systems, editing tools and save/load remain separate scope decisions.

### D-7. Expanding procedural arena with camera demand and lazy exposure

Owner, directly in this pane on 2026-11-06:

> keep extending as you explore, this is how the testing arena works in synarchy (or should work according to my memory). the arena should be procedurally generated, and loaded in with the camera, so that only the top tile is defined and the rest underground remain not in memory until a tile above is removed

Choose an arena that keeps extending horizontally with exploration, rather
than the proposed finite rectangle. Camera movement requests new chunks from
a procedural source. D-1's initial flat surface remains selected: procedural
here means terrain supplied by a generation rule on demand; variable elevation
generation remains deferred. Coordinate representation and practical limits
still need specification; expansion is not a promise of infinite residency.

For untouched columns loaded by the camera, materialize the top tile only.
Do not allocate underground tile records or enumerate all buried spans.
Removing a tile demands the newly exposed terrain from the same source;
deeper untouched terrain remains unmaterialized. The complete gap-capable
model remains D-4/D-5, and D-6 still allows explicit game queries to demand
invisible terrain. A compact source definition supplies the meaning of
unmaterialized terrain without allocating its individual tiles.

Removal/reveal behavior is part of the terrain contract. Subsequent D-8–D-10
settle its development interaction and session-only retention, and D-21
excludes automatic shape edits.
For gaps and openings, exposure must include relevant neighboring side faces,
floors and ceilings rather than assume every removal merely lowers a single
height value. This follows from the agreed full model; it does not require
materializing the full surrounding underground volume.

### D-8. Keyboard shortcut for tile removal; no UI yet

Owner, directly in this pane on 2026-11-06, accepting the proposed initial
select-and-remove tile tool:

> yes sure, by keyboard shortcut, we dont want to implement any ui yet

Include an arena shortcut that removes one targeted exposed tile and exercises
D-7's lazy exposure behavior. Do not add a UI system, menus, toolbar, buttons
or other on-screen UI controls for this arc. The exact key and how the target
is chosen remain to be specified; accepting keyboard activation does not
choose mouse hover, click selection or a keyboard-controlled tile cursor.
Other editing tools remain outside the accepted scope. D-9 subsequently
settles mouse targeting and limits this shortcut to development verification.

### D-9. Temporary development shortcut; retain the Lua API

Owner, directly in this pane on 2026-11-06, accepting mouse targeting and one
tile removal per shortcut press:

> that is fine, this would be a dev only shortcut that we would soon delete when the task is done, leaving only the lua api call

Use the mouse to target an exposed tile and a keyboard shortcut to remove one
tile per press during development. The shortcut is temporary verification
scaffolding, not a shipped arena editing control. Remove its binding and
shortcut-specific glue by task completion, leaving the Lua tile-removal API
as the durable removal interface. The temporary control must exercise that
same API rather than a separate mutation path. Retain appropriate API-level
regression coverage after the shortcut is deleted. Do not infer deletion of
general camera/input or terrain-query capabilities from this cleanup.

The exact API name, arguments, result/failure semantics and temporary key
remain to be designed. No UI implementation is introduced.

### D-10. Session-only changes retained across chunk offload/reload

Owner, directly in this pane on 2026-11-06:

> yes that fits, the testing arena is not supposed to be persistent, but the loaded chunks will have to track the changes, then save thos changes on chunk offload, then reapply them on reload

Loaded chunks track their changes. Before offloading a changed chunk, retain
those changes in a store owned by the current arena session. Reloading
regenerates terrain from the same source and reapplies the retained changes
before the chunk becomes usable. Further edits and repeated offload/reload
must preserve all earlier changes, including removals, without resurrecting
deleted tiles. Untouched underground detail remains lazy under D-7.

Here, saving on offload means retaining changes for the current session;
the accepted scope does not require disk saves or recovery across application
restarts. Destroying the arena ends the store's lifetime, and a new arena
starts fresh. The store retains changes independently of resident chunk data,
so chunk eviction cannot discard them. Exact encoding, compaction, threading
and transfer/publication mechanics remain design choices in Q-3/Q-6/Q-9.

### D-11. Effectively unlimited depth, generated on demand

Owner, directly in this pane on 2026-11-06, responding to a proposed
configurable bottom versus terrain extending downward with digging:

> ideally it would be infinite, unless you see a reason why it cant be

Select the direction of no designed bottom: terrain continues downward as
needed. Lazy generation is compatible with this direction; no need to
allocate or compute an infinite column. A terrain recipe can define what
exists at a requested depth without enumerating intervening underground cells.
The finite-bottom recommendation is not selected.

This means effectively unlimited exploration, not infinite machine resources.
Coordinate representation, arithmetic/conversion limits and out-of-range
behavior remain explicit implementation choices. Do not silently wrap or lose
tile identity at large depths. No specific coordinate type is approved here.

Residency must work vertically too: descending must not require retaining
every previously visited depth in the same horizontal chunk. Recommend sparse,
bounded vertical residency within the compressed-column model and queries
restricted to demanded ranges, rather than traversal from the surface to the
requested depth. Exact partitioning remains Q-3/Q-9. Exposed geometry also
needs bounded preparation; a deep shaft must not force an arbitrarily tall
wall mesh to stay resident. Session edit storage remains D-10 and can grow
with edits; compression does not promise constant memory for arbitrary
modifications. None of these constraints requires a gameplay depth floor.

### D-12. Shift-scroll cutaway and optional Z on camera jumps

Owner, directly in this pane on 2026-11-06, accepting cutaway viewing:

> yes that works, i was thinking shift-scroll would change the z level of the cutaway, that should be how synarchy works, with the camera automatically snapping to the top level when the camera first jumps to a location, unless the optional z level was included in the camera move api command.

Include manual cutaway viewing, controlled by Shift-scroll. Terrain above the
selected plane is hidden rather than removed. The view demands needed terrain
under D-6 without materializing the full depth between the surface and slice.
The selected slice and terrain picking must describe the same displayed view.

The Lua camera move/jump command accepts an optional Z level. With Z omitted,
the camera initially snaps to the destination's top terrain level; with Z
provided, that level overrides automatic surface selection. The command must
work for an unloaded destination through terrain demand and must not
subsequently overwrite an explicit Z with a late surface lookup. Exact API
name/signature, loading publication and failure behavior remain open.

Synarchy confirms the Shift-scroll reference. Its inspected jump API has no
optional Z argument, so optional Z is a selected Hetoimasia requirement rather
than a claim of existing Synarchy parity. D-13 subsequently selects normal
terrain-following navigation and rejects the recommendation to keep the view
at a fixed Z through ordinary navigation. The detailed meaning of top level at
an edited or empty destination and scroll step/direction remain to be
specified. D-14 settles the manual-panning override and jump reset.

### D-13. Follow terrain during ordinary camera navigation

Owner, directly in this pane on 2026-11-06, correcting the fixed-Z navigation
recommendation:

> no, like synarchy panning zooming and rotation simply follow the terrain, so that we can move around hills without having to manually set the z slice level

Normal panning, zooming and rotation automatically follow terrain height.
Moving around hills must not require manually adjusting the cutaway level.
The previous fixed-Z navigation recommendation is withdrawn. Flat initial
generation remains D-1; this camera behavior must also accommodate varied
terrain heights and edits without requiring procedural hills in this arc.

D-12's manual Shift-scroll and explicit jump Z still apply. D-14 subsequently
settles the manual-panning exception and reset on a camera jump. Synarchy's
inspected implementation uses a tracking flag: Shift-scroll disables it, a
reset action restores it, and a zoom-map transition can also restore it.
That zoom-map transition is reference behavior, not an independently selected
Hetoimasia feature.

### D-14. Manual cutaway overrides panning until a camera jump

Owner, directly in this pane on 2026-11-06:

> in synarchy, if the z slice is set by custom shift scroll, then panning is temporarily overridden to allow for no changes, that is right, that works well, this then resets when we move the camera to a new spot

Shift-scroll selects a manual cutaway level and temporarily disables automatic
height following while panning. Panning still changes horizontal position;
it does not change the selected slice. Moving the camera to a new spot here
means the move/jump command discussed in D-12, distinct from ordinary panning.
A jump without Z clears the manual override, selects the destination's top
level and resumes terrain following. D-12's explicit Z argument takes
precedence when supplied, so such a jump uses the requested depth rather than
snapping to the surface.

| Action | Selected behavior |
| --- | --- |
| Normal pan, zoom or rotation while following | Follow terrain height (D-13). |
| Shift-scroll | Change cutaway Z and enter manual override. |
| Pan with manual override | Preserve the chosen cutaway Z. |
| Move/jump without Z | Clear override, select destination surface and follow terrain. |
| Move/jump with Z | Honor requested depth rather than automatic surface selection. |

No UI toggle or additional reset shortcut is selected by this decision.
D-22 subsequently settles zoom/rotation behavior during manual override;
do not import Synarchy's zoom-map reset implicitly.

### D-15. Full blocks and slopes in the initial terrain foundation

Owner, directly in this pane on 2026-11-06, accepting the recommendation to
include full blocks and slopes from the beginning:

> yea sure, that's fine

Include full blocks and slopes in the first terrain contract, with consistent
shape meaning for rendering, mouse picking and terrain queries. The default
arena remains flat. Use small authored slope cases to verify the contract;
procedural hill generation remains deferred. The exact slope catalog and
orientation rules and additional partial-height shapes are not selected by
this scope decision alone; D-21 settles no automatic reshaping and P-5 proposes
the exact catalog.

### D-16. Configurable soil-over-stone arena recipe

Owner, directly in this pane on 2026-11-06, accepting a shallow soil layer over
stone continuing downward, defined by a configurable recipe:

> yes that is what synarchy does too, i approve

The initial flat arena uses soil above stone, with stone continuing downward
on demand under D-11. Soil thickness and material identifiers are recipe
parameters rather than engine constants. A shared rule answers the material
at a requested depth without allocating intervening tiles. Initial camera
demand still materializes only the top tile; removal or other explicit demand
reveals deeper soil and then stone.

This selects the layering pattern, not Synarchy's exact four loam/twelve
granite cell counts. The inspected Synarchy arena has that finite base stack
(see the evidence table); Hetoimasia's selected source continues downward.
Exact default soil thickness, material assets and recipe API remain to be
specified. No geological generation or additional material system is implied.

### D-17. Haskell mechanisms, Lua arena rules

Owner, directly in this pane on 2026-11-06, selected:

> Yes—Haskell mechanisms, Lua arena rules

The accepted division is reusable Haskell terrain storage, streaming, geometry
and edit retention, with Lua defining the arena's material/layer recipe and
driving camera, query and removal calls. Haskell engine libraries must not
contain Ecce Homo's soil/stone choices or import concrete game modules. This
settles the direction of Q-5; the concrete package/service interfaces and
execution/lifetime contract still require specification.

### D-18. Synarchy presentation baseline

Owner, directly in this pane on 2026-11-06, selected:

> Yes—use that Synarchy presentation baseline

Use an isometric view with four 90-degree facings, keyboard panning, mouse
dragging, wheel zoom and Synarchy's soil/stone artwork. Shift-scroll and the
camera tracking modes remain D-12–D-14. This does not introduce a UI system or
copy Synarchy's renderer implementation. Exact bindings, asset packaging,
shape masks/material adaptation and pixel/depth correctness belong in the
concrete presentation contract.

### D-19. Bounded asynchronous loading and atomic edits

Owner, directly in this pane on 2026-11-06, selected:

> Yes—bounded asynchronous requests

Camera controls remain responsive while terrain loads. Loading and editing
use bounded asynchronous requests; edits complete atomically. Exhausted
memory/request admission returns `busy` without losing earlier changes or
partially applying a new edit. Unloaded terrain is visibly absent until ready;
no loading UI is introduced. Define concrete request/cancellation, snapshot
and publication semantics in the technical contract. This choice does not
decide the separate Q-10 general gameplay-state boundary, settled by D-20.

Technical consequence authorized by verified `het-manager` in `#het-terrain`,
message `am56vec4v3yevcyqfinijqiw72`, at 2026-11-07T02:46Z (2026-11-06 local):
terrain requests use M1's `OptionalRequest` policy. Expected domain failures
(`not_found`, `arena_closed`, `stale_view`, `definition`, `source_failure`)
remain recoverable structured request results; they do not end the requesting
instance, including when unread. Malformed arguments remain ordinary validation
errors and provider/accounting defects remain fatal host failures. No Lua
options are added. `busy` remains the existing immediate admission result with
no request handle or provider work, rather than a terminal result of an accepted
request. The manager authorized this as a consequence of D-19 and the routine
stale-pick refusal, not a new owner design choice.

Further technical consequences authorized by verified `het-manager` in
`#het-terrain`, message `qvcaa4ctkdb8swvxx7cvwpdkd6`, at
2026-11-07T03:02Z (2026-11-06 local): add expected `OptionalRequest` codes
`too_large` and `name_in_use`. A valid column request whose complete answer
exceeds 1,024 runs settles as recoverable `too_large`, never a truncated
answer; the caller can narrow the range. P-5's caps are unchanged.
An open claims its name in the same admission boundary; concurrent opens
from either role or any instance cannot both create that named arena, and
the loser settles as recoverable `name_in_use`. A pending open, including
one held for its gameplay logical position, holds the claim but is invisible
to attach: attach settles `not_found` until open settles successfully, without
waiting. Failed or cancelled opens release their claim at terminal settlement;
a successful open keeps its claim until the arena closes.

### D-20. Narrow terrain transactions; general gameplay state stays deferred

Owner, directly in this pane on 2026-11-06, selected:

> Yes—terrain transactions only

Implement a narrow terrain service with atomic individual edits. Leave the
general gameplay-state/ECS system and whole-tick rollback for their later arc.
The service does not implement or replace `api.state`, nor promise rollback
of earlier terrain operations when later Lua code fails. Preserve the earlier
state design and its decisions. This resolves the scope fork in Q-10.

### D-21. Explicit full blocks, ramps and corner slopes

Owner, directly in this pane on 2026-11-06, selected:

> Yes—explicit shapes, no automatic reshaping

Include full blocks, ramps and corner slopes. Removal deletes only the
requested tile; it does not reshape neighbors. Neighbor visibility and derived
render data must still be recomputed where affected. Slopes come from authored
terrain definitions for now. No procedural slope inference, general editor,
or automatic material-dependent smoothing belongs to this arc.

### D-22. Manual depth survives all local navigation

Owner, directly in this pane on 2026-11-06, selected:

> Yes—manual depth survives local navigation

Pan, zoom and rotation preserve a manually selected cutaway level. A jump
without Z restores terrain following; a jump with Z enters manual mode at the
requested depth. This completes the manual-mode transition in D-12–D-14.
Synarchy's zoom-map-triggered reset is not carried over.

### D-23. Separate automatic headroom from manual cutaway

Owner, directly in this pane on 2026-11-06, responding to MR-1:

> yes, they need ot be seperate, the headroom makes things much more natrual.

Automatic terrain-following uses headroom; an explicitly selected manual
cutaway is a separate setting. Do not clip ordinary navigation exactly at the
ground under the camera. Retain D-12–D-14/D-22's follow/manual transitions.
P-5 uses Synarchy's 25-level headroom as its initial configurable default and
sets a corresponding viewing band below it; manual slice selection adds no
automatic headroom to the explicitly requested level.

### D-24. Defer movement and later-game integration

Owner, directly on 2026-11-06: walkable connections and movement speed are
deferred; MR-3 source/general-edit extension, MR-4 gameplay commit integration
and MR-5 future scene composition are also deferred.

These are recorded future migration work, not prerequisites added to the first
terrain arena. Do not implement navigation, speed rules, generalized edits,
geology, whole-game transaction coordination or entity/UI scene composition
in this arc. Keep D-20's narrow terrain transactions and the current arena-only
interfaces. Their limits remain explicit rather than claiming whole-game parity.

### D-25. Preserve Synarchy's full 16-ID slope set

Owner, directly in this pane on 2026-11-06, selected:

> Yes—preserve Synarchy’s full 16-ID set

Replace the agent's thirteen-shape simplification with all Synarchy slope/mask
IDs 0–15 and their visual forms in all four facings. ID 0 is flat; ID 15 is a
distinct authored ID with flat-top treatment in Synarchy's generation logic.
Do not collapse their identities or omit opposite-direction masks. Walkable
connections and movement speed remain deferred under D-24. D-21 still forbids
automatic neighbor reshaping. Rendering, geometric coverage and mouse picking
must agree; current visual fidelity is qualified without adding pathfinding.

### D-26. Delegated storage selection: adaptive sparse packed segments

Owner, directly in this pane on 2026-11-06:

> about the compressed storage, figure out which system is better and specify that one

The selected technical design is sparse columns whose materialized segments
use uniform, run-length or dense packed encoding according to their content.
The rationale and exact selection rule are in P-5's storage comparison below.
This is the agent's determination under the owner's explicit delegation, not
a claim that the owner approved a measured speedup. Unrequested underground
remains implicit; dense fallback is restricted to already-materialized small
segments and never expands into unknown cells.

### D-27. Approve Q-12 and readiness for one-at-a-time issue processing

The owner said “i sign off on this” directly in the manager pane. Verified
`het-manager` relayed that approval in `#het-terrain`, message
`39em862uwqaj3x3t4dn9kipeta`, at 2026-11-07T02:13Z (2026-11-06 local),
explicitly binding it to Q-12 and the design at `398a58f35c`.

P-5's technical contract, defaults and limitations, the epic done condition,
verification strategy and TRA-1–TRA-12 delivery boundaries are approved.
The design is ready for issue processing. Q-13 stays the in-delivery
renderer-proof gate with its existing stop/ask behavior; this sign-off does
not claim that proof or any implementation has run.

The same manager post authorizes processing the EPIC draft only, delivered in
`#het-terrain` for the manager's explicit filing sign-off before creation.
Each later tracker artifact needs a separate invocation and approval; the
manager arranges readiness reviews. No tracker or code mutation follows from
this design sign-off alone.

Readiness recheck, 2026-11-06 local: all 12 delivery IDs match the ledger and
have an acyclic, dependency-valid order. The current open tracker contains
#446 (deferred render-target sampling) and #563 (Lua test-failure triage),
neither an overlapping terrain umbrella. Searches across open/closed issues
for terrain, arena and chunk streaming found no duplicate epic. Q-13 names
the affected slices and their stop/ask behavior explicitly.

### D-28. Correct face-map fidelity in a follow-up before TRA-12

Owner, directly in the manager pane on 2026-11-07, selected option 2 for the
#644 reference-silhouette finding: correct it as a follow-up before TRA-12.
The manager's owner-request prompt for `user-het-terrain-20261106-1838`
records the owner's words:

> you need to implement the alpha cutout from the facemaps in the shaders, that
> means implementing the full lighting system too i think, you tell me,
> investigate how synarchy does it, then we will implement here

The owner then requested this amendment and a proper Synarchy investigation
before work. Verified `het-manager` also relayed this scope in `#het-terrain`,
message `ye56izyasfrs3urdn95a6eqeuw` at 2026-11-07T14:26:50Z, explicitly
holding PR #654 until the amendment determines what it keeps.
This supersedes acceptance of the solids-only rendering route as
sufficient final reference fidelity under D-25/P-5, and reopens D-27's readiness
for the amendment. Preserve the earlier decisions and filed slices as history;
do not silently rewrite their original contracts or call their measurements
invalid for the geometry they actually measured.

The required correction includes shader face-map alpha. The owner's statement
about a full lighting system is a question, not approval of day/night, solar
pages, new gameplay clocks or a particular static lighting policy. Exact
render/pick authority, asset loading, remaining presentation scope and follow-up
slice boundaries remain Q-15–Q-19. No new issue or code is created here.

### D-29. Parameterized sun lighting now; automatic day/night later

Owner, directly in this design pane on 2026-11-07, approved the face-map
cutout and facing-aware lighting scope, with this clarification:

> we can defer day/night as a cycle, but the shaders are supposed to have a
> value that indicates the position of the sun (and moon eventually) that
> gives it 3d definition so that we can see what the tiles look like when we
> preview it.

The CPU submits ordinary isometric sprite quads; the selected face map's
alpha supplies the ramp silhouette on the GPU, and its face weights plus
the supplied sun position give the tile its apparent three-dimensional
lighting. This preserves the owner's intended rendering mechanism instead
of rebuilding the silhouette as CPU-side solid polygons. Exact tile emission,
occlusion, cut surfaces and picking remain Q-16.

Sun position is an explicit, adjustable shader input for previewing different
lighting, not a permanently baked brightness per face or a hard-coded sun
position. Facing-aware face shading is in scope now. An automatic day/night
cycle, calendar/clock ownership and moon lighting are deferred; the future
moon is an extension intent, not a second light implementation in this arc.
This supersedes P-6's earlier recommendation of a fixed light configuration
where that wording could imply that previews cannot change the sun position.
No simulated passage of time is needed to preview a selected sun position.

Q-15 is resolved by this decision. Q-18 still must settle the parameter's
representation and coordinate convention, how preview callers supply it,
initial values, ambient/brightness behavior and any depth haze. Q-17 retains
asset/sampling ownership, and Q-19 retains slice and readiness sign-off.
No new issue, implementation or change to the held PR follows from this
decision alone.

### D-30. Pick the visible terrain through shared sprite coverage

Owner, directly in this design pane on 2026-11-07, accepted the recommendation
following the focused Synarchy picking investigation:

> ok good investigation, note down your recommendation as what i want

Terrain picking uses the actual adopted draw's candidate quads and transforms,
examines them in front-to-back drawing order, and tests the same colour-artwork
and face-map coverage at the cursor. A transparent part of a ramp does not
capture the click; the visible covered tile behind it is eligible instead.
Visible block sides and top edges belong to the quad that draws them, rather
than to the rounded grid candidate or a lower/rear cell from Synarchy's picker.

Keep spatial pruning and shared CPU coverage per asset/version. This does not
require a CPU-side 3D mesh, a coverage copy per terrain cell or GPU readback
on each pick. The adopted-view identity and ordering must match rendering;
adding only alpha rejection to the old one-candidate-per-Z loop is insufficient.
The returned hit identifies a logical terrain cell; removal still acts on
that cell under the existing atomic edit contract. Texture coverage does not
become authoritative world occupancy.

This supersedes D-15/D-25 and P-5 wherever their shared analytic-solid coverage
was the authority for visual terrain picking. It preserves the all-16-ID and
four-facing requirements, coordinate/storage identity, and edit semantics.
The new picker must be qualified with transparent-ramp, visible-side,
top-edge and overlapping-tile cases from the focused audit, alongside the
existing adopted-view and camera requirements.

The picking approach in Q-16 is resolved by D-30. Remaining Q-16 choices are
the meaning/fate of exact subcell-solid query APIs, tile/face emission,
occlusion and cut-surface handling. Q-17 still owns exact sampling/threshold
agreement and the coverage payload's budget, loading, version and lifetime;
shared CPU coverage is now a chosen mechanism, not an open alternative.
The amendment remains exploring; follow-up slices and issue revisions still
require Q-19 sign-off.

### D-31. Preserve underground fog of war, including concealed air gaps

Owner, directly in this design pane on 2026-11-07, corrected the proposed
removal of generic blank cutaway tiles:

> the generic blank tile is important from a gameplay perspective, the
> player should not know what's underground, its supposed to be fog of war,
> that includes air gaps.

The owner also reaffirmed lazy underground loading with gaps, approving it
if it can be implemented correctly. Preserve the blank tile's concealment
role: undiscovered underground terrain must not disclose either its material/
shape or the presence of air. Moving a cutaway through hidden underground
space must not by itself expose a cavern. The concealed region can therefore
look filled even when the authoritative terrain contains air; this is an
intentional knowledge boundary, not fabricated physical terrain.

This supersedes the agent's unapproved recommendation to replace every blank
with the real material or a visible gap. The source audit remains accurate
about S's blank fallback condition, but its implication that covering a real
gap is inherently a fidelity defect was incomplete. The owner has supplied
the gameplay intent that the source condition alone did not establish.
No claim that S already separates residency from player knowledge follows.

Lazy storage and fog must coexist: actual terrain, materialized/resident data
and what the player has discovered are distinct meanings. A query or streaming
load must not silently grant player knowledge. Concealment must also apply to
visual picking: D-30 does not authorize clicking through a fog quad to return
the secret terrain behind it. The exact fog hit result and permitted actions
are open in Q-20, rather than treating the blank as an ordinary removable
physical solid.

The sparse source/overlay model can represent buried solids and air gaps
without allocating each cell. The feasibility approach is to keep unknown
knowledge implicit and represent discovered regions sparsely as well;
bounded demand materializes only what a reveal/query actually needs.
That approach and its costs need implementation qualification. A large or
fragmented revealed region still consumes resources; this is not a promise
of unlimited exploration history in bounded memory. Exact representation,
budgets, reveal propagation and retention remain Q-20/Q-17/Q-19.

The owner has not yet chosen how excavation discovers an air gap, whether
discovery spreads through connected space, whether it survives offload, or
how Lua controls it. This decision adds the fog requirement without silently
adding units, line-of-sight simulation or the deferred general gameplay-state
system. Q-16 remains partially open; Q-20 is a new blocking design question.

### D-32. Unsealing a cavity discovers and loads the whole connected space

Owner, directly in this design pane on 2026-11-07, answered the choice between
whole-cavity discovery and exposure limited to the opening:

> yes we will need to consider more than just loading in the adjacent tiles,
> when we unseal a empty space it needs to load in all the new tiles for the
> whole space

Unsealing a cavity starts discovery of its entire connected empty space and
loads the newly exposed terrain surfaces throughout it: walls, floor, ceiling
and other terrain bordering that connected space. Discovery must propagate
beyond the immediately adjacent cells and across chunk boundaries; it is not
silently restricted to the current viewport. The owner accepted the proposed
bounded-step processing: discovery/loading may progress asynchronously while
the camera remains responsive. This is whole-space discovery, not character
line of sight, so the selected behavior can reveal around corners.

Preserve D-31's separation of terrain, residency and knowledge. This does not
require allocating one record for every empty cell or materializing solids
deeper behind the newly exposed boundary. Empty ranges and discovered regions
may remain compressed; a solid barrier still conceals separate sealed spaces.
Do not interpret the requirement to load the whole cavity as permission to
stop after one neighboring ring, skip off-screen boundary terrain or abandon
the remaining discovery work silently.

This resolves the propagation-scope part of Q-20 and supersedes the local-only
reveal alternative. Exact connectivity (face versus edge/corner contact and
partial openings around shaped cells), the boundary with the unbounded
exterior, initial disclosure, work/residency budgets, completion/failure
behavior, retention on offload and fog interactions remain open. In particular,
the design still must reconcile a cavity larger than available resident memory
with whole-space discovery/loading; no unlimited resident allocation or
permanent pin of every discovered tile is silently authorized. Q-19 must
account for the discovery/loading work in the amended slices and qualification.

### D-33. Retain discovery as chunk changes and replay it on reload

Owner, directly in this design pane on 2026-11-07, approved remembering
discovery for the arena session while allowing normal off-screen unloading:

> yes, revealed tiles would need to be regestered as changes to the chunk and
> offloaded and replayed on load, i think, that sounds right.

Register revealed state as retained changes belonging to the affected chunk.
On offload, preserve those changes alongside retained terrain edits; on reload,
reapply them before the chunk is published for rendering/picking. A previously
discovered cavity must not become unknown again just because its chunks were
unloaded. This includes discovered air as well as exposed solid boundary tiles,
so a remembered opening cannot turn back into a fog-filled apparent solid.

Discovery and material/shape/removal changes remain distinct kinds of state:
revealing a cell does not change what occupies it. Retention need not allocate
one change record per empty cell; compressed revealed ranges/regions may carry
the same knowledge. Exact encoding and accounting remain to be specified.

Off-screen chunks can unload normally; discovery does not permanently pin the
whole cavern in resident memory. D-32 still requires traversal/discovery and
loading of the newly exposed terrain throughout the connected space. The
retained discovery survives eviction for this arena incarnation and is
discarded when that arena is reset/closed, consistent with D-10's session-only
scope. This decision does not add persistence across application runs.

The retention/replay choice in Q-20 is resolved by D-33. Exact capacity refusal,
in-progress discovery resumability, publication/commit boundaries and reset
implementation still need the concrete contract; eviction may not silently
discard approved retained discovery. Q-19 must cover replay-before-publication
and cross-chunk offload/reload evidence in the amended work.

### D-34. Empty cells connect through shared faces only

Owner, directly in this design pane on 2026-11-07, answered “yes that is
correct” to the recommendation that empty cells connect up, down, north,
south, east and west, with edge-only or corner-only contact excluded.

For whole empty cells, D-32 discovery traverses the six face-adjacent
neighbors, including across chunk boundaries. Diagonally touching cells do
not join cavities merely because their edges or corners meet; discovery must
not pass through a zero-width contact. This is a world-coordinate rule and
does not change when the camera rotates. Paths through other face-connected
empty cells can still join two regions; only the edge/corner shortcut is
excluded.

This resolves the face-versus-edge/corner choice in Q-20. It does not yet
define partial empty regions inside cells containing ramps/corner slopes, or
whether/how their openings connect. Those need an explicit logical shape
contract under Q-16/Q-20; camera-facing sprite alpha is not that contract.
The remaining exterior, capacity/completion and fog interaction choices
remain open. Q-19 qualification must include face-connected cross-chunk
spaces and distinct cavities that touch only at an edge or corner.

### D-35. Explicit shape openings connect and reveal cavities

Owner, directly in this design pane on 2026-11-07, approved connectivity through
the partial empty space above ramps/corner slopes and made the diagonal case
explicit:

> yes, we will need explicit shape rules too, no cutting corners here. a ramp
> that has a diagonal open to the air gap of an unrevealed space needs to
> reveal that space

Define logical solid/empty regions and their connected openings for the full
16-ID shape catalog. Discovery must follow continuous empty space through
shaped cells, including a ramp-created diagonal opening into an unrevealed
cavity. That opening triggers D-32 discovery/loading of the connected space;
it cannot be blocked simply because the ramp cell has a non-air material or
because the route is diagonal. Treating every shaped cell as a sealed full
block is not an acceptable first implementation.

D-34 still governs whole empty cells and excludes mere zero-width edge/corner
contact. It is not a restriction to a flood fill that only visits completely
empty cells: the actual open regions of intervening shapes must participate.
The exact geometric mapping must distinguish a genuine ramp-created opening
from a corner/edge coincidence, rather than approving all diagonal neighbors.

Connectivity is world-space terrain meaning, independent of camera facing,
lighting and sprite alpha. Each shape needs explicit openings and internal
connections, including which openings are joined within that cell; a loose
list of open sides cannot silently connect otherwise separate empty regions.
The previous analytic solids and ID-15-equals-ID-0 assumption are not a
validated replacement for that catalog. Define and review the actual shape
rules before declaring the amendment ready; preserving IDs alone is not proof.
No particular triangulation, sampling resolution or per-shape geometry table
is approved by this behavioral decision.

Q-19 qualification must cover the owner's diagonal-ramp reveal case, sealed
controls, all shape IDs and world orientations, cross-chunk openings and
retained discovery replay. Missing neighbor data is pending/unknown until
resolved, not proof of an air connection. Camera rotation must not change
which spaces are connected. Movement, speed and unit line-of-sight remain
deferred; discovery connectivity must not be borrowed uncritically from a
movement rule.

Relevant S evidence: `src/Unit/Pathing/Cost.hs:343–347,486–528` interprets
slope bits for surface movement and classifies diagonal one-level steps as
cliffs. That is not a cavity-connectivity contract and cannot decide this
owner-approved reveal behavior. `src/World/Slope/FaceMaps.hs:33–47,80–119`
supplies only a partial procedural mask helper, not an authoritative 16-shape
logical volume catalog. The earlier source audit records why actual PNG
silhouettes and the old CPU solids cannot be equated.

The inclusion of partial-shape and diagonal openings in Q-16/Q-20 is resolved
by D-35. Their exact geometric catalog and validation remain open, along with
exterior/capacity/completion and fog interaction policies.

### D-36. Share logical geometry between discovery and terrain queries

Owner, directly in this design pane on 2026-11-07:

> ok cool, let me answer the question. i approve your recommended shared
> geometry authority

Use one canonical logical definition of each shape's solid/empty regions and
openings for both cavity discovery and terrain point/ray queries. Correct
the existing mathematical-solid definitions to that agreed catalog; do not
retain incompatible occupancy/intersection answers alongside a separate
discovery model. D-35's partial and diagonal opening rules are part of this
authority. Rotation acts consistently on the same world-space shape.

GPU rendering and screen-space picking continue to use the approved face-map
and artwork coverage (D-29/D-30). A screen hit identifies the displayed tile;
it is not substituted for a logical world-space point/ray query. Conversely,
the logical intersection model must not replace the sprite-alpha screen picker.
The reference art and logical definitions must be checked together for their
intended shape meaning, without pretending raster silhouettes uniquely specify
every interior geometric detail.

This resolves the query-authority/fate choice in Q-16: amend the existing solid
query implementation to use the shared, corrected shape authority. The exact
16-shape definitions, boundary conventions and compatibility details still
need a concrete specification and review. No particular geometric encoding
or new gameplay physics system is chosen by this decision; movement/speed
remain deferred. Q-19 must include the merged geometry/query corrections and
their consistency evidence with discovery in the follow-up work.

### D-37. Fog tiles are unselectable and block interaction with hidden terrain

Owner, directly in this design pane on 2026-11-07, corrected the proposal to
return a selectable unknown-cell location:

> yes that is right, generic blank tiles should be uninteractable, not even
> selectable by the player.

Generic blank fog tiles provide concealment only. They are not player hover,
selection or action targets. A player-facing screen pick whose frontmost
covering surface is fog yields no selectable target, including no unknown-cell
selection handle or hidden material/shape/air information. The temporary
removal shortcut does nothing at that fog-covered point; it must not submit
a removal using coordinates inferred from the blank.

Fog still participates in visual occlusion: stop the hit search at its covered
pixels rather than skipping the non-selectable quad and selecting secret
terrain behind it. Visible selectable terrain drawn in front of fog remains
eligible. D-30's ordinary transparent-ramp behavior remains in force where
there is no intervening fog cover.

This supersedes the agent's unapproved unknown-cell selection proposal and
resolves the fog interaction/result choice in Q-20. Keep this player-facing
rule distinct from trusted engine queries needed to load/generate terrain or
carry out discovery; it does not make fog a physical solid or create a new
general Lua permission system. Concrete API result encoding belongs in the
amended contract; the behavior must expose no selectable fog target.

Q-19 qualification must cover no selection/removal on blank fog, no picking
through fog to hidden solid or air, and normal selection of genuinely visible
foreground terrain. Reveal/load/reload publication must preserve this rule
without transiently exposing secret contents.

### D-38. Exterior-connected space starts discovered; overlapping reveals are safe

Owner, directly in this design pane on 2026-11-07, accepted the exterior
boundary and clarified its meaning:

> open sky should be discovered from the start obviously, and a newly
> discovered cavity that was exposed to air would already be discovered from
> that, so any newly discovered caverns would be closed systems, not exposed
> to air.

The owner also identified the interleaving case: while bounded discovery is
still progressing, two openings at opposite ends of the same sealed space can
be made, allowing the traversed space to connect back to the exterior. The
owner requires logic to handle this and requested engineering guidance rather
than selecting an algorithm.

Sky/exterior air and spaces already connected to it in the initial terrain
start discovered. Discovery is distinct from loading: this does not preload
every exterior-connected cave or allocate a record for every sky cell. A
space that requires a later unsealing discovery was previously enclosed.
The initial known set must account for actual connectivity through the agreed
shape rules, not merely a fixed Z threshold or whether a chunk was loaded.

Subsequent openings must discover the newly reachable enclosed space without
expanding into open sky, rediscovering the world, losing unfinished branches
or confusing already-discovered space with pending discovery work. Two fronts
meeting in the same space must not duplicate unbounded work or cancel each
other's remaining obligations. Newly created connections must be considered
even if neighboring terrain has already been processed. Preserve D-32's
whole-space discovery and D-33's retained knowledge throughout.

This resolves the initial exterior/discovery behavior in Q-20 and supersedes
any reading of the earlier exterior proposal as initially fogged sky or an
already-open cave waiting to be unsealed. P-7 below is the recommended
engineering mechanism, not an owner-approved queue/source representation.
Exact initial-knowledge derivation, publication/cancellation and capacity
contracts remain for review before amendment readiness.

### D-39. Share bounded discovery work across overlapping openings

Owner, directly in this design pane on 2026-11-07, answered “that sounds good”
to the proposed shared discovery queue and its two-opening explanation.

Use shared arena-owned discovery work with distinct undiscovered,
pending-exploration and fully-explored states. Each new excavation seeds the
connections it creates, including connections adjacent to already-explored
terrain. Pending regions retain their unfinished branches and boundary-load
obligations. When two fronts meet, they share that work rather than duplicate
it or cancel each other's remaining exploration.

Already-known exterior ends the outward branch only; finding an exit does not
finish the cavern. Prior knowledge and pending work remain distinguishable
from the fact that a newly opened cavity now physically connects to sky.
Process the work in bounded steps under the existing terrain-owner model,
preserving whole-space discovery, retention and camera responsiveness.

This approves the shared-work mechanism presented in P-7. It does not approve
its still-open exact source-metadata compiler, shape/component encoding,
capacity policy, disk backing, API result types or commit/cancellation details.
Those remain concrete contract work under Q-16/Q-20 and the final Q-19 review.

### D-40. Back retained chunk changes with a temporary session disk store

Owner, directly in this design pane on 2026-11-07, answered “yes that works”
to the recommendation for temporary disk backing of retained chunk edits and
discovery, with a bounded RAM cache and asynchronous I/O.

Retained chunk changes can move to a per-arena temporary backing store when
they leave the active memory working set. Reload reads and replays those
records before publication, including both terrain edits and revealed state.
Use bounded RAM caching and asynchronous storage work so retained history need
not remain entirely in memory and storage I/O does not block camera response.
Compressed terrain and knowledge remain compressed; this does not require
writing every unchanged or empty cell.

The store belongs to the arena session and is discarded on arena close/reset.
There is no user save, restoration across application runs or crash-recovery
feature in this decision. It preserves D-10/D-33's session lifetime while
superseding P-5's RAM-only authoritative-retention policy and its hard total
32 MiB session-history limit. RAM staging/cache and disk consumption still
need explicit bounds; no unlimited disk allocation is authorized.

Q-20 must specify quotas, record/index format, I/O ownership and scheduling,
atomic offload/replay, errors and cleanup. An acknowledged edit or revealed
state cannot be discarded from RAM before a backing copy is safe to replay;
normal eviction must not erase discovery or remaining reveal obligations.
The exact write/commit and failure policy remains a concrete design choice.
Q-19 must include this storage work and qualification in the amended slices.

### D-41. Pause new changes on storage exhaustion without losing progress

Owner, directly in this design pane on 2026-11-07, answered “yes that sounds
fine” to pausing new edits and discovery when temporary storage fills or a
write fails, preserving existing changes and unfinished work, reporting the
problem through Lua, and resuming after storage recovers. Navigation may
continue wherever its required data remains available; this does not promise
that an unavailable backing store can serve further reads.

Expected storage exhaustion or write failure must not erase acknowledged
terrain edits, revealed state or outstanding discovery obligations. Keep the
last coherent published view and the unwritten committed state needed for
safe replay. Do not continue accepting changes into an unbounded RAM fallback
or report an unfinished reveal as complete. Exact admission, write/commit,
error-result and recovery mechanics remain Q-20. This selects a recoverable
storage-failure behavior, not a replacement for supervision of unknown host
faults or a cross-run recovery guarantee.

The owner also suggested checking free space, limiting the terrain store,
refusing startup without enough room and never creating a world that could
exceed that budget, asking for advice. Those suggestions remain proposals:
a hard storage limit is compatible with D-11's expandable world if new retained
changes can pause at capacity; a guarantee that every possible future change
fits would require bounding the world or its allowed changes. P-8 records this
distinction for the next decision. No finite world boundary is approved here.

### D-42. Raise CPU budgets and keep camera demand best effort

Verified `het-manager` relayed the owner's decision in `#het-terrain` on
2026-11-07T16:56:07Z, message `2tw98c6v6pkzge9yzhdvntgtki`, and instructed
this design to record [#639 amendment 2](https://github.com/coghex/hetoimasia/issues/639#issuecomment-6710245034).

Raise the configurable, service-wide initial CPU banks to 256 MiB resident
terrain, 64 MiB retained session edits and 128 MiB CPU render/staging. Other
limits remain unchanged. Camera demand keeps the full approved zoom/depth
range and is best effort: admit what fits, nearest/visible first under the
priority/aging rules, keep the remainder pending and show unloaded terrain as
absent. Large camera demand is not invalid merely because it exceeds a bank.
It must not block or starve explicit queries/removals; latest-value replacement
and withdrawal remain. The construction-time capacity guarantee in that
amendment applies to explicit requests, not the whole camera envelope.

This supersedes P-5's earlier 64/32/64 MiB CPU defaults and any reading of its
camera bounds as a restriction on the approved zoom range. The 64 MiB edit
bank is the revised pre-backing CPU allowance; D-40 still supersedes RAM-only
total-history retention. Q-20 must map edits, discovery, cache and staging to
explicit banks in the backing-store contract rather than silently treat this
CPU number as a disk quota or unlimited memory for discovery.

### D-43. Reserve a hard storage allowance while keeping the world expandable

Owner, directly in this design pane on 2026-11-07, answered “yes that is sound
i think” to the recommendation to keep the expandable world with a reserved
storage allowance and pause when that allowance is exhausted.

Before arena opening succeeds, check the actual storage volume and reserve a
configurable allowance for its temporary store, including bookkeeping and
temporary write space. Refuse arena opening if that allowance cannot be
reserved. Enforce the allowance before accepting additional retained changes;
unchanged terrain is regenerated from its source instead of saved. At capacity
or on storage failure, D-41's pause/preserve/report behavior applies to edits
and discovery, including unfinished discovery work. Do not acknowledge changes
on the assumption that more disk space will become available later.

This chooses a storage boundary rather than a finite terrain boundary. It
preserves D-11's expandable procedural world without promising unlimited
retained history in a fixed store. The alternative of guaranteeing that every
possible future change fits by bounding the world or allowed changes is not
selected. A free-space query alone is not the required reservation; runtime
storage failures still need D-41 even after a successful reservation.

Q-20 must specify the numeric allowance, filesystem and multi-arena accounting,
physical reservation and write protocol, safety margin, bounded continuation,
exact Lua results and recovery/cleanup behavior. These are not established by
this high-level approval. Opening the engine application itself is not
prohibited: the failure boundary is opening the terrain arena. This decision
does not create a UI, a persistent game-save feature or a live quota-change API.

### D-44. Correct inconsistent masks and require solver-delivered proof

Owner, directly in this design pane on 2026-11-07, approved correcting
inconsistent masks in Hetoimasia while retaining all 16 IDs, material textures
and face-map rendering:

> yes, i may have made mistakes in synarchy, that is the motivation for our
> rewrite in the first place, now is the perfect time to correct things, but
> im going to need proof of this from the solver when we get to it

Correct demonstrated reference mistakes instead of preserving them for exact
pixel fidelity. This supersedes D-25's requirement to preserve visual forms
where a pinned mask conflicts with the intended, rotation-consistent logical
geometry. Keep the 16 authored identities, existing material artwork and
GPU face-map cutout/lighting approach. D-36's shared geometry authority for
discovery and point/ray queries remains; screen picking follows the corrected
drawn coverage under D-30. This does not approve renumbering/dropping IDs,
automatic neighbor reshaping, changes to Synarchy, or an unspecified new
geometry catalog. Those concrete shapes still need Q-16 review.

The solver must reproduce the relevant original mismatch and provide
reviewable evidence that each correction fixes it. The design's N/E pixel
calculation is a lead to verify, not a substitute for that proof. Require
before/after offscreen captures and a catalog covering all 16 IDs in all four
facings, with the intended logical shapes/openings shown alongside the mask
results. Include reproducible checks of rotation consistency, rendered alpha,
screen picking and discovery/query agreement; the detailed evidence contract
below makes this a delivery gate rather than an optional screenshot.

Deliver that evidence to the owner with the correction's immutable source/asset
revision and reproduction instructions. If the solver cannot reproduce a
claimed defect, or the correction fails the agreed geometry or coverage
checks, report the discrepancy and stop the affected qualification rather
than declaring the correction proven. Q-13 carries this implementation gate;
Q-19 must assign it to the geometry/mask correction and final qualification
work. No implementation or tracker mutation is authorized by this design turn.

### D-45. Keep terrain pixel edges crisp and picking consistent

Owner, directly in this design pane on 2026-11-07, chose “crisp edgs” in
response to the choice between nearest-neighbor terrain/mask sampling with
matching picking and smooth filtered coverage.

Use nearest-neighbor sampling for both terrain colour artwork and face maps.
Rendering and screen picking use the same alpha cutoff and matching sampled
coverage from the adopted asset versions. Do not smooth a visible edge while
testing a different, unfiltered silhouette for picking. This chooses crisp
pixel artwork through the existing pan/zoom/facing controls; it does not add
camera snapping, fixed zoom steps or a new UI.

This resolves Q-17's nearest-versus-smooth appearance choice, alongside D-30's
shared CPU coverage authority. The numeric cutoff, exact UV/texel-boundary
rule, mip/LOD policy, bounded data-image loading and resource accounting remain
concrete contract work. Include non-integer zoom, tile edges and all four
facings in D-44's coverage/picking evidence. No particular corrected shape or
lighting appearance is selected by this sampling decision.

### D-46. Control a world-fixed sun through Lua

Owner, directly in this design pane on 2026-11-07, answered “yes” to Lua
setting the sun's compass direction and height above the horizon, with the
same terrain side staying sunlit when the camera rotates.

The preview light is anchored in world space. Camera facing changes how the
light is expressed for the selected face map; it does not move the sun around
the terrain. Lua supplies the direction/elevation through the terrain-view
lighting controls. Preserve D-29's deferred automatic day/night cycle and moon
lighting; this adds neither a UI nor a world clock.

Q-18's input meaning and supply path are resolved. Exact angle units/ranges,
binding shape, initial sun position, ambient/intensity values and depth
dimming/haze remain concrete contract choices. D-44's evidence must include
camera rotation at a fixed sun input and changing the sun at a fixed camera,
so a light that accidentally follows the camera cannot pass the preview check.

### D-47. Keep both depth effects and require better testing

Owner, directly in this design pane on 2026-11-07, answered the choice between
both adjustable depth effects, darkening alone and neither:

> keep both, but this is something that doesnt really work well so we will
> need to make sure we get better testing in place

Retain gradual depth darkening and blue haze below the cutaway, with Lua
controls to adjust or disable each. These are presentation effects, separate
from directional face lighting and from the discovery/fog-of-war state. They
must not change terrain knowledge, alpha cutout coverage or screen-pick targets.
Turning both off provides a face-lit baseline for tile/geometry previews.

The owner requires improved tests, not unquestioned reproduction of S's
appearance. Its exact depth formula, strengths and colour mixing are therefore
not approved merely by keeping both effects. Q-18 must define those numerical
expectations; the evidence contract below requires isolated and combined
effects, depth extremes, changing cutaway/camera/lighting, and streaming seams.

The reported reference weakness has not yet been narrowed to a reproduced
symptom. The owner has been asked what they remember seeing. Add that case
to the solver's regression/evidence matrix when known; do not invent a root
cause or claim that this design has diagnosed or fixed it. The general
qualification work can still be specified without an exact reproduction.
Q-19 must assign D-47's tests/evidence to the lighting and integration work,
and carry the requirement into final TRA-12 acceptance.

### D-48. Load terrain from the projected view, not a flat camera radius

Owner, directly in this design pane on 2026-11-07, answered “yes, if you think
its feasable, its what i want” to P-10's viewport-driven loading contract.

The feasibility basis is the existing pure planner's viewport/height-window
calculation and the approved bounded runtime demand model, verified in P-10.
This establishes a feasible implementation direction, not measured capacity
or completion of the face-map integration.

Derive camera demand from viewport size/aspect, zoom, facing, cutaway and the
visible height range. Include potentially visible background tiles even when
their horizontal chunks are far from the camera anchor. Visible demand comes
before the small prefetch margin, while explicit query/removal priority remains.
Eviction respects current view interests and capacity rather than a fixed
horizontal radius. Preserve D-42's bounded best-effort admission: unresolved
visible demand remains pending, and insufficient memory can still leave
terrain absent. No memory-limit increase or full-view residency guarantee is
implied.

P-10's refinement and regression package are approved. The solver must show
the owner's background/haze case requested from a nonresident starting state,
loaded and retained when budgets suffice, and distinguished from expected
capacity pressure when budgets do not suffice. Include rotation, zoom,
viewport changes, cutaway/elevation displacement and eviction/reload. Keep
fog concealment and sparse underground materialization intact; merely moving
the camera cannot discover a hidden cavern.

This refines P-5's visible-region demand and D-42 rather than adopting S's
5×5 camera square. Q-16/Q-19 must carry the actual whole-tile bounds and the
planning-limit/runtime integration work; the existing pure planner alone is
not the solver proof. No code or tracker change is made in this design turn.

### D-49. Adopt the illustrated lowered-edge catalog, including peak ID 15

Owner, directly in this design pane on 2026-11-07, answered “ok sounds good”
to adopting the illustrated P-9 catalog as the logical target for corrected
masks and solver proof. All 16 IDs were shown with their forms and maximum
heights; the diagram was explicitly a design illustration, not engine output.

Adopt P-9's exact rule in the unit cell: `N=y`, `E=1-x`, `S=1-y`, `W=x`;
ID 0 has top height 1 and every other ID uses the minimum of the expressions
selected by its bits. The solid lies between the base and that top. Combining
lowered edges gives the illustrated corner and ridge forms. ID 15 is the
four-sided central peak, height 1/2, with all four edges at the base.

This explicitly supersedes D-25/P-5's flat-top treatment of ID 15 and the old
alias between IDs 0 and 15. Retain the IDs and rotation/coordinate conventions.
For IDs 0–14 the intended mathematical shapes agree with the existing
lower-envelope definitions; that does not make the mismatching reference
artwork correct. Correct and qualify the masks against the chosen catalog
under D-44. Discovery and terrain point/ray queries continue to share D-36's
logical geometry, with real openings rather than image-alpha connectivity.

P-9's table durably specifies the illustrated forms. Its opening regions
follow from those solids and D-34/D-35's positive-area connection rule; query
and portal implementation still require the specified qualification. This is
not approval of automatic reshaping, movement rules, new IDs or a new renderer
ABI. Q-16 retains emission/cutaway and compatibility details; Q-20 retains
discovery execution/storage mechanics. The solver must still provide evidence
rather than treating this approval or the illustration as a completed proof.

### D-50. Cutaways preserve known shapes without additional flat caps

Owner, directly in this design pane on 2026-11-07, answered “yes that's right
i think” to hiding levels above the selected slice while keeping every
remaining known tile's actual shape and material, including ramps, without
adding flat caps; unknown regions retain generic blank fog.

At integer slice `k`, omit cell levels `z > k`. Each remaining known tile
keeps its approved geometry and material: a ramp at the slice remains a ramp.
Do not create an additional flat cap or change terrain to represent the cut.
Known air stays air. Generic blank coverage still conceals unknown regions,
including unknown air, under D-31/D-37; it is neither a physical cap nor a
selectable tile. Changing the cutaway grants no discovery.

This supersedes earlier proposals for additional cutaway caps. It settles
their visible behavior, not whole-cell emission, hidden-cell culling, painter
ordering or their qualification. Those remain Q-16/Q-19 work; automatic
headroom and manual camera navigation retain their earlier decisions.

### D-51. Discover whole caverns without exhaustively loading their detail

Owner, directly in this design pane on 2026-11-07, answered “yes that fits”
to the recommendation to remember the entire connected cavern and its exposed
boundary as discovered in compressed form, while loading actual tile/render
detail only when the camera or an explicit request needs it. The question
explicitly identified this as a refinement of the earlier requirement to load
every boundary tile, including in enormous/world-spanning spaces.

Whole-space discovery remains the behavior: it crosses chunks, includes the
exposed solid boundary and is not restricted to the current view. Represent
that knowledge with exact compressed regions. Finite caverns use the same
rule as enormous or world-spanning ones. Materialize their boundary detail
only for camera or explicit query/edit demand, with normal bounded streaming.
There is no requirement to instantiate every boundary tile once before the
discovery can finish.

Completion means the connected space and its boundary are known, with the
required connectivity work accounted for, not that all detail is resident or
has been loaded. Do not guess across unresolved connections or label a partial
reveal complete: unprocessed obligations stay pending under D-39. Compact
source connectivity and its limits still require a concrete implementation
contract and proof; this decision promises neither constant-size encoding nor
instant discovery of arbitrary terrain.

This supersedes D-32's exhaustive boundary-loading requirement and that
requirement's restatement in D-33. It preserves their whole-cavity scope and
D-33's session retention/replay: compressed knowledge must survive normal
offload, apply before chunk publication and disappear only with arena
close/reset. Detail eviction cannot erase discovery. D-41/D-43 still govern
capacity and I/O failure. Q-20 retains exact representation, publication,
source-compilation, capacity and API mechanics; Q-19 must assign their proof.

### D-52. Lua may increase a live arena's reserved storage allowance

Owner, directly in this design pane on 2026-11-07, answered “yes” to allowing
Lua to request a larger reservation without restarting the arena, reserving
the additional space before resuming capacity-paused work and preserving
existing state and the pause if reservation fails.

Provide an explicit asynchronous Lua request to increase the same live arena's
storage allowance. The old cap remains authoritative until the additional
reservation succeeds. Only then may the larger cap admit retained changes and
allow capacity-paused work to resume. Failure preserves the old allowance,
acknowledged changes and pending discovery; it does not discard history to
make room or reset the arena.

This extends D-43's startup-only configuration scope. Growth is explicit and
bounded by the newly reserved allowance; it is not automatic quota growth,
a shrinking API, a UI or persistence across runs. D-41 still governs other
storage failures: obtaining extra capacity is not proof that a separate I/O
fault has recovered. Q-20 retains the exact Lua signature/authority, request
results, cancellation/close behavior, reservation accounting and retry protocol;
Q-19 must include the operation and its failure-path qualification.

### D-53. Prepare bounded exact source connectivity before opening the arena

Owner, directly in this design pane on 2026-11-07, answered “approved” to
preparing and validating a compact connectivity summary before arena opening,
with a clear refusal when preparation exceeds its limits. The recommendation
explicitly preserved asynchronous opening and required support/proof for the
flat terrain, gaps and shape fixtures without generating underground tiles.

Haskell derives and validates the initial summary from the copied Lua source
recipe, compressed layers and the approved shape openings before the arena-open
request succeeds. Work from compressed structure, without enumerating buried
tiles or flooding the sky. This establishes initial exterior connectivity;
computing the summary does not reveal sealed caverns to the player. Keep
opening asynchronous, bounded and cancellable, with no partial arena published.

Preparation has explicit work and memory limits. If an exact summary cannot
be established within them, refuse opening with a clear expected Lua result.
This is an additional admission condition beyond the existing authored-record
limits: a syntactically valid but too complex recipe can be refused before
play. It is not approval to exclude the required flat arena, world-spanning
air layer or specified shape/cavity fixtures to avoid their implementation.
The solver must prove those cases and bounded refusal for excessive complexity.

Q-20 still needs the precise representation, accounting/bounds, error encoding,
cleanup and edit-time update contract; Q-19 must assign the preparation and
qualification work. This is not a general constant-cost topology oracle or
approval of new procedural callbacks. D-51's knowledge/detail separation and
D-39's retained pending obligations continue to govern later discovery.

### D-54. Control ambient illumination independently of sun position

Owner, directly in this design pane on 2026-11-07, answered “yes that works”
to a separate Lua-controlled ambient level that stays fixed when only the
sun position changes. The recommendation explained that Synarchy derives
ambient from its sun phase and that a later Lua day/night cycle could still
animate both independent inputs.

Ambient supplies the base illumination of faces receiving little or no direct
sun. Give it its own Lua control; changing only sun direction/elevation must
not alter that value. Directional face lighting still responds to the
world-fixed sun under D-46. This intentionally replaces Synarchy's automatic
sun-phase ambient curve for this preview contract. It does not select a fixed
uneditable ambient level or remove the possibility of a later day/night cycle.

No cycle, moon or UI is added now. Q-18 still needs numeric defaults, bounds,
face-light equations and their composition with D-47's depth effects. The
qualification must vary sun with ambient held fixed and ambient with sun held
fixed, across all facings, so independent controls are observable rather than
two names for the same automatic curve.

### D-55. Adopt P-11's cutout asset, sampling and ownership contract

Owner, directly in this design pane on 2026-11-08, answered “approved” to
P-11 as written at `f372d0793f`. The review explicitly covered binary-alpha
96×64 artwork/masks, nearest level-zero sampling, the common 0.5 cutoff,
bounded data/CPU-coverage loading options, exact displayed-version ownership,
existing memory budgets, refusal of incompatible/semi-transparent terrain
assets and required CPU/GPU edge-agreement evidence.

Adopt all six clauses of P-11, including its UV/pixel convention,
premultiplied-colour/data-image distinction, `api.content.texture` options,
coverage accounting/lifetime and failure-path qualification. The normal
texture-loading behavior remains unchanged when the new options are omitted.
The initial terrain style uses the approved opaque/cutout contract; other
translucent terrain needs a later contract rather than silent alteration of
authored assets.

This resolves Q-17's concrete asset/sampling/ownership specification. It is
not a claim that the bounded loader or renderer has been changed or that
D-44's corrected masks have been proved. Full-cell emission/ordering and
lighting equations remain Q-16/Q-18; Q-19 must assign the approved loader,
coverage and integration work and its qualification before final acceptance.

### D-56. Use surface-normal RGB with the existing alpha-cutout technique

Owner, directly in this design pane on 2026-11-08, answered “ok, i see, i
approve your idea” after clarification of P-12's difference from Synarchy:
the reference blends right/top/left brightnesses, while the proposal stores
actual surface orientation and compares it with the sun direction. The
clarification used a ramp facing low sunlight and explicitly preserved flat
CPU quads, GPU cutouts, texture dimensions and the picking contract.

Encode the visible surface normal in the face map's RGB channels, with alpha
retaining its binary silhouette. Generate normals and cutouts from D-49's
logical catalog, transform directions consistently with the chosen camera
facing, and shade against D-46's world-fixed sun plus D-54's independent
ambient illumination. Regenerate the maps' RGB contents deliberately and
distinguish the encoding so old face-weight maps cannot be silently reused
as normals. D-44's correction/provenance and visual proof remain mandatory.

This explicitly supersedes the right/top/left RGB-weight interpretation in
the earlier lighting framing and P-11's description of face weights. It
preserves P-11's approved raw-data transport, dimensions, cutout alpha,
sampling, CPU picking coverage and resource ownership. It adds no terrain
cell mesh or extra per-cell texture. The exact encoded-normal format,
numerical lighting/depth equations, defaults and Lua configuration require
the remaining Q-18 contract review; the idea's approval does not choose those
unstated values or prove the material implementation.

Include low-angle sunlight on opposing ramps and all peak facets, ambient/sun
independence and world-surface consistency through four camera facings in
the solver's proof. No implementation or tracker mutation occurs here.

### D-57. Adopt P-13's numerical lighting and depth-effect contract

Owner, directly in this design pane on 2026-11-08, answered “approved” to
P-13 as written at `f052296f6e`. The review named encoded-normal validation,
southwest sunlight at 45 degrees, 35% ambient and full direct strength,
15% darkening and 60% blue haze over a fixed 250-level range, post-lighting
haze blending, independent Lua controls, zero direct sun at/below the horizon
and required numerical/side-by-side visual evidence.

Adopt P-13's exact `unit-normal-rgb-v1` encoding and additional bounded
`normal_encoding` texture option, lighting/depth schema and defaults, atomic
configuration behavior, equations/composition order, existing-ABI packing
direction and qualification obligations. Its numerical/API choices are now
the initial contract. Lua can tune the settings within the approved ranges;
the defaults are starting values, not a claim of visually accepted output.

This resolves Q-18's specification. The normal-map correction, material
implementation, exact sampling agreement and D-44/D-47/D-48 evidence still
need solver proof and owner visual acceptance. Geometry emission/ordering
and discovery/storage mechanics remain Q-16/Q-20; Q-19 must assign delivery.
There is no code or tracker mutation in this design turn.

### D-58. Adopt P-14's cell-quad, fog and visual picking contract

Owner, directly in this design pane on 2026-11-08, answered “approved” to
P-14 as written at `07930b5295`. Adopt its whole-cell representations,
complementary known-material/fog masks, exact ordering and bounded depth-rank
admission, conservative view planning, adopted-snapshot alpha picking and
explicit visual/logical API migration.

Knowledge remains distinct from residency and from the underlying terrain.
A known shaped solid can border an undiscovered void: its required material
and fog parts are admitted/adopted together. Confirmed fog is uninteractable,
stops traversal and yields `no_hit` without hidden coordinates or edit
authority. Unavailable information that could cover a candidate yields
`loading`. Logical point/ray queries retain their separate truth contract;
loading or querying does not itself discover terrain.

This resolves Q-16's remaining specification and the concrete player-facing
fog-result portion of Q-20. Preserve P-14's all-shape/facing, ordering,
coverage, disclosure, loading and lifecycle qualification obligations under
D-44/D-47/D-48. Approval is not evidence that the renderer or picker has been
implemented or proved. Storage, discovery transactions and recovery remain
Q-20; delivery and fresh amendment readiness remain Q-19. No code or tracker
mutation occurs in this design turn.

### D-59. Adopt P-15's compressed discovery and temporary-store contract

Owner, directly in this design pane on 2026-11-08, answered “approved” to
P-15 as written at `d527957369`. The checkpoint named the configurable
1 GiB reservation per arena, writing edits and their pending discovery work
before reporting success, bounded compressed connectivity/preparation/cache
work, Lua status/growth/retry and preservation of committed history on failure.
It explicitly stated the edit-latency and admission-refusal tradeoffs and
that a raw buried removal does not reveal a sealed space until it connects
to known air.

Adopt all seven P-15 clauses: exact parameterized source components and
upper-boundary exterior semantics; monotonic removal/connectivity overlays
and retained discovery obligations; the reserved private temporary-file and
copy-on-write page contract; numeric preparation/cache/I/O/transaction limits;
one publication/settlement arbitration after writes; the exact Lua surface,
authority and expected result classes; and resource ownership/qualification.
The stated defaults are initial limits requiring proof, not performance
measurements or a guarantee against external filesystem/device failures.

This resolves Q-20's concrete storage, discovery, API and lifecycle
specification alongside D-58's fog/picking contract. It does not claim that
the symbolic compiler, backing store or amended runtime exists or has passed
its independent tests. No cross-run save/recovery, general terrain placement,
gameplay-state/ECS or whole-tick rollback is added. Q-19 still requires the
follow-up delivery plan, existing-issue revision plan and fresh amendment
readiness sign-off. No tracker or implementation change occurs here.

### D-60. Approve the amendment delivery plan and readiness

Owner, directly in this design pane on 2026-11-08, answered “yes i approve”
to the explicit checkpoint approving P-16 at `b012fabbfc` and declaring the
terrain amendment ready for issue processing. The checkpoint enumerated
eleven follow-up slices under existing EPIC #636, revisions to #645–#648,
required amended proof before final qualification and the continuing hold
on renderer PR #654.

Approve P-16's exact one-PR boundaries and dependencies for TRA-13–TRA-23,
the baseline disposition/coordination, existing-issue revision scopes and
evidence ownership. Promote the new slices as unprocessed in the ledger and
delivery plan, ordered EPIC; TRA-1–TRA-8; TRA-13–TRA-23; TRA-9–TRA-12.
Preserve every original stable ID and issue link. Original filed scopes remain
history where explicitly superseded; the amended contracts govern delivery.

This resolves Q-19 and completes design readiness. D-28–D-59's behavior,
P-9–P-15's contracts and P-16's delivery plan are the signed-off amendment.
Q-13 remains a deliberate in-delivery proof gate: TRA-17 must establish the
amended renderer path before dependent integration, and TRA-12 still requires
the complete final evidence. Readiness is not implementation completion,
successful qualification or owner acceptance of uncaptured visual output.

Later issue processing revises existing EPIC #636 first and then handles
one new child or existing-issue revision at a time, each with its own concrete
draft and separate approval before tracker mutation. This sign-off neither
files/edits tracker items nor authorizes code work, releases PR #654's hold,
approves a PR head or authorizes a merge. Report the published design and
readiness to the manager; operational coordination remains with that workflow.

### D-61. Atlas regions, offline packing and byte-bounded textures

Owner direction relayed by verified `het-manager` in #het-terrain,
`apa6ni3b85xr2pt5n4etv5fxr6` (2026-11-08T16:53Z): every texture is an atlas;
a single image is a 1×1 atlas, not a separate rendering model. This is a
family/content grouping, not one atlas for the whole project. It continues
the owner's 2026-09-29 bindless/atlas decision (archived GPU resource design,
D-1). The authored whole-canvas maps from TRA-14 remain the source.

The manager explicitly delegated selection of the packing boundary in the
atlas-revisions prompt. Select **offline asset preparation owned by TRA-17**,
beside the existing terrain map generator and material integration: produce
deterministic colour and normal-data atlases plus a region manifest before
runtime loading. Runtime uses TRA-15's existing bounded loader and validators;
the material samples checked regions. This keeps game/catalog packing out of
the generic decoder, avoids a second runtime pack/upload owner and preserves
the exact qualified source images. It does not introduce a project-wide atlas,
runtime repacking, a texture-atlas service or a new Lua call. P-17 gives the
complete region, coverage, lifetime and evidence contract.

Later owner direction is implemented by merged PR #672 at `2d7f35f7` and
relayed in `zhzz9jn6sd266g5zcaf78kpwyw`: texture admission is memory-only,
512 MiB per presentation instance and 1 GiB per session, with a 4 KiB minimum
charge per physical texture. Pending/live/retiring obligations and the existing
native/workspace/coverage banks still apply. This supersedes the earlier
count-based interpretation of the atlas direction; atlases remain required.
Regions share the atlas resource and do not each consume an image allocation.

The explicit dispatch authorizes recording this delegated choice, landing the
design, and drafting #659 before later revisions. This atlas update is ready
for that one-artifact processing; it grants no tracker mutation or GPU proof.
Q-13 still gates implementation qualification. Keep all stable ledger links
and the earlier decisions as history where this update supersedes them.

## Design boundaries

Hetoimasia V-1 keeps game rules, authored data and orchestration outside engine
libraries, using narrow services. Synarchy's world managers and coupled
environment are not the new architecture (H `docs/vision.md:15–36`).

**Direction reconciliation remains open:** H `MEMORY.md:64–65` still records
“Not committed: ... a full Synarchy port”. The owner's new recreation direction
was flagged in this conversation. It chooses the real game and this first
step, but does not yet specify complete feature/asset/save fidelity or revise
V-1. Do not silently update memory or equate recreation with source portability.

Before selecting state or concurrency, document its owner, readers/writers,
thread, lifetime, reset and disposal. CPU completion and GPU retirement remain
distinct (H `AGENTS.md:14–35`). No terrain-specific ownership table or storage
layout was approved by the earlier direction alone. P-5 supplies these details,
now approved through the explicit Q-12/D-27 contract review.

## Concrete technical contract — P-5, approved through Q-12/D-27

This is the original approved implementation contract. D-1–D-25 record the individual
owner choices, D-26 the delegated storage selection, and D-27 the owner's
approval of this complete contract and delivery plan. Numeric caps are initial
implementation defaults to qualify, not measured performance claims. Q-13
retains its explicit renderer-proof gate.

Read P-5 with the explicit amendments D-28–D-59 and P-9–P-15. In particular,
the old flat-ID-15, extra cutaway-cap, analytic visual-picker and RAM-only
total-history assumptions are superseded, as are the old CPU bank defaults.
Their original wording remains as filing history, not an alternative current
contract. P-16/D-60 approves how the filed baseline is extended and migrated.

### Scope and compatibility

Ship the expanding flat arena, layer recipe, sparse gap-capable terrain,
explicit block/ramp/corner geometry, session edits, demand loading, isometric
presentation, camera/input APIs and Lua removal. Verify caves, slopes and
disconnected spans with small authored definitions using the same source
interface as the arena. Keep the temporary removal binding only long enough
to capture development evidence; delete it before final acceptance.

Exclude procedural elevation/geology, fluids, flora, units, pathfinding,
structural support, constructed buildings, automatic slope inference, a
general set-cell editor, UI/fonts, disk saves, multiplayer, general ECS/state
and whole-tick rollback. Excluding a simulator does not prevent it using the
terrain query contract in a future arc. No Synarchy saved-world or Lua-source
compatibility is claimed. Preserve asset provenance and authored identifiers.

Existing M1 scenes, profiles and CPU-only compositions keep their current
behavior. Terrain is an optional injected service with its own validated
limits and request kinds. Leave `api.state` and its unavailable guard intact.
Do not grow the simple rectangle schema into a per-tile transport or raise
its 4,096-sprite cap to hide a missing terrain path.

### Components and dependency direction

| Component | Owns | Depends on |
| --- | --- | --- |
| `hetoimasia-terrain` | Coordinates, shapes, source recipes, sparse spans, overlays, queries and pure residency/transaction decisions | Base/containers/packed data and math as used; no Lua, GLFW, graphics or game |
| `hetoimasia-terrain-runtime` | Bounded requests, the single writer, arena lifetime, revisions and CPU snapshots | Terrain, runtime/resources/logging; no concrete game |
| `hetoimasia-terrain-render-2d` | Projection, cutaway visibility, picking, render descriptions and terrain material declaration | Terrain, math and render-2d; pure planning separated from backend effects |
| Lua terrain/input adapter | Argument/role/lease checks and request conversion; no game rules | Abstract terrain/input ports plus Lua host/facade; backend composition kept separate |
| Graphics composition | Retained terrain uploads, target publication and GPU holds | Terrain render adapter and existing graphics host/backend |
| Ecce Homo arena content | Recipe/material identifiers, artwork references, camera controls and temporary development removal binding | Public Lua APIs only |

The generic launcher assembles these services; it imports no concrete arena.
An application material implements generic terrain face shading; Lua supplies
its soil/stone textures and style parameters. Do not add terrain concepts to
the generic 2D renderer's public snapshot types. See current renderer boundary
at H `packages/render-2d/README.md:43–56` and current material interface at
H `packages/render-2d-vulkan/README.md:325–355`.

### Spatial identity, shapes and sources

Use signed 64-bit tile coordinates with an explicitly checked supported range
`[-2^62, 2^62-1]` on each axis. Compute intermediate additions, products and
floor division in a checked wider representation. Refuse out-of-range inputs;
never wrap. Horizontal storage keys cover 16 × 16 columns. Vertical residency
keys cover 32 tile levels, but are accounting/index regions, not allocated
16 × 16 × 32 voxel arrays. Negative coordinates use floor division and
nonnegative local remainders. Render using integer camera-relative offsets
before float conversion, never huge absolute float positions.

A cell `(x,y,z)` occupies the unit footprint and begins at elevation `z`.
The cutaway level `k` includes cell levels `z <= k`, with a clipping plane at
`k+1`; surface following returns the highest occupied cell level. Empty space
is a value, not a material requiring allocation. Public answers distinguish
`air`, `solid(material,shape)`, pending request, failure and coordinate refusal.

Use the full 16-ID mask catalog selected by D-25:

| IDs | Canonical reference names |
| --- | --- |
| 0 | Flat |
| 1, 2, 4, 8 | N, E, S, W |
| 3, 6, 9, 12 | NE, ES, NW, SW |
| 5, 10 | NS, EW (opposite-direction forms) |
| 7, 11, 13, 14 | NES, NEW, NSW, ESW |
| 15 | NESW; preserve the ID even with flat-top treatment |

Amendment: D-49/P-9 now defines the exact logical catalog and replaces ID 15's
flat-top treatment with a central half-height peak. D-44 permits demonstrated
mask corrections and requires solver proof; the original reference-fidelity
wording below does not override those decisions.

Rotation permutes the four bits; the world ID itself does not change when
the camera turns. Preserve reference silhouettes and face orientation in all
four facings. Establish canonical geometric coverage alongside each reference
mask so render faces/cutaway coverage and picking agree; do not substitute the
discarded thirteen analytic forms. TRA-1/TRA-7 must cover every ID, and TRA-8
compares the full visual matrix. Synarchy's mask selection is at S
`src/World/Render/Textures.hs:23–57`; its all-four normalization is at
`src/World/Slope/Compute.hs:153–166`. Walkability, speed and slope inference
remain deferred. Arbitrary fractional slabs and new IDs require a later
extension rather than silently falling back to flat terrain.

The initial Lua source is copied declarative data, not callbacks invoked from
a loading worker. Example: surface cell level `0`, soil depth `4`, material
identifiers `loam` and `granite`, then stone to the supported lower coordinate
limit. Recipe parameters may differ; no per-column buried stack is created.
Source queries evaluate only requested coordinates/ranges. Bounded authored
span patches allow the slope/cavity fixtures; reject overlapping source
patches, unknown materials, invalid shapes and oversized definitions at open.
The source is immutable for one arena incarnation. No random generator is
needed for this first flat source.

Concrete definition record: `materials` is a bounded list of unique authored
IDs; `layers` is a sorted, nonoverlapping list of `{z_min,z_max,material,shape}`
half-open intervals shared by all columns, with omitted lower/upper endpoints
meaning the supported coordinate extremes; `patches` contains bounded
`{x,y,z_min,z_max,value}` overrides, where value is air or material/shape.
Uncovered base intervals are air. The Lua arena builds stone `[-infinity,-3)`
and soil `[-3,1)` for its four-soil-cell default. Thus the engine implements
generic layers, not soil/stone-specific rules. Names/IDs are validated UTF-8
text with bounded length; unknown record fields and duplicate material IDs
are refused. Built-in shape IDs name the exact P-5 catalog.

### Sparse representation and edits

Keep three distinct representations: immutable source definition, sparse
resident detail, and retained session changes. Resident detail is a sparse map
of known column segments, each covering at most 32 consecutive levels within a
vertical region. Coverage is explicit: an absent segment is unmaterialized,
not air. Nonadjacent known segments do not force allocation or computation of
their intervening levels. A top-only load creates a one-cell segment, not a
32-cell slab. Region indexing never licenses filling buried source cells.

Within a materialized segment use the smallest of these packed encodings:

- **Uniform:** one 16-bit cell value for the entire known interval.
- **Runs:** sorted exclusive-end/value pairs, one packed 32-bit word per run;
  adjacent equal values coalesce. Segment start/length are common metadata.
- **Dense:** contiguous 16-bit values for exactly the known segment length.

A cell value has a 12-bit arena-local material palette index and the 4-bit
Synarchy slope ID. Index 0 is air, canonically encoded as zero; non-air indices
1–4095 map to stable authored material IDs. Reject an oversized catalog rather
than truncate it. Vegetation and other deferred systems are not stored here.
The packing is internal, not a saved-game or Lua numeric-ID compatibility
promise. The recipe validates IDs before values are packed.

For a segment of N cells and R runs choose uniform if R=1, otherwise runs
if `4*R < 2*N`, otherwise dense (dense wins ties for direct indexing).
This deterministic rule minimizes value payload among the three encodings;
the common sparse-index/segment metadata remains additional. It does not
claim minimum total process memory or universal optimal throughput.

Uniform lookup is constant time; dense lookup is direct indexing; runs use
binary search, with at most 15 runs in a selected nonuniform 32-cell segment.
Updates split/merge or use owner-local scratch for at most 32 known cells,
then choose the encoding once at commit. Published buffers are immutable and
must not alias subsequently mutated scratch. Range queries traverse runs in
bulk; callers are not required to issue a Lua request per cell. Do not expand
long implicit source/air intervals merely to select an encoding.

#### Storage comparison and selection evidence

Design-time exact payload calculation, 2026-11-06; not a runtime benchmark.
All candidates encode the same 16-bit material/shape values. A dense segment
costs 2N bytes, run records cost 4R bytes, and uniform costs 2 bytes. Segment
metadata, sparse indexes, Haskell allocation headers, source definitions,
retained changes and graphics are excluded from this payload-only comparison.

| Known segment | Dense bytes | Runs bytes | Selected bytes / mode |
| --- | ---: | ---: | --- |
| One requested surface tile | 2 | 4 | 2 / uniform |
| 32 identical cells | 64 | 4 | 2 / uniform |
| 32 cells, soil/stone in 2 runs | 64 | 8 | 8 / runs |
| 32 cells, a cavity in 3 runs | 64 | 12 | 12 / runs |
| 32 cells, 16 runs | 64 | 64 | 64 / dense |
| 32 alternating cells | 64 | 128 | 64 / dense |

Unrequested underground has no resident segment/value payload in any of these
cases. Source/retention metadata still exists. These values follow directly
from the proposed layouts. Synarchy's material+slope arrays also use two bytes
per stored cell (plus its separate vegetation array; S
`src/World/Chunk/Types.hs:72–94`); do not compare its full process memory with
this isolated payload table.

**Selection:** adaptive sparse packed segments (D-26). Always-dense spans lose
the uniform/layered-space savings; always-run storage can double payload for
alternating cells. Adaptive encoding retains direct indexing where runs cease
to save space, bounds recompression work and leaves untouched depth implicit.
This is a storage/algorithmic determination, not a measured speedup claim.
TRA-2/TRA-12 must still measure allocation, metadata overhead, lookup/scan/edit
cost and representation transitions on the implementation. Numerical host
budgets remain provisional; no terrain benchmark was compiled or executed,
and neither engine was launched for this payload calculation.

For this removal-only API, changes are canonical removed-cell intervals per
column. A removal of a ramp removes its entire occupied cell shape. Removing
air returns `changed=false` and creates no redundant change record. Repeated
removals merge into existing intervals; no ever-growing operation log is
required. The source plus these changes is the authority. Full materialized
chunks and derived render data are reconstructible caches.

A loaded region owns its working changes plus the revision inherited from
the session store. Every successful removal reserves its worst-case retained
edit storage before commit, so later offload can transfer the already-funded
changes without dropping them or requiring new storage. Offload atomically
merges/transfers changes into the arena store before discarding resident data.
Reload composes the immutable source and all retained removals before
publication. Querying an offloaded area must consult retained changes too.
Removing a tile only invalidates affected visibility/shape queries and render
regions; neighboring authoritative shapes remain unchanged (D-21).

### Execution, transactions and coherence

Use one dedicated terrain owner thread per injected session service. This is
the single writer for its arenas and keeps generation/edit work off the Lua
and native-window threads. It runs bounded work quanta and services queued
requests round-robin; initial generation uses this owner rather than an
additional worker pool. Pure source/shape algorithms remain independently
testable. No synchronous cross-VM calls and no Lua callbacks from this thread.

Assign monotonically increasing arena incarnations, content revisions and
request identities; never reuse a live identity or wrap exhaustion. Content
revisions change only on committed edits; residency changes have a separate
generation. A read captures one immutable content revision, including its
change overlay, and returns that revision with its result. A render/pick
snapshot also carries the camera revision and residency generation. No frame
mixes faces, picking and surface-following answers from different snapshots.

For removal: validate and reserve first; materialize the requested cell if
needed; stage the overlay and affected snapshot; then commit the edit and
successful result settlement in the same arbitration as cancellation and
arena admission. If cancellation/close wins before commit, nothing changes.
If commit wins, cancellation answers already settled and cannot undo it.
Provider adapters must expose that arbitration through the request endpoint;
never commit state and subsequently report a winning cancellation. Failure
leaves the previous content revision intact. Lua errors after a successful
operation do not roll back it or earlier operations (D-20).

Query/source results carry the arena incarnation and content revision. A late
result for a closed arena is discarded; a result based on superseded edits is
recomputed or rejected before publication. A stale picking token is refused
as `stale_view` rather than removing a different tile behind the old image.
CPU edit completion means authoritative commit, not immediate GPU display.
The previous coherent frame may remain until its replacement is adopted.

### Demand, bounds and failures

Camera demand describes a bounded visible region plus a one-chunk horizontal
prefetch margin; it is latest-value state, not a FIFO of every camera motion.
Manual/API queries may demand invisible coordinates. Deduplicate source work
by arena/revision/region, retaining separate caller interests. Canceling one
interest must not cancel work another still needs. Foreground queries and
edits precede view prefetch; use aging so accepted finite requests progress.

D-42/#639 amendment 2 makes camera demand best effort across the full approved
zoom/depth range: admit nearest/visible regions as capacity permits and leave
the rest pending and visibly absent. Do not reject an oversized camera demand
as invalid or reduce the zoom range to make all its regions fit. Explicit
requests retain priority and their construction-time capacity guarantee;
camera holdings must not prevent progress when eviction can release them.

Separate the followed surface level, automatic headroom and manual slice.
Initial configurable automatic headroom is 25 levels, matching Synarchy;
the effective automatic clip level is followed surface plus headroom. Manual
mode uses the exact selected slice without adding headroom. Initially permit
up to 250 levels below the effective clip level, with budgeted demand; this
matches Synarchy's maximum depth rather than the rejected fixed 32-level
viewing band. This is a visibility cap, not a promise to preload 250 levels
or a terrain floor. Zoom-dependent tuning is qualified visually in TRA-8;
do not conflate the 32-cell storage region size with the viewing depth.
Render only bounded visible faces and minimal adjacency facts; deep shafts and absent
columns must not cause an unbounded scan toward negative infinity. Source
interval summaries plus removed-span indexes answer next-solid/surface
queries without enumerating a long contiguous air gap. Bound the number of
resident vertical regions independently of horizontal columns.

Initial host profile, amended by D-42 (defaults, not measured capacity):
256 MiB resident terrain data, 64 MiB session edits, 128 MiB CPU render/staging,
128 MiB terrain GPU data including retiring versions, 128 internal load jobs,
256 queued terrain commands and at most two pinned CPU view revisions per
view. Also cap the service at 4 arenas, 8 views and 64 arena leases per session;
source definitions at 256 KiB/8,192 authored runs; a column result at 1,024
runs and an 8,192-level requested range; input polls at 128 events. Validate
each definition/result against the tighter existing copied-value limits too.
Existing per-instance/VM request limits still apply and may be the
tighter bound. Use explicit conservative byte accounting for metadata and
scratch, plus allocation measurements; these caps are not a process-RSS claim.

Evict unused LRU regions, excluding active readers, pending edit handoffs and
reserved publication dependencies. If no safe eviction fits, return busy for
explicit work and retain/coalesce camera demand for a later service quantum.
Do not spin, silently grow a bank, remove old edits or retry a failed edit.
An accepted removal must have reserved enough edit space to survive offload.
Infinite exploration does not imply infinite retained edits: at the configured
edit bound, new edits return busy until the arena ends; reads/navigation can
continue within their own bounds. This is the original RAM-only behavior:
D-40 replaces total-history retention with temporary backing, and D-41 selects
pause/preserve/recover for expected storage exhaustion or write failures.
The amended cache/disk admission contract remains Q-20. A session-wide failure
ends arenas under the existing supervision policy; no error UI is introduced.

Expected domain failures include `not_found`, `arena_closed`, `stale_view`,
`definition`, `source_failure`, `too_large` and `name_in_use`. Terrain requests
use M1's `OptionalRequest` policy: these failures are recoverable structured
results and do not latch an
instance failure, even when unread. This is the manager-authorized D-19
clarification recorded above; no new Lua options are added. Transient admission
is the existing immediate `busy` result with no request handle or provider work,
not a terminal request failure. Malformed Lua types,
foreign handles and out-of-range coordinates are ordinary validation errors
before provider work. Unknown failures/provider contract defects remain host
failures, not disguised empty terrain. Diagnostic records contain bounded
arena/request/revision context, not a per-cell stream.

### State ownership and shutdown

| State | Owner / writer | Readers / thread | Lifetime and disposal |
| --- | --- | --- | --- |
| Recipe, source patches, material IDs | Arena, immutable after open | Terrain owner; copied pure reads | Arena incarnation; freed after requests/snapshots release |
| Residency, working edits, retained changes, budgets | Terrain service single writer | Terrain owner only; snapshots for other threads | Session arena; offload transfers edits; close discards all changes |
| Commands, request settlement | Request adapter plus terrain owner | Lua threads submit; owner executes; settlement arbitrated atomically | Bounded per request; cancel/close settles once |
| Camera and input gestures | Presentation instance | Its Lua owner; copied view demand | Window/view; input reset clears held state before acknowledgement |
| Terrain view/pick snapshots | Terrain view adapter | Immutable borrows by presentation/planning | Bounded revisions; release never mutates another snapshot |
| Style texture interests | Terrain view adapter | Acquired at attachment; used by view preparation/publication | Held until view close; GPU uses may outlive the view's interests |
| Retained chunks, textures, pending uploads | Existing graphics host/backend | Backend owner; adopted frames hold exact generations | CPU release marks retirement; free only after actual frame completion |

Construct service resources through `withResource`. Closing first revokes new
admission and camera demand, then settles/cancels pending work at bounded safe
points, retires views, joins the terrain owner and releases CPU stores after
borrowers finish. Graphics retirement continues through the existing host's
adoption/completion protocol before device resources are destroyed. Never wait
for GPU completion while holding the terrain owner or a publication lock.
Arena replacement is close plus a fresh incarnation, not in-place identity
reuse; no explicit reset command is added in this arc.

### Lua surface and authority

Approved dot-call surface below. Operations that may load, edit or allocate
return the existing `request,nil` / `nil,{code="busy",...}` convention and
settle through `api.request`. The facade validates copied records with no
metamethod execution. Changes to this approved surface require explicit review;
semantics may not be left implicit. Result arrays are complete and bounded,
never silently truncated.

| Call | Contract |
| --- | --- |
| `api.terrain.open(name, definition)` | Create one session-local named arena with copied layered source and bounded authored patches; request result is an opaque arena lease. Either role may create; duplicate name settles as expected `name_in_use`. |
| `api.terrain.attach(name)` | Obtain this instance's own lease to an existing arena in the same content root/session; no global lookup or cross-content authority. Missing arenas and pending opens return `not_found`, without waiting for creation. |
| `api.terrain.cell(arena, {x,y,z})` | Async demand/read; result has revision and `air` or material/shape. |
| `api.terrain.column(arena, {x,y,z_min,z_max})` | Complete bounded runs for a finite half-open range; a valid request whose answer exceeds 1,024 runs settles as expected `too_large`, never a partial answer. The caller can narrow the range; existing range/result caps are unchanged. |
| `api.terrain.surface(arena, {x,y})` | Highest occupied cell level after edits, via source/change indexes; can explicitly answer absent for authored empty columns. |
| `api.terrain.remove(arena, {x,y,z} [, pick])` | One cell removal, including an explicitly queried buried cell; optional opaque pick token enforces displayed-revision consistency. Returns changed flag and committed revision. |
| `api.terrain.release(arena)` | Release this instance's lease; releasing the creator's final owner lease closes the arena, invalidates attached authority and cancels outstanding requests. Instance exit closes owned arenas. |
| `api.terrainView.open(window, arena, style)` | Presentation-only `OptionalRequest` through `api.request`, yielding a view with instance-owned window/texture authorities and a separate terrain publication path. One terrain view owns the window's presentation while attached. |
| `api.terrainView.move(view, {x,y} [, z])` | Async jump as an `OptionalRequest` through `api.request`; default surface following or explicit manual Z. Newest jump identity wins; canceled/older results cannot reposition the camera. |
| `api.terrainView.configure(view, changes)` | Bounded nonwaiting latest-intent update: pan delta, zoom, facing, absolute slice or checked integer `slice_delta`. Success is `true,nil`; temporary pressure is `nil,{code="busy",...}` with no partial change. Applied coherently; either slice form enters manual mode. Absolute slice and `slice_delta` together are rejected. |
| `api.terrainView.pick(view, cursor)` | Bounded nonwaiting read of the currently adopted snapshot; returns a copied `hit`/`no_hit`/`loading` record with opaque consistency authority on a hit. Never loads terrain or picks unloaded/hidden geometry. |
| `api.terrainView.close(view)` | Stop demand/publication; release CPU holds and retire GPU resources through existing host rules. |
| `api.input.poll(window, max_events)` / `acknowledgeReset(window, token)` | Presentation-only ordered input/reset boundary, preserving GLFW epochs; cursor observation is coalesced. |

The view-call timing and results above are a manager-authorized P-5
clarification: verified `het-manager` in `#het-terrain`, message
`v3zqruduivrr3i59p3a2zj96gi`, at 2026-11-07T03:32Z (2026-11-06 local).
`configure` and `pick` return no request handle and do not wait for terrain
preparation, graphics adoption or GPU completion. Terrain loading and render
publication remain asynchronous under the view adapter; a camera-intent
update is not a claim that its frame has already been adopted.

`slice_delta` is added atomically to the current effective clip level:
followed surface plus headroom in follow mode, or the selected slice in
manual mode. The result becomes the exact manual slice, with no further
headroom; positive deltas raise it. Lua accumulates fractional Shift-scroll
and submits whole-level deltas, without reading/reconstructing camera height.
An invalid combined absolute/relative slice record or a busy refusal applies
neither change. This is the manager-authorized P-5 consequence of D-12/D-14,
verified `het-manager` in `#het-terrain`, message
`yhfa7a443kthfhksqntcnjwct2`, at 2026-11-07T03:40Z (2026-11-06 local).

The named arena table is local to this narrow service, keyed by session and
content root; it is not a universal service locator. Claim a name in the same
admission boundary as its open. Concurrent opens cannot both create it;
the loser settles `name_in_use`. Pending opens, including gameplay opens held
for their logical position, block duplicates but are invisible to attach until
successful settlement. Failed or cancelled opens release the claim at terminal
settlement; successful opens hold it until arena closure. These and the
`too_large` outcome above are the manager-authorized D-19 consequences recorded
in message `qvcaa4ctkdb8swvxx7cvwpdkd6`.

Trusted instances within that content may obtain their own query/edit leases;
handles themselves never
cross VMs. Terrain mutation requests are domain operations, not direct memory
writes by presentation. A future gameplay integration can restrict authority
through injected ports without changing storage. Acquisitions are allowed in
init/update; waits only in update, and release/cancel in shutdown. No calls at
module top level. Parent session admission dominates every service gate.

View `style` maps the arena's material IDs to instance-owned texture handles,
face tint/filter settings and the selected view zoom/band settings; missing
material mappings are refused before attachment. It contains no shader source
or arbitrary callback. The adapter validates the full mapping and acquires
its own protected texture interests at attachment, held until view close.
Releasing the original Lua style handles revokes those handles for new caller
work only; the attached view continues rebuilding and publishing under its
already-acquired authority. Physical retirement waits for both the view's
interests and actual GPU uses. M1's released-handle behavior is unchanged.

This lifetime rule is a consequence of P-5's acquisition of texture authority
at attachment, authorized by verified `het-manager` in `#het-terrain`, message
`qfu3dq7r45vymbei4wuprummwn`, at 2026-11-07T03:23Z (2026-11-06 local).

Attaching a view
temporarily claims exclusive scene publication for that window; attempts to
publish an M1 rectangle scene while attached fail without replacing either
scene. Closing the view retires it and returns the target to normal use.

### Camera, appearance and render publication

Proposed bindings: WASD/arrows pan, middle-button drag, wheel zoom, Q/E rotate,
Shift-wheel changes slice by one cell level per wheel step. Positive scroll
raises the slice; accumulate fractional scroll before applying whole steps.
Use F8 for the temporary one-removal-per-press binding, ignoring key repeat;
delete that binding/glue in TRA-12. Default zoom scale is 1, range 0.125–8
relative to the artwork's native scale; these are view configuration,
not terrain coordinate limits.
Release/reset clears held keys, drags and scroll accumulators before input
acknowledgement. D-22 controls follow/manual transitions. Preserve zoom and
facing across camera jumps; no implicit Synarchy tile-level zoom reset.

In follow mode query the highest remaining solid cell at the camera's anchor
column, using retained edits as well as base terrain. Track that surface,
then derive automatic visibility using separate headroom (D-23); do not turn
the followed ground level into a manual cut plane. If the destination is not
ready, preserve the last coherent view until the jump can resolve; ordinary
pan can show unloaded regions as blank.
An authored empty column preserves the current slice and reports no surface.
Rotation preserves the same world anchor. Clamp zoom to the configured finite
range to keep view demand bounded, without restricting world extent.

Preserve Synarchy's diamond proportions (96-pixel width, 48-pixel top diamond,
16-pixel cell side at source scale; S `src/World/Grid.hs:47–65`, `:90–109`).
Copy the approved loam/granite artwork deliberately into authored content,
recording source paths and revision; no runtime dependency on `~/work/synarchy`.
Use the existing bounded texture pipeline. Derive geometric coverage masks
from the shared shape definitions and reuse the approved texture artwork;
Synarchy's face-map IDs are not the authoritative geometry definition.

Render only faces exposed to air or to the cutaway; do not modify terrain to
make a cutaway. Floors, walls and ceilings share material/shape authority.
An application material can shade/sample face textures under the existing
material ABI. If fixed-quad depth ordering cannot represent the selected
geometry correctly, stop and present that renderer-contract change before
expanding the backend: no per-fragment depth or vertex-ABI change is silently
authorized. Prove ordering with intersecting projections of roofs, ramps and
disconnected spans; a flat-arena screenshot alone is insufficient.

Prepared render regions key on arena/content revision, cutaway, facing and
material/asset version. Rebuild invalidated regions whole; bounds include all
projected faces. Publish new references coherently, retire old references
only after adopted frames finish, and include both versions in budget checks.
Picking uses the exact adopted view's geometry, metrics and camera mapping.
Retain a last coherent frame during preparation; missing new terrain stays
blank. The temporary removal shortcut submits the picked cell/token through
the public Lua API, then disappears before final qualification.

## Synarchy migration comparison — 2026-11-06 review

Requested by the owner after the complete draft: assess whether this preserves
Synarchy's goals and is an improvement, rather than merely a different arena.
Comparison baseline: S `3777d437ea00e1302bf55162ad5693fee4879187`, H design
`233fcfcdd01b6b8a58cc61588ba90b4c9ec4fae0`. Read-only inspection; neither
engine was launched or benchmarked. The following distinctions and concerns
do not change accepted behavior or silently approve replacement proposals.

**Subsequent owner disposition:** D-23 corrects automatic headroom separation;
D-25 selects the full 16-ID visual catalog; D-24 defers movement/traversal and
MR-3/MR-4/MR-5 integration work; D-26 selects adaptive storage. The comparison
table and MR narratives below describe the earlier draft at the baseline above,
not unresolved instructions to expand the current arc. P-5 carries the updated
contract. No measured performance superiority is claimed.

### Earlier draft comparison, preserved as review history

| Area | Synarchy at the inspected revision | Earlier design at `233fcfcdd01` | Assessment at review |
| --- | --- | --- | --- |
| Arena identity | Flat loam over granite; starting 5 × 5 chunks are not a horizontal boundary (S `src/World/Generate/Arena.hs:2–33`, `:70–104`) | Same layering direction and exploration-driven chunks | Familiar first consumer, not a new gameplay goal |
| Depth/storage | Arena base has 16 cells; columns have contiguous arrays, including interior air (S `src/World/Generate/Arena.hs:16–22`; `src/World/Chunk/Types.hs:72–94`) | Implicit deep stone, sparse runs, top-only initial detail and vertical eviction | Better fit for the owner's deep/gapped model; performance is unproved |
| Reconstruction | A common source plus edits reconstructs evicted chunks; arena parameters/edits also participate in saves (S `src/World/Generate/Arena.hs:2–14`; `src/World/Edit/Types.hs:2–9`) | Source plus session changes, no disk saves | Reuses an existing good idea; session-only persistence is an intentional first-arc reduction |
| Basic camera | Four facings, pan/drag/zoom, Shift-scroll, manual override (S `src/Engine/Graphics/Camera.hs:22–37`; `scripts/test_arena.lua:255–293`) | Same selected interaction direction | Similar feel, but numerical follow/depth defaults differ below |
| Camera visibility | Follow target is surface + 25; depth band varies with zoom, capped at 250 (S `src/World/Render.hs:47–81`; `src/World/Generate/Constants.hs:15–18`) | P-5 follows exact surface and proposes a 32-level band | Not equivalent; automatic clipping is a migration risk |
| Jump/zoom | `gotoTile(x,y)` sets tile-level zoom 0.5 and enables tracking; a zoom-map transition can restore tracking (S `src/Engine/Scripting/Lua/API/Camera.hs:223–318`; `src/World/Render.hs:282–288`) | Optional explicit Z, preserve zoom, no zoom-map reset in manual mode | Explicit-Z/manual behavior is approved; preserve-zoom/default range are proposed differences |
| Shapes | Directional slope bits select 16 masks; slope bits also affect pathing (S `src/World/Render/Textures.hs:23–57`; `src/Unit/Pathing/Cost.hs:331–347`, `:453–474`, `:491–528`) | Thirteen analytic solid shapes, shared by geometry/render/picking | Cleaner geometric authority is plausible; no established shape/traversal parity yet |
| Editing | Delete/add tile, set cell/material, set slope, structures and more (S `src/World/Edit/Types.hs:40–84`) | Removal-only public API and removed-span overlay | Appropriate demo scope, narrower than the eventual game |
| World generation/topology | Geological/hydrological source; cylindrical normal worlds, nonwrapping arenas (S `README.md:42–44`; `src/World/Chunk/Types.hs:37–55`) | Layered source with finite authored patches, nonwrapping arena | Real world generation/topology is deferred; the source abstraction must allow replacement |
| Rendering integration | Terrain, units, buildings and structures join one world render (S `src/World/Render.hs:40–45`, `:250–280`) | Terrain view exclusively claims the window's scene publication | Narrow initial path; composition with later entities/UI needs an explicit seam |

### MR-1. Automatic camera mode currently risks hiding higher terrain

P-5 clips at the highest occupied cell under the camera, with no headroom.
That can hide a neighboring taller hill even though the user asked to move
around hills naturally, and later hide buildings/units above the local ground.
Synarchy explicitly adds 25 levels above the tracked surface and coordinates
terrain/entity visibility (S `src/World/Render.hs:47–81`). This is an agent
proposal mismatch, not an owner request for that clipping behavior.

Recommend separating camera terrain following from an explicitly requested
cutaway: automatic mode needs a defined headroom/visible-height policy, while
manual Shift-scroll is an intentional cut plane. Compare full neighboring
hills and tall-object fixtures before selecting the margin/band. The proposed
32-level band and zoom limits are tuning hypotheses, not validated parity.
Do not just add 25 to a 32-level band and accidentally leave only seven levels
below the surface. A complete height-window rule is needed.

### MR-2. Slopes need a behavioral migration mapping

The thirteen-shape catalog was proposed for coherent geometry; it was not
derived from all of Synarchy's masks or movement rules. Synarchy's masks
include opposite-direction combinations, and its pathing tests directional
ramp bits for one-level steps and uses them for movement grade. Its roughness
logic deliberately preserves walkable downhill edges
(S `src/World/Slope/Roughness.hs:80–88`; `src/Unit/Pathing/Cost.hs:491–528`).
Therefore equal-looking sprites are insufficient evidence of equivalent
terrain. Recommend a fixture table mapping each reachable Synarchy slope to
surface shape, exposed faces and traversable edge connections; explicitly
resolve unmatched shapes before freezing the catalog. This requires geometry
and future-query compatibility tests, not implementing units/pathfinding now.
No automatic neighbor reshaping remains the owner's D-21 choice.

### MR-3. Arena recipes and removal records must not become permanent limits

P-5's global layers and finite patches describe the arena well, but cannot
alone express Synarchy's geological/hydrological world. Keep this as one source
implementation behind bounded coordinate/range queries, not the sole lifetime
world schema. Similarly, removed-cell intervals cannot represent future soil
replacement, filling, slope edits or constructed terrain; Synarchy already
has those edit varieties (S `src/World/Edit/Types.hs:40–84`).
Recommend reserving an explicit source-provider boundary and a general sparse
cell-value override contract, with removal represented efficiently as air.
The first public API can remain removal-only, and the first source layered.
No need to build geology, construction or disk persistence now. Define how
those future mechanisms attach without changing coordinate identity, source
queries or existing retained changes.

### MR-4. Terrain transactions must remain compatible with gameplay ordering

D-20 correctly defers general state/tick transactions. P-5 nevertheless lets
either Lua role submit committed edits, with the terrain worker choosing their
runtime processing order. Its same-ordered-trace guarantee does not establish
H's required deterministic gameplay for tick-assigned inputs
(H `docs/vision.md:212–222`). Later mining may need to change terrain, spend
work/stamina, produce an item and invalidate movement as one game action;
independent immediate terrain commits cannot alone supply that atomicity.
Synarchy's delete handler already performs related flora/simulation/render
updates (S `src/World/Thread/Command/Edit/Terrain.hs:35–87`).
Recommend defining a sequenced command/commit boundary that a future gameplay
owner can control, and treating presentation removal as a development adapter
to it. Do not let provider timing or memory availability become simulation
order. This does not require implementing whole-tick rollback now. Also review
P-5's creator-instance-owned arena lifetime: a game's world may need to remain
as a last committed snapshot after its logical Lua role fails, consistent with
the intended healthy presentation behavior (H `docs/vision.md:201–222`).

### MR-5. Terrain must compose with later scene content

P-5's exclusive terrain scene attachment is convenient for this no-UI arena,
but it is not a complete future scene composition contract. The renderer
already has ordered views/world/UI layers (H `packages/render-2d/README.md:59–69`);
Synarchy combines world entities and structures with terrain. Recommend a
terrain scene contribution owned by the common presentation host, preserving
later units, effects and UI layering. The first scene may contain only terrain;
that should not require redefining the view API when other content arrives.
Retain the existing exclusive native graphics attachment and GPU lifetime
rules; the issue is scene composition, not allowing competing renderer owners.

### MR-6. Sparse and asynchronous is not automatically faster or smaller

Synarchy's packed arrays give direct indexing and cheap contiguous traversal.
Runs avoid storing large empty or uniform volumes, but add indexing, split/
merge and metadata costs. Fragmented columns can compress poorly. A single
owner and individual asynchronous cell calls may bottleneck future fluid or
navigation scans. Recommend range/snapshot/batch paths and measurement before
choosing the final physical layout or expanding worker concurrency.

The original 32 MiB retained-edit cap (raised to 64 MiB by D-42) is also not
an eviction solution: retained edits
cannot be discarded, so new edits can remain refused until reset, even with
no chunks resident. This is an explicit P-5 policy, not observed Synarchy
equivalence or a measured capacity requirement. Preserve the owner's session-
only arena, but design configurable accounting and a future backing-store
boundary; explain capacity exhaustion distinctly from short-lived queue
pressure. No bounded-memory system can retain arbitrarily many unrelated
edits indefinitely without another storage policy.

D-40 now selects temporary session backing; this paragraph preserves the
earlier rationale, not a recommendation to retain all history in RAM.

### Assessment and proposed next action

The selected direction is a credible improvement for the owner's desired
gaps/depth model and for engine/game separation. The core arena experience is
intended to stay familiar. It is not currently a drop-in Synarchy migration,
and no performance, fidelity or completed implementation claim is supported.
Synarchy's shared reconstruction authority and edit replay are strengths to
preserve, not defects this design invented a solution for.

The review originally requested resolution before approval. The owner has now
provided that disposition in D-23–D-26: camera separation and mask fidelity are
current work, MR-3/MR-4/MR-5 and traversal are deferred, and storage uses the
adaptive design with payload analysis and later runtime qualification. Keep
Q-13's renderer proof gate and the narrow first-arena scope. Deferred migration
concerns remain recorded without blocking this arena or pretending full-game
compatibility has been implemented.

## Face-map amendment — source audit, 2026-11-07

This audit corrects the incomplete earlier migration comparison. Its evidence
prefix **S** means Synarchy `3777d437ea00e1302bf55162ad5693fee4879187`;
**H** means Hetoimasia `2a2a4a9ff9a709636dda9fa6621deb37a35ca6f6`.
H file:line references, including this design's original sections, are to that
pre-amendment revision. **P** means held, unmerged PR #654 at
`57bd8a40c17fb4f62de895272f8081ade583f95a`. Source and image inspection only:
no build, test, game launch or performance experiment was run for this audit.
Synarchy was read from a temporary snapshot, never modified.

### Verified path from cells to pixels

1. **Cell data and material selection.** S stores 16×16 columns of material,
   slope and vegetation IDs in contiguous arrays, including interior air
   (`src/World/Chunk/Types.hs:72–109`). The arena initializes a flat material
   stack and slope zero (`src/World/Generate/Arena.hs:126–149,212–232`).
   Terrain edits replay before reloaded chunks are admitted
   (`src/World/Thread/ChunkLoading.hs:170–189`). A material selects an ordinary
   colour texture; a world slope ID is rotated for the camera and selects a
   separate face-map texture (`src/World/Render/Textures.hs:17–57`). No
   polyhedral mesh is constructed from that ID on this terrain draw path.

2. **The loaded images, not just a generator name.** S
   `scripts/world_view.lua:96–145` loads `isoface.png`, all 15
   `isoface_slope_*.png`, left/right masks and `isoface_level_1..8.png`.
   The inspected images are 96×64 RGBA with binary alpha; their RGB channels
   encode right/top/left weights. Mixed RGB values in slopes describe weighted
   lighting, not three independently textured geometric polygons. The
   `isoface_slope_nesw.png` image is a lower flat diamond, with nonzero alpha
   beginning at row 16 and no full-block side silhouette. It is visibly
   different from ID 0's full three-face `isoface.png`.

   S `src/World/Slope/FaceMaps.hs:33–47,65–119,128–161` contains procedural
   helpers, but its `SlopeFaceMaps` record has only flat plus four cardinal
   ramps, not the full shipped 16-image catalog. Its cardinal ramp helper
   makes the entire canvas opaque, and its side helpers only fill rows 48–63;
   the shipped side masks start at row 23. Runtime source/script inspection
   found PNG loading, not calls generating the full catalog from those
   helpers. Porting the helpers alone would not preserve the inspected art.
   The level masks are fluid thicknesses: each adds two pixels of side below
   the same diamond (`FaceMaps.hs:52–78`; `Textures.hs:80–90`). They are not
   sixteen terrain slopes or authorization to add fluids.

3. **Quad production, coverage and cutaway.** S walks loaded columns in the
   visible slice/depth range and emits one full sprite quad for each non-air
   terrain cell it visits (`src/World/Render/Quads.hs:211–265`). A quad uses
   the whole colour image and whole selected face map with UV 0..1; its top,
   sides and slope silhouette are pixels in that quad
   (`src/World/Render/TileQuads.hs:42–113`). The projection uses the 96/48/16
   proportions (`src/World/Grid.hs:47–109`), with vertical displacement
   `(worldZ-zSlice)*tileSideHeight`. It does not emit one mesh face per solid
   plane. Deeper terrain cells provide exposed stacked sides; neighboring
   sprites hide overlap through draw order.

   At the cut, S may emit a blank full-tile sprite when the terrain surface
   is above the slice but no stored material exists at that slice
   (`Quads.hs:292–311`; `TileQuads.hs:117–157`). This is not authoritative
   generation of a cut surface. Additional left/right quads in
   `src/World/Render/SideDecoQuads.hs:29–58,126–179` are fluid edge strips,
   not proof that ordinary terrain uses split solid faces. The current
   amendment must account for cavities, roofs and cutaways explicitly rather
   than treating S's blank fallback as known solid terrain.

4. **Ordering and cursor.** S tile painter keys are facing-adjusted `x+y`
   plus relative Z × 0.001 (`TileQuads.hs:54–66`). The foreground/background
   cursor adds/subtracts 0.0004, while fluid tops add 0.0005
   (`TileQuads.hs:167–176,352–429,432–457`). Quads are grouped and sorted by
   layer, with stable painter tie rules, then static and dynamic runs merge
   (`src/Engine/Scene/Types/Batch.hs:130–160,187–212`). Its world pipeline uses
   source-alpha blending (`src/Engine/Graphics/Vulkan/Pipeline/Bindless.hs:141–152`).
   Thus matching a single silhouette does not by itself qualify the new
   renderer's whole-quad depth order at roofs or overlapping cell sprites.

5. **Vertex and fragment stages.** S
   `src/Engine/Graphics/Vulkan/ShaderCode.hs:85–169` carries texture and
   face-map handle IDs, render flags, facing, world U/V and solar-page slot.
   Handles resolve through the slot table; an unresolved face map uses the
   default face map (`:214–227,254–260`), whose texel is neutral top weight
   `(0,255,0,255)` (`src/Engine/Graphics/Vulkan/Texture/DefaultFaceMap.hs:43–44`).
   The fragment samples both images, normalizes RGB weights (zero sum means
   top), swaps right/left weights for odd facings and rotates apparent sun
   direction by facing × π/2 (`ShaderCode.hs:254–303`). It multiplies base
   colour by tint, weighted face brightness and global brightness. Ordinary
   alpha is colour alpha × face-map alpha (`:305–318`). S writes that alpha
   for blending; it does not itself use Hetoimasia's 0.5 cutout discard.

   Selection outline is a separate flag using four neighboring **colour
   texture** alpha samples before face-map shading (`:235–251`). Lifecycle
   flag bit 1 deliberately ignores the face-map alpha for partially built
   structures while keeping its RGB lighting (`:307–317`). Neither feature
   is required merely to mask a terrain tile; neither has been silently added
   to this UI-free arena.

6. **What the full lighting path actually contains.** The terrain shader has
   weighted top/left/right directional shading and an ambient day/night
   curve, not a terrain shadow-map/occlusion-light simulation. With
   `h=sin(2*pi*phase)`, ambient is `0.5+0.2*h` for h≥0 and
   `0.15+0.35*(1+h)` otherwise. Direct strength uses `max(0,h)`; side ambient
   is ambient × 0.85, and side direct weight is `0.4+0.6*max(0,±direction)`
   (`ShaderCode.hs:204–212,286–303`). A fixed phase and facing supply all
   inputs needed for this face shading; advancing time is a separate system.

   Full S day/night adds independently advancing visible-page clocks and
   calendar/time-scale behavior (`src/World/Thread/Time.hs:35–69`;
   `src/World/Time/Types.hs:91–115`), up to 16 solar-page entries
   (`src/Engine/Graphics/Solar.hs:120–121`), each page's angle/circumference
   (`src/World/Render.hs:393–413`), and a live global override applied at UBO
   upload (`Solar.hs:138–171`; `src/Engine/Loop/Frame.hs:352–385`). The vertex
   stage adds `(gx-gy)/circumference` to phase without wrapping before
   interpolation (`ShaderCode.hs:126–165`); the fragment's periodic functions
   give longitude-local lighting. It is not a stored light map per column.
   The CPU local-sun query applies the same longitude concept
   (`src/World/Time/Local.hs:26–37`). Nonpositive world size falls back to
   one chunk's circumference, not an infinite-world lighting policy.

   A further source discrepancy must stay explicit: clock comments label
   phase 0 midnight and 0.5 noon (`Time/Types.hs:39–61`), but the shader's
   sine puts maximal sun height at 0.25. Copying labels is not evidence of
   astronomical parity. Separately, S applies depth dimming/blue haze and
   underwater tint before lighting (`TileQuads.hs:68–98`), plus zoom-map
   crossfade (`src/World/Render.hs:73–81`). Static face shading alone does
   not imply those presentation effects have been ported.

7. **Picking is not face-map accurate in S.** The per-frame cursor and Lua
   picker share `pickWorldTile` (`src/World/Render/CursorQuads.hs:117–129`;
   `src/Engine/Scripting/Lua/API/WorldQuery/Pick.hs:85` onward). It transforms
   a screen point through the camera, descends Z from the slice, inverse-
   projects a grid position and returns the first non-air stored tile in a
   visible chunk (`src/World/Render/HitTest.hs:93–158`). It does not sample
   face-map/colour alpha or use slope geometry. S's terrain data and cursor
   agree on a cell convention, but this is not pixel-perfect silhouette
   agreement. The new design's promise to pick what is actually drawn needs
   explicit masked-quad coverage and ordering, not a blind copy of that picker.

### Focused terrain-picking audit, 2026-11-07

The owner requested this closer inspection before answering Q-16. This is
source/asset evidence at the same S revision, not a report of a running-game
reproduction. D-30 subsequently approves the proposed picking approach;
D-31 subsequently establishes that blank cutaway coverage deliberately
conceals undiscovered terrain, including air gaps. Interpret the blank/pick
observation below in that fog context, not as a direction to remove the blank.

**What S already does well.** Hover and synchronous terrain clicks use the
same pure `pickWorldTile`, with facing, zoom, framebuffer aspect, window-pixel
normalization, elevation and the displayed depth band
(`src/World/Render/HitTest.hs:79–120`). It canonicalizes wrapped coordinates,
rejects unavailable finite-arena tiles and missing columns, and checks chunk
visibility (`:130–158`). A degenerate viewport returns no hit (`:95–99`).
The synchronous click path avoids relying on a lagging hover cache and
returns page-selection generation with the hit to protect subsequent actions
(`src/Engine/Scripting/Lua/API/WorldQuery/Pick.hs:85–112,124–158`). These are
useful correctness measures to preserve, not reasons to replace everything.

**What the terrain picker actually intersects.** At each descending integer
Z it subtracts half the full sprite height, inverse-projects to one rounded
grid coordinate, and accepts nonzero material there. It never reads
`ctSlopes`, a texture, alpha or the sorted quad list
(`HitTest.hs:112–158`; `src/World/Grid.hs:238–243`). Thus all 16 shapes have
the same pick footprint at a given cell/Z even though their visible coverage
differs. The renderer instead chooses a facing-dependent mask
(`src/World/Render/Textures.hs:24–57`), emits its whole sprite
(`src/World/Render/TileQuads.hs:54–66,101–104`), and multiplies colour alpha
by mask alpha (`src/Engine/Graphics/Vulkan/ShaderCode.hs:254–260,305–318`).

Concrete counterexamples, calculated from those expressions and the shipped
PNGs rather than inferred merely from the absence of an alpha lookup:

- Use South facing, slice Z=0, loaded in-bounds cells and 96×64 sprite-local
  coordinates. A cell at `(0,0,0)` has top-left projected pixel `(-48,0)`.
  For its local point `(u,v)`, the pick's candidate at Z=0 is
  `round(((u-48)/48 + (v-32)/24)/2)` for X and
  `round(((v-32)/24 - (u-48)/48)/2)` for Y. Each lower Z adds `16*Z` to
  the numerator's Y term. These are the normalized constants from
  `Grid.hs:61–109` and `HitTest.hs:115–120`, not new engine units.
- **Transparent ramp accepted:** at local `(57.5,15.5)` the candidate is
  `(0,0,0)`, but `isoface_slope_n.png` texel `(57,15)` has alpha 0, with a
  fully transparent 7×7 neighborhood. Put a flat cell at `(-1,-1,-1)`:
  it draws behind at local `(57.5,47.5)`, where `isoface.png` has alpha 255.
  The front ramp is still picked before the visible flat cell can be tried.
- **Visible side assigned below:** put flat cells at `(0,0,0)` and
  `(0,0,-1)`, with other candidates empty. At local `(48.5,58.5)` the upper
  cell's mask alpha is 255. The picker first looks at empty `(1,1,0)`, then
  returns `(0,0,-1)`. The upper cell is what the painter order actually draws
  on top. This is a visual-ownership mismatch even without a ramp.
- **Visible top tip assigned behind:** at local `(48.5,4.5)` a flat cell's
  mask is opaque, but the pick candidate is `(-1,-1,0)`. If that rear cell
  exists, it is returned even though `(0,0,0)` draws on top there. The fixed
  pick diamond is centered at sprite Y=32; the artwork's top diamond is
  centered at Y=24. Center clicks can work while these edge areas disagree.

For those samples, the shipped `assets/textures/world/loam/loam.png` colour
alpha is also 255 at the relevant opaque texels. Painter keys come from
`TileQuads.hs:61–62`, with ordering defined by
`src/Engine/Scene/Types/Batch.hs:128–160,187–212`. The calculations stay away
from rounding ties; the ramp example's transparent neighborhood avoids a
single boundary-texel artifact. This establishes source-level counterexamples,
not their frequency in typical generated terrain or a GPU test result.

Two related limits matter for the migration. The blank cutaway fallback can
draw where there is no stored non-air cell (`src/World/Render/Quads.hs:292–311`),
while this picker only accepts stored cells. Generic three-face cursor art
also uses `wtIsoFaceMap`, not the target's slope map
(`TileQuads.hs:352–370,443–457`); it is a cell marker, not evidence of exact
ramp coverage. Separately, synchronous picks sample live camera/tile/window
references (`WorldQuery/Pick.hs:133–149`) rather than an adopted render token.
That is a potential displayed-frame consistency gap during updates, not a
race reproduced by this inspection. The inspected seam tests
(`test-headless/Test/Headless/World/Render/PickSeam.hs`, especially its
`solidChunk` and `pixelFor` helpers) exercise coordinate framing and center
clicks with slope zero; they do not establish sprite-alpha agreement.

**Recommendation, subsequently approved as D-30:** use the adopted draw's candidate
quads, transforms and front-to-back order, then test the same material/mask
coverage at the cursor. Retain spatial pruning and shared coverage per asset;
no per-cell copy or GPU readback is implied. Merely adding an alpha rejection
to S's one-grid-candidate-per-Z loop would address some false hits but still
miss visible side/top pixels that belong to another candidate at that Z.
Cell identity and edit authority remain distinct from visual coverage; exact
cut-surface handling and filtering/threshold rules still require agreement.

### Cross-facing shape-mask consistency audit, 2026-11-07

The all-16 logical geometry catalog must not be inferred from image names or
from S's incomplete procedural generator. A further source/asset check finds
that even arbitrary geometry confined to a unit cell cannot have every pinned
mask as its exact rotated silhouette. This is distinct from the already-known
failure of H's particular lower-envelope solids to match the artwork.

**Scope and assumptions.** S `src/World/Render/Textures.hs:24–56` rotates
the four slope bits for the camera and selects the corresponding PNG; it
does not supply independent geometry per facing. S `src/World/Grid.hs:61–65,
99–108,226–236` gives the 96-pixel width, 48-pixel diamond and 16-pixel level;
`src/World/Render/TileQuads.hs:54–66,101–104` uses the same full-canvas quad
placement/UV for these masks. Compare the same shape under a quarter turn,
within the approved unit-cell bounds, at equal elevation and without fog or
other tiles hiding it. Under that interpretation the following is impossible.
This does not assert that S implements an exact geometric solid: its draw
path is deliberately sprites, and it can display inconsistent silhouettes.

**Reproducible counterexample, using S's pinned assets.** In local unit-cell
coordinates, the full-block canvas fixes
`u = 48 + 48(x-y)` and `v = 16 + 24(x+y) - 16z`, for `0 <= x,y,z <= 1`.
A positive shape quarter turn maps N to E and maps points to `(1-y,x,z)`
(the adopted H convention, `packages/terrain/src/Hetoimasia/Terrain/Geometry.hs`,
`rotatePoint`; equivalently compare S's matching camera/facing-bit rotations).

- `isoface_slope_e.png` texel `(48,2)` is `(0,255,0,255)`: fully opaque.
- For any point in the unit cell that could project into that entire texel,
  `u in [48,49]`, `v in [2,3]`, let `q=x+y`, `d=x-y`. Then
  `0 <= q <= 1/8`, `0 <= d <= 1/48`, and `13/16 <= z <= 1`.
- Inverse rotation puts the corresponding N point at `(y,1-x,z)`. Its
  projection is `uN=48q`, `vN=40-24d-16z`: contained in
  `[0,6] × [23.5,27]`.
- Every enclosing N texel is transparent. The first opaque N texels in
  columns `0..7` occur at rows `39,39,38,38,37,37,36,36`. This separation is
  much larger than a pixel-edge or nearest-versus-linear sampling convention.

Thus an opaque part required by E would have to exist inside a transparent
part of N after rotation. Allowing a non-convex solid inside the same cell
does not resolve this example. This is a mathematical source/PNG check with
Pillow reading existing pixels, not a game launch, GPU test or proof that
every other mask is inconsistent. Snapshot integrity was checked against
S's Git blobs: N `effc21564c7a653605dcbafca23ce7bc560e262d`,
E `5ed533b4d9467fa3b371a4cb489a87844fa64611`.

**Correction direction approved by D-44; catalog approved by D-49.** Preserve
all 16 authored IDs, the isometric material artwork and the face-map shader
approach, with corrections to inconsistent mask silhouettes/face weights in
the new project's catalog.
Specify the intended logical shapes/openings explicitly, then derive or
validate their four-facing masks against those definitions. This keeps cavity
discovery and queries camera-independent and makes their openings agree with
the visible shape. D-44 qualifies/supersedes D-25's visual-form fidelity
where the pinned artwork is inconsistent; it does not authorize renumbering
IDs, dropping shapes, automatic neighbor reshaping or editing Synarchy.

The alternative of retaining exact masks while accepting disagreement between
visible openings and logical geometry is not selected. D-44 requires proof
from the solver, including reproduction of the original mismatch and the
corrected result. D-49/P-9 now specifies the replacement shapes, including
ID 15's central half-height peak. Pixel-edge conventions and lighting still
need a concrete contract; approval of the catalog is not implementation proof.

### Solver evidence required for the shape/mask correction — D-44

This is an implementation acceptance requirement, not evidence already
produced by the design or permission to begin solving. Q-19 must carry it into
the relevant follow-up slice and final TRA-12 qualification.

- **Reproduce the defect.** Pin the reference source and asset hashes; explain
  coordinate, rotation, UV and sampling conventions. Reproduce the original
  N/E counterexample above and identify the demonstrated mismatch motivating
  each changed mask. Report any refuted assumption instead of using this
  document as an unquestioned expected result.
- **Make the correction visible.** Supply labeled original/corrected offscreen
  captures at matched scale, facing, camera and lighting. Include all 16 IDs
  in all four facings, isolated tiles and joined terrain; distinguish changes
  made for correctness from unchanged artwork. Show canonical logical geometry
  and openings beside/over the mask result so the owner can inspect what was
  corrected. Pin captures and reproduction commands to the submitted revision.
- **Check more than the pictures.** Verify the approved shape table's quarter
  turns and solid/empty regions; compare projected reference coverage with
  GPU alpha and CPU screen picks using the agreed sampling/edge convention.
  Expected geometry comes from the approved catalog, not snapshots of whatever
  the new implementation happens to produce. Verify the face-weight/lighting
  changes at selected sun positions; a silhouette-only check cannot establish
  that a changed lighting mask is correct.
- **Prove opening behavior.** Include a ramp-created diagonal opening into a
  hidden cavity and sealed/zero-width-contact controls, rotated through all
  four facings and crossing a chunk boundary. Discovery and logical point/ray
  queries must agree with the canonical shape; camera rotation must not change
  connectivity. Check fog remains non-interactive and visual picking follows
  the corrected drawn coverage. Exercise offload/reload for the discovered
  result in the integrated qualification.
- **Deliver the proof.** Land the evidence write-up and retained captures via
  the repository's documentation/evidence workflow, link the immutable revision
  from the correction PR and include it in the owner-facing handoff. Unit tests
  alone, unretained local captures or the old solid-renderer evidence do not
  satisfy this requirement. Unexplained mismatches block the affected renderer
  qualification and final arena acceptance until resolved.

### Depth-effect qualification required — D-47

Specify the numerical depth/colour contract under Q-18 before implementing
its expected-result tests. The solver must then deliver the following evidence
through the same retained, revision-pinned workflow as D-44:

- A controlled scene with repeated soil/stone materials and slopes at known
  depths, including adjoining chunk boundaries. Capture all four combinations:
  neither effect, darkening only, haze only and both. Each disable control must
  reproduce its defined baseline without changing alpha coverage or picking.
- Independent reference calculations in the renderer's linear-colour contract
  for depth zero, intermediate depth, the configured end of the effect range
  and clamped out-of-range inputs. Check each curve's intended direction,
  bounds and exact composition order with face lighting; visual approval alone
  cannot detect a colour-space or clamp error reliably.
- Offscreen comparisons at selected sun directions/elevations and all four
  camera facings, sampling corresponding visible surfaces. Show that lighting
  still follows D-46 while the depth effects follow their specified depth
  measure. Include non-integer zoom and partially transparent/cutout edges
  under D-45; darkening/haze must not create opaque fringes or select fog.
- Controlled pan/zoom/rotation, manual slice changes, surface-following over
  different heights, and jumps with/without explicit Z. Expected changes from
  a changed depth must be distinguished from spurious resets, stale parameters
  or changes caused solely by chunk boundaries. Camera/lighting/style and
  retained terrain must publish coherently; no frame may combine incompatible
  old and new settings.
- Offload/reload and delayed chunk arrival in the same scene. Identical terrain
  under the same adopted camera/style must regain the same depth treatment;
  loading order must not create seams. Supply a side-by-side comparison of the
  owner's reported bad case when it can be reproduced, documenting what
  changed and any remaining limitation.

The implementation handoff must include reviewable captures and the numerical
results/reproduction commands, not only a passing test count. This is a
required qualification matrix, not a claim that tests have run or that the
unspecified reference complaint has already been reproduced. It adds no
fluid, moon, day/night-cycle or UI testing scope.

### Existing material ABI and the remaining integration gap

The manager's ABI reading is supported. H
`packages/render-2d-vulkan/src/Hetoimasia/Render/TwoD/Vulkan/MaterialSources.hs:11–36`
defines the fragment function, per-instance parameter, full texture handles
in records, secondary `sampleTexture` and application push fields. Its
`Material/Sample.hs:34–51` already samples a second texture from a one-handle
record. H `packages/render-2d/src/Hetoimasia/Render/TwoD/Material.hs:27–37`
allows records in retained chunks and generation-checked handles.
H `packages/render-2d-vulkan/src/Hetoimasia/Render/TwoD/Vulkan/ShaderSources.hs:353–375`
discards alpha below 0.5 on the cutout path. A new face-map material can use
these mechanisms without a new descriptor, vertex format or depth output;
this is source feasibility, not a new GPU qualification result.

Important conditions the amendment must resolve:

- The material returns **premultiplied linear colour**. Applying mask alpha
  must preserve that contract, including the ordered path; copying S's
  straight-alpha output verbatim is wrong for H. Binary-alpha eligibility,
  nearest/linear filtering and CPU pick threshold must agree.
- Numeric face weights require a data-image policy. H's general decoder has
  `DataImage` (`packages/asset-image/src/Hetoimasia/Asset/Image/Png.hs:3–19`),
  but the production bounded Lua decoder is explicitly sRGB colour-only,
  with no data-image option (`PngDecode.hs:14–25`;
  `packages/lua-engine/texture/Hetoimasia/LuaEngine/Texture/Pipeline.hs:34–38,180`).
  S uploads RGBA8 UNORM (`src/Engine/Graphics/Vulkan/Texture.hs:37–47`).
  Passing a face map through the current Lua colour path would transform
  intermediate RGB weights. The ABI supports another texture; that does not
  mean the bounded asset/API path already preserves its intended data.
- Picking needs CPU coverage from the same pinned artwork/mask identity and
  sampling convention as the adopted draw. A full texture handle alone does
  not supply CPU alpha. Its storage, budget, version and lifetime require
  explicit ownership; no GPU readback per click or image-shaped world state
  is implied.
- The new whole-cell/face quads need their own ordering/occlusion proof.
  Existing Q-13 results qualify the old solids and material, not automatically
  the changed silhouettes. Keep the unchanged ABI and re-prove the affected
  fixture matrix before claiming final acceptance.

### Re-audit of the approved design and filed slices

These are differences found across the approved terrain arc, not a claim of
full-game Synarchy equivalence. Rows marked **intentional** record earlier
owner choices; they do not reopen them. **Amendment** rows need decisions or
contract corrections before the new path is qualified. Both sides use the
pinned evidence revisions above.

| Area and disposition | Synarchy evidence | Hetoimasia design / implementation evidence and consequence |
| --- | --- | --- |
| Shape IDs versus visible shape — amendment | S `Render/Textures.hs:24–57`, loaded masks in `scripts/world_view.lua:105–128`; ID 15 image is a lower diamond. `Slope/Compute.hs:153–166` normalizes some generated 15 cases to 0; it does not make their authored images equal. | H design D-25 `:689–701`, P-5 `:826–846`; `packages/terrain/src/Hetoimasia/Terrain/Geometry.hs:17–29,193–202` instead defines lower-envelope edge solids and makes 15 equal 0. #637's identities are reusable; its solid silhouettes are not Synarchy fidelity proof. |
| Facing and projection convention — verified agreement, preserve it | S `Grid.hs:185–206,226–236` and `Render/Textures.hs:24–36` rotate positions and masks consistently. The shader separately numbers South/West/North/East as 0/1/2/3 (`Engine/Loop/Frame.hs:362–366`). | H `packages/terrain/src/Hetoimasia/Terrain/Shape.hs:54–76` selects the same view mask using positive turns 0/3/2/1; `Terrain/Render2D/Projection.hs:108–140` uses those turns and the same 96/48/16 proportions. Do not feed H's positive-turn count straight into S's differently numbered lighting-facing input. |
| Cell sprite versus separate geometric faces — amendment | S `Render/Quads.hs:211–265`, `Render/TileQuads.hs:42–113`. | H design `:1175–1190`; `Terrain/Render2D/Plan.hs:682–714`; P `packages/terrain-render-2d/material/Hetoimasia/Terrain/Render2D/Material.hs:11–41`. #643/#644 draw polygons cut from shared solids, not the face-map sprite. |
| Exposure, adjacency and cut surfaces — amendment | S non-air cell enumeration and blank slice fallback, `Render/Quads.hs:222–238,292–311`; fluid side strips are separate `SideDecoQuads.hs:29–58`. | H design D-7 `:368–371`, `:1183–1190`; Plan `:694–714` uses solid adjacency and flat caps. Changing silhouette alone leaves occlusion/cavity/cap differences unresolved; do not draw missing terrain as known solid. |
| Ordering — amendment | S tile/cursor/fluid painter offsets, `TileQuads.hs:61–62,174–176,403–407,452–454`; `Engine/Scene/Types/Batch.hs:187–212`. | H Plan `:59–68` orders projected solid planes and assigns unique depth keys. Sprite ordering must be requalified; mathematical ray depth through the old solid is no longer the appearance oracle. |
| Pick authority — amendment | S `Render/HitTest.hs:112–158`: inverse grid, descending Z, non-air; no slope or alpha test. | H `Terrain/Render2D/Pick.hs:1–28,81–109` picks planned solid polygons; design `:1192–1199` and #645/#646 demand adopted-view consistency. Preserve consistency while changing the coverage being tested to match rendered masks. |
| Lighting and depth appearance — amendment/open | S ShaderCode `:204–212,254–318`, TileQuads `:68–98`, solar/time path above. | H D-18 `:576–587`, P-5 `:1175–1190` and #644 have no selected face-map lighting contract. Static shading, dynamic day/night and depth haze are different scope choices, not one mandatory package. |
| Texture data, filtering and alpha — amendment | S loaded masks, UNORM upload `Engine/Graphics/Vulkan/Texture.hs:37–47`, source-alpha blend `Pipeline/Bindless.hs:141–152`, global world sampler `Texture/Policy.hs:23–41`. | H premultiplied linear material ABI, colour-only bounded decoder and 0.5 cutout above; P material `:35–41` forces nearest. New mask/data loading and CPU/GPU sample semantics need explicit agreement; exact raw framebuffer colour parity is not established by copying PNG bytes. |
| Cache and resource ownership — intentional foundation, amend payload | S `Render.hs:115–149` caches page-wide sorted CPU quads by generation/camera/solar slot; `Render/Camera.hs:19–57` uses viewport margins. | H design `:1192–1199`, #645 requirements 3–8 use immutable retained regions, adopted revisions and completion-safe retirement. Keep this improvement; add mask/lighting identity, CPU coverage and secondary texture interests to the owned payload, rather than copying S's cache wholesale. |
| Flat default source — intentional | S `Generate/Arena.hs:16–33,212–232`: finite initial stone stack, four soil cells, seeded surface vegetation. | H D-7/D-16, P-5 `:848–866`: implicit stone to supported lower bound, four soil cells, no vegetation or RNG. Face maps do not add geology/flora. |
| Streaming and storage — intentional | S `Chunk/Types.hs:72–109` stores contiguous arrays and interior air; `Slope/EdgePatch.hs:95–110` extends bottoms by repetition. | H D-5/D-11/D-26, P-5 `:809–818,869–905,992–1036`: sparse adaptive segments, source-plus-removals, checked coordinates and explicit budgets. Keep lazy depth and gap semantics; no new per-cell light volume. |
| Arena extent/startup — intentional | S `Generate/Arena.hs:70–104,120–149`, `scripts/test_arena.lua:188–207`: initial 5×5, optional finite rectangle, no arena wrapping. | H D-7/D-11 and P-5 `:811–818,994–1008`: camera demand, no designed edge/bottom within checked range. Do not import cylindrical longitude or finite-world solar circumference without an owner choice. |
| Shape changes on edits — intentional | S `Slope/Compute.hs:130–169`, `Thread/ChunkLoading.hs:256` applies inferred slope edits. | H D-21/D-24 `:641–651,677–687`: authored IDs and only requested cell removal; walkability/speed/inference remain deferred. |
| Edits, retention and authority — intentional | S `Edit/Apply.hs:298–343,412–438`, `Thread/ChunkLoading.hs:170–189,531–540`: broader edits/overlays, replay including saved edits. | H D-10/D-19/D-20 and P-5 `:958–990,1074–1089`: atomic bounded optional requests, session retention, no persistent saves or whole-tick rollback. Cell/material/shape records remain separate from texture pixels; any altered subcell geometry contract needs its own answer. |
| Camera navigation — intentional extensions | S `Render.hs:49–64,282–317`, `scripts/test_arena.lua:265–293`, `Engine/Scripting/Lua/API/Camera.hs:223–318`: headroom, manual tracking off, reset action, two-coordinate jump. | H D-12–D-14/D-22/D-23 and P-5 `:1105–1115,1154–1173`: optional jump Z, exact manual level through local navigation, fractional scroll accumulation, atomic relative slice, preserved zoom/facing. Keep approved controls. |
| Zoom/depth/crossfade — partly intentional, look still open | S `Render.hs:73–81`, `Grid.hs:148–154`: zoom-dependent depth and fading terrain into zoom-map rendering. | H P-5 `:1001–1009,1154–1163` has 250 maximum depth, own zoom units/range and no zoom map. Equivalent maximum is not identical depth curve or apparent zoom. No map/UI crossover is added by this amendment. |
| Input, cursor and selection effects — intentional scope | S `CursorQuads.hs:56–129`, `TileQuads.hs:352–429`, ShaderCode `:235–251,307–317` includes visible cursors, outlines and structure lifecycle treatment. | H D-8/D-9/D-18, #647/#648: no UI, temporary F8 then Lua API only; ordered reset-safe input. Correct terrain masking does not require importing designation/selection/structure effects. |
| Engine/game and scene composition — intentional | S `World/Render.hs:68–90,327–333` reads EngineEnv and assembles terrain plus game layers; page clocks feed rendering. | H D-17/D-20/D-24, P-5 `:791–807,1125–1150`: injected services, Lua rules, exclusive terrain window claim, deferred general scene/gameplay integration. Do not introduce a global clock/service registry for shading. |
| Qualification and performance — amendment evidence, no speed claim | S sprite/mask/shader sources above are the reference, not the old solid model. | H TRA-8 evidence `docs/evidence/terrain/tra8/README.md:34–52,113–155` qualifies the old model and explicitly records mismatch; #648 final matrix must add actual face-map/lighting/coverage cases and changed resource costs. Existing bounds and all-16/four-facing coverage remain, with no unmeasured superiority claim. |

In this table, shortened S paths begin at `src/World/` unless explicitly
prefixed with `scripts/` or `Engine/` (the latter begins at `src/Engine/`).
Shortened H `Terrain/Render2D/*` paths begin at
`packages/terrain-render-2d/src/Hetoimasia/`. These aliases only abbreviate
the citations; the revisions above remain the authority.
Bare `ShaderCode`, `TileQuads`, `Quads`, `Solar` and `Time/Types` citations in
the prose refer to the full S paths named in the corresponding trace above;
H `Plan` refers to `packages/terrain-render-2d/src/Hetoimasia/Terrain/Render2D/Plan.hs`.

### P-6. Amendment framing — historical framing, resolved through D-59

The investigation below records how the amendment developed. Its earlier
open emission/API/storage questions are now specified by P-9–P-15 and
D-49–D-59. Those later approved contracts govern where this framing still
says “open” or “proposed”; D-60 now resolves Q-19's delivery/readiness decisions.

The proposed correction is a terrain material that samples colour artwork and
the selected face map on cell/visible-face quads, applies silhouette alpha and
face lighting, and uses the existing material ABI. It replaces the claim that
the current convex solid's projected polygons reproduce Synarchy's sprites.
The exact emission/occlusion contract is still open; D-50 selects unchanged
known shapes/materials at the cutaway with no additional flat caps. The verified S path
is one whole quad per non-air visible-range cell, not three separately meshed
faces. Preserve sparse authoritative cell/material/shape state and atomic
removal; do not infer world occupancy from camera-facing texture alpha.
D-36 resolves the query authority: the existing subcell point/ray queries and
cavity discovery use the same corrected logical shape definitions. The exact
per-shape catalog is now selected by D-49/P-9; API compatibility and the
implementation's geometry/coverage proof remain to be specified and qualified.

The cross-facing mask audit above found that the pinned N/E assets cannot
both be exact silhouettes of one rotated unit-cell shape. D-44 approves
correcting inconsistent masks while retaining all 16 IDs, with solver-delivered
proof of the defect and correction. D-49 supplies the logical catalog; do not
choose camera-dependent logical geometry or claim the current PNG set already
establishes a coherent solid catalog.

D-30 selects the picking approach: use the adopted drawn quads, matching
artwork/mask coverage and front-to-back order, with shared CPU asset coverage.
D-45 selects nearest-neighbor colour/mask sampling and a shared render/pick
alpha cutoff. D-55/P-11 specifies the exact cutout sampling, bounded asset
loading and shared CPU coverage ownership. The former analytic-solid picker
is not the visual authority. Emission/ordering remains Q-16 and the changed
path still needs implementation proof.

D-31 requires a separate fog presentation over undiscovered underground
terrain, including real air gaps. The generic blank is intentional gameplay
concealment. The earlier proposal to expose real material/air at every cutaway
is superseded; lazily loading terrain must not itself reveal it. Fog must
occlude visual picking without becoming authoritative physical occupancy.
D-32 selects whole-cavity discovery on unsealing, including boundary terrain
beyond adjacent cells and across chunks, processed in bounded steps. D-51
refines exhaustive boundary loading into compressed whole-space knowledge
with tile/render detail materialized on camera or explicit demand.
D-33 retains discovery as chunk changes across normal offload/reload for the
arena session, replayed before render/pick publication. Revealing terrain is
distinct from editing its contents; discovered chunks need not stay resident.
D-34 connects whole empty cells through their six shared faces and excludes
edge/corner-only contacts. D-35 additionally requires explicit shape openings,
including real diagonal openings through ramps into unrevealed spaces. D-49
supplies the shape geometry; capacity/completion and API authority remain Q-20.
D-37 resolves fog interaction: fog is unselectable, returns no player target
and blocks screen picks/removal of the terrain it conceals.
D-38 starts sky and initially exterior-connected spaces discovered and requires
overlapping unsealing operations to preserve all pending discovery without
expanding across the exterior. D-39 approves the bounded shared-work mechanism
in P-7; its remaining concrete representation/capacity choices are still open.
D-53 requires bounded exact source-connectivity preparation before arena
opening succeeds, with clear over-budget refusal and no underground tile
enumeration. Required flat/gap/shape cases remain qualification obligations.
D-40 approves P-8's temporary session disk backing for retained changes with
bounded RAM caching. D-41 selects pause/preserve/recover for expected storage
exhaustion or write failures; its exact protocol and storage/quota/lifecycle
rules remain open. D-42 records larger CPU banks and best-effort camera demand,
without choosing the disk allowance. D-43 selects reservation of a hard disk
allowance before arena opening and pausing at capacity while preserving the
expandable world; the allowance's size and qualified mechanism remain open.
D-52 adds explicit asynchronous Lua requests to increase a live allowance,
resuming capacity-paused work only after the larger reservation succeeds.
Failed increases preserve the old cap, state and pending work.

D-29 resolves the first lighting scope: face-map alpha and facing-aware
top/left/right shading with an adjustable sun-position input for previews.
The earlier fixed-configuration recommendation is superseded to the extent
it implied an unchangeable sun. The automatic cycle is deferred; selected
sun positions can still change the lighting without a world clock, calendar
or solar-page/time simulation. Eventual moon lighting is deferred too.
D-46 selects Lua-supplied compass direction and elevation anchored in world
space through camera rotation. D-47 retains both adjustable depth darkening
and blue haze and requires improved numerical/visual/navigation coverage.
D-54 supplies independent Lua ambient control; changing sun position alone
does not change ambient illumination.
D-56 replaces RGB face-brightness weights with encoded surface normals in
the same cutout data texture. P-12 records the reason and required proof;
P-13 supplies its exact numerical/configuration contract, approved by D-57.
This specifies units, bindings, depth/colour equations and initial strengths;
the material and visual result still require qualification.

D-48 approves P-10's viewport-driven demand, view-aware eviction and explicit
background/haze regression within D-42's existing budgets. The face-map path
must preserve the height-aware footprint and reconcile bounded planning with
best-effort runtime admission; this is not a guarantee that every view fits.

Affected tracker work, for later approved revisions only:

- **#637 and #643 are merged.** Preserve coordinate, ID, storage and camera
  work. A follow-up must replace/supersede the inappropriate visual solid
  assumptions, planned coverage/ordering and picking together. No reopening
  or code change occurs in this design turn.
- **#644 / PR #654 is open and held unmerged.** Its measured ABI result and
  silhouette finding remain useful evidence. Its per-face material/model
  is not the final face-map implementation. This design does not release
  the hold or direct a merge; manager delivery coordination remains separate.
- **#645:** revise region payload, mask/lighting/material versioning, CPU
  coverage and secondary-texture holds, budgets and adoption tests.
- **#646:** revise the bounded style/data loading and pick-result contract
  where required, preserving role/lease and adopted-frame token authority.
- **#647:** load/retain the approved masks alongside colour art, supply the
  agreed light/style data and verify actual silhouette selection in content.
- **#648:** final qualification must run the amended path, include all masks
  and facings with lighting/cutout/pick controls, and measure the additional
  data/texture ownership before shortcut removal and final acceptance.

The owner chose a follow-up before TRA-12. D-60/P-16 now approves the exact
one-PR boundaries, dependency insertion and existing-issue revision scopes.
The ledger and delivery plan reflect that amendment; original issue links and
filed scopes remain preserved. No final issue bodies are drafted here.

### P-7. Shared discovery — framing completed by D-59/P-15

Historical mechanism discussion below; D-59 approves P-15's concrete source,
overlay, accounting, transaction, API and proof contract. References here to
details still needing specification are resolved there, not delegated to an
implementation's discretion.

The high-level shared-work mechanism implementing D-31–D-38 is approved by
D-39, with D-51 separating whole-space knowledge from detail loading. The
detailed engineering below still identifies representation,
capacity, publication and source-compilation choices requiring a concrete
contract; this is not a claim that the algorithm is implemented. It builds
on P-5's existing single terrain owner, serialized edit commits and bounded
round-robin work quanta.

1. **Initial knowledge is a source property, not a global sky flood.** Derive
   or supply compact metadata for the immutable initial source's exterior-
   connected empty regions and their exposed terrain boundaries. The exterior
   is implicit; a query can recognize it without allocating/enqueueing sky
   cells. The current source is bounded authored layers/column runs
   (`packages/terrain/src/Hetoimasia/Terrain/Source.hs:1–30`), which supports
   a run/region-level compilation approach; its actual connectivity compiler,
   accounting and refusal encoding still need specification. D-53 requires
   bounded exact preparation before opening succeeds, with a clear refusal
   if it exceeds its limits. No claim of a
   general constant-time exterior oracle is made. Initially known cave
   detail loads only on demand. Never reclassify an entire newly opened cave
   as already-processed exterior merely because it now has a path to sky.
2. **One shared discovery work set per arena.** Track unseen regions,
   claimed-but-pending work and fully expanded regions separately. Keys must
   distinguish the logical empty components of a shaped cell/region, so one
   discovered component cannot expose another disconnected part. Claims and
   their queue/continuation obligations are installed together by the terrain
   owner. Discovering/claiming a region is not proof that all of its exits or
   boundary discovery has been processed. Use compressed spans/regions
   where valid; do not turn this into a dense visited-cell array.
3. **Edits seed new connectivity in the same commit boundary.** Each accepted
   removal installs the obligation to inspect its new empty regions and open
   connections before work can be lost to cancellation/offload. Inspect both
   sides of newly created connections, including already-known neighbors.
   A visited bit from before the edit is not permission to ignore a newly
   opened passage. Reserve the minimal continuation/claim capacity before
   committing the edit, or refuse admission without a partial edit. Later
   discovery capacity/failure behavior remains an explicit open contract.
4. **Process bounded batches, share claims and stop at known exterior.** An
   unseen reachable region is claimed once and queued. A pending region joins
   existing work without dropping its queued exits/boundary discovery. A completed
   known region or implicit initial exterior needs no traversal through it;
   edits that change its connectivity must have supplied new obligations as
   above. Reaching sky ends that branch, not the entire reveal. The queue is
   shared, so opposite openings naturally contribute to the same work rather
   than running unrelated flood fills with conflicting visited sets.
5. **Version topology and retain obligations.** Revalidate work against arena
   incarnation and relevant topology changes before publishing it. A removal
   can merge previously separate empty components; stale component keys must
   be remapped/re-examined rather than publishing old connectivity. Completed
   knowledge uses D-33 retention. Pending work is separately arena-owned and
   must survive ordinary chunk offload; its cancellation/close/reset and
   publication rules must be specified. A component is complete only when its
   connectivity and boundary-knowledge obligations are fulfilled, never just
   because two fronts met. D-51 removes exhaustive detail loading from that
   completion condition; view/query-driven detail work remains separate.

For the owner's two-opening example: opening A queues one end of the cave;
opening B queues the other end. Each meets already-known sky at its entrance
and stops only that outward branch. They traverse the cave until their claims
meet, reuse the same pending work, and finish all remaining branches and
boundary discovery. A small abstract graph check exercised immediate and delayed
second openings in both directions, including a side branch: each of eight
unknown nodes expanded once and sky expanded zero times. This is a design-
model sanity check, not a repository test, a geometric proof or performance
evidence. The concrete implementation needs interleaving, chunk-offload,
capacity, later-edit and partial-shape cases before its claims are qualified.

**Still unresolved:** implementation/encoding of D-49's regions/portals;
source metadata
for initially exterior-connected spaces (including unbounded authored air
layers); exact completion/publication of compressed discovery with normal eviction;
retained-discovery and pending-work capacity/refusal; API results and coherent
publication. An enormous/infinite component cannot silently become an
unbounded allocation, a completed partial reveal or an erased obligation.

**Discovery versus materialization — approved by D-51.**
The current source can describe a world-spanning underground air layer with
just a gap between two base layers: those layers apply to every column, and
uncovered levels are air (H `packages/terrain/src/Hetoimasia/Terrain/Source.hs:1–19`
at `3ce8bf411f`). Its description is small even though enumerating all exposed
floor/ceiling tiles is infeasible. Bounded batches alone do not make such an
enumeration finish; a larger disk allowance does not solve this either.

D-51 refines D-32's boundary-loading requirement: discover the whole
connected space and its exposed boundary using exact compressed knowledge
regions, while materializing boundary tile/render data only for camera or
explicit query/edit demand. Completion means the connected space and
boundary are known, not that every boundary tile has been instantiated once.
Finite caverns follow the same rule. D-33 retention/replay still applies
to the compressed knowledge, and ordinary detail eviction cannot undo it.

The owner approved this change to D-32's requirement to load all boundary
tiles. It is not permission to mark an unexplored
region complete by guessing: compact source connectivity must be proved, and
work not yet established stays pending. Exact source compilation, limits,
refusal and integration with edit-created connections remain to specify; no
constant-size representation or instant discovery of arbitrary terrain is
claimed. The rejected exhaustive-loading alternative would require an explicit
restriction on supported cavern sizes/topologies or accepting work that cannot
finish at the available capacity.

Qualification must distinguish known regions from resident detail: use a small
finite cavern, a world-spanning authored air layer and a fragmented connected
cavity. Whole-space knowledge must survive eviction/reload without enumerating
each boundary tile; camera demand must materialize newly viewed known detail.
Exercise unresolved branches, two openings, edits merging regions, offload and
capacity interruption without false completion, lost obligations or accidental
discovery of sealed controls. Record work/storage scaling rather than claiming
compression alone proves bounded behavior.

**Bounded connectivity preparation before arena opening — approved by D-53.**
The existing source validator checks authored
layers/patches and their size; its stored form is layer/patch interval maps,
not a cavity-connectivity index (H
`packages/terrain/src/Hetoimasia/Terrain/Internal/Source.hs:95–133` at
`e3363c4b5b`). D-53 selects preparing and validating an exact compact connectivity
summary in Haskell from the copied Lua recipe before the arena-open request
succeeds. Work from runs, repeated regions and the approved shape portals,
not enumerated underground cells or a flood across sky. The summary identifies
initial exterior connectivity without making sealed cavities player-known.

Bound preparation work and memory explicitly. If the summary cannot be
established within those limits, refuse arena opening with a clear expected
Lua result and publish no partial arena. Keep the asynchronous opening
responsive/cancellable. This adds an admission condition beyond today's
source-record limits: a syntactically valid but too complex recipe may be
refused before play. It does not authorize refusing the required flat arena,
world-spanning air-layer case or the specified shape/cavity fixtures merely
to avoid implementing their connectivity. Those remain qualification cases.

The tradeoff is bounded preparation before entering the arena, in exchange
for establishing its initial sky/closed-space classification before it is
visible. Exact symbolic representation, numeric bounds and edit-time updates
still need specification and proof. No arbitrary procedural callback or
general finite-cost topology oracle is implied by this decision.

### P-8. Session retention backing — framing completed by D-59/P-15

Historical tradeoff discussion below; the exact quota, format, reservation,
cache/staging, commit, failure/recovery and lifecycle choices are now approved
by D-59/P-15. The earlier open questions here are preserved as design history.

The original P-5 keeps retained changes in memory, with an initial 32 MiB
session-edit cap (raised to 64 MiB by D-42) and new edits refused once that
retention capacity is exhausted. Offloading
reconstructible terrain does not free the authoritative changes it must retain.
D-33 adds retained discovery, including large connected cavities. D-40 now
explicitly supersedes the RAM-only retention policy with temporary disk backing;
the original cap is historical rather than the amended total-history contract.

D-40 selects a temporary per-arena disk backing store for
retained chunk edits and discovery, with a bounded RAM cache and asynchronous
I/O. Keep only the active working set resident; committed retained records
can be loaded and replayed when their chunks return. This is session storage,
discarded on arena close/reset, not a user save or cross-run recovery feature.
This does not authorize unbounded disk consumption or silently store game saves.

The tradeoff is additional storage/I/O lifecycle and failure handling now.
D-41 selects pausing new edits/discovery while preserving existing state and
unfinished work on storage exhaustion or write failure, reporting through Lua
and resuming after recovery. Navigation continues only where data is available.
The concrete contract still needs quotas, atomic offload, bounded queue/cache
ownership, exact read/write results and recovery triggers, cleanup and pending
discovery recovery within the live arena. In particular, no acknowledged edit
or revealed state may be evicted from RAM before its backing copy is safe to replay.

The RAM-only alternative is superseded: it would cap exploration history even
after resident chunks were evicted. Temporary backing does not make an infinite
region exhaustively materializable. The storage direction is resolved; its
concrete quota/failure contract remains Q-20, and its scope must be incorporated
in Q-19 before issue revisions are drafted.

**Storage allowance — approved by D-43 (2026-11-07).** The
owner suggested checking free space, imposing a terrain disk allowance,
refusing startup without enough room and ensuring the world cannot exceed it.
D-43 chooses a configurable hard allowance for the arena's whole temporary store,
including indexes, metadata and peak replacement/compaction/write overhead;
check capacity on the actual store volume and reserve the required storage
before arena opening succeeds. The proposed separate free-space safety margin
and its size remain part of the concrete contract review.
If the required capacity cannot be established, refuse arena opening with a
clear Lua result. This is an arena-creation requirement, not a prohibition on
launching the engine application.

Maintain accounting and reserve capacity before admitting retained changes;
do not spend space reserved for completing in-flight writes on new work.
At capacity, preserve existing changes and pending discovery under D-41.
Unchanged terrain remains reconstructible from its source; revisiting readable
terrain need not grow retained history. For a large cavity, do not promise a
whole reveal fits based on its opening tile: continuation and its capacity
must remain bounded and resumable. Exact default size, reservations, platform
support and admission/recovery protocol remain open.

**Increasing a live arena's allowance — approved by D-52.**
A full retained-history allowance is distinct from a temporary device write
failure: freeing reconstructible resident chunks does not remove the edits
and discovery the session must remember. D-52 selects an explicit asynchronous
Lua operation to request a larger allowance for the same live arena. Establish
the additional reservation before raising the cap or resuming capacity-paused
work; on failure retain the old cap, stored state and pending obligations.
This permits continued exploration without discarding the arena, while
keeping storage growth explicit and bounded. It adds no UI, automatic quota
growth, shrinking or cross-run persistence. D-52 extends D-43's configurable
startup allowance to explicit live increases. Exact operation/results,
reservation accounting and recovery from
non-capacity I/O errors remain part of the concrete storage contract.

A free-space query is a snapshot, not a reservation against other writers.
[Apple's file-control documentation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
documents file preallocation, including an all-requested-space-or-none option;
this establishes an available mechanism, not a qualified guarantee for the
eventual storage layout or every supported filesystem. Platform qualification
must cover physical allocation, filesystem overhead, replacement writes and
failure handling; merely setting a sparse file's logical length is insufficient.
Reservation also does not eliminate device failures, so D-41 remains necessary.

The D-43 boundary is on retained storage, not world coordinates.
An expandable procedural world can be cheap before edits, but arbitrarily
many independent changes/discovery records cannot be guaranteed to fit a fixed
finite store. Guaranteeing every possible future edit fits at startup would
need a finite world/allowed-change bound and worst-case storage sizing, not
an assumed compression ratio. That would narrow D-11 and is not approved.

Other-game evidence is limited, not a universal industry policy: in a
[Factorio staff diagnosis](https://forums.factorio.com/viewtopic.php?t=130690)
of a save failure, the write directory had only 27 MB free at startup and the
developer fixed the error to report insufficient space. It supports retaining
runtime error handling, not claiming Factorio pre-reserves all future saves.

### P-9. Concrete logical shape catalog — approved by D-49

This is the intended logical catalog approved after an illustrated owner
review in D-49. D-44 requires the solver to correct and prove the artwork
against it. It preserves S's documented meaning of a set bit as a
lower cardinal neighbor (`src/World/Slope/Compute.hs:135–143,173–205`), and
makes that direction the cell's lowered edge. It does not infer terrain shape
from camera pixels or enable automatic slope recomputation after removal.

Use the existing local frame: X east, Y south and Z up, each in `[0,1]`.
Let `N=y`, `E=1-x`, `S=1-y`, `W=x`. Shape 0 has top height `h=1`; every
other shape's top is the minimum of the expressions named by its bits.
Its closed solid is `0 <= z <= h(x,y)`. This is a finite, piecewise-planar
catalog with exact rational intersections, not an arbitrary height-field API.

| ID | Name | Approved top height | Form / maximum height |
| --- | --- | --- | --- |
| 0 | Flat | `1` | Full block, 1 |
| 1 | N | `N` | Ramp, 1 at S edge |
| 2 | E | `E` | Ramp, 1 at W edge |
| 3 | NE | `min(N,E)` | Corner form, 1 at SW corner |
| 4 | S | `S` | Ramp, 1 at N edge |
| 5 | NS | `min(N,S)` | Central E–W ridge, 1/2 |
| 6 | ES | `min(E,S)` | Corner form, 1 at NW corner |
| 7 | NES | `min(N,E,S)` | Ridge extending inward from W, 1/2 |
| 8 | W | `W` | Ramp, 1 at E edge |
| 9 | NW | `min(N,W)` | Corner form, 1 at SE corner |
| 10 | EW | `min(E,W)` | Central N–S ridge, 1/2 |
| 11 | NEW | `min(N,E,W)` | Ridge extending inward from S, 1/2 |
| 12 | SW | `min(S,W)` | Corner form, 1 at NE corner |
| 13 | NSW | `min(N,S,W)` | Ridge extending inward from E, 1/2 |
| 14 | ESW | `min(E,S,W)` | Ridge extending inward from N, 1/2 |
| 15 | NESW | `min(N,E,S,W)` | Central four-sided peak, 1/2 |

Each named edge meets the base. Combining directions retains all their height
constraints; this produces the ridge/corner forms without a camera-dependent
exception. Quarter turns permute the bits and rotate the same solid. The
half-height peaks are consequences of intersecting unit-rise/unit-run slopes,
not new fractional-slab IDs or an arbitrary authored-height parameter.

**Departure approved by D-49:** ID 15 becomes a central half-height peak
with all four edges at the base, instead of the old flat-block alias or S's
lowered flat-diamond mask. This changes D-25/P-5's earlier flat-top treatment
as explicitly approved in D-49. The alternative of retaining ID 15 as a
documented flat-block exception is not selected.

For IDs 0–14, this mathematical rule matches the existing H
`packages/terrain/src/Hetoimasia/Terrain/Geometry.hs` lower-envelope definition.
The audit disproved its claimed fidelity to the pinned masks; it did not
establish that the solids are intrinsically invalid. Keeping that rule as the
new intended catalog while correcting the masks is the D-49 design choice.
ID 15 removes the existing full-block special case. Actual API
compatibility, corrected masks and evidence still belong to the amendment.

**Opening geometry derived from D-49's catalog and D-34/D-35:**

- In each shaped cell, the empty region is the space above `h`. Shape 0 has
  no interior empty region; each other catalog shape has one connected empty
  region. Retain a component-aware representation so discovery does not rely
  on every future shape necessarily sharing this property.
- A horizontal side's opening is the exact portion where `z > h` restricted
  to that side; a top opening exists where `h < 1`. None has a positive-area
  bottom opening: the solid reaches the base over the footprint. A selected
  side is open above the base; unselected sides may be partly or fully sealed
  according to the same height function. Do not equate an unset bit with an
  entirely sealed side.
- Neighboring empty components connect where their common-face openings
  overlap over positive area. Geometry within each cell connects its portals.
  A path can turn diagonally through ramps and neighboring open regions;
  an edge/point-only contact cannot bypass intervening sealed terrain. This
  implements D-34/D-35's real-opening distinction without unconditional
  diagonal-neighbor links or camera-alpha tests.
- Keep the existing exact closed-solid point/ray boundary convention; air
  does not include the solid boundary. Derive queries and portal polygons
  from the same catalog, without unrelated floating tolerances. Qualify the
  table and rotated portal intersections independently under D-44.

This catalog does not settle full-cell emission/ordering, sampling
edges, lighting weights or the renderer proof. It provides a concrete logical
target to implement and test rather than asking the solver to invent the shape
semantics while fixing artwork. The illustrated owner review is complete;
the solver's independent implementation qualification is still required.
D-50 separately settles cutaway appearance: preserve remaining known shapes
and materials without additional flat caps, retaining fog over unknown regions.

### P-10. Viewport-driven demand and missing hazed background — approved by D-48

**Owner's clarified symptom, 2026-11-07:**

> since the haze happens over far away tiles, because of the isometric view
> and the chunk loading limit around the camera, often the tiles that are
> supposed to be hazed in the background are simply not loaded, and show up
> blank. it looks ok, but i would like to look into the possibility of loading
> the chunks needed based on what the camera sees, not just a flat radius

This request initiated the viewport-based loading investigation; D-48 approves
the resulting contract below. It does not approve an unbounded resident world
or a larger arbitrary camera radius. It explains the
D-47 complaint as missing terrain that the haze would have shaded, rather
than establishing that its colour formula is wrong.

**Verified reference mechanism.** At S `3777d437`,
`src/World/Thread/ChunkLoading.hs:96–111` computes the camera chunk and demands
the square `[-chunkLoadRadius..chunkLoadRadius]` in X/Y. The configured radius
is 2 (`src/World/Generate/Constants.hs:12–13`): 5×5 chunks. The queue is sorted
by camera-chunk distance and admits at most 8 new chunks per tick
(`ChunkLoading.hs:62–63,151–154`); camera-driven eviction also receives that
radius (`:219–222`). This camera demand is not derived from the viewport's
projected extent or its vertical visibility band.

S's render path independently inspects already-loaded chunks
(`src/World/Render/Quads.hs:127,162–170`). Its view bounds include viewport
aspect/zoom and a padding proportional to visible depth
(`src/World/Render/ViewBounds.hs:32–50`), then test projected chunk extents
(`src/World/Render/ChunkCulling.hs:58–73`). Thus the renderer can consider a
region visible that the camera loader never requested. A larger culling bound
cannot render an absent chunk. This source mismatch supports the owner's
report; no exact camera/scene capture or runtime reproduction has been made.

S's haze is specifically based on `zSlice - worldZ`, normalized by effective
view depth (`src/World/Render/TileQuads.hs:68–75`), not a horizontal-distance
fog formula. The loading correction is independent of any future choice of
haze curve; do not silently change its distance/depth meaning on this report.

**Existing Hetoimasia foundation.** The approved P-5 describes a visible region
plus one chunk of prefetch, and D-42 preserves the full zoom/depth range with
best-effort camera admission. At H revision
`e61a1ec55284e7ec8aa71664878c89a38d2322c2`, the merged pure planner already derives
the view rectangle from the viewport mapping
(`packages/terrain-render-2d/src/Hetoimasia/Terrain/Render2D/Projection.hs:230–242`),
uses the vertical band to enumerate candidate columns and per-column level
windows (`Plan.hs:396–420,453–477`), and builds camera demand plus a margin
(`Plan.hs:849–896`). It is not a flat-radius planner. Existing tests cover
visible chunks/margins and bounds (`packages/terrain-render-2d/test/Test/TerrainRender2D/Planning.hs`,
the `demand for the camera` group); they are not proof of this end-to-end
background scene through the new face-map path.

Two remaining integration issues must not be hidden: the planner's bounds
were written for the old solid/face representation, and `prepare`/`cameraDemand`
can refuse an oversized enumeration/demand (`Plan.hs:457–459,885,893–895`).
The face-map follow-up must enclose the actual whole-tile sprites and reconcile
bounded planning with D-42's best-effort camera policy. Do not turn a planning
capacity refusal into a silent, permanently empty background or claim that
runtime admission alone has fixed every upstream limit. The filed #645 view
adapter connects this demand to runtime; that integration remains separate
from a pure planner's existence. This turn changes no code or tracker item.

**Refined contract approved by D-48:**

1. Derive demand from the current viewport, aspect, zoom, facing, cutaway and
   allowed height range. Include any known/discovered terrain whose projected
   tile bounds could contribute pixels, even when its horizontal chunk lies
   far from the camera anchor. Determine potential coverage without relying on
   which chunks are already resident; otherwise blank areas never request data.
2. Use conservative projected bounds and per-column/region height intervals.
   Do not project only the ground plane or materialize the whole underground
   prism. Compressed source/discovery summaries prune air and hidden interior;
   fog-covered undiscovered terrain stays concealed under D-31/D-37. Camera
   demand alone does not grant discovery or load every buried cell.
3. Prioritize current visible demand before the existing small prefetch margin,
   while preserving explicit query/removal priority. Coalesce superseded
   camera intents; old GPU frames retain their required resources. Eviction
   must respect current view interests and capacity policy, not discard a
   needed background chunk merely because it is beyond a camera radius.
4. Keep bounded, progressive preparation/admission and D-42's budgets. At
   sufficient capacity a settled view must not have holes caused by an omitted
   demand footprint. At insufficient capacity, unresolved visible demand stays
   pending and unloaded terrain remains absent as already approved; no promise
   that every maximum-zoom view fits, no automatic budget increase and no LOD
   system is introduced. Prefetch must not consume the capacity needed for
   visible terrain or explicit work.

**Required regression coverage under D-48:** a controlled, discovered terrain
scene with lower/distant background surfaces outside a camera-radius square
but inside the projected viewport, with both depth effects enabled. With ample
budgets, assert those chunks enter demand and remain available while needed,
then capture the loaded/hazed result after streaming settles. A radius-based
negative control must leave the expected background absent. Vary all four
facings, zoom, portrait/wide aspect, resize and the manual/automatic cutaway;
include sprite edges and elevation displacement, not only flat tile centres.
With constrained budgets, show visible-before-prefetch admission and explicit
request progress, with pending work distinguished from a missed footprint.
Include pan/rotation away and back, delayed loads and eviction so the same
background does not repeatedly disappear despite sufficient capacity. Preserve
fog concealment and sparse underground allocation in those traces.

Q-16 owns the amended projection/emission demand bounds, Q-18 the owner's
visible haze/background qualification, and Q-19 the planner/view integration
and final evidence assignment. The viewport-based direction already has P-5
support; D-48 approves the explicit refinement and regression package above.
This does not settle Q-20's separate cavity discovery work.

### P-11. Concrete cutout asset and sampling contract — D-55, amended by D-61

D-61/P-17 distinguish the 96×64 **logical image region** from its physical
atlas. In the clauses below, a canvas and UV `[0,1]` describe that logical
region; they do not require one GPU texture per map or authorize sampling
outside its rectangle. P-17 supersedes whole-image texture/version assumptions
with checked atlas-region identity and shared whole-atlas coverage.

This Q-17 contract was approved as written at `f372d0793f` by D-55. It fills in
D-30/D-45's shared coverage and crisp sampling without deciding the remaining
emission/ordering or lighting equations. The initial scope is opaque/cutout
terrain; partial translucency would require a later contract.

D-56 subsequently replaces the RGB face-weight meaning below with encoded
surface normals. The approved alpha, dimensions, sampling, loading and
ownership clauses remain; P-13 supplies encoding validation and exact lighting
parameters, approved by D-57. This annotation preserves
the signed P-11 text.

**Verified fit with the reference and current engine.** At S `3777d437`,
`assets/textures/world/loam/loam.png` and
`assets/textures/world/granite/granite.png` are 96×64 and contain only alpha
0/255, as is the checked
`assets/textures/facemap/isoface_slope_n.png`. A read-only PNG inspection
checked these dimensions and complete alpha-value sets; the earlier audit
records binary alpha across the slope-mask catalog. This is asset evidence,
not GPU output or proof of the corrected masks. At H `b0f28910d5`,
`packages/render-2d-vulkan/src/Hetoimasia/Render/TwoD/Vulkan/ShaderSources.hs:353–375`
uses the cutout threshold 0.5. `MaterialSources.hs:11–36` supplies the
secondary texture and requires premultiplied linear output. The bounded PNG
decoder still lacks the data-image policy described in the integration audit.

1. **Initial asset contract.** Preserve full 96×64 authored colour and face-map
   canvases and local UV `[0,1]` across each region, with the already approved
   projection proportions. Both images must have binary alpha. Keep colour
   artwork on the premultiplied sRGB-colour path and face maps on a linear
   RGBA8 data path that preserves decoded numeric channels, without gamma
   conversion or colour premultiplication. Face-weight RGB may contain
   intermediate values; binary alpha does not mean binary lighting weights.
   Validate atlas kind, region dimensions/bounds and binary coverage before attaching the
   style. Refuse incompatible assets clearly, retaining the previous adopted
   style/view on an unsuccessful replacement. Do not silently threshold or
   resize authored assets. Corrected masks still need D-44's evidence/provenance.
2. **Sampling and coverage.** Nearest-neighbor, clamp-to-edge, level zero only;
   no mip generation, trilinear filtering or smoothed mask edges. The
   reference texel rule on an image of width `w` is
   `i = min(w-1, floor(clamp(u,0,1)*w))`, and similarly for `v`/height, with
   top-row-first region coordinates. Add the checked region origin only after
   clamping locally. GPU sampling uses that atlas texel's centre; whole-atlas
   clamp alone is insufficient at a region boundary. At an interior texel
   boundary select the higher index; the outer region edge selects its last
   texel, never its neighbour. Rendering and
   picking use the same adopted quad/UV transform and viewport clipping; the
   texel rule does not extend coverage outside the rasterized quad. Map a
   logical cursor through the adopted framebuffer scale to its physical pixel
   and test that pixel's centre; an outside-viewport cursor gives no hit.
   Quad-edge ownership must match the backend's raster convention, including
   the shared diagonal of the two triangles. Colour
   alpha and mask alpha multiply; coverage survives exactly when the product
   is at least 0.5. For these assets this is the AND of their two coverage bits.
   Lighting, haze and darkening alter RGB only. Terrain tint opacity remains
   one, and this material does not add additive/translucent terrain blending.
3. **Bounded loading, explicit data policy.** Extend the existing
   `api.content.texture(path [, options])` route with `kind="colour"|"data"`
   (default colour) and optional `coverage="binary"`. Omission preserves
   current behavior. Binary coverage requests validate binary alpha and
   produce an immutable CPU bitplane alongside the texture; a nonbinary
   source is an expected content refusal. Both terrain colour and mask loads
   request this coverage. Preserve existing root/optional rules, instance
   authority, request cancellation, decode/upload quotas and source preflight
   limits. Extend the accounted decoder rather than substituting the unbounded
   general decoder. Do not introduce a terrain dependency into the generic
   decoder or graphics facade; pass the narrow policy/accounting capabilities
   through their existing service boundaries.
4. **Coverage ownership and admission.** Store one bit per texel per immutable
   loaded atlas version, plus accounted region metadata, shared by its consumers;
   never one copy per world cell. Identity includes image kind, dimensions and
   the exact texture/version authority. Generate it from the same decoded
   alpha that is uploaded, reserving bytes before allocation. Charge retained
   bitplanes/metadata and overlap during replacement to the existing 128 MiB
   CPU render/staging bank through an injected account; existing tighter
   texture/workspace limits still apply. No extra unbounded cache or automatic
   bank increase is authorized. Transfer ownership from decode work to the
   delivered asset resource without leaving uncharged or duplicate payloads.
   The texture lease and prepared/adopted snapshots retain their interests;
   CPU payload dies after its last CPU reader/owner, while GPU retirement
   follows the existing completion rules. Cancellation, failed adoption,
   instance exit and style replacement release each interest exactly once.
5. **Coherent render/pick use.** A style holds both texture authorities and
   their matching CPU coverage. A new frame cannot adopt a texture version
   without the corresponding bitplane; picking reads only the adopted pair,
   in front-to-back draw order. It never reads back the GPU or reopens the PNG
   during a pick. Invalid/released Lua handles cannot acquire new authority;
   already accepted work retains its protected interests under the existing
   lifetime rules. Material output multiplies premultiplied RGB and alpha by
   mask alpha, preserving the render-2d contract before its cutout wrapper.
   Fog still yields no selectable target and stops the search under D-37.
6. **Qualification.** Compare a CPU coverage oracle against retained offscreen
   output at framebuffer pixel centres, including exact UV/texel boundaries,
   both quad triangles, viewport edges, fractional pan/zoom, device scaling,
   all 16 masks and all four facings. Prove the sampler and raster-edge tie
   convention; mathematical nearest-neighbor intent alone is not proof of
   GPU agreement. Test transparent colour holes independently of mask holes,
   raw intermediate face-weight bytes, malformed/nonbinary/wrong-kind/wrong-size
   assets, budget refusal, cancellation, replacement and handle-generation
   reuse. A mismatch blocks qualification; do not introduce a different pick
   threshold or silently switch filtering to hide it. The immutable asset
   provenance and reproduction commands accompany D-44's corrected-mask proof.

The approved loading options are new API surface; the audited facade accepts
only `root`/`optional` at this call
(H `packages/lua-engine/README.md:1098–1101`). The approved binary-only terrain
contract intentionally excludes semi-transparent terrain textures now. It
preserves the imported loam/granite assets and crisp cutouts, not a promise
that arbitrary existing translucent content is accepted by a terrain style.
Q-19 must assign the bounded loader/coverage work and its integration separately
from mask correction and final renderer qualification. Approval specifies the
target and does not establish that the implementation exists or passes proof.

### P-12. Lighting representation for actual ramp orientations — approved by D-56

**Source fact.** S `3777d437`
`src/Engine/Graphics/Vulkan/ShaderCode.hs:258–303` normalizes nonnegative RGB
as right/top/left weights and blends three computed face brightnesses. Its
sun phase drives both height and apparent direction, while D-46 has already
selected separate world-space direction/elevation. The ramp PNGs also carry
authored gradients: read-only inspection found 511 distinct opaque RGB values
in `isoface_slope_n.png`, 35 in `_e`, 342 in `_s` and 252 in `_w`; `_nesw`
has only green on its 2,400 opaque pixels. These are lighting weights under
the source shader, not stored three-dimensional surface normals. This is
not a new claim that every gradient is an accidental asset bug.

**Constraint exposed by the approved shape catalog.** D-49 includes ramp
planes facing each horizontal direction. For example, the W shape has
`h=x`, outward top normal `(-1,0,1)/sqrt(2)`. With sun from west at elevation
10 degrees, its ideal diffuse response `max(0,dot(normal,sunDirection))` is
about 0.81915. The two camera-facing vertical cube normals `+X`/`+Y` have
response zero and the flat top has response about 0.17365. No nonnegative
normalized blend of those three face responses can reach the ramp response.
The ramp is visible from the reference above-ground isometric view, so this
is not solely a hidden-face case. The calculation establishes a limitation of
three fixed face responses if the target is actual surface-orientation
lighting; it does not claim S promised that model or substitute for GPU proof.

**Direction approved by D-56.** Keep the same RGBA data texture and
binary-alpha silhouette, but encode the visible surface normal in RGB instead
of right/top/left brightness weights. Generate normals and cutouts from the
same D-49 catalog, transform normals consistently with the selected facing,
and shade against the world-fixed sun plus D-54's independent ambient level.
The CPU still submits the same flat cell quads; the GPU uses the mask alpha
for the cutout. P-11's bounded raw-data loading, dimensions, sampling, CPU
coverage and resource ownership remain applicable. D-56 explicitly
revises its description of RGB as face weights, not its approved alpha or
transport contract.

This is an intentional lighting/asset-encoding change from Synarchy, requiring
new RGB map contents and an unambiguous encoding identity so old weight maps
cannot be silently interpreted as normals. It needs no additional texture
per cell or new vertex/depth ABI by the source-level feasibility reading;
the material implementation still requires qualification. Do not promise
performance parity without measurement. Exact normal encoding, directional
equation, default sun/ambient values and depth-effect composition are specified
by P-13, approved through D-57.

The rejected alternative retains the stylized three-face brightness blend
and its surface-orientation limits. Under D-56, solver evidence must
include the low-angle ramp case, opposite slopes and all facets of ID 15,
sun/ambient independence, and the same world-facing surface under all four
camera facings, alongside D-44/P-11's cutout/picking proof.

### P-13. Numerical preview lighting contract — approved by D-57

This Q-18 specification under D-29/D-46/D-47/D-54/D-56 was approved as written
at `f052296f6e` by D-57, including the numbers, API additions and depth-effect
composition below. These are initial preview defaults, not measured visual
acceptance.

**Normal encoding and validation.** Name the data encoding
`unit-normal-rgb-v1`. Store a unit surface normal in RGB bytes as
`round(128 + 127*n)` componentwise; decode byte vector `c` by normalizing
`c-(128,128,128)`. Opaque texels require all components in `1..255` and a
nonzero decoded vector. Transparent texels' RGB is ignored; the material
returns zero coverage before attempting to normalize a transparent sample.
Recover bytes by rounding the nearest-sampled UNORM RGB times 255, avoiding
a spurious nonzero component at the neutral byte 128. Flat-up is `(128,128,255)`;
the W ramp normal is `(38,128,218)`, which decodes to
`(-1,0,1)/sqrt(2)`. Cardinal and 45-degree catalog normals are represented
without an angular quantization error under this encoding.

Maps carry the outward normal of the visible D-49 facet at the baked pixel
centre, in the rotated view frame used to draw that catalog entry. Preserve
hard geometric creases; do not average unrelated facet normals into a smooth
surface. The generator/reference must document a deterministic tie rule at
shared facet edges and prove silhouette and normal selection together.

Extend P-11's data-load options with optional
`normal_encoding="unit-normal-rgb-v1"`, valid only with `kind="data"`.
Validate nontransparent RGB while the accounted decode buffer exists, before
upload/publication, and retain the checked encoding fact with the immutable
asset identity. Malformed normals are an expected content refusal. Terrain
mask loads request this option plus `coverage="binary"`; attachment requires
that encoding fact. A raw data handle or an old face-weight map does not
silently acquire normal-map authority. Omitted encoding preserves P-11's
generic colour/data behavior. This additional texture option is approved by
D-57, extending D-55. Keep the validator generic to
normal data, without importing terrain/game code into the decoder.

**Lua settings.** Add optional `lighting` and `depth` records to the terrain
view's opening style, with these defaults. The same records may be supplied
as partial changes to `api.terrainView.configure`; omitted fields retain
their current values. Unknown fields/metatables and nonfinite/out-of-range
values are refused before mutation. Scalar controls accept finite Lua
numbers; `range_levels` is an integer. An entire camera/lighting/depth change
is validated and admitted atomically under the existing `true,nil` / `busy`
configure contract. It creates no request handle or UI.

| Record field | Meaning / accepted range | Initial value |
| --- | --- | --- |
| `lighting.sun_azimuth_deg` | Compass degrees `[0,360)`: north 0, east 90, south 180, west 270 | 225 (southwest) |
| `lighting.sun_elevation_deg` | Degrees above horizon, `[-90,90]`; no direct sun at or below 0 | 45 |
| `lighting.ambient` | Independent linear base illumination, `[0,1]` | 0.35 |
| `lighting.sun_strength` | Direct-light strength, `[0,1]`; zero disables direct light | 1 |
| `depth.range_levels` | Fixed depth-effect range in cell levels, `1..250` | 250 |
| `depth.darkening` | Fractional darkening at that range, `[0,1]`; zero disables it | 0.15 |
| `depth.haze` | Haze blend fraction at that range, `[0,1]`; zero disables it | 0.60 |
| `depth.haze_srgb` | Plain `{r,g,b}` record of sRGB components in `[0,1]` | `{r=0.72,g=0.85,b=0.95}` |

At open, missing records/fields use the defaults. A supplied `haze_srgb` is a
complete three-component value; it is not a nested partial patch. Lighting
and depth settings belong to the presentation view, with its existing owner,
revision/lifetime and close/reset behavior, not a global clock or mutable
terrain source. The depth range stays fixed through zoom/viewport changes;
the effects measure depth below the effective cutaway, not horizontal distance.

**Directional equation.** In the established world frame X east, Y south,
Z up, azimuth `a` and elevation `e` give the unit direction toward the sun
`s=(sin(a)*cos(e), -cos(a)*cos(e), sin(e))`, converting degrees to radians.
Apply the existing camera quarter-turn transform to its X/Y components
exactly once (`Projection.hs:108–134`: one turn is `(x,y)->(-y,x)`). Normals
are already encoded in that view frame; do not apply Synarchy's additional
left/right weight swizzle. Let `p=clamp(dot(n,s_view),0,1)` and let `S` be
`sun_strength` above the horizon, zero otherwise. The brightness is
`B=A+(1-A)*S*p`, with `A=ambient`. There is no extra per-side ambient factor.
This is unshadowed directional/ambient preview lighting; cast shadows and
occlusion lighting are not added by a normal texture.

With the defaults, unmodified top, south-facing and east-facing surfaces
have brightness about 0.80962, 0.675 and 0.35 respectively, before depth
effects. These calculated reference values illustrate the proposed settings;
they are not captures or proof of a running shader.

**Depth and colour composition.** For a drawn cell at level `z` and effective
clip level `k`, form `d=k-z` with checked/wide integer arithmetic before
conversion to a bounded render value. Set `t=clamp(d/range_levels,0,1)`,
darkening multiplier `D=1-darkening*t`, and haze fraction `H=haze*t*t`.
Convert `haze_srgb` once to linear colour `F`: per component use `v/12.92`
when `v<=0.04045`, otherwise `((v+0.055)/1.055)^2.4`.

For sampled premultiplied linear colour `T`, mask alpha `m` and resulting
coverage `alpha=T.a*m`, the material returns:

```text
rgb   = (1-H) * T.rgb * m * B * D + H * F * alpha
alpha = T.a * m
```

Lighting then darkening then haze is the explicit composition order. P-11's
cutout wrapper/threshold applies afterward; haze never makes a cutout opaque.
Use opaque white instance tint and unit wrapper brightness so these factors
are applied once. Fog shading may use only its generic cover geometry/data,
never a hidden tile's normal/material to reveal what lies behind it.

This intentionally changes S `TileQuads.hs:68–98`, which builds a blue tint
and multiplies the material by it: here haze blends the already lit terrain
toward `F`, so even dark surfaces can fade into the haze. The haze colour is
an independent scene input; turning off sun/ambient does not darken it. A
future Lua day/night rule could change it too. The strengths 0.15/0.60 and
blue sRGB triplet are starting values derived from the reference, while the
linear-light composition and fixed range are deliberate changes. At depths
0/half/full range the dark multipliers are 1/0.925/0.85 and haze fractions
0/0.15/0.60. This does not replace D-48's missing-background streaming fix.

**Bounded publication and ABI fit — amended by D-61/P-17.** Use one colour
atlas and one normal-data atlas for this catalog, with checked regions for
both samples. Keep quad UVs logical; the material explicitly samples both
atlases at region-local texel centres. Its bounded record carries two full
generation-checked handles (colour and normal), their rectangle/extent words
and the per-cell depth. The primary texture slot still names the same colour
atlas, but its pre-sampled texel is not the region-clamped material input.
Duplicating that handle in the record does not allocate a second image.
Three `vec4` application pushes suffice: view-space sun plus ambient;
effective sun strength/darkening/haze/reciprocal range; linear haze RGB plus
padding. They use the existing 48-byte allowance
(`render-2d-vulkan/.../Layout.hs:55–61` at H `c21d080e2f`). The existing
material ABI at H `da001722` permits 16 record handles and 64 words; the
two handles, region metadata and depth fit without extending that ABI.
This is source-level layout feasibility, not a GPU qualification result.
Publish camera, both atlas/region identities, depth and lighting coherently
with the adopted frame. No frame mixes a new setting with stale depth/facing
data; no absolute large-world coordinate is converted to a low-precision
shader position merely to calculate depth. Picking remains P-11 coverage-only.

**Qualification.** Independently check encoded normals, the low-angle ramp
case and all peak facets, quarter-turn world-light invariance, every parameter
endpoint and invalid input, and the numeric examples above. Exercise sun-only,
ambient-only, darkening-only, haze-only and combined settings, including black
terrain under haze and disabled haze with both light sources zero. Capture
the intentional tint-to-haze change beside the reference and test it across
offload/reload, delayed arrival, noninteger zoom and manual/follow cutaways
under D-47/D-48. Predeclare numeric/pixel tolerances appropriate to the output
format; retain expected values, captures and reproduction commands. Solver
proof and owner visual acceptance remain required after this contract's
approval. No performance improvement is inferred from the unchanged ABI.

### P-14. Cell-quad emission, fog composition and visual picking — approved by D-58

This is the concrete Q-16 proposal, with the player-facing fog/pick result
needed by Q-20. It preserves P-9 geometry, D-50's integer cutaway, P-11
coverage and P-13 normals/lighting. D-58 approves this contract as written at
`07930b5295`; discovery and storage mechanics remain a separate P-15 checkpoint.

**Knowledge is not residency.** The planner consumes a coherent immutable
terrain/knowledge snapshot. Distinguish a confirmed undiscovered region from
data whose retained knowledge is still loading. Knowledge of a solid boundary
tile is also distinct from discovery of the empty component above a ramp:
seeing the solid from one side does not prove that empty component connects
to the discovered space. A discovery publication records its revealed void
and exposed solid boundary together; materialized detail may arrive later.

For display only, unknown space is covered by generic opaque fog. It does not
change the source, occupancy, logical geometry or query results. Select the
following representations within the existing bounded viewing band:

| Available knowledge | Emission at a potentially visible cell |
| --- | --- |
| Confirmed undiscovered cell, regardless of its hidden contents | One generic full-cell fog quad, with no lookup of its hidden material/shape for display |
| Discovered whole-air cell | No terrain quad |
| Known solid, with its empty component discovered or absent | One whole-cell quad with the material and approved shape/normal mask |
| Known shaped solid, but its empty component is undiscovered | At most two whole-cell quads with shared complementary masks: visible known material and generic fog over the unknown component |
| Terrain or retained knowledge needed for this result is unavailable | Pending/loading, not fabricated air, newly forgotten fog or an authoritative pick |

Each emitted quad uses the same logical 96×64 canvas/projection (a checked
atlas region under P-17), with GPU cutout and
normal shading. Do not emit independent top/side meshes or add flat cutaway
caps. At slice `k`, omit levels above `k`; remaining known shapes keep their
forms/materials. Whole-cell omission is allowed when safely culled; two quads
is a maximum for the mixed-knowledge case, not a requirement to retain hidden
instances. The approved catalog has one empty component per nonflat shape;
new shapes with other component structures require a new contract.
Admit/adopt a mixed cell's required parts and their asset interests together;
budget pressure must never publish its material while dropping its fog cover.

**Mixed ramp/fog masks.** In a cell whose solid is known but void is not,
the presentation volume is the solid plus opaque cover filling that void.
Bake the frontmost visible portions of that union into disjoint known-material
and fog masks, with each part's outward normal. Their alpha union is the full
cell cover. Use the known solid's material only where it is visible; use
generic blank colour where cover is visible. Removing the cover after
discovery exposes the ordinary sloped shape mask. Do not show the actual ramp
through the cover or make its visible known side unselectable merely because
another part of the same cell is fogged.

These are shared catalog assets, not per-cell images. The 16 ordinary shape
maps plus two mixed-part maps for each of the 15 nonflat IDs need at most 46
normal/cutout maps before deduplication; generic full fog reuses ID 0's map.
Rotating selects the corresponding rotated catalog entry under the existing
bit convention. Use the reference grey blank artwork
`assets/textures/utility/blanktexture.png` (S `3777d437`) as the initial fog
colour asset: read-only inspection found 96×64, binary alpha, and opaque RGB
`(66,63,64)`. Record/copy its provenance with the other artwork. All added
maps/coverage/retiring versions count against existing budgets, and each mixed
cell's actual instance count is charged. No resource bank grows automatically.

The disjoint-mask construction is specific to these shapes and this view.
Along the camera-facing direction `(1,1,3)`, `z-h(x,y)` increases for every
P-9 facet: its directional derivative is at least 2. Thus a ray cannot pass
from the unknown void into a nearer known solid in the same cell. This gives
a basis for the two-part construction, but the generator and raster coverage
still need proof, including material-alpha holes and facet/cell boundary ties.

**Order and bounds.** For cells in rotated view coordinates, use ascending
exact key `(viewX+viewY, z, viewX, viewY)` for far-to-near cell order. Within
a mixed cell, use a fixed fog-then-known part order; the baked masks must be
disjoint, so that tie cannot change a covered pixel's classification. Compute
keys using checked/wide integers or exact camera-relative coordinates, never
Synarchy's floating `x+y+0.001*z` approximation. Rank the admitted instances
into the existing 24-bit render depth-key space and refuse/admit progressively
within the existing key/work limits; do not silently collide or wrap keys.

The ordering argument is that two distinct cells intersecting the same view
ray occur with nondecreasing X, Y and Z toward the camera. X+Y distinguishes
them unless X/Y agree, in which case Z distinguishes them. Stable tie fields
resolve equal key prefixes. Shared geometric boundaries need the same raster
ownership convention as P-11. This is a mathematical design argument, not a
claim that masks, backend rank translation or all raster edges already pass
Q-13. A counterexample blocks the affected implementation; it does not grant
a new depth/vertex ABI or an unreviewed mesh fallback.

Candidate generation uses the full quad envelope, the viewport/height band
and D-48's independent demand, not only already resident chunks. Skip buried
intervals using compressed presentation/knowledge summaries; never instantiate
a dense vertical prism to find their boundary. Cull conservatively: an
unavailable neighbor is not air or a guaranteed occluder, and hidden terrain
truth cannot choose fog shape/material. Omit a candidate only with a valid
boundary/occlusion proof under the adopted coverage; preserve visible sprites
through cutouts and partial neighbors. If work/data capacity is exhausted,
retain pending demand under D-42 rather than making an oversized camera view
invalid. Viewport edges and missing chunks do not invent terrain walls or
change which regions the player has discovered.

**Picking and compatibility.** Preserve exact world cell identities rather
than recovering them from projected floats. Traverse the adopted instances
front-to-back using P-11's pixel/alpha rules. A known-material hit returns its
cell and existing opaque edit authority. A fog hit stops traversal and returns
Lua `no_hit`, with no hidden coordinate/material/shape, selection token or
fallback target. The shortcut therefore submits nothing there. If a missing
data region could cover the pixel ahead of a candidate, return `loading`
without actionable candidate details; a missing region proved behind a known
hit does not invalidate that hit. Never call a pending region undiscovered
just because its retention record has not arrived.

Plan identity includes the knowledge revision as well as existing arena,
content, residency, camera and asset/style identities. Geometry, mask parts,
pick data and settings adopt together. Keep existing stale-view rejection
and cancellation authority for edits. Refine the former `PlannedFace`/polygon
visual payload into cell-quad/part data and migrate repository clients/tests
in the owning follow-up; do not keep the old analytic visual picker as a
second answer path. The existing pure logical point/ray query interfaces and
closed-solid boundary conventions remain, with ID 15 corrected under D-49.
Raw terrain queries continue to answer authoritative terrain independently
of residency/knowledge; querying or loading it does not itself discover it.
Presentation fog is never substituted into those logical queries.

H at `f052296f6e` provides the migration baseline:
`packages/terrain-render-2d/src/Hetoimasia/Terrain/Render2D/Plan.hs:1–69`
describes the old per-face polygon plan, incomplete facts and 24-bit ranking;
`Pick.hs:1–28,57–78` uses analytic face coverage and an incomplete candidate.
`packages/terrain/src/Hetoimasia/Terrain/Query.hs:1–29` supplies source/change
queries independent of residency, and `Geometry.hs:30–38` defines closed
exact solids. This proposal changes visual planning/picking, not that logical
authority or the source's sparse-query guarantee.

**Qualification.** Extend all-16/four-facing evidence to ordinary, fully fogged
and mixed-knowledge cases. Include a known ramp side beside an unrevealed void,
cutaway over undiscovered air, later reveal, two openings, offload/reload and
late knowledge arrival. Assert that fog never produces a target or leaks
hidden contents, visible known material stays selectable, and undiscovered
air/solid with the same knowledge produce identical fog. Compare exact sort
keys to an independent geometric ray oracle for roofs, cavities, stacked
spans, steep depth separations, chunk seams and extreme legal coordinates;
verify the GPU depth-key path and shared raster-edge ownership. Include
transparent colour/mask holes, loading in front/behind a candidate, camera
capacity pressure and generation reuse. Retain captures, counts and commands
under D-44/D-47/D-48, not only mathematical reasoning or passing headless tests.

### P-15. Compressed discovery and temporary-store transactions — approved by D-59

**Owner checkpoint completed by D-59 at `d527957369`.** All seven clauses
below are approved; “proposed” describes their drafting history, not remaining
implementation discretion. This completes Q-20's specification for
D-38–D-43/D-51–D-53. The principal tradeoff is that an edit is
acknowledged only after its changed records and discovery continuation have
been written to the temporary store. The camera remains asynchronous, but
edit completion includes disk latency. This is a session store, not a game
save or a promise of recovery after process, OS or power failure.

The proposed initial allowance is **1 GiB per arena**, configurable at open,
with explicit Lua growth and recovery. The following limits are conservative
starting contracts, not measurements of throughput or process RSS. They must
be qualified; an implementation that cannot meet them reports the evidence
and returns for a design decision instead of silently relaxing them.

**1. Compile exact component families, not hidden cells.** The immutable
source remains the bounded layer/column-patch recipe. Derive compressed
regions and shared-face portal relations from that recipe and P-9's exact
geometry. Partition at authored coordinate/interval boundaries, with
parameterized families for repeated independent components and bounded
exceptions around patches. Coordinates, interval ends and intersection
calculations use checked exact arithmetic, including the upper endpoint one
past the highest supported cell.

One rectangular range is not necessarily one connected space. For example,
a uniform N-ramp layer has separate parallel row channels: the S face is
sealed while the N face is open. Repeating shaped cells vertically can also
leave separate components at each level because no approved shape has a
positive-area bottom opening. The compiled representation must preserve
row/column and level indices as component parameters where necessary.
Full-air slabs, connected shaped planes, isolated channels and patch-created
splits have distinct descriptors; a descriptor may cover a vast range without
asserting that every member is mutually connected.

Represent joins between entire parameter ranges symbolically when the portal
proof applies to that range, with explicit fragments/exceptions otherwise.
A shaft can join many layer components without enumerating their cells.
The compiled result provides exact component lookup, canonical source keys,
range membership, portal relations and compressed boundary descriptions.
Keys depend on the validated source, never the order of chunk loading.
Do not infer connectivity from overlapping bounding boxes or visual alpha.

Initial exterior means connection through positive-area openings to the
**upper Z boundary**, including the unobstructed sky above ordinary terrain.
The horizontal and lower coordinate limits are not exterior openings: a
world-spanning covered air layer must not become known merely because its
range reaches X/Y limits. Derive upper connectivity symbolically; do not flood
the sky. An occupied topmost full block supplies no opening, while a topmost
shape's actual top portal can reach exterior. This explicitly defines the
otherwise exceptional finite-coordinate boundary behavior.

Open succeeds only with exact exterior/component metadata. The required
flat arena, world-spanning air layer, all-16-shape cavity fixtures and huge
uniform ramp/channel/layer families must work. Valid but excessive patch or
connectivity complexity may settle as expected `source_complexity` before
an arena is published. There is no dense fallback or partial open.

Proposed default preparation bounds, all checked before the corresponding
allocation/work, are:

| Resource | Initial bound |
| --- | --- |
| Compiled connectivity per arena | 16 MiB, charged to the 256 MiB resident terrain bank |
| Compilation peak, including its result | 48 MiB from that bank; one compilation active per session |
| Structural nodes / portal or range relations | 65,536 / 262,144; the byte bound may be tighter |
| Total compilation work | 8,388,608 counted bounded primitive steps |
| Service quantum | At most 1,024 such steps before yielding fairly to other work |

A primitive step cannot conceal a scan over a coordinate span, unbounded
container or arbitrary recipe. Decoder/page operations and exact arithmetic
also have checked bounded inputs. Opening is asynchronous and cancellable;
discard all partial metadata/reservations on failure. Existing source and
copied-value limits continue to apply independently.

**2. Removal adds connectivity; it never splits existing air.** Keep the
source component index immutable. The dynamic overlay contains coalesced
removed intervals, additional connections/unions, discovered component/range
labels and pending obligations. Whole-cell removal only enlarges air, so old
source components remain valid connected subsets. Union aliases may combine
them; they do not require rebuilding all underground terrain. This reasoning
does not authorize later placement, reshaping or moving solids: those would
need a split-capable topology contract.

Every changed removal records a minimal connection-inspection continuation
in the same transaction as the edit. Connecting to known space propagates
knowledge; merely executing a raw Lua removal inside a sealed unknown area
does **not** grant discovery. Such edits still record their new connections,
so a later opening reaches the whole modified component. Raw queries and
loading remain non-discovering under P-14. Removing already-air terrain is a
no-op and does not append redundant history.

Shared work records distinguish unseen, pending and expanded obligations,
refer to the arena/source incarnation and authoritative revision, and merge
overlapping fronts. A batch that marks a component/range known also retains
its unprocessed outgoing obligations and exposed-boundary knowledge. Existing
known/exterior branches may stop traversal only after newly added connections
have been accounted for. Two opposite openings cannot lose each other's work
or turn a pending branch into a false completion.

Knowledge is recorded by compressed component/range identity. Exposed solid
boundary knowledge is derived/retained with that identity and exact contact
geometry; it need not copy one marker into every boundary chunk. A chunk
reload resolves the source, removed intervals and applicable knowledge before
publication. Global compressed knowledge therefore satisfies D-33/D-51's
per-chunk replay requirement without enumerating all chunks of a vast cavern.
Known solid and known empty component remain separate facts under P-14.
Completion means no unaccounted connectivity obligation, not resident detail
or a percentage of hidden tiles. Progress cannot rely on unbounded RAM sets.

**3. A reserved, private, bounded temporary file.** Create one arena-private
file with private permissions and no inherited descriptor, then unlink its
name while retaining the descriptor. Open-file lifetime lasts until its final
descriptor closes; there is no named save to reopen and no later orphan-file
scan. The resource owner must drain descriptor borrowers before closing it.
This lifecycle follows the native [unlink contract](https://man7.org/linux/man-pages/man2/unlink.2.html);
both target platforms require qualification.

`storage_bytes` defaults to 1 GiB, has a minimum of 64 MiB, and must be an
integer multiple of 1 MiB within checked native signed file-offset limits.
The allowance includes private data/index/allocator pages, in-flight copies,
retired pages and conservative reservation/format overhead. Reserve before
successful open; preserve at least 256 MiB of reported free-space headroom
on that volume after the proposed reservation. This headroom is an initial
host-profile guard, not a guarantee that other applications cannot fill it.

The backend must actually reserve the required extents and account for its
allocation granularity/overhead; making a sparse file of the right length
does not qualify. The target mechanisms are macOS
[`F_PREALLOCATE` with `F_ALLOCATEALL`](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
and Linux native [`fallocate` allocation](https://man7.org/linux/man-pages/man2/fallocate.2.html).
Require qualified filesystem behavior and checked file-length establishment;
do not substitute an unreserved or user-space zero-writing fallback on an
unsupported filesystem. Native API documentation is a starting point, not
proof of APFS/Linux behavior, overhead or later writes. External filesystem,
device and space failures remain possible and use D-41's pause/preserve rule.

Use immutable 4 KiB pages with copy-on-write B+tree indexes for removed
intervals, component/union/knowledge records, pending discovery and allocator/
retirement records. Keep complete history and indexes on disk with bounded
caches, not an ever-growing heap index or replay-only operation log. The
private versioned codec uses explicit little-endian fields, bounded counts,
checked page references and CRC32C page checksums, tied to the arena/source
identity. It is not `Show`/`Read` serialization or a public game-save format.

The live committed root set is held by the terrain owner. Write all new pages
successfully before publishing a new root; never overwrite pages reachable
from the committed root or a reader's pinned root. Successful writes mean OS
write completion, not per-edit `fsync` or power-loss durability. No cross-run
root journal/recovery protocol is required for this disposable arena.

Before publication, staged pages are unreachable and claimed only by the
pending transaction. If writing/cancellation fails, retain the old root and
release those claims after I/O drains; reverting the authoritative state must
not require another successful write. After publication, retire only replaced
pages, retaining their reclamation obligations until the last reader of the
old root releases it. Shared unchanged pages remain owned by the new tree.
Store reclamation work on disk and process it incrementally. No full-store
second copy or unbounded compaction is permitted.

Keep 8 MiB **inside** the allowance protected for allocator/reclamation
progress. Ordinary new history cannot spend it. Reserve the transaction's
worst-case new pages, index paths and retirement metadata before admitting
the mutation. If that cannot fit, pause before changing authoritative state.
The memory-held root and page-cache accounting do not excuse disk growth.

**4. Bound the working set and I/O.** Preserve D-42's service-wide banks and
P-5's arena/view/lease/command/load-job limits. Proposed sub-budgets inside
the existing 64 MiB edit bank are 48 MiB for record/page caches, 8 MiB for
staging and 8 MiB for control/frontier state. These are shared across arenas;
retained history beyond the caches belongs in the reserved files. Coverage,
render preparation and GPU resources keep their separate existing banks.

Use one active mutating store transaction per session, fairly scheduled
between explicit edits, discovery, growth/recovery and reclamation. Each
transaction reserves at most 4 MiB of RAM and writes at most 1 MiB of new
encoded pages, including its index/allocator/retirement changes. A discovery
batch performs at most 64 structural updates and persists a continuation
when more remain. Both bounds apply; large discoveries span transactions.

Use two storage I/O workers and at most eight queued I/O descriptors per
session. A job transfers at most 1 MiB; allocate its accounted buffer at
dispatch, not once per queued job. A transaction's I/O buffers count within
its own reservation. Protect 4 MiB of staging for a foreground mutation so
camera reads cannot consume every byte it needs. Every buffer, decoded copy,
cache pin, reader root and queued continuation has an owner and byte/count
charge. Scratch maps and retiring pages are not free hidden banks.

The terrain-owner thread alone publishes roots, revisions and request
results. Workers perform bounded file I/O with arena-incarnation jobs and
return completions; they do not mutate the world or retain Lua values. Pure
connectivity, codec and allocation decisions remain independently testable.
Explicit requests retain priority over camera prefetch, with fair service
for already accepted work and discovery/reclamation. Reads and camera/input
processing can continue while a write is outstanding. Admission must prove
that the supported standalone explicit transaction fits; eviction or a clear
`busy` result handles temporary occupied capacity, never a circular wait.

**5. One publication point for an edit and its discovery obligation.**

1. Validate authority, coordinates and optional pick consistency against the
   current arena; reserve the peak RAM/disk needs and minimum continuation.
2. Stage the removal plus its connection-inspection obligation and associated
   metadata against the committed root. Compute bounded discovery batches
   by the same protocol, with known labels and remaining obligations together.
3. Write the new pages asynchronously, handling short writes and failures
   explicitly. No staged knowledge is exposed to a view or raw terrain query.
4. On the terrain owner, recheck incarnation, root and cancellation. Arbitrate
   cancellation/close against publication once: either the old state survives
   with no committed mutation, or the new root/revisions and success result
   become authoritative together. Cancellation cannot undo a published edit.
5. Release staging; reclaim replaced pages only after their readers finish.

Removal success means the edit and required pending work are backed; it does
not mean the whole cavern has finished discovery or the GPU has adopted it.
Content revision advances for changed terrain, knowledge revision for changed
knowledge, and a private store revision for frontier/maintenance commits.
Check all revision increments for overflow; none wraps or silently reuses
an authority. P-14's coherent plan identity includes knowledge revision.

Acknowledged changes already have a backing copy, so ordinary chunk offload
can evict caches without another required write. Reload uses one coherent
committed root; missing edit/knowledge pages are `loading` or an expected
storage failure, never permission to substitute pristine source terrain.
Prepared rendering copies its data and releases store readers; a GPU fence
must not pin disk pages. Existing CPU/GPU retirement still applies to its
separate resources.

Expected capacity, I/O or integrity failures pause new edits and advancing
discovery for the affected arena, retain its last committed state and pending
frontier, and settle uncommitted user mutations with an expected result.
Do not keep those requests hanging or automatically repeat them after
recovery. Unaffected arenas may continue. Already available coherent display
and provable reads remain usable; unreadable authoritative pages do not
become air, unknown fog or regenerated unedited terrain. An integrity failure
cannot be cleared merely by demonstrating that a scratch write works.

**6. Concrete Lua control and expected results.** Extend the P-5 facade as
follows. Each call uses its existing `OptionalRequest`/`api.request` policy,
copied plain records, phase/role checks and immediate `busy` admission result.
Both script roles may use terrain services; creator authority is still local
to the creating instance, not obtainable by attaching to an arena name.

| Call | Proposed contract |
| --- | --- |
| `api.terrain.open(name, definition [, options])` | Optional `storage_bytes`; omitted means 1 GiB. Finish source compilation, reservation and initial roots before returning the creator's arena lease. No other new options. |
| `api.terrain.status(arena)` | Any valid own lease; bounded copied status snapshot, with no hidden coordinates or history dump. Advisory, not a reservation for later work. |
| `api.terrain.grow_storage(arena, new_bytes)` | Creator-owner lease only. Larger reservation is obtained before publishing the larger allowance and resuming capacity-paused work. Equal size is an idempotent success; a smaller size at execution settles as `storage_size_not_increased`. No shrink or automatic growth. |
| `api.terrain.retry_storage(arena)` | Creator-owner lease only. Explicit bounded I/O/revalidation attempt; resume internal discovery only if the recorded failure is actually cleared. Never re-execute a previously failed user edit. |

Status, growth and retry remain admissible while the arena is paused, subject
to their ordinary bounded request capacity. Retry on an already ready arena
is an idempotent success. Protected reclamation may continue during a
capacity pause; retry succeeds only after space for the supported next
transaction is available. Growth or explicit successful retry clears that
pause, rather than automatically restarting failed user mutations.

Status contains `storage.state` (`ready`/`paused`), an optional `reason`,
`reserved_bytes`, `used_bytes`, `pending_reclaim_bytes` and
`pending_reserved_bytes`; `discovery.state` (`idle`/`pending`/`paused`) and
`pending_items`; and content/knowledge revisions. Counts refer to compressed
work records and bytes, not a hidden-tile count or completion percentage.
Reserved bytes are the committed allowance; used bytes count occupied private
pages and overhead within it, not the still-free preallocated pages. Used
bytes include live, staged and retired allocations; pending reclaim is a
subset, not extra available space. Report uncommitted
growth reservations separately until committed or released. Status itself
does not require enumerating the store.

Malformed options/types, foreign/non-owner handles where owner authority is
required, invalid size/alignment and out-of-range coordinates are ordinary
binding errors before provider work. Add expected domain codes
`source_complexity`, `storage_unsupported`, `reservation_failed`,
`storage_full`, `storage_io`, `storage_integrity` and
`storage_size_not_increased`; preserve existing `arena_closed`, cancellation
and other request results. Expected domain results do not latch an instance
failure. Host invariant/provider defects remain host failures.

Growth is serialized with store mutation and checks the current cap at
execution. Failure/cancellation before its commit preserves the old cap,
roots and pause. Account and finish releasing any partially obtained extra
reservation before another growth attempt; if release itself fails, retain
that accounted pending reservation and report it until recovery/close.
Capacity recovery does not clear a separate I/O/integrity pause. Retry checks
the recorded failing operation/pages plus a bounded reservation/write probe
as applicable; persistent errors preserve the pause. No polling retry loop,
implicit reset or history deletion is allowed.

**7. Ownership, teardown and proof.** The arena owns the recipe/index,
committed roots, file and knowledge; the narrow terrain service owns workers
and shared bank accounting. Reads borrow bounded immutable roots, and views
hold coherent copied publications. Close, creator-instance exit or session
reset invalidates the incarnation, cancels uncommitted work, drains I/O and
reader borrowers, closes the private file through `withResource` and releases
the banks. Preserve primary/cleanup failures under the resource contract.
Do not close/reuse a descriptor while an old job can still use it. Reset
means closing and opening a fresh arena; no new reset API or cross-run replay
is introduced. A process exit naturally discards this unnamed temporary
store after all descriptors close.

Required evidence, assigned to implementation slices later under Q-19:

- Compare the symbolic compiler to an independent small explicit portal/flood
  oracle across all 16 shapes, rotations, patch-created splits, sealed spaces,
  diagonal openings and sky. Prove huge independent ramp rows/levels remain
  separate, whole-air layers stay compact, and X/Y/lower limits do not act as
  sky. Record structural/work/byte counts and bounded complexity refusals.
- Exercise both opening orders and interleavings, a raw buried removal,
  long coalesced removed runs, range unions, known solid beside unknown void,
  pending continuation and coherent offload/reload after every discovery
  batch. Whole-space completion cannot require materializing its boundary.
- Inject short writes, read/write failures, checksum faults, full allowance,
  growth and rollback/release failures, and cancellation/close on each side
  of root publication. Prove unchanged old roots on failure, no duplicate
  edit, no lost obligation, bounded queues/buffers and safe reader retirement.
- Qualify reservation, write capacity, overhead/peak space, growth and
  unlink/last-close behavior on the supported macOS/Linux backends using
  bounded temporary-volume or fault-provider fixtures. Never fill the owner's
  ordinary drive as a test. Unsupported storage must refuse cleanly.
- Retain storage latency/allocation evidence, close/reset/late-incarnation
  checks and the P-14 fog/picking integration proof. Headless algorithm tests
  do not replace P-11/P-13/P-14's offscreen visual evidence. No performance
  result is claimed by this design.

The alternatives not recommended are acknowledging RAM-only edits before
backing succeeds, an ever-growing operation log/heap index, dense hidden-cell
flooding, automatic quota expansion and cross-run crash recovery. This
proposal adds none of the deferred general gameplay/ECS transactions,
whole-tick rollback, movement rules, UI or saved-world schema.

### P-16. Amendment delivery and readiness — approved by D-60

**Q-19 owner checkpoint completed on 2026-11-08.** D-60 approves P-16 as
written at `b012fabbfc` and declares the amendment ready for issue processing.
The approved plan adds **11 follow-up children, TRA-13–TRA-23**, to existing
EPIC #636, specifies revisions to #645–#648 and the baseline coordination
below. It creates no second epic, reopens no completed issue and changes no
tracker artifact. The approved slice clauses are promoted verbatim into the
delivery plan; the ledger retains all original IDs/links and marks only the
new follow-ups unprocessed. They are design IDs, not filed issue numbers.

**Tracker refresh, 2026-11-08.** #636 is the existing open terrain epic;
no overlapping second open arc was found. #637/#638/#642/#643 are closed with
merged PRs #649/#651/#650/#652. #639 remains open with PR #653 at
`8938cc7286be`; #640/#641 remain open. #644 remains open with held PR #654
at `734a8543ab9b`; #645–#648 remain open without implementation PRs in the
checked listing. The other open work (#563 and deferred #446) does not supply
this amendment; render-target sampling from #446 is not a prerequisite.
These are snapshot facts, not a claim that readiness labels approve new text.

**Keep useful baseline work and replace its superseded assumptions explicitly.**
Retain #654's artwork provenance, material registration/package separation,
offscreen harness and original measured evidence as baseline work. Complete
its existing review defects through the manager's normal review path before
any landing; its old per-face renderer is replaced by TRA-17. The approved
plan keeps this as a follow-up correction under D-28, rather than expand
#644 into the entire amendment. Approval of this plan does **not** release
the manager's hold, approve the current PR head or authorize a merge. The
manager coordinates resumption and any baseline-disposition change before
dependent implementation. New renderer qualification is mandatory below.

Likewise, #639/#640/#641 remain the pure-residency, service and Lua-settlement
baseline, with D-42's already authorized CPU budgets/explicit-demand policy.
TRA-20–TRA-23 replace their RAM-only total-history/capacity assumptions with
the approved store contract. Do not make the active residency worker absorb
the storage subsystem or treat a baseline's completion as amended acceptance.

Each new child in the delivery plan is one PR with its own owning contracts,
focused tests and required evidence. Phase order expresses dependencies, not
permission to skip proof or broaden a slice. Independent work may proceed
once its prerequisites exist; no numeric ID grants parallel edit authority.

The eleven approved one-PR slice specifications now appear in **Delivery
plan**, in the same order as the processing ledger. Promotion changes their
location and heading level, not the signed-off scope, dependencies or proof.

**Existing tracker artifacts to revise later, one signed-off draft at a time.**
The following is the revision scope, not ready-to-post issue body text.

**Atlas update (D-61/P-17):** the baseline tracker snapshot above is historical.
The manager's 2026-11-08 dispatch records the merged geometry/maps/loader,
cell-quad planner and source/discovery work, plus #672's byte-only texture
admission. First revise **#659 / TRA-17** for offline atlas preparation,
checked region sampling and shared coverage. The #645/#646 bodies already
applied and the pending #647 draft then need the same region contract:
#645 retains distinct parent/region versions and shared interests; #646
validates complete region mappings and kind/profile; #647 loads the generated
atlases/manifest. #648 must qualify packed-versus-1×1 equivalence and final
bank accounting. All consume P-17's current byte banks, with no texture-count
cap. This paragraph and P-17 supersede whole-image assumptions in the scope
table and historical TRA-9–TRA-12 text below; those earlier requirements
otherwise remain intact.

| Artifact | Required revision or coordination |
| --- | --- |
| EPIC #636 | Extend the existing arc/checklist and dependency graph with TRA-13–TRA-23; distinguish logical query geometry from visual alpha picking; add corrected ID 15, fog/discovery, lighting, viewport demand and temporary backing/recovery. Replace the cross-run-persistence exclusion's ambiguous wording, keep saves deferred, and require new evidence before final acceptance. No new umbrella. |
| Closed #637/#638/#642/#643 | Preserve their history and issue status. TRA-13 and TRA-16/TRA-17 supersede affected geometry/visual assumptions; TRA-18–TRA-22 extend source/change behavior. No duplicate rewrite of ordered input. |
| #639 / PR #653 | Preserve the manager's D-42 budget and best-effort/explicit-demand clarification. Add later coordination links to the new model/store owners; do not enlarge this active baseline into discovery/storage or silently claim its RAM-only model is the final history policy. |
| #640 | Keep its scoped service, settlement seam and baseline scope; link TRA-22 as the owner of write-backed transactions, startup compilation and knowledge revisions. Its “no disk store” is a baseline scope limit, superseded for the complete arc by the follow-up. |
| #641 | Keep the original facade/real settlement bridge; link TRA-23 as the owner of storage options/control/error changes. Its old immediate busy rule for total RAM history is not the amended hard-disk-cap contract. Preserve pending-open name-claim semantics. |
| #644 / PR #654 | Record the baseline disposition and retained evidence limits above; add TRA-17 as the new amended Q-13 gate. Original review fixes and a fresh exact-head review remain required. No hold release or merge follows from this document. |
| #645 / TRA-9 | Depend on TRA-17 and TRA-22 as well as baseline prerequisites. Consume cell/mixed-fog quads and coherent knowledge revisions; own exact normal/colour versions and CPU coverage interests; charge the amended 128 MiB CPU render bank and existing GPU/retirement banks. Integrate full projected viewport/height-band demand, progressive bounded admission and view-aware eviction. Test hazed background beyond the old radius, pending knowledge, reveal/offload/reload and atomic mixed-part adoption under pressure. Preserve exclusive target ownership and actual frame-completion retirement. |
| #646 / TRA-10 | Depend on TRA-23, TRA-6 and revised TRA-9. Add P-13's strict partial lighting/depth records and defaults to style/configure, with complete colour/blank/normal-map mappings and P-11/P-13 validated texture authorities. Preserve the existing atomic camera controls/`slice_delta`; replace conflicting legacy face-tint/filter controls with the approved sampling and unit wrapper tint/brightness. Issue picks only from adopted matching coverage/knowledge: confirmed fog gives `no_hit`, incomplete information gives `loading`, known cell hits alone yield edit authority. Replace the old analytic face/cap result contract. Cover wrong normal profile, stale knowledge/assets, all-or-nothing configuration and independent lighting controls. |
| #647 / TRA-11 | Depend on revised TRA-10 and all transitive amendment gates. Load approved colour/blank/maps with the proper options, author the exact lighting/depth defaults and storage allowance in Lua, and use the real amended services. Keep the default flat source, generic launcher and existing controls. Extend the temporary F8 proof to fog refusal, ramp/mask selection and discovery replay; expose no new UI or debug binding. A storage pause is an expected reported condition: preserve the arena and navigation where data is available, without replaying edits or automatically growing/resetting it. Startup failure retains the existing bounded failure/quit path. |
| #648 / TRA-12 | Depend on revised TRA-11 and every amendment child/proof gate. Replace old flat-ID-15/cap/analytic-picker/RAM-only assertions and stale CPU budgets. Qualify final all-16/four-facing normal/cutout/pick/fog behavior, sky/cavity/dual-opening discovery, viewport/haze loading, store limits/failure/recovery and all owning banks. Retain pre-removal F8 proof separately, remove its binding/glue, then verify final public Lua API behavior and visual/resource evidence. Preserve the bounded optional memory experiment, honest measurements, M1 compatibility and owner visual acceptance. |

**Approved ledger and delivery order:** EPIC; TRA-1–TRA-8; TRA-13–TRA-23;
TRA-9–TRA-12. Every original ID/link remains; its checked mark means filed,
not implemented. The 11 follow-ups are unprocessed and the delivery plan
mirrors that order. Baseline scopes remain history, with current amendment
requirements preceding TRA-9–TRA-12's historical text. The numbers need not
be ascending when dependencies require inserted work.

The material path is TRA-13/TRA-14/TRA-15 → TRA-16 → TRA-17 → TRA-9.
The discovery/storage path is TRA-13 → TRA-18 → TRA-19 → TRA-20 → TRA-21
→ TRA-22 → TRA-23, with baseline dependencies listed above. TRA-9 also waits
for TRA-22; TRA-10 joins TRA-9, TRA-23 and ordered input. TRA-11 assembles that
result, and TRA-12 is the final barrier after **all** amended behavior exists.
This lets baseline service work and rendering/discovery foundations proceed
independently where their actual source/interface boundaries permit.

**Evidence gates and readiness.** TRA-13/TRA-14 own the reference-defect and
canonical geometry/map evidence; TRA-17 owns amended offscreen Q-13 proof;
TRA-18/TRA-19 own exact compressed-connectivity/discovery proof; TRA-20–TRA-22
own store/admission/publication and native-reservation qualification. Revised
TRA-9 owns live viewport/haze demand, adoption and GPU lifetime evidence;
revised TRA-10/TRA-11 own real Lua/content behavior; TRA-12 owns the final-build
matrix, native observations, retained captures, measurement summary and
shortcut removal. Each owning slice updates its current contract and catalog,
and lands human docs/evidence with `docs-push` before final implementation review.

No old screenshot, unreviewed fixture fix or passing CPU-only test proves the
amended GPU result. No unlimited world-size claim, default limit or source
compression formula is a measured performance result. Required unproved
geometry, sampling/order, source-family or filesystem behavior is an explicit
delivery blocker with a reproducible counterexample; return material changes
to the owner rather than silently dropping a fixture or widening an interface.

D-60 records approval of this slice/revision plan and the explicit declaration
that the amendment is **ready for issue processing**. The document's ledger,
order and readiness are promoted; this does not create/edit tracker items,
authorize code work or release PR #654. Later processing revises the existing
epic first, then handles one new child or existing-issue revision per invocation,
with a separately approved concrete tracker draft.

### P-17. Atlas preparation, region sampling and shared coverage — D-61

This amendment supersedes whole-texture assumptions in P-11/P-13/P-14 and
the affected TRA-17/TRA-9–TRA-12 contracts. The source catalog remains the
qualified output of TRA-14. Packing is **offline asset preparation owned by
TRA-17 (#659)**, beside that generator and the terrain material integration.
It is not work for the generic runtime loader, and does not reopen a merged
prerequisite. At H `da001722`, TRA-13–TRA-16 and TRA-18/TRA-19 have merged;
TRA-17 extends their public contracts narrowly where regions require it.

**Authored sources and derived assets.** Preserve the original loam, granite,
blank and 46 whole-canvas normal maps, their logical IDs, bytes and provenance.
Produce two derivative atlases: one colour/blank atlas and one numeric normal
atlas, with a versioned, deterministic manifest mapping every logical ID to
its parent atlas and integer rectangle. Keep the source hashes, parent atlas
hashes, dimensions, colour/data kind and normal profile in the checked asset
identity. The four-facing catalog lookup still selects logical maps; it does
not become four separately authored atlas sets. A single image is represented
by the same contract with a full-image rectangle (a 1×1 atlas).

Packing may not rotate, trim, scale or alter a source canvas. Each logical
region remains 96×64 with the existing row orientation. Rectangles are
non-overlapping and contained within the physical atlas; unused pixels have
zero alpha. Keep colour and numeric data separate because their decode,
premultiplication and colour-space rules differ. Deterministic regeneration
and a non-writing check cover both the original maps and the derivative
atlases/manifest. Region extraction must recover each source's decoded RGBA
exactly; a packing change cannot quietly replace authored art or geometry.

**Loading and checked region authority.** Use TRA-15's bounded texture loader
with the existing colour/data, binary-coverage and `unit-normal-rgb-v1`
options. Normal validation still covers every opaque texel of the data atlas;
transparent padding contributes no normal. A region is an immutable checked
view of a particular parent texture/coverage generation, not another texture
allocation. Its integer rectangle must be positive, fit the parent without
overflow, match the logical extent, and have the required kind/profile.
Reject incomplete, incompatible or wrong-parent mappings before publication.
An unchanged parent hash with a changed rectangle/layout is a changed asset
identity: include the rectangle and layout identity in snapshot/cache keys,
alongside parent versions, map IDs and normal profile. Old region metadata
must never be paired with a newer atlas or adopted camera/knowledge snapshot.

The CPU stores one immutable binary coverage plane per loaded atlas. Provide
a checked region view that translates local texels into that parent plane;
do not copy a plane per region, quad or terrain cell. Keep any neutral image
region type at an image/asset boundary without a dependency on terrain. Adapt
TRA-16's 96×64 checks, opacity proofs and asset snapshot identity to the
logical region, not the larger physical plane. The existing #657 decode and
#658 coverage/picking authorities remain the source of truth; #659 owns the
narrow region-view integration required to use them. No independent PNG
decoder or separately reconstructed picking mask is introduced.

**Exact CPU/GPU sampling.** Quad UVs stay in logical `[0,1]²`. For local
region extent `(w,h)=(96,64)`, choose
`i=min(w-1,floor(clamp(u,0,1)*w))` and the corresponding `j`. Read CPU coverage
at `(originX+i, originY+j)` in the parent plane. The GPU samples that exact
texel centre, `(origin+(i+0.5,j+0.5))/atlasExtent`, at level zero with the
existing nearest/clamp sampler. Apply the same calculation independently to
colour and normal regions; their parent dimensions and origins need not match.
P-11's higher-index interior-edge and clamped outer-edge rules are unchanged.
Clamping only to the whole atlas is insufficient. A linear interpolation
between half-texel-inset endpoints is also insufficient: it moves the interior
decision boundaries. Neighbouring cells and transparent packing space must
not bleed into the result. Geometric clipping, raster pixel-centre ownership,
normal decoding and the shared 0.5 cutout threshold remain unchanged.

P-13's record carries both full texture handles and checked region words,
so the material can sample both parents correctly using the existing helper.
Validate that its colour handle agrees with the primary texture slot; retain
both parents through actual GPU completion. The old pre-sampled primary texel
cannot substitute for the region-clamped colour sample. Shader sampling must
respect the existing material compiler's control-flow/derivative constraints.
No new renderer ABI, descriptor scheme, per-cell GPU image or public Lua call
is part of this change. TRA-10 consumes the same authority through its strict
copied style mapping; the five public terrain calls remain the same.

**Ownership and memory.** Loaded assets own parent textures and coverage;
regions borrow those immutable parents through explicit interests. An adopted
mixed terrain/fog cell acquires all required parent/region interests together.
CPU last-reader retirement and GPU completion retirement remain distinct.
Count the parent allocation once within its existing bank, even when many
regions or a duplicated material handle reference it; releasing a Lua lease
does not invalidate an adopted view. Existing bounded metadata/input limits
still apply, without a new texture-count policy.

Merged #672 removes the per-instance texture-count admission limit. The
texture-byte banks are **512 MiB per UI instance and 1 GiB per session**, with
a **4 KiB minimum charge per physical texture**; pending/live/retiring charges
stay reserved until their established release point. These are texture banks,
not whole-process RSS ceilings. The amended **128 MiB CPU render bank** still
covers shared coverage and render metadata; decoder staging/workspace and
native-accounted banks remain independent. Charge actual atlas allocations
and their bounded preparation/validation costs under the owning contracts.
Refusal must preserve the previous usable style/frame and release partial
acquisitions. Neither adding regions nor packing is permission to evade a bank.

**Proof and migration.** TRA-17 retains its full Q-13 material proof and adds
independent atlas checks: exact source extraction; distinct colour/data
treatment; all logical map IDs/facings; nonzero origins and unequal parent
layouts; internal texel boundaries, outer corners, adjacent regions with
different colour/alpha/normals, and transparent padding. Compare full-image
1×1-atlas and packed-atlas render/pick results under the same transforms.
Reject invalid/out-of-bounds/overflowing rectangles, wrong kind/profile and
stale parent/layout identity. Negative controls must detect whole-atlas-only
clamping, shifted texel boundaries, swapped regions and stale region reuse.
Keep independent expected values and discriminating GPU pixels rather than
blessing generated output as its own oracle. Shared bitplanes and unchanged
logical IDs do not by themselves prove sampling or visual equivalence.

TRA-17 owns packing, material use and pure coverage/pick integration; revised
TRA-9 owns live interests, adoption and retirement; TRA-10 owns strict Lua
region mappings; TRA-11 loads the derivative assets; TRA-12 qualifies the final
composition. The manager's processing order is **#659 first, then #645, #646,
#647**, each as its own complete draft and sign-off before mutation. The later
#648 final acceptance revision must also consume this contract. Existing
links/statuses remain intact; neither this design publication nor a previous
readiness review approves a changed issue body.

## Open questions and review checkpoints

### Q-1. What does flat terrain contain vertically?

Resolved by D-4: the model includes subsurface structure and gaps. D-15/D-21
add explicit blocks, ramps and corner slopes.

### Q-2. Finite arena or expandable terrain?

Resolved in direction by D-7/D-11: expand horizontally and downward with no
designed boundary. P-5 specifies checked coordinate limits and region sizes;
these machine/resource limits do not introduce a gameplay terrain floor.

### Q-3. How does demand become usable terrain and then retire?

Behavior resolved by D-2/D-6/D-10/D-19. P-5 supplies the concrete owner,
request/cancellation protocol, revision checks, vertical residency, memory
budgets, offload transfer and GPU retirement contract approved through Q-12.

### Q-4. What can the owner see and control in the first version?

Behavior resolved by D-8/D-9/D-12–D-14/D-18/D-22: isometric four-facing view,
pan/drag/zoom, Shift-scroll cutaway, follow/manual modes and optional jump Z.
The removal shortcut is development-only. P-5 supplies exact bindings,
surface selection, cutaway band, picking and artwork adaptation approved through Q-12.

### Q-5. What belongs to the reusable engine and what belongs to Ecce Homo?

Direction resolved by D-17. P-5 supplies the concrete package/port split and
instance-owned Lua leases. Game recipe/artwork remain outside engine packages.

### Q-6. Mutation, persistence and state publication?

Resolved in scope by D-9/D-10/D-19/D-20/D-21: atomic tile removal, session-only
changes, no automatic neighboring shape edits, no whole-tick rollback. P-5
specifies canonical removed spans, snapshots, request cancellation and
arena replacement. General editing/reset tools are excluded from this arc.

### Q-7. What proves this first terrain foundation complete?

The epic done condition, verification matrix and TRA-12 below give the
observable acceptance approved with the delivery boundaries through Q-12.
Actual runtime/visual/performance evidence belongs to implementation; none is
claimed from this documentation turn.

### Q-8. What is the logical model of solid terrain and gaps?

Scope resolved by D-4/D-5/D-15/D-21/D-25: preserve all 16 Synarchy slope/mask
IDs and visual forms. Shared coverage/picking and four-facing fixture fidelity
are current requirements; movement and walkable connections are deferred by
D-24. Do not silently fall back to a full block for a supported mask.

### Q-9. How is terrain represented compactly, including unmaterialized depth?

Direction resolved by D-5/D-7/D-11/D-16/D-26. P-5 specifies implicit layered
source, sparse adaptive uniform/run/dense segments, compressed removed
intervals, vertical eviction and memory accounting. Its payload comparison
selects the representation; runtime allocation/throughput remain implementation
qualification. Host-budget defaults and API boundaries are approved through Q-12.

### Q-10. Terrain transactions versus the deferred gameplay-state service?

Resolved by D-20: narrow terrain transactions only. Preserve the general
gameplay-state design and M1 unavailable-state guard. Per-operation commit is
not a promise of full gameplay tick rollback or arbitrary Lua rollback.

### Q-11. Complete scope of the camera and shapes?

Resolved in behavior by D-18/D-21/D-22. P-5 makes the exact geometry and
presentation mechanisms reviewable. It does not copy Synarchy's zoom-map
reset, material-dependent slope inference or game managers.

### Q-12. Approve the concrete technical contract and delivery boundaries?

Resolved by D-27: the owner approved the complete design at `398a58f35c`,
including P-5, its defaults/limitations, the epic done condition and
TRA-1–TRA-12. Verified manager relay: `#het-terrain`, message
`39em862uwqaj3x3t4dn9kipeta`, 2026-11-07T02:13Z.

This was the original design's readiness sign-off and authorization for an
EPIC draft for manager sign-off before creation, not approval to file it.
The original arc was subsequently filed. D-28 reopened readiness for the
amendment; D-60 now records its new sign-off and resolves Q-19. The design
is `ready for issue processing` for the approved amendment.
Q-13 remains an in-delivery proof gate; Q-14's migration dispositions stand.

### Q-13. Can the current renderer represent the geometry correctly?

Deliberately gated implementation question: TRA-7/TRA-8 own the historical
baseline; D-60 assigns amended-path proof to TRA-17, using TRA-13/TRA-14's
geometry/map evidence, before TRA-9–TRA-12 proceed. Prove depth ordering,
cutaway coverage and pick/render
agreement for roofs, gaps, ramps and corner slopes through the current
render-2d ABI. If the proof fails, stop those dependent slices and return a
specific renderer-change proposal to the owner. Do not broaden renderer
interfaces, substitute incorrect visuals or call the arc complete.

Measured outcome (TRA-8, #644, offscreen on one device, material and geometry path
only, not runtime qualification): the existing ABI represented every supported
fixture correctly; see
[the assessment](../evidence/terrain/tra8/README.md), which also records a
fidelity finding against the reference sprites' silhouettes for the owner's
reading. This links the measurement and changes no owner decision.

D-44 adds the solver evidence gate for the amended shape/mask path: reproduce
the reference defect, deliver original/corrected captures covering all 16 IDs
and four facings, and prove corrected coverage, picking and logical opening
agreement as specified above. The old per-face solid-renderer measurement is
not that proof. This evidence is required during implementation before the
affected qualification and final arena acceptance can pass.

The broader historical “full Synarchy port” memory reconciliation is not an
implementation dependency for this explicitly approved first arena. Fidelity
beyond this arc remains uncommitted; MEMORY.md is unchanged.

Readiness refresh, 2026-11-08: PR #654 remains open at `734a8543ab9b`.
Its body records fixes after CHANGES_REQUESTED, unreconciled snapping proof
and stale captures for several earlier fixtures; the fixes have not been
reviewed. The linked historical outcome above is not current-head approval,
release of the manager's hold or qualification of P-9–P-15. The approved
delivery plan retains those limitations and assigns fresh amended-path evidence.

### Q-14. Migration-review disposition

Resolved for this arc by D-23–D-26. Separate automatic headroom and manual
cutaway; preserve the full 16-ID visual mask catalog; defer walkability/speed,
source/general-edit expansion, gameplay transaction integration and later scene
composition. Select adaptive sparse storage using the stated payload/complexity
analysis, with actual runtime costs qualified during implementation. Those
deferred systems are not added readiness gates for the first arena. Q-12 is
approved; the deliberately gated Q-13 remains for implementation.

### Q-15. Static face shading now, or the full day/night path?

Resolved by D-29. The owner approved face-map silhouette alpha and
facing-aware directional shading now, with an adjustable sun-position shader
input so previews show the tile under selected lighting. Automatic day/night
and eventual moon lighting are deferred. "Static" means no automatic cycle;
it does not mean an unchangeable sun or baked face brightness. The exact input
and preview contract remain Q-18.

### Q-16. Logical terrain, visual coverage and picking contract

Resolved as a specification by D-30/D-36/D-49/D-50/D-55–D-58 and
P-9/P-11/P-13/P-14. Picking uses the adopted drawn quads and matching
artwork/mask coverage in front-to-back order, with shared CPU asset coverage.
The result identifies the logical cell for the existing edit contract.

D-31 additionally preserves blank fog coverage over undiscovered terrain,
including air. Cutaway movement and data residency do not grant discovery.
Fog-specific picking is resolved by D-37: no selectable target, no interaction
and no picking through the fog. Remaining reveal behavior is tracked in Q-20.
D-35 requires
logical shape openings for discovery, including ramp-created diagonal
connections; D-49/P-9 now supplies the approved 16-shape solid/empty regions
and their derived openings.

D-36 resolves #637's subcell query authority: correct those definitions so
point/ray queries and discovery share the canonical logical shape model.
Rendering/screen picking retain sprite coverage as their visual authority.

P-14/D-58 resolves query/API compatibility, whole-cell emission and
hidden-cell culling/ordering. D-50 resolves cap behavior: omit
levels above the slice, retain known shapes/materials and add no flat caps;
unknown regions retain generic blank fog. D-49 approves P-9's lowered-edge catalog,
including the central half-height peak for ID 15, replacing its earlier
flat-block exception. The existing closed-solid boundary convention and the
derived positive-area portal geometry remain the qualification targets.
D-44 resolves the fidelity choice: correct demonstrated mask inconsistencies
while preserving all 16 IDs and face-map rendering, and require solver proof
of both defect and correction. D-49 selects the replacement logical catalog;
exact sampling conventions and corrected-mask evidence remain separate work.
P-10 adds the owner's viewport-loading concern and source comparison. Preserve
the existing view-aware direction when adapting demand bounds to whole-tile
face maps, and reconcile planning limits with D-42. The explicit
coverage/admission/eviction contract is approved by D-48; the concrete planner
integration and qualification remain implementation work to assign in Q-19.
Do not silently retain incompatible ray/coverage claims. Q-17's exact
sample/threshold and coverage resource contract is resolved by D-55/P-11;
its proof is implementation work, not another design choice.

The integer-cutaway owner question is resolved by D-50. Concrete emission,
culling and ordering must implement that behavior and prove it alongside
D-44's shape/mask/picking qualification.

Completed owner checkpoint: D-58 approves P-14's whole-cell quads, mixed ramp/fog
composition, exact ordering, conservative bounded planning, `no_hit` for fog,
loading distinctions and visual/logical API migration. Q-13's renderer proof
and Q-19's assignment of that work remain; specification approval does not
claim implementation, successful captures or owner visual acceptance.

### Q-17. Face-map data loading, sampling and ownership

Resolved as a specification by D-30/D-45/D-55 and P-11: binary-alpha
96×64 initial terrain art/masks, level-zero nearest/clamped sampling and
threshold 0.5, bounded explicit data loading, shared versioned CPU bitplanes,
accounted ownership and CPU/GPU qualification. It adds `kind`/`coverage` options
to the existing texture API and refuses incompatible terrain assets.
General `DataImage` support is not proof that the bounded Lua route implements
the approved policy. Implementation/qualification and the corrected asset
catalog/provenance remain required; no temporary colour-decoding workaround is
approved. D-56/P-12 explicitly supersedes RGB face weights with surface
normals; the alpha/sampling/ownership contract remains. P-13's proposed
normal-encoding validation is now approved through D-57.

### Q-18. Exact initial appearance beyond the silhouette

Resolved as a specification by D-29/D-46/D-47/D-54/D-56/D-57 and P-13. Lua
supplies world-fixed sun direction/elevation and independent ambient, sun
strength and depth effects, without a cycle or moon lighting. P-13 fixes
units/ranges, configuration, initial values and linear-light composition,
including its intentional deviations from the reference.
S's clock phase labels and shader sine disagree; full clock parity cannot be
claimed from labels alone. Fluids, selection outlines, lifecycle sprites and
zoom-map crossfade remain outside the approved arena unless explicitly changed.

D-47 resolves which depth effects to keep: both, adjustable/disableable through
Lua, with stronger tests/evidence. Darkening-only and no-depth-effect defaults
are not selected. The owner reports S's behavior does not work well; specific
symptoms are now recorded in P-10: hazed background tiles can be absent outside
the camera loader's radius despite projecting into the viewport. Source
inspection supports that mismatch, but no runtime reproduction is claimed.
P-13 now specifies the numerical contract; the qualification described above
still must prove it and the background loading correction.

Ambient control is resolved by D-54: use a separate Lua-controlled ambient
level that stays unchanged when only the
sun direction/elevation changes. Directional face lighting still follows the
world-fixed sun. Ambient is the base illumination of faces receiving little
or no direct sun; an independent control makes preview conditions explicit.
Later Lua day/night rules could drive both values without changing the shader
contract, but no cycle is part of this amendment.

This intentionally differs from S's `computeAmbientLight`, which derives
ambient from its sun phase (`src/Engine/Graphics/Vulkan/ShaderCode.hs:204–212`
at `3777d437`); merely supplying a new sun position also changes background
illumination there. The approved independence means moving the preview sun
does not itself perform that ambient day/night transition. P-13 specifies the
numeric defaults, face-light equation and depth composition. Retaining S's
automatic sun-linked ambient curve is the
rejected alternative, not assumed parity.

The lighting-representation question is resolved by D-56/P-12: surface-normal
RGB supplies actual ramp/peak orientation while alpha retains the cutout.
The numerical/API checkpoint is resolved by D-57/P-13. Corrected-map,
normal/lighting, cutout/picking and depth/streaming qualification remain
implementation gates; specification approval is not visual acceptance.

### Q-19. Follow-up slices, revisions and amendment readiness

Resolved by D-60. On 2026-11-08 the owner explicitly approved P-16 at
`b012fabbfc` and declared the terrain amendment ready for issue processing.
The approved 11 follow-ups (TRA-13–TRA-23), baseline disposition, existing
artifact revisions and evidence ownership are now reflected in the
processing ledger and delivery plan, preserving all original IDs/links.

D-44's geometry/map proof belongs to TRA-13/TRA-14; TRA-17 owns amended
Q-13 material qualification. D-47's numerical lighting/depth proof and
D-48/P-10's live viewport/haze regression remain separately assigned to
TRA-17 and revised TRA-9, then final TRA-12. D-59's connectivity, storage and
recovery qualification has explicit model/effects/runtime owners. Those are
implementation obligations, not remaining design choices or delivered results.

No tracker artifact or code changes in this design turn. Each eventual
EPIC/child revision or new issue still requires its own concrete draft and
separate approval before mutation. PR #654 remains held; implementation
coordination, reviews and merge authority remain with the manager/owner.

### Q-20. Underground discovery, fog interactions and sparse retention

Resolved as a specification by D-31–D-41/D-43/D-49–D-53/D-58/D-59 and
P-9/P-14/P-15. Preserve the decisions' history; the exact current contract
is P-15, approved as written at `d527957369`, together with P-14's visual
knowledge and fog-result contract.

Knowledge, truth and residency remain separate. Sky and initially
sky-connected spaces begin known; sealed spaces become known through real
positive-area connections under the shared logical shape catalog. Whole-space
discovery includes exposed solid boundaries and crosses chunks, in bounded
steps. It retains compressed component/range knowledge and pending obligations;
it does not require loading every boundary tile. Two openings share work
without losing newly added connections or flooding the exterior.

P-15 fixes exact source component families and exceptions, upper-boundary
exterior semantics, startup work/memory limits and expected complexity
refusal. Required flat, world-spanning gap and shape/channel cases must be
proved. Removal enlarges air and records its connection-inspection obligation
atomically; an isolated raw buried edit does not itself discover that space.
Queries and residency alone still do not grant knowledge.

The reserved temporary store replaces the original RAM-only history cap:
default 1 GiB per arena, configurable at open with explicit creator-authorized
growth. P-15 fixes the private file/page/index format, cache/staging/I/O bounds,
peak-space reservations, reader retirement and one commit/settlement
arbitration after backing writes. Offload evicts reconstructible caches;
reload reapplies source, edits and knowledge coherently before publication.

Storage capacity, I/O and integrity failures preserve committed state and
pending obligations, pause affected mutations/discovery and return the
specified expected results. Exact Lua status/growth/retry authority,
cancellation, recovery and close/reset behavior are approved. A new arena
starts fresh; no save or cross-run recovery is added.

D-58/P-14 resolves player interaction: confirmed generic fog is unselectable,
stops traversal and returns `no_hit`; unavailable authoritative information
remains `loading`. Mixed known-solid/unknown-void presentation is coherent
and does not expose hidden contents.

Qualification remains implementation work: independent connectivity oracles,
compressed-space/limit evidence, I/O and publication fault interleavings,
retention/replay, native reservation/lifecycle checks and visual fog/picking
proof. Q-19/D-60 assigns those obligations to reviewable slices and final
TRA-12 acceptance. Approval supplies no test result and does not introduce
unit vision, automatic day/night, general gameplay state or placement.

## Verification strategy — approved through Q-12

Use focused Hspec/model tests for identity, demand deduplication, bounded
admission and refusal; causally controlled integration tests for late results,
world replacement, cancellation and retirement. Qualify exact flat-terrain
content independently of chunk request order where that contract is selected.
For D-16, exercise removal across the configured soil/stone boundary and
reload on each side of it, plus direct deep-stone demand without intervening
allocation. Check that different configured soil depths use the same contract.
Include non-flat authored cases that exercise D-4 even though the initial arena
generator is flat: a cavity with a solid ceiling, separated solid spans,
completely empty columns and geometry crossing chunk boundaries. Require the
full-block and authored slope cases selected by D-15 to agree across rendering,
picking and terrain queries, including shape orientation. Require the
agreed terrain reads, rendering/picking and reload behavior to describe the same
geometry; no procedural cave generator is implied by these cases. Exact
consumers and evidence remain Q-4/Q-6/Q-7 decisions.
Include all 16 masks in all four facings, with explicit identity checks for
0 and 15 and visual cases for NS/EW; do not add traversal or movement tests.
Check automatic headroom over nearby higher terrain separately from exact
manual slicing. For D-26, require identical decoded values/query results and
removal/reload behavior across uniform/run/dense encodings, transitions at the
byte-cost threshold and segment boundaries, and no allocation of unknown
intervening cells. Measure metadata/heap costs separately from the payload
table; include coherent and fragmented lookup, scan and edit workloads.
Exercise camera exploration beyond the startup footprint, top-only initial
materialization, repeated removal revealing deeper terrain, and exposure of
side faces and gaps. Inspect terrain allocations as well as rendered output
to verify that untouched depth stays unmaterialized. Check explicit invisible
queries separately under D-6 and returning to an edited, evicted region.
Under D-10, verify remove/offload/reload, additional removal followed by another
cycle, and reconstruction independent of chunk demand order. Verify a fresh
arena inherits no changes from the previous session. No disk persistence test
is implied by this session-only contract.
For D-11, query widely separated depths without constructing the intervening
volume; verify vertical eviction/reload and bounded resident/render data as
the demanded depth moves. Include coordinate-limit and conversion checks once
the representation is chosen. Report retained edit storage separately from
resident terrain; no test can establish literal infinite resource capacity.
For D-12, verify Shift-scroll changes visibility without editing terrain;
camera jumps choose the surface when Z is omitted and honor explicit Z for
both resident and unloaded targets. Exercise successive jumps so a late result
cannot reset a newer view. Verify picking against the displayed cutaway and
that viewing a deep slice does not materialize the intervening volume.
For D-13, navigate varied-height authored terrain using pan/zoom/rotation and
verify that normal terrain following keeps the relevant surface visible.
For D-14, Shift-scroll then pan over different heights and verify the slice
stays fixed; jump without Z and verify surface following resumes; jump with Z
and verify that requested depth wins. Include unloaded jump destinations and
late surface results. These fixtures do not add a procedural hill generator
to the arc.
During development, exercise the D-8/D-9 shortcut through the agreed
targeting/input path, including no valid target and focus/reset behavior.
Capture its removal/reveal evidence before deleting the shortcut. Final
acceptance verifies the Lua API and retained regression coverage, and that
the temporary binding and its dedicated glue are gone. No UI framework is
needed to demonstrate this control.
Use captured rendering evidence for the agreed visible result and native input
evidence for controls actually included. Select checks from Hetoimasia's
validation catalog once slices exist (H `AGENTS.md`, Language and build;
`docs/vision.md:244–263`). No build, test or window launch ran for this design.

## Delivery plan

Approved one-PR boundaries: original Q-12/D-27, amended by Q-19/D-60.
The ledger and this plan have the same dependency-valid order. TRA-1–TRA-8
retain their filed baseline scopes as history; later follow-ups supersede
conflicting assumptions. TRA-9–TRA-12 state their current amendment first and
preserve the original filed text underneath. P-16 owns existing-issue revision
and baseline coordination; an issue's old readiness label does not approve a
new body or prove this amendment implemented.

Phases express dependency barriers, not permission to create issues. Every
slice includes its owning contract/tests/catalog updates; human documentation
lands through `docs-push` and is linked from its eventual PR. Broader scope
discovered during processing is split/reviewed explicitly, never hidden inside
a child. All amended rendering/discovery/storage evidence precedes TRA-12.

### TRA-1. Define terrain coordinates and shared shape geometry

- **Outcome/scope:** CPU terrain component, checked coordinates, negative
  region indexing, shape catalog, exact rotations and shared intersection/face
  semantics. No resource effects.
- **Phase:** 1. **Depends on:** none. **Ordering:** critical path.
- **Relevant decisions:** D-4, D-11, D-15, D-17, D-21, D-24, D-25.
- **Acceptance signals:** independent geometry fixtures, all orientations,
  boundary coordinates, all 16 mask IDs/four facings, shared coverage agreement
  and external-client boundary checks. Movement/pathing is deferred.
- **Out of scope:** streaming, Lua and rendering effects.
- **Open questions:** none; Q-12 contract approved.

### TRA-2. Implement layered sources and compressed terrain changes

- **Outcome/scope:** immutable copied recipes, bounded authored span patches,
  sparse adaptive uniform/run/dense segments and canonical removal overlays;
  pure cell/range/surface queries and source-plus-edits reconstruction.
- **Phase:** 1. **Depends on:** TRA-1. **Ordering:** critical path.
- **Relevant decisions:** D-5, D-7, D-10, D-16, D-17, D-21, D-26.
- **Acceptance signals:** soil/stone boundary, cavities and slopes, repeated
  removals, air no-op, arbitrary deep queries without intervening allocation,
  and complete bounded range results; encoding round trips, cost-threshold
  transitions and allocation/work bounds without densifying unknown depth.
- **Out of scope:** live service, persistence and automatic slopes.
- **Open questions:** none; Q-12 contract approved.

### TRA-3. Define bounded horizontal and vertical residency

- **Outcome/scope:** pure residency/admission model, coalesced camera demand,
  interest deduplication, eviction eligibility, edit-transfer reservations and
  separate data/staging/edit accounting. Include limit validation.
- **Phase:** 1. **Depends on:** TRA-2. **Ordering:** critical path.
- **Relevant decisions:** D-2, D-6, D-10, D-11, D-19.
- **Acceptance signals:** tiny-budget model traces, starvation/fairness cases,
  vertical descent, shared-interest cancellation and no eviction of borrowed data.
- **Out of scope:** threads, GPU ownership and numeric performance claims.
- **Open questions:** none; Q-12 contract approved.

### TRA-4. Implement the transactional terrain service

- **Outcome/scope:** scoped single owner, bounded command execution, arenas and
  incarnations, immutable snapshots, atomic removal/cancellation settlement,
  offload/reload and orderly close over TRA-2/TRA-3.
- **Phase:** 2. **Depends on:** TRA-3. **Ordering:** critical path.
- **Relevant decisions:** D-10, D-17, D-19, D-20, D-21.
- **Acceptance signals:** controlled race tests for cancel/commit, close/load,
  repeated edit/offload/reload, stale revisions and failure cleanup; same ordered
  command trace yields identical terrain despite residency scheduling changes.
- **Out of scope:** general gameplay-state transactions and Lua bindings.
- **Open questions:** none; Q-12 contract approved.

### TRA-5. Expose terrain requests through Lua

- **Outcome/scope:** optional narrow service injection, open/attach/lease,
  query/remove/release bindings, copied recipe validation, role/phase checks and
  existing request protocol. Preserve unavailable `api.state` behavior.
- **Phase:** 2. **Depends on:** TRA-4. **Ordering:** critical path.
- **Relevant decisions:** D-9, D-17, D-19, D-20.
- **Acceptance signals:** real Lua clients, foreign/stale lease refusal,
  busy-before-action, duplicate names, cross-role own-lease attachment, canceled
  mutation and invalid recipes, plus existing M1 compatibility tests.
- **Out of scope:** window/input/view bindings and general state schemas.
- **Open questions:** none; Q-12 contract approved.

### TRA-6. Expose ordered window input to Lua

- **Outcome/scope:** presentation input poll/observation/reset acknowledgement
  through a narrow injected port; native modifier/button/key/scroll semantics.
- **Phase:** 2. **Depends on:** none. **Ordering:** independent; can land first.
- **Relevant decisions:** D-8, D-9, D-12, D-18.
- **Acceptance signals:** synthetic ordered feed tests, overflow and focus
  reset, clear-before-acknowledge, window/instance authority and cursor metrics.
- **Out of scope:** UI routing, action-rebinding UI and terrain mutation.
- **Open questions:** none; Q-12 contract approved.

### TRA-7. Implement isometric cutaway planning and picking

- **Outcome/scope:** pure projection/rebasing, camera follow/manual transitions,
  bounded visible faces, cutaway caps, shared-shape picking and stable ordering
  candidates. Authored fixtures cover roofs, gaps, ramps and corners.
- **Phase:** 2. **Depends on:** TRA-2. **Ordering:** critical path; independent
  of live terrain service and Lua integration.
- **Relevant decisions:** D-4, D-12–D-16, D-18, D-21–D-25.
- **Acceptance signals:** geometry/pick consistency, all facings, negative and
  far coordinates, manual/jump transitions, separate automatic headroom,
  all 16 mask forms, seam and occlusion fixtures. No movement-cost work.
- **Out of scope:** Vulkan uploads and new renderer ABI.
- **Open questions:** Q-13 ordering feasibility. Escalate rather than
  approximate if the geometry cannot be ordered correctly.

### TRA-8. Qualify terrain materials and depth ordering offscreen

- **Outcome/scope:** generic terrain face material/masks under the existing
  renderer ABI, approved artwork provenance, and offscreen fixture rendering.
- **Phase:** 3. **Depends on:** TRA-7. **Ordering:** critical prerequisite to
  runtime graphics integration.
- **Relevant decisions:** D-15, D-17, D-18, D-21, D-23, D-25.
- **Acceptance signals:** retained exported captures and oracle/geometry
  comparisons for all 16 reference masks, roofs, gaps, cutaways and all facings,
  including overlapping projections. Establish correct depth and transparent coverage.
- **Out of scope:** live streaming and unapproved vertex/depth ABI changes.
- **Open questions:** Q-13 is a hard stop gate: failed proof returns a concrete
  renderer proposal to the owner before dependent slices proceed.

### TRA-13. Correct canonical shape geometry and expose exact opening portals

- **Outcome/scope:** implement P-9's complete logical catalog, including the
  ID-15 central half-height peak, exact rotated facet/portal geometry and
  closed-solid point/ray behavior. Keep coordinate/source identities intact.
- **Phase:** amendment geometry. **Depends on:** TRA-1 and the baseline TRA-8
  completion. **Ordering:** critical prerequisite shared by rendering and
  discovery. Complete the held baseline first so its review/evidence is not
  changed underneath it by the ID-15 correction; this is a delivery dependency,
  not a graphics import into the pure terrain library.
- **Relevant decisions:** D-34–D-36, D-44, D-49; P-9.
- **Acceptance:** independent all-16/four-facing solid and positive-area
  portal tests, diagonal paths versus edge/point contacts, exact boundaries
  and query compatibility. Preserve a reproducible reference-defect fixture.
- **Excludes:** texture generation, source compilation, runtime and GPU work.
- **Open questions:** none; a refuted shape premise returns to the owner.

### TRA-14. Generate and qualify canonical cutout and normal-map assets

- **Outcome/scope:** deterministic P-9/P-11/P-13/P-14 map generation and
  rotated-ID lookup: ordinary shapes, full fog and complementary mixed
  known-solid/unknown-void parts within P-14's shared-map bound. Preserve
  loam/granite artwork and import the pinned generic blank with provenance.
- **Phase:** amendment assets. **Depends on:** TRA-8, TRA-13.
  **Ordering:** rendering prerequisite; independent of terrain runtime.
- **Relevant decisions:** D-44/D-49/D-55/D-56/D-57/D-58.
- **Acceptance:** reproduce the pinned Synarchy inconsistency independently,
  retain immutable original/corrected comparisons for all 16 IDs/four facings,
  verify silhouette unions/disjoint parts, facet normals, encoding, dimensions
  and deterministic hashes. Mark CPU/generated-image proof as such; actual
  material/readback qualification follows in TRA-17.
- **Excludes:** new colour art, automatic slopes, shader/runtime integration.
- **Open questions:** none; D-44's stop/report rule applies to refuted evidence.

### TRA-15. Load validated data maps with shared versioned CPU coverage

- **Outcome/scope:** P-11/P-13's bounded `kind`, `coverage` and
  `normal_encoding` texture options from decoding through protected asset
  ownership. Produce one immutable bitplane per exact asset version, preserve
  raw normal data and validate the declared profile before upload.
- **Phase:** amendment asset service. **Depends on:** no new terrain child;
  uses the existing content/texture/resource interfaces. **Ordering:** may
  proceed independently of geometry and storage.
- **Relevant decisions:** D-30/D-45/D-55–D-57.
- **Acceptance:** exact boundary/alpha/profile fixtures; colour/data handling;
  nonbinary/incompatible rejection; bounded decode and 128 MiB bank charges;
  version replacement, canceled load and CPU/GPU-interest retirement. Existing
  omitted-option texture loading and M1 clients retain their behavior.
- **Excludes:** terrain planning, camera controls and arbitrary shader loading.
- **Open questions:** none; keep injection narrow, with no terrain import in
  the generic image/content machinery.

### TRA-16. Build pure cell-quad planning and coverage-based visual picking

- **Outcome/scope:** P-14's whole-cell/mixed-fog plans, exact sort/rank keys,
  conservative projected bounds and matching P-11 alpha picker. Accept one
  coherent supplied terrain/knowledge/asset/camera snapshot; include the
  P-10 viewport/height-band demand envelope and bounded progressive planning.
- **Phase:** amendment pure rendering. **Depends on:** TRA-7, TRA-13,
  TRA-14, TRA-15. **Ordering:** prerequisite to the production material switch.
- **Relevant decisions:** D-30/D-37/D-42/D-48/D-50/D-55/D-58.
- **Acceptance:** independent ray/order and texel-coverage oracles; fog stops
  traversal without a target; pending data in front versus behind a hit;
  mixed-part atomic admission, cutaways without added caps, extreme checked
  coordinates, chunk seams and viewport bounds at fractional pan/zoom.
- **Compatibility staging:** add the new pure path with its tests while the
  filed baseline still builds. It is not a second final player-facing picker.
  TRA-17 switches every existing repository consumer and removes the obsolete
  face-plan/analytic visual-picking path in one coherent migration.
- **Excludes:** live discovery/I/O, GPU effects and Lua token issuance.
- **Open questions:** Q-13 remains a proof gate; counterexamples stop migration.

### TRA-17. Switch terrain rendering to face-map cutouts and normal lighting

- **Outcome/scope:** consume TRA-16 plans through the existing material ABI,
  sample colour plus normal/cutout atlas regions, implement P-13's exact
  lighting/depth equations and replace the legacy per-face material/adapter/
  picker clients. D-61/P-17 add deterministic offline packing beside the map
  generator, a checked region manifest and the narrow shared-coverage/asset-
  identity adaptations to the merged TRA-15/TRA-16 authorities. Preserve every
  original source image. Keep pure material/model and preparation code
  separate from the Vulkan definition and generic runtime loading.
- **Phase:** amendment rendering proof. **Depends on:** TRA-8, TRA-14,
  TRA-15, TRA-16. **Ordering:** hard prerequisite to TRA-9–TRA-12.
- **Relevant decisions:** D-29/D-44–D-50/D-54–D-58/D-61; P-17.
- **Acceptance:** retained real offscreen proof of all 16 IDs/four facings,
  ordinary/fog/mixed masks, overlap, transparent colour holes, integer slices,
  fractional transforms/scaling and shared pixel-edge ownership. Verify
  numerical normal/sun/ambient/depth/haze cases, low-angle ramp lighting,
  world-fixed illumination across facings and isolated/combined depth effects.
  Independent discriminating probes and negative controls must reject wrong
  masks, order, colour/data treatment and picking; no self-approved goldens.
  Add source extraction/hash preservation, checked region identity, exact
  texel-edge/adjacency tests and real packed-versus-1×1 render/pick equivalence
  under P-17. Retain the required CI time limits and separate opt-in judging.
- **Migration:** remove old `PlannedFace`/polygon visual contracts and migrate
  repository tests/harnesses/material adapters; retain pure logical queries.
  Historical captures stay labelled with their original model/revision.
- **Excludes:** new renderer ABI, day/night, live streaming and view retirement.
- **Open questions:** Q-13 is discharged for the amended material only by its
  evidence. An ABI/ordering/sampling counterexample returns to the owner.

### TRA-18. Compile bounded symbolic source connectivity

- **Outcome/scope:** P-15's pure exact source compiler, component families,
  exceptions, portal/range relations and initial exterior classification.
  Expose bounded resumable preparation and canonical source keys without
  allocating hidden cells or marking sealed components discovered.
- **Phase:** amendment discovery foundation. **Depends on:** TRA-2, TRA-13.
  **Ordering:** independent of rendering after shared geometry.
- **Relevant decisions:** D-38/D-49/D-51/D-53/D-59.
- **Acceptance:** independent small explicit flood/portal oracle; required
  flat, enormous gap, independent ramp-row/level and patch-split fixtures;
  upper versus horizontal/lower boundary cases; measured structural/work/byte
  counts and bounded `source_complexity` refusals at P-15's limits.
- **Excludes:** edit-time knowledge, file I/O, arena open and Lua binding.
- **Open questions:** none; unsupported required fixtures are a blocker,
  not permission for dense fallback or a silent reduced source language.

### TRA-19. Model compressed knowledge and resumable discovery after removal

- **Outcome/scope:** pure monotonic removed-interval/connection overlays,
  component/range knowledge, exposed-boundary lookup and shared pending work.
  Produce bounded edit/discovery deltas and retained continuations suitable
  for the later atomic store transaction; no I/O or mutable world owner.
- **Phase:** amendment discovery model. **Depends on:** TRA-3, TRA-18.
  **Ordering:** prerequisite to store records and live discovery.
- **Relevant decisions:** D-31–D-39/D-49/D-51/D-59.
- **Acceptance:** both orders and interleavings of two openings, new joins to
  already known exterior, raw buried edits without premature discovery,
  known solid versus unknown void, compressed boundary replay and whole-space
  completion without boundary enumeration. Independent state traces prove no
  lost obligation, false completion, duplicate work or unbounded RAM set.
- **Excludes:** placement/splits, units/vision, file I/O and rendering.
- **Open questions:** none; the source-plus-removal restriction is explicit.

### TRA-20. Define bounded copy-on-write store records and transactions

- **Outcome/scope:** pure store codec, page/index/allocator/retirement model
  and staged transaction planning inside the terrain-runtime boundary.
  Encode TRA-19 records and changes with P-15's page size, checksums, limits,
  peak reservation, reader roots and protected reclamation allowance.
  Adapt the baseline admission model to bounded edit caches and disk-backed
  history without freeing authoritative records as ordinary cache entries.
- **Phase:** amendment storage model. **Depends on:** TRA-4, TRA-19.
  **Ordering:** prerequisite to storage effects and runtime adoption.
- **Relevant decisions:** D-40–D-43/D-51/D-52/D-59.
- **Acceptance:** bounded codec refusals, reference-map round trips, COW
  root isolation, no write-dependent rollback, pinned-reader reclamation,
  interrupted staged pages, capacity/overflow and per-transaction byte limits.
- **Excludes:** native files/workers, live arena publication and public saves.
- **Open questions:** none; no generic database framework is part of the slice.

### TRA-21. Own reserved backing files and bounded asynchronous storage I/O

- **Outcome/scope:** private unlinked arena files, qualified native reservation
  and growth, scoped descriptors, bounded workers/buffers and page reads/
  staged writes for TRA-20. The storage boundary prepares results; the later
  terrain owner still controls authoritative root publication.
- **Phase:** amendment storage effects. **Depends on:** TRA-20.
  **Ordering:** prerequisite to write-backed terrain transactions.
- **Relevant decisions:** D-40/D-41/D-43/D-52/D-59.
- **Acceptance:** deterministic short-read/write, I/O, integrity, cancellation
  and reservation failure fixtures; bounded platform qualification of actual
  reservation, peak space/growth and unlink/last-close; pending-reservation
  release failures; worker/drain/descriptor-reuse and primary/cleanup failures.
  Use private test volumes/providers, not a full personal drive.
- **Excludes:** terrain settlement/discovery orchestration, Lua and cross-run
  recovery. No root may publish as a side effect of an I/O worker completion.
- **Open questions:** filesystem qualification is a delivery gate; unsupported
  environments use the approved expected refusal, not an unreserved fallback.

### TRA-22. Commit terrain edits and discovery through the temporary store

- **Outcome/scope:** integrate TRA-18–TRA-21 with the single terrain owner:
  bounded opening/preparation, backed edits and discovery batches, coherent
  content/knowledge revisions, cache replay, typed status/growth/retry and
  affected-arena pause/recovery. Use the existing settlement arbitration.
- **Phase:** amendment runtime. **Depends on:** TRA-4, TRA-5, TRA-19,
  TRA-21. **Ordering:** prerequisite to amended views and storage Lua calls.
  TRA-5 is a delivery dependency so its real settlement bridge exists; the
  runtime library must still import no Lua component.
- **Relevant decisions:** D-17/D-19/D-20/D-33/D-38–D-43/D-51–D-53/D-59.
- **Acceptance:** actual service tests at each write/publication/cancellation
  boundary, two-front discovery, offload/reload after each committed batch,
  capacity/I/O/integrity pause and explicit recovery, growth failure, open/
  close/instance/session end and late incarnation results. Preserve one host
  settlement and test logical eligibility delays through the existing bridge;
  neither disk completion nor a held reply is terminal success.
- **Excludes:** new Lua schemas, graphics effects and general gameplay rollback.
- **Open questions:** none; all old committed state survives a failed update.

### TRA-23. Expose terrain storage status, growth and recovery through Lua

- **Outcome/scope:** extend TRA-5 with exactly P-15's optional open storage
  record, status/grow/retry requests, creator authority and expected codes.
  Replace the old RAM-total-history refusal rule with the approved distinction
  between immediate transient `busy` and terminal storage-domain outcomes.
- **Phase:** amendment Lua service. **Depends on:** TRA-5, TRA-22.
  **Ordering:** prerequisite to amended Lua view/content assembly.
- **Relevant decisions:** D-19/D-40–D-43/D-52/D-53/D-59.
- **Acceptance:** real Lua plus production terrain service, strict plain-record
  validation, both roles/phase rules, owner versus attached lease, status while
  paused, atomic name/open settlement and cancellation, equal/decreasing/
  failed growth, retry without repeated user edits and unread expected failures.
  No engine-owned handle or terrain authority crosses VMs through Lua data.
- **Excludes:** UI, reset/save APIs, automatic expansion and view bindings.
- **Open questions:** none; existing request timing/cleanup policies remain.

### TRA-9. Publish retained terrain views with safe GPU retirement

**Current amendment — D-60:** Depend on TRA-17 and TRA-22 as well as baseline prerequisites. Consume cell/mixed-fog quads and coherent knowledge revisions; own exact normal/colour versions and CPU coverage interests; charge the amended 128 MiB CPU render bank and existing GPU/retirement banks. Integrate full projected viewport/height-band demand, progressive bounded admission and view-aware eviction. Test hazed background beyond the old radius, pending knowledge, reveal/offload/reload and atomic mixed-part adoption under pressure. Preserve exclusive target ownership and actual frame-completion retirement.

**Current dependency gate:** TRA-4, TRA-8, TRA-17 and TRA-22. Q-13's amended-path evidence
must pass; filing or readiness approval is not implementation qualification.
The inherited one-PR phase/ownership and exclusions below still apply where
consistent with P-9–P-16; the amendment supersedes conflicting payload,
appearance, retention and acceptance requirements.

**Original filed scope (historical):**

- **Outcome/scope:** view adapter from coherent CPU snapshots to retained
  render regions, bounded uploads, target ownership, adoption/picking snapshot
  linkage and release through existing frame-completion holds.
- **Phase:** 3. **Depends on:** TRA-4, TRA-8. **Ordering:** critical path.
- **Relevant decisions:** D-2, D-6, D-17, D-19.
- **Acceptance signals:** held-frame replacement/close tests, stale-view
  refusal, superseded camera demand, retiring-version accounting, no mixed
  terrain/camera revision and no release before GPU completion.
- **Out of scope:** Lua view facade and general scene schema expansion.
- **Open questions:** Q-13 must have passed.

### TRA-10. Expose terrain views and camera controls to Lua

**Current amendment — D-60:** Depend on TRA-23, TRA-6 and revised TRA-9. Add P-13's strict partial lighting/depth records and defaults to style/configure, with complete colour/blank/normal-map mappings and P-11/P-13 validated texture authorities. Preserve the existing atomic camera controls/`slice_delta`; replace conflicting legacy face-tint/filter controls with the approved sampling and unit wrapper tint/brightness. Issue picks only from adopted matching coverage/knowledge: confirmed fog gives `no_hit`, incomplete information gives `loading`, known cell hits alone yield edit authority. Replace the old analytic face/cap result contract. Cover wrong normal profile, stale knowledge/assets, all-or-nothing configuration and independent lighting controls.

**Current dependency gate:** TRA-23, TRA-6 and revised TRA-9. Q-13's amended-path evidence
must pass; filing or readiness approval is not implementation qualification.
The inherited one-PR phase/ownership and exclusions below still apply where
consistent with P-9–P-16; the amendment supersedes conflicting payload,
appearance, retention and acceptance requirements.

**Original filed scope (historical):**

- **Outcome/scope:** view open/close, move with optional Z, configure and pick
  through instance-owned leases and the coherent graphics adapter.
- **Phase:** 3. **Depends on:** TRA-5, TRA-6, TRA-9. **Ordering:** critical path.
- **Relevant decisions:** D-12–D-14, D-17–D-19, D-22, D-23.
- **Acceptance signals:** Lua camera traces, unloaded jump with/without Z,
  consecutive jumps, stale picks and view/window/arena teardown; old M1 scenes
  remain valid and cannot concurrently seize an attached terrain target.
- **Out of scope:** UI widgets and camera behavior not selected here.
- **Open questions:** Q-13 must have passed.

### TRA-11. Assemble the authored terrain arena

**Current amendment — D-60:** Depend on revised TRA-10 and all transitive amendment gates. Load approved colour/blank/maps with the proper options, author the exact lighting/depth defaults and storage allowance in Lua, and use the real amended services. Keep the default flat source, generic launcher and existing controls. Extend the temporary F8 proof to fog refusal, ramp/mask selection and discovery replay; expose no new UI or debug binding. A storage pause is an expected reported condition: preserve the arena and navigation where data is available, without replaying edits or automatically growing/resetting it. Startup failure retains the existing bounded failure/quit path.

**Current dependency gate:** revised TRA-10 and its amendment prerequisites. Q-13's amended-path evidence
must pass; filing or readiness approval is not implementation qualification.
The inherited one-PR phase/ownership and exclusions below still apply where
consistent with P-9–P-16; the amendment supersedes conflicting payload,
appearance, retention and acceptance requirements.

**Original filed scope (historical):**

- **Outcome/scope:** generic launcher/service composition plus Lua arena
  content, approved textures, four-layer soil default, camera controls and
  temporary mouse-targeted removal shortcut through the public API.
- **Phase:** 4. **Depends on:** TRA-10. **Ordering:** critical path.
- **Relevant decisions:** D-1–D-3, D-7–D-10, D-16–D-18, D-22, D-23.
- **Acceptance signals:** visible exploration beyond startup footprint,
  underground/cutaway demand, surface/manual navigation, soil-to-stone removal,
  revisit after offload and fresh state after session restart.
- **Out of scope:** production editor, gameplay systems and UI.
- **Open questions:** Q-13 must have passed. Development shortcut removal
  is mandatory in TRA-12, not an optional follow-up.

### TRA-12. Qualify the arena and remove the development shortcut

**Current amendment — D-60:** Depend on revised TRA-11 and every amendment child/proof gate. Replace old flat-ID-15/cap/analytic-picker/RAM-only assertions and stale CPU budgets. Qualify final all-16/four-facing normal/cutout/pick/fog behavior, sky/cavity/dual-opening discovery, viewport/haze loading, store limits/failure/recovery and all owning banks. Retain pre-removal F8 proof separately, remove its binding/glue, then verify final public Lua API behavior and visual/resource evidence. Preserve the bounded optional memory experiment, honest measurements, M1 compatibility and owner visual acceptance.

**Current dependency gate:** revised TRA-11 and all amendment children/proof gates. Q-13's amended-path evidence
must pass; filing or readiness approval is not implementation qualification.
The inherited one-PR phase/ownership and exclusions below still apply where
consistent with P-9–P-16; the amendment supersedes conflicting payload,
appearance, retention and acceptance requirements.

**Original filed scope (historical):**

- **Outcome/scope:** complete end-to-end and resource evidence, remove the
  temporary binding and its dedicated glue, retain Lua API regressions and
  finish current subsystem contracts/test catalog entries.
- **Phase:** 4. **Depends on:** TRA-11. **Ordering:** final acceptance barrier.
- **Relevant decisions:** D-4–D-26 as applicable.
- **Acceptance signals:** the epic done condition and matrix below pass;
  exported visual evidence is retained, allocation trends and configured caps
  are reported honestly, shortcut is absent, and the public Lua removal path
  remains tested. Existing M1/native resource qualification stays green.
- **Out of scope:** broader profiling campaigns, gameplay parity and new art.
- **Open questions:** Q-13 must have passed; Q-12 acceptance scope approved.

### Acceptance matrix and evidence delivery

The original rows remain baseline coverage. D-60's additions below and the
current TRA-12 amendment govern where original presentation/retention
assumptions differ from P-9–P-15; every required final row needs evidence.

| Concern | Required evidence |
| --- | --- |
| Model/source | All 16 mask identities and shared geometry; deep queries allocate no intervening volume; compressed gaps and soil transition; uniform/run/dense round trips and transitions |
| Retention | Multiple edit/offload/reload cycles and new-session freshness; no unbounded duplicate removal log |
| Concurrency | Causally controlled cancellation/close/publication tests, one settlement and no stale incarnation publication |
| Camera/input | Follow with headroom over authored hills; exact manual slice through pan/zoom/rotation; Shift-scroll and jumps; reset clears held input; no UI dependency |
| Presentation | Exported offscreen and native captures for all 16 masks in four facings, roofs/cavities, cutaways and chunk seams; pick agrees with displayed geometry |
| Residency | Traverse and descend many region boundaries under fixed caps; record resident bytes/counts, retained edits, staging and retiring GPU data separately |
| Compatibility | Existing M1 rectangle scenes, state-unavailable behavior, CPU composition and role/lease rules remain intact |
| Delivery | Updated owning contracts and validation catalog; public Lua API remains; temporary shortcut/glue absent |

| Amendment concern | Additional required final evidence / owning slices |
| --- | --- |
| Canonical geometry/maps | Reproduced reference inconsistency; corrected ID 15 and all 16 IDs/four facings; exact openings, ordinary/mixed/fog masks and normals — TRA-13/TRA-14/TRA-17 |
| Render/pick/lighting | Actual cutout/readback and adopted CPU coverage agree at the specified pixels; fog cannot yield a target; no added cutaway caps; numerical sun/ambient/depth/haze and navigation evidence — TRA-17, amended TRA-9–TRA-12 |
| Compressed discovery | Sky, sealed cavities, partial openings, independent ramp families, two fronts, buried edits and whole-space completion without boundary enumeration; retained knowledge replays coherently — TRA-18/TRA-19/TRA-22 |
| Temporary backing | Real reservation/overhead, bounded caches and I/O, write-before-settlement, capacity/I/O/integrity pause, growth/retry, reader retirement and close/reset with fault/interleaving evidence — TRA-20–TRA-23 |
| View-driven demand | Full projected height-band footprint requests hazed background beyond the old radius when capacity permits; explicit priority, progressive pressure and view-aware eviction preserve coherent fog/loading distinctions — TRA-16, amended TRA-9–TRA-12 |

Qualify deterministic terrain for an identical source and ordered successful
command trace on the same build/platform. Vary internal loading/eviction order
without changing that trace. This does not claim arbitrary asynchronous
submission races or the unfinished general gameplay scheduler are deterministic.
Do not add whole-game replay or cross-platform bit identity.

Use Hspec and controlled synchronization for CPU/contracts, the existing
offscreen renderer path for image evidence, and the owning native suite for
input/display integration. Select required groups using the repository's
validation planner when each implementation slice exists. Numeric budgets are
initial caps, not benchmark results: measure representative flat/layered/
hollow/sloped/fragmented fixtures and report allocation cost and refusal
behavior. No arbitrary FPS claim is an acceptance criterion.

Retain requested captures and measurement summaries with the owning evidence
document through `docs-push`; an ignored local screenshot is not delivery.
No code, build, test, native launch or performance measurement was performed
while drafting this design. Final design signoff and tracker processing are
separate from implementation qualification.
