# TRA-14 evidence: canonical cutout and normal-map assets (#656)

**Label.** Every image here is CPU / generated-image evidence produced by `terrain-mapgen --evidence`. None is an engine screenshot, a shader output or a GPU qualification, and no lighting is applied: the normal images are the maps' own bytes. Actual material sampling, raster-edge agreement, alpha picking, lighting/depth composition and offscreen readback remain TRA-15, TRA-16 and TRA-17's amended Q-13 gate. No performance improvement is claimed.

## Immutable revision

- Implementation revision: `b62cad5507080ee702360884d490a946ec0dbad5` (pull request #669, branch `issue-656-canonical-cutout-normal-map-assets`). Later heads of that pull request differ from it only by merges of `origin/master` and body edits unless the revision is restated in the pull request body.
- Generator recipe: `terrain-mapgen/1`. Reference inputs: Synarchy `3777d437ea00e1302bf55162ad5693fee4879187`, read only through git; no build, test or runtime dependency on a Synarchy checkout or the network.
- Toolchain: GHC 9.14.1, Cabal 3.18.1.0 (docs/toolchain.md); PNG bytes from JuicyPixels over the project's bundled zlib (`cabal.project.common`), identical on Linux and macOS by construction.

## Reproduce (changes no tracked file)

```sh
terrain_evidence_dir="$(mktemp -d)"
cabal run --project-file cabal.project.cpu exe:terrain-mapgen -- --evidence "$terrain_evidence_dir"
cabal run --project-file cabal.project.cpu exe:terrain-mapgen -- --check      # the committed catalog equals a fresh regeneration
```

The images below are byte-identical to what that command writes at the implementation revision (their SHA-256 are in the table and in `evidence-index.json`).

## Comparison sheets and index

Each `comparison-<facing>.png` shows, for all 16 world IDs at one facing, at matched 2x scale: the original legacy face-weight mask the reference selects, the corrected unit-normal map, the alpha change (magenta = texel the legacy mask had and the corrected map does not, cyan = added, grey = both), the corrected cutout over the unchanged loam art, and the known solid (loam) beside its cover (blank). Row labels give the world ID, the catalog shape the facing selects and the wall coverage of that shape (`-` none, `P` partial, `F` full: the logical openings). Each `joined-<facing>-{normals,art}.png` draws the sixteen shapes as one joined block, far to near by the key `(viewX + viewY, viewX, viewY)`.

| File | SHA-256 |
| --- | --- |
| [comparison-south.png](comparison-south.png) | `8c91ad8d552544efc67fe9c98fc1e49cb551987214646d9cdf987385a1760efe` |
| [comparison-west.png](comparison-west.png) | `0a08049c780e3fbf6742c52c7e5f645116cd7e21d4a5fc87c9bd0947782749e1` |
| [comparison-north.png](comparison-north.png) | `9b964dbfa5c2e2d7b700c3c37dbb9d7c694852b505ac3a2dd7803fa66d257a88` |
| [comparison-east.png](comparison-east.png) | `bf9f3483f13b99253ea79e105a7318a8234bfaea1e8d6dc3856de5ce81542f81` |
| [joined-south-normals.png](joined-south-normals.png) | `173cdb8c9dba6bb9ba16dbbc214113c4c03e40a7a44e273e4a445f75dc69dd1e` |
| [joined-south-art.png](joined-south-art.png) | `7d11942c987d52fd2f48a97f43ac24f7be6ff0bc85a721b6bf4766b5e199be5a` |
| [joined-west-normals.png](joined-west-normals.png) | `6382efc98b11ba486dfb29d76c516fa18157ddf0dbdedc4ae31602e581b0778e` |
| [joined-west-art.png](joined-west-art.png) | `b0de8835c4e5c9a461f6ccd2aa7e0cc4300fcf84eee95c3f40ff900e149690c2` |
| [joined-north-normals.png](joined-north-normals.png) | `0de1db6638343599c095cbfae8c6b6f2ce13d96ac06f066b177d02836cb6c996` |
| [joined-north-art.png](joined-north-art.png) | `88dfd04458664f45c1e19c3bd692e0e19e63aa002ce2a3bb703249e962e0cd18` |
| [joined-east-normals.png](joined-east-normals.png) | `0e4e537f7fed92fcb180ada9dd235c494575534050807920ee6af49d24ef38cc` |
| [joined-east-art.png](joined-east-art.png) | `44f34492143a317631dfcd12399a79c2aba0ddd417e8187c9dfd7f624d763914` |
| [evidence-index.json](evidence-index.json) | `ed375a9a0ede50ef213f3eca61e904338e165a6a9f02289fa2637a0b4689c995` |

## Reference defect reproduced from the pinned inputs (issue #655's N/E counterexample)

- E mask `isoface_slope_e.png`: git blob `5ed533b4d9467fa3b371a4cb489a87844fa64611`, SHA-256 `b63967d34e447e487a504ddf97b723d4c4f7cd642b1a319f44fe88eb55ab2c1d`. N mask `isoface_slope_n.png`: blob `effc21564c7a653605dcbafca23ce7bc560e262d`, SHA-256 `1e0d2e7e559a004821d3b02150ed650ebfa6360fd77648164010efb9fb3c6310`.
- E texel `(48, 2)` is opaque `(0, 255, 0, 255)` (a face-weight green).
- The unit-cell surface E shows there (the E solid's top `z = 1 - x`, texel footprint `u in [48,49]`, `v in [2,3]`) has corners at `(x, y)` = (1/32,1/32), (3/64,3/64), (5/128,7/384), (7/128,13/384). Turned 3 positive quarter turns (`(x, y, z) -> (1 - y, x, z)` thrice) into N's frame and projected, it covers `u in [11/4..9/2]`, `v in [193/8..99/4]`, inside the issue's `[0,6] x [23.5,27]`; the enclosing N texels (columns [2, 3, 4], rows [24]) are all transparent: yes.
- N's first opaque rows at columns 0-7 are [39, 39, 38, 38, 37, 37, 36, 36].
- This is one counterexample, recorded as such: it does not assert that every legacy mask is wrong. The suite re-derives it independently (`TRA-14 ... the reproduced reference defect`).

## Which proposed masks change, and why

Counts are of 96 x 64 texels. `removed` = opaque in the legacy mask and transparent in the corrected one; `added` the reverse. Legacy RGB is a right/top/left brightness weight and corrected RGB a surface normal, so RGB is not compared: every opaque texel differs in meaning by design (D-56).

**Facing south**

| World ID | Name | View ID | Legacy opaque | Corrected opaque | Removed | Added |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | 0 | 3936 | 3840 | 96 | 0 |
| 1 | N | 1 | 2400 | 2688 | 72 | 360 |
| 2 | E | 2 | 3504 | 3456 | 72 | 24 |
| 3 | NE | 3 | 2760 | 2688 | 72 | 0 |
| 4 | S | 4 | 3112 | 3456 | 50 | 394 |
| 5 | NS | 5 | 3120 | 2496 | 624 | 0 |
| 6 | ES | 6 | 3504 | 3072 | 456 | 24 |
| 7 | NES | 7 | 2760 | 2496 | 264 | 0 |
| 8 | W | 8 | 3504 | 2688 | 816 | 0 |
| 9 | NW | 9 | 2712 | 2304 | 409 | 1 |
| 10 | EW | 10 | 3160 | 2496 | 664 | 0 |
| 11 | NEW | 11 | 3120 | 2304 | 816 | 0 |
| 12 | SW | 12 | 3504 | 2688 | 816 | 0 |
| 13 | NSW | 13 | 2760 | 2304 | 456 | 0 |
| 14 | ESW | 14 | 3936 | 2496 | 1440 | 0 |
| 15 | NESW | 15 | 2400 | 2304 | 96 | 0 |

**Facing west**

| World ID | Name | View ID | Legacy opaque | Corrected opaque | Removed | Added |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | 0 | 3936 | 3840 | 96 | 0 |
| 1 | N | 8 | 3504 | 2688 | 816 | 0 |
| 2 | E | 1 | 2400 | 2688 | 72 | 360 |
| 3 | NE | 9 | 2712 | 2304 | 409 | 1 |
| 4 | S | 2 | 3504 | 3456 | 72 | 24 |
| 5 | NS | 10 | 3160 | 2496 | 664 | 0 |
| 6 | ES | 3 | 2760 | 2688 | 72 | 0 |
| 7 | NES | 11 | 3120 | 2304 | 816 | 0 |
| 8 | W | 4 | 3112 | 3456 | 50 | 394 |
| 9 | NW | 12 | 3504 | 2688 | 816 | 0 |
| 10 | EW | 5 | 3120 | 2496 | 624 | 0 |
| 11 | NEW | 13 | 2760 | 2304 | 456 | 0 |
| 12 | SW | 6 | 3504 | 3072 | 456 | 24 |
| 13 | NSW | 14 | 3936 | 2496 | 1440 | 0 |
| 14 | ESW | 7 | 2760 | 2496 | 264 | 0 |
| 15 | NESW | 15 | 2400 | 2304 | 96 | 0 |

**Facing north**

| World ID | Name | View ID | Legacy opaque | Corrected opaque | Removed | Added |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | 0 | 3936 | 3840 | 96 | 0 |
| 1 | N | 4 | 3112 | 3456 | 50 | 394 |
| 2 | E | 8 | 3504 | 2688 | 816 | 0 |
| 3 | NE | 12 | 3504 | 2688 | 816 | 0 |
| 4 | S | 1 | 2400 | 2688 | 72 | 360 |
| 5 | NS | 5 | 3120 | 2496 | 624 | 0 |
| 6 | ES | 9 | 2712 | 2304 | 409 | 1 |
| 7 | NES | 13 | 2760 | 2304 | 456 | 0 |
| 8 | W | 2 | 3504 | 3456 | 72 | 24 |
| 9 | NW | 6 | 3504 | 3072 | 456 | 24 |
| 10 | EW | 10 | 3160 | 2496 | 664 | 0 |
| 11 | NEW | 14 | 3936 | 2496 | 1440 | 0 |
| 12 | SW | 3 | 2760 | 2688 | 72 | 0 |
| 13 | NSW | 7 | 2760 | 2496 | 264 | 0 |
| 14 | ESW | 11 | 3120 | 2304 | 816 | 0 |
| 15 | NESW | 15 | 2400 | 2304 | 96 | 0 |

**Facing east**

| World ID | Name | View ID | Legacy opaque | Corrected opaque | Removed | Added |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | Flat | 0 | 3936 | 3840 | 96 | 0 |
| 1 | N | 2 | 3504 | 3456 | 72 | 24 |
| 2 | E | 4 | 3112 | 3456 | 50 | 394 |
| 3 | NE | 6 | 3504 | 3072 | 456 | 24 |
| 4 | S | 8 | 3504 | 2688 | 816 | 0 |
| 5 | NS | 10 | 3160 | 2496 | 664 | 0 |
| 6 | ES | 12 | 3504 | 2688 | 816 | 0 |
| 7 | NES | 14 | 3936 | 2496 | 1440 | 0 |
| 8 | W | 1 | 2400 | 2688 | 72 | 360 |
| 9 | NW | 3 | 2760 | 2688 | 72 | 0 |
| 10 | EW | 5 | 3120 | 2496 | 624 | 0 |
| 11 | NEW | 7 | 2760 | 2496 | 264 | 0 |
| 12 | SW | 9 | 2712 | 2304 | 409 | 1 |
| 13 | NSW | 11 | 3120 | 2304 | 816 | 0 |
| 14 | ESW | 13 | 2760 | 2304 | 456 | 0 |
| 15 | NESW | 15 | 2400 | 2304 | 96 | 0 |

Why: the corrected maps are baked from one canonical solid per ID (P-9), at texel centres, so every ramp, ridge and corner silhouette follows the solid's own geometry; the legacy masks are hand-authored and disagree with their own rotations (the N/E counterexample above). ID 15 changes most: the legacy `isoface_slope_nesw.png` is a flat diamond (only green, 2,400 opaque texels) and the corrected map is the central four-faced half-height peak (D-49). Rotated views are not separately authored: the lookup selects the catalog entry of the turned shape.

## Independent expected result

The suite (`Test.TerrainRender2D.MapAssets`) does not bless the generated output. Its reference states the solid as the closed half-spaces of the P-9 height table (`z <= N, E, S, W` per set bit or `z <= 1`, inside the unit footprint, above the base), takes the points that project to one canvas position as the line `(x0 + z/3, y0 + z/3, z)`, finds the frontmost point by trying every height at which the line meets a constraint plane and keeping the highest feasible, and compares every texel of every committed PNG with it, with every expected normal byte stated by hand (flat-up `(128,128,255)`, W ramp `(38,128,218)`, walls `(255,128,128)`, `(128,255,128)`). The baker is compared with the same reference at exact rational boundary points, where the tie rule decides. Because every projected edge is vertical at a whole canvas coordinate or has slope 1/2, 1/6 or 5/6 through a whole point, no texel centre lies on any facet, ridge, wall or silhouette edge (proved exhaustively); no counterexample to that argument was found.

## Source and output hash inventory (implementation revision)

Generated catalog, `samples/ecce-homo/content/textures/facemap/`: 46 maps, at most the P-14 bound of 46 before deduplication, every authored identity kept.

| Map id | File | Role | Shape | Opaque texels | SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `shape.00` | `shape_00_flat.png` | ordinary | 0 Flat | 3840 | `fa9b13c48aeb9c06d06aa879aa9a52a86ccbe414d3166410cb008312d2bf3780` |
| `shape.01` | `shape_01_n.png` | ordinary | 1 N | 2688 | `10e2b06a3ffd735476be7b7552d9c6321d5b403300368eba01637e71f85481e8` |
| `shape.02` | `shape_02_e.png` | ordinary | 2 E | 3456 | `06a34a9600856460287f8c6ef9838d83d68059516d347beeeab4531d0d67cbb8` |
| `shape.03` | `shape_03_ne.png` | ordinary | 3 NE | 2688 | `36dcb6e0b4b6cc1f808ffd1512d2512fbfd082dbea2b65b5a1023199577e11fe` |
| `shape.04` | `shape_04_s.png` | ordinary | 4 S | 3456 | `f51f03f706b4c01fa539ae5f4a3f9db35b49cf066927eb3cc2c67c4f866dd028` |
| `shape.05` | `shape_05_ns.png` | ordinary | 5 NS | 2496 | `26d7ec3080a0d6927ca3c38e7a168af2505917cc6d6aa462ce3254489feaa192` |
| `shape.06` | `shape_06_es.png` | ordinary | 6 ES | 3072 | `22a5e84d4936f34c598e4bffc5cf1f4118aa5500c29ccb35f332fd9a89d55ad3` |
| `shape.07` | `shape_07_nes.png` | ordinary | 7 NES | 2496 | `abc7e7532aa2418d6c00872c3224dea8c1c86227e8b8fcca8ca3fdcd14026b97` |
| `shape.08` | `shape_08_w.png` | ordinary | 8 W | 2688 | `3a8d489fe2be07a4d3f7ada225005a1c4392755e1f2bfa132676aa9f7546e2b9` |
| `shape.09` | `shape_09_nw.png` | ordinary | 9 NW | 2304 | `381d56c04b451c2c7da2332b685785a87382fecd9a5540cdf26c2500a55ca115` |
| `shape.10` | `shape_10_ew.png` | ordinary | 10 EW | 2496 | `a393473e129006fefd0aa3e0932f842b7a60f618d0bece0d548fcf24d6093665` |
| `shape.11` | `shape_11_new.png` | ordinary | 11 NEW | 2304 | `af0bb92081cfae38a43456a699089fe6340fa1187fd1819c70a0a17499468551` |
| `shape.12` | `shape_12_sw.png` | ordinary | 12 SW | 2688 | `c34f07ea73637eb8cbb1ea12795741f10a6f4f5a4822b990e81d20798a5127a5` |
| `shape.13` | `shape_13_nsw.png` | ordinary | 13 NSW | 2304 | `292b8501373f11c75cc4e8ad3cf3aa37bd04a5d822032287df6043e67ed6dd5a` |
| `shape.14` | `shape_14_esw.png` | ordinary | 14 ESW | 2496 | `35da401dede09c57168c324b8a5a01b12e0d72c800f586c421befdd45a2b4b9f` |
| `shape.15` | `shape_15_nesw.png` | ordinary | 15 NESW | 2304 | `2a6a7a5d14437e5ac24ac3be55477dd97fcb2e54e15c1f9d85b660e65cf90b6c` |
| `mixed.01.known` | `mixed_01_n_known.png` | mixed-known | 1 N | 1152 | `91fb1a2504825250c2c62c2064094457b82221647ad97dec54927a5b5849a915` |
| `mixed.01.fog` | `mixed_01_n_fog.png` | mixed-fog | 1 N | 2688 | `456b577842081d5d6096ea380f3169da04f0cbeb706d98fdaff98b3497648cea` |
| `mixed.02.known` | `mixed_02_e_known.png` | mixed-known | 2 E | 384 | `8ea196ce102af0705a5e9f1d7c4a4e1e645c01bf5e200deef643c9938d27e23e` |
| `mixed.02.fog` | `mixed_02_e_fog.png` | mixed-fog | 2 E | 3456 | `8b00cf26a01539870200034b8d3f77dde9b445e9530938eb70118ab06074644e` |
| `mixed.03.known` | `mixed_03_ne_known.png` | mixed-known | 3 NE | 384 | `8ea196ce102af0705a5e9f1d7c4a4e1e645c01bf5e200deef643c9938d27e23e` |
| `mixed.03.fog` | `mixed_03_ne_fog.png` | mixed-fog | 3 NE | 3456 | `8b00cf26a01539870200034b8d3f77dde9b445e9530938eb70118ab06074644e` |
| `mixed.04.known` | `mixed_04_s_known.png` | mixed-known | 4 S | 384 | `6e98a1b1cfa6aa893d2b2562e31f9e774ae7e9ffe458ac2af0144fd65d80aa5c` |
| `mixed.04.fog` | `mixed_04_s_fog.png` | mixed-fog | 4 S | 3456 | `452c52a68802ca8b8efa5bb425a71369e086cdeafcef4a30776c52e53c09e883` |
| `mixed.05.known` | `mixed_05_ns_known.png` | mixed-known | 5 NS | 192 | `45c7b5d93276d26ff24a8830b6192ff39a9555f6f9b25a0c24232de6063c50a5` |
| `mixed.05.fog` | `mixed_05_ns_fog.png` | mixed-fog | 5 NS | 3648 | `14d58e7bba27d68cd306a121436fc59b19ebd51fd89abc70b5f772cfd1089e6a` |
| `mixed.06.known` | `mixed_06_es_known.png` | mixed-known | 6 ES | 0 | `8cc84bdaf3e2ceaac89932578ddbf9b5632d3644c9280f70ac2a827b46ce8ea3` |
| `mixed.06.fog` | `mixed_06_es_fog.png` | mixed-fog | 6 ES | 3840 | `fa9b13c48aeb9c06d06aa879aa9a52a86ccbe414d3166410cb008312d2bf3780` |
| `mixed.07.known` | `mixed_07_nes_known.png` | mixed-known | 7 NES | 0 | `8cc84bdaf3e2ceaac89932578ddbf9b5632d3644c9280f70ac2a827b46ce8ea3` |
| `mixed.07.fog` | `mixed_07_nes_fog.png` | mixed-fog | 7 NES | 3840 | `fa9b13c48aeb9c06d06aa879aa9a52a86ccbe414d3166410cb008312d2bf3780` |
| `mixed.08.known` | `mixed_08_w_known.png` | mixed-known | 8 W | 1152 | `697c7aae534a4d4098b9062f04b150c95555895f83c949253ead573bc380c586` |
| `mixed.08.fog` | `mixed_08_w_fog.png` | mixed-fog | 8 W | 2688 | `c4c6b94f98cee72058248bb05a91caa353d9c7a3d4964979d2ab7b75f667f4c7` |
| `mixed.09.known` | `mixed_09_nw_known.png` | mixed-known | 9 NW | 768 | `4014bb60d20aa04bd066aa6668d426fc50f30acbdf356e04b46b7edffa42bb27` |
| `mixed.09.fog` | `mixed_09_nw_fog.png` | mixed-fog | 9 NW | 3072 | `4562d4104104c6b364e9dc925fbf7246515e809dc154e944d48ec89a686067ce` |
| `mixed.10.known` | `mixed_10_ew_known.png` | mixed-known | 10 EW | 192 | `b5a11d9bfa7cd7853d6ee93e1b485ff8ec5db54e89b28acb007ce63f2cf848fd` |
| `mixed.10.fog` | `mixed_10_ew_fog.png` | mixed-fog | 10 EW | 3648 | `2f269bafda1886aac8bfe43fddc30c12dd3276985fb646247b7a37dea170fb68` |
| `mixed.11.known` | `mixed_11_new_known.png` | mixed-known | 11 NEW | 192 | `b5a11d9bfa7cd7853d6ee93e1b485ff8ec5db54e89b28acb007ce63f2cf848fd` |
| `mixed.11.fog` | `mixed_11_new_fog.png` | mixed-fog | 11 NEW | 3648 | `2f269bafda1886aac8bfe43fddc30c12dd3276985fb646247b7a37dea170fb68` |
| `mixed.12.known` | `mixed_12_sw_known.png` | mixed-known | 12 SW | 384 | `6e98a1b1cfa6aa893d2b2562e31f9e774ae7e9ffe458ac2af0144fd65d80aa5c` |
| `mixed.12.fog` | `mixed_12_sw_fog.png` | mixed-fog | 12 SW | 3456 | `452c52a68802ca8b8efa5bb425a71369e086cdeafcef4a30776c52e53c09e883` |
| `mixed.13.known` | `mixed_13_nsw_known.png` | mixed-known | 13 NSW | 192 | `45c7b5d93276d26ff24a8830b6192ff39a9555f6f9b25a0c24232de6063c50a5` |
| `mixed.13.fog` | `mixed_13_nsw_fog.png` | mixed-fog | 13 NSW | 3648 | `14d58e7bba27d68cd306a121436fc59b19ebd51fd89abc70b5f772cfd1089e6a` |
| `mixed.14.known` | `mixed_14_esw_known.png` | mixed-known | 14 ESW | 0 | `8cc84bdaf3e2ceaac89932578ddbf9b5632d3644c9280f70ac2a827b46ce8ea3` |
| `mixed.14.fog` | `mixed_14_esw_fog.png` | mixed-fog | 14 ESW | 3840 | `fa9b13c48aeb9c06d06aa879aa9a52a86ccbe414d3166410cb008312d2bf3780` |
| `mixed.15.known` | `mixed_15_nesw_known.png` | mixed-known | 15 NESW | 0 | `8cc84bdaf3e2ceaac89932578ddbf9b5632d3644c9280f70ac2a827b46ce8ea3` |
| `mixed.15.fog` | `mixed_15_nesw_fog.png` | mixed-fog | 15 NESW | 3840 | `fa9b13c48aeb9c06d06aa879aa9a52a86ccbe414d3166410cb008312d2bf3780` |

Maps that share bytes (all authored identities are kept regardless):

- `14d58e7bba27d68c…`: `mixed.05.fog`, `mixed.13.fog`
- `2f269bafda1886aa…`: `mixed.10.fog`, `mixed.11.fog`
- `452c52a68802ca8b…`: `mixed.04.fog`, `mixed.12.fog`
- `45c7b5d93276d26f…`: `mixed.05.known`, `mixed.13.known`
- `6e98a1b1cfa6aa89…`: `mixed.04.known`, `mixed.12.known`
- `8b00cf26a0153987…`: `mixed.02.fog`, `mixed.03.fog`
- `8cc84bdaf3e2ceaa…`: `mixed.06.known`, `mixed.07.known`, `mixed.14.known`, `mixed.15.known`
- `8ea196ce102af070…`: `mixed.02.known`, `mixed.03.known`
- `b5a11d9bfa7cd785…`: `mixed.10.known`, `mixed.11.known`
- `fa9b13c48aeb9c06…`: `shape.00`, `mixed.06.fog`, `mixed.07.fog`, `mixed.14.fog`, `mixed.15.fog`

Colour art and imported blank (unchanged byte for byte from Synarchy `3777d437`):

| Asset | Source path | SHA-256 |
| --- | --- | --- |
| loam | `assets/textures/world/loam/loam.png` | `f449a06bc3aa76fdf56607c4e4d23ac1cc8c1a67245b8ae5b295dbff621105e1` |
| granite | `assets/textures/world/granite/granite.png` | `776a28d3ee45f656ee8f024444c0f2529b4d176da455902e4ac9bfb329d79d1c` |
| blanktexture | `assets/textures/utility/blanktexture.png` | `c747223e0f788c942d1e8699735ac4a26a011599b6442c707b91c29f42f2f90e` |

Reference-only legacy masks (never resolved as normal maps), `samples/ecce-homo/reference/synarchy-3777d437/facemap/`: see `samples/ecce-homo/content/textures/provenance.json` (`referenceOnlyMasks`) for each file's Synarchy path, git blob and SHA-256 and the selection rule (`src/World/Render/Textures.hs:27-56`, `scripts/startup_loader.lua:311,320-334`).

## Observations

- The colour art's silhouette (3,936 opaque texels) is a superset of the exact centre-sampled cutout of ID 0 (3,840) by 96 texels along the top diamond's two upper edges; every one of the 46 maps lies inside the art, so the product of colour and map alpha equals the cutout. Nothing resizes, repaints or thresholds the art.
- Shapes 6, 7, 14 and 15 have no visible known solid in the mixed case (their east and south walls are lowered to the base), so their known part is empty and their cover equals ID 0's full cover.
- The generic blank covers every texel any cover map uses.

## What this does not show

Sampling by a shader, raster-edge ownership, picking by alpha, lighting, depth composition, the bounded texture loader and its quotas, and any offscreen readback are TRA-15 through TRA-17. The baseline TRA-8 evidence under `docs/evidence/terrain/tra8/` is history and describes the old geometry; it is not rewritten here.

