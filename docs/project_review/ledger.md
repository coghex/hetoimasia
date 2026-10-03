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
| #360 | Supersede #331 with VMA: record D-38/D-39 and keep the allocator parity evidence | 2026-09-30T21:43:03Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-09-30T23:02:36Z | [docs/project_review/360.md](360.md) | — |
| #359 | Keep the graphics owner from blocking when a presenting window is hidden on Wayland | 2026-09-30T21:35:52Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:01:27Z | [docs/project_review/359.md](359.md) | — |
| #358 | Start the Vulkan device and owner progress without a window | 2026-09-30T20:02:23Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:20:01Z | [docs/project_review/358.md](358.md) | — |
| #356 | Collect Wayland rendering evidence on the pinned Lavapipe stack | 2026-09-30T15:00:26Z | findings | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:08:30Z | [docs/project_review/356.md](356.md) | — |
| #355 | Establish packages/math with the vectors, matrices and projections the 3D fixture needs | 2026-09-30T14:53:16Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:15:22Z | — | — |
| #354 | Extract the async log adapter's record preparation into a private module | 2026-09-30T14:45:57Z | ✓ clean | `bc758d29a65aa9179bbbeb28e47064145b70b93a` | 2026-09-30T14:51:38Z | — | — |
| #353 | Split the validation planner into cohesive tool modules | 2026-09-30T07:19:24Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T07:35:55Z | — | — |
| #352 | Split the Lua protocol session aggregate into focused private modules | 2026-09-30T04:18:21Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T04:36:50Z | — | — |
| #351 | Keep the shader toolchain fingerprints for quruntul's Vulkan trials | 2026-09-30T04:13:34Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T04:41:00Z | — | — |
| #347 | Split the GLFW window implementation and remove its identity boot cycle | 2026-09-30T03:48:38Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T04:47:59Z | — | — |
| #339 | Activate the pinned GHC for quruntul builds and trials | 2026-09-30T03:02:14Z | findings | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:02:40Z | [docs/project_review/339.md](339.md) | — |
| #332 | Split the GLFW main-thread window host into cohesive private modules | 2026-09-29T20:09:43Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:09:37Z | — | — |
| #329 | Split the GLFW graphics owner into cohesive private modules | 2026-09-29T19:23:51Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:14:41Z | — | — |
| #328 | Split the graphics-owner test module into owner fixtures and behavior-group specs | 2026-09-29T18:43:42Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:20:50Z | — | — |
| #326 | Split the GPU model's state implementation into cohesive private modules | 2026-09-29T18:07:26Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:30:39Z | — | — |
| #322 | Move the local test and flake lab to quruntul behind a repository adapter | 2026-09-29T18:02:33Z | findings | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:42:27Z | [docs/project_review/322.md](322.md) | — |
| #316 | Keep the owner's failure records atomic while a diagnostic failure is being published | 2026-09-29T15:28:06Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:49:43Z | — | — |
| #315 | Drive the stalled live-resize example from the scripted clock | 2026-09-29T14:41:39Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T05:55:37Z | — | — |
| #314 | Release the lifetime example's announced producer only after closing begins | 2026-09-29T14:30:31Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:00:26Z | — | — |
| #312 | Ask for the replacement surface a target retirement's generations step admits | 2026-09-29T14:08:37Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:17:06Z | — | — |
| #311 | Give a construction's reservation back when its out-of-memory retry raises | 2026-09-29T14:02:33Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:22:59Z | — | — |
| #310 | Keep the triangle sample's pipeline layout when its pipeline is refused | 2026-09-29T13:56:22Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:29:58Z | — | — |
| #309 | Wait for the helper's blocked delivery before releasing the worker (#308) | 2026-09-29T13:49:49Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:39:13Z | — | — |
| #302 | Deliver the triangle sample and VK-17's required native profile | 2026-09-29T12:13:58Z | ✓ clean | `284d782d4e0ab79fb777bc644173b77ab106b725` | 2026-09-30T06:48:39Z | — | — |
| #301 | Refuse a callback's call into its own Lua VM instead of hanging the owner | 2026-09-29T03:26:54Z | ✓ clean | `ae04949d22516fe2a912cb019ccacd83bde1c5b1` | 2026-09-30T06:55:44Z | — | — |
| #300 | Expose consumer-built pipelines and verification capture through the Vulkan host (VK-19) | 2026-09-29T02:24:52Z | ✓ clean | `ae04949d22516fe2a912cb019ccacd83bde1c5b1` | 2026-09-30T07:08:11Z | — | — |
| #298 | Refuse pull requests that change MEMORY.md together with non-Markdown files | 2026-09-28T18:45:33Z | ✓ clean | `ae04949d22516fe2a912cb019ccacd83bde1c5b1` | 2026-09-30T07:14:25Z | — | — |
| #294 | Compose rendering demand and retirement with TIME and LIFE (VK-16) | 2026-09-28T18:28:53Z | ✓ clean | `ae04949d22516fe2a912cb019ccacd83bde1c5b1` | 2026-09-30T07:23:48Z | — | — |
| #293 | Apply bounded target and allocation recovery (VK-14) | 2026-09-28T05:07:34Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T07:46:09Z | — | — |
| #292 | Complete terminal graphics failure and device-loss teardown | 2026-09-28T03:06:05Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:02:33Z | — | — |
| #291 | Track presentation completion and retire generations (VK-13) | 2026-09-27T17:53:57Z | findings | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:17:33Z | [docs/project_review/291.md](291.md) | — |
| #290 | Track frame acquisition, submission and safe abandonment (VK-12) | 2026-09-27T16:34:13Z | findings | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:25:44Z | [docs/project_review/290.md](290.md) | — |
| #289 | Separate messaging types and give its component identity a common owner | 2026-09-27T14:53:53Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:34:37Z | — | — |
| #288 | Separate time data and pure arithmetic from clock operations | 2026-09-27T14:36:28Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:40:30Z | — | — |
| #287 | Make build-test read the latest attempt's receipts after a re-run | 2026-09-27T13:38:23Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:52:56Z | — | — |
| #286 | Stop the glfw-native launcher regression from racing the orphan's reaping | 2026-09-27T12:55:00Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:59:39Z | — | — |
| #283 | Separate recovery policy and outcome types | 2026-09-27T13:58:50Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T08:46:28Z | — | — |
| #282 | Separate worker data, requests, startup, observation and group lifetime | 2026-09-27T04:31:40Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T09:09:20Z | — | — |
| #281 | Make the native wake examples' settle a Wayland barrier | 2026-09-27T02:50:55Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T09:17:42Z | — | — |
| #279 | Separate resource representations and collection types | 2026-09-27T02:35:03Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T09:24:43Z | — | — |
| #278 | Collect headless native Wayland evidence and confirm connection loss | 2026-09-26T23:14:39Z | findings | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:04:15Z | [docs/project_review/278.md](278.md) | — |
| #277 | Split Vulkan swapchain generation management into cohesive private modules | 2026-09-26T23:06:31Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:16:05Z | — | — |
| #276 | Separate logging and failure data from their operations | 2026-09-26T23:00:30Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:20:38Z | — | — |
| #270 | Give native desktop runs the owner's standing approval | 2026-09-26T17:48:02Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:27:37Z | — | — |
| #267 | Split Vulkan managed recording into cohesive private modules | 2026-09-26T14:56:39Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:33:29Z | — | — |
| #264 | Name native Vulkan objects and label recording regions in validation diagnostics | 2026-09-26T00:12:48Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:41:37Z | — | — |
| #263 | Record through retained managed resources (VK-11) | 2026-09-25T20:11:14Z | ✓ clean | `46e6bad6757cc336d5d81e47c211011a713345e6` | 2026-09-30T14:47:03Z | — | — |
| #262 | Manage swapchain generation construction and replacement | 2026-09-25T15:41:43Z | ✓ clean | `acaa0ff36f17a793ec81daba785f8879693198f5` | 2026-09-30T14:59:41Z | — | — |
| #261 | docs: replace the Vulkan design's stale platform-selector claim | 2026-09-25T12:48:36Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:18:43Z | — | — |
| #260 | Integrate package-native Vulkan fixtures and CI evidence | 2026-09-25T02:00:40Z | findings | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:30:10Z | [docs/project_review/260.md](260.md) | — |
| #259 | Read graphics-owner destruction and completion coherently during shutdown | 2026-09-24T23:04:06Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:34:18Z | — | — |
| #257 | Own Vulkan instance, device and targets under protected retirement | 2026-09-24T20:41:14Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:42:58Z | — | — |
| #256 | Make Template Haskell shaders reproducible (VK-9) | 2026-09-24T19:41:36Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:47:52Z | — | — |
| #255 | Expose which workers a protected drain is still waiting on | 2026-09-24T19:35:26Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:52:08Z | — | — |
| #254 | Keep a failed body primary when Vulkan diagnostic finalization is cancelled | 2026-09-24T15:12:08Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T15:58:36Z | — | — |
| #252 | Add the loader-aware GLFW surface bridge (VK-5) | 2026-09-24T14:07:11Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T16:04:08Z | — | — |
| #249 | Capture Vulkan validation diagnostics in C, drained by an independent worker | 2026-09-24T11:42:30Z | findings | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T17:23:20Z | [docs/project_review/249.md](249.md) | — |
| #248 | Recognize completed X server exits above status 128 | 2026-09-24T00:18:05Z | ✓ clean | `32eb02e3bcb5c7d99dc09b6edc35c90c42509c56` | 2026-09-30T17:35:34Z | — | — |
| #247 | Preserve timeout outcomes while unreaped group members remain | 2026-09-23T23:36:57Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:27:33Z | — | — |
| #245 | Bound the toolchain evidence freshness claim to the revision it establishes | 2026-09-23T15:36:38Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:31:52Z | — | — |
| #244 | Align the attachment protocol's callback restrictions with finite backend progress | 2026-09-23T15:33:51Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:38:45Z | — | — |
| #243 | Retain each macOS memory step's native buffer | 2026-09-23T15:20:38Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T01:07:25Z | [docs/project_review/243.md](243.md) | — |
| #242 | Add a durable shared lab for optional probes and flaky tests | 2026-09-23T15:14:17Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T01:16:45Z | — | — |
| #241 | Correct misleading cancellation and ownership comments | 2026-09-23T15:27:48Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T00:54:49Z | [docs/project_review/241.md](241.md) | — |
| #240 | Separate routine validation from optional local probes | 2026-09-23T15:07:59Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T01:26:37Z | [docs/project_review/240.md](240.md) | — |
| #239 | Provision the pinned native Vulkan environment | 2026-09-23T14:59:14Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T01:52:56Z | — | — |
| #238 | Settle the supervised graphics owner's cross-thread contract | 2026-09-22T04:21:32Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T02:15:36Z | [docs/project_review/238.md](238.md) | — |
| #236 | Tell the X server's startup outcomes apart from their own channels | 2026-09-21T13:57:35Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T02:25:23Z | [docs/project_review/236.md](236.md) | — |
| #235 | Settle Wayland session selection and the capability contract | 2026-09-21T06:15:15Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T02:40:28Z | — | — |
| #214 | Provision pinned Wayland inputs and an isolated headless compositor | 2026-09-21T03:46:59Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T02:54:40Z | [docs/project_review/214.md](214.md) | — |
| #213 | Add an optional bounded asynchronous logging adapter to the runtime | 2026-09-20T21:51:10Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:10:20Z | [docs/project_review/213.md](213.md) | — |
| #210 | Qualify owner-loop progress during macOS window interactions | 2026-09-20T19:49:55Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:23:30Z | — | — |
| #209 | Correct the Vulkan proof shim header comments to match the C implementation | 2026-09-20T18:27:09Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:31:15Z | — | — |
| #206 | Bound the storage a failure reason's detail retains | 2026-09-20T18:12:54Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:38:06Z | — | — |
| #203 | Correct the Frames comment that made submission completion a reacquisition prerequisite | 2026-09-20T18:09:07Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:42:40Z | — | — |
| #198 | Settle a safe failure of observing work after the session has failed | 2026-09-20T16:09:44Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:48:50Z | — | — |
| #197 | Give the Linux-only validation group a satisfiable execution policy on Darwin plans | 2026-09-20T15:52:49Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T03:56:27Z | — | — |
| #196 | Make the acquisition-handoff example reject an unprotected handoff | 2026-09-20T15:03:42Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T05:18:35Z | — | — |
| #192 | Publish the proof's presentation obligation under the same mask as its enqueue | 2026-09-20T14:49:46Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T05:27:34Z | — | — |
| #188 | Make a validated GPU budget read-only through the public exports | 2026-09-20T13:13:30Z | ✓ clean | `a89d419aaab9d952d6dc058fb5eec62985010008` | 2026-09-20T13:18:22Z | — | — |
| #187 | Admit reacquiring an image whose presentation is already enqueued | 2026-09-20T12:58:57Z | findings | `a89d419aaab9d952d6dc058fb5eec62985010008` | 2026-09-20T13:23:36Z | [docs/project_review/187.md](187.md) | — |
| #186 | Own every Vulkan proof handle before the next fallible construction step | 2026-09-20T06:31:22Z | findings | `a89d419aaab9d952d6dc058fb5eec62985010008` | 2026-09-20T13:30:17Z | [docs/project_review/186.md](186.md) | — |
| #185 | Retain presentation obligations when the Vulkan proof stops before retirement | 2026-09-20T04:26:41Z | findings | `a89d419aaab9d952d6dc058fb5eec62985010008` | 2026-09-20T13:38:06Z | [docs/project_review/185.md](185.md) | — |
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
| #14 | Preserve cancellation and primary failures in the worker example | 2026-09-11T13:26:55Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T05:39:46Z | [docs/project_review/14.md](14.md) | — |
| #7 | Integrate startup configuration and the module authoring guide | 2026-09-11T03:17:21Z | findings | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T05:49:50Z | [docs/project_review/7.md](7.md) | — |
| #6 | Implement deterministic output and safe sink ownership | 2026-09-11T02:52:54Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T05:54:55Z | — | — |
| #5 | Establish structured logging, filtering, and scoped context | 2026-09-11T02:09:34Z | ✓ clean | `5b56b17d5eb1af5ec10a1a5a28510f096096c825` | 2026-10-01T06:03:47Z | — | — |

- Migrated from the cursor-v2 record.

<!-- project-review:ledger:v1 -->

```json
{
  "repositories": {
    "coghex/hetoimasia": {
      "direct": {
        "adopted": null,
        "endpoint": null,
        "reports": [],
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
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T05:39:46Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T05:38:04.175841Z",
              "kind": "allocation",
              "report": "docs/project_review/14.md",
              "token": "9138873e7a5bb9b2422ed5ab640a8091"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T05:39:46Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/14.md",
              "token": "9138873e7a5bb9b2422ed5ab640a8091"
            }
          ],
          "merged_at": "2026-09-11T13:26:55Z",
          "report": "docs/project_review/14.md",
          "status": "findings",
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
        "185": {
          "claim": null,
          "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
          "completed_at": "2026-09-20T13:38:06Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T13:36:14.845018Z",
              "kind": "allocation",
              "report": "docs/project_review/185.md",
              "token": "20477b5c228aa8a54dc6390a2d36a498"
            },
            {
              "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
              "completed_at": "2026-09-20T13:38:06Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "ba3c74bcbbd031791cd67b83164be92e57c304aa",
                  "pr": 185,
                  "report": "docs/project_review/174.md"
                }
              ],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/185.md",
              "token": "20477b5c228aa8a54dc6390a2d36a498"
            }
          ],
          "merged_at": "2026-09-20T04:26:41Z",
          "report": "docs/project_review/185.md",
          "status": "findings",
          "title": "Retain presentation obligations when the Vulkan proof stops before retirement"
        },
        "186": {
          "claim": null,
          "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
          "completed_at": "2026-09-20T13:30:17Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T13:29:10.967579Z",
              "kind": "allocation",
              "report": "docs/project_review/186.md",
              "token": "d8814d3dac650bcd610b412d5dffd7b9"
            },
            {
              "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
              "completed_at": "2026-09-20T13:30:17Z",
              "fixes": [
                {
                  "key": "PRR-2",
                  "merge_commit": "b398c08b15c6cb0c93c51aead244cd96252893fd",
                  "pr": 186,
                  "report": "docs/project_review/174.md"
                }
              ],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/186.md",
              "token": "d8814d3dac650bcd610b412d5dffd7b9"
            }
          ],
          "merged_at": "2026-09-20T06:31:22Z",
          "report": "docs/project_review/186.md",
          "status": "findings",
          "title": "Own every Vulkan proof handle before the next fallible construction step"
        },
        "187": {
          "claim": null,
          "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
          "completed_at": "2026-09-20T13:23:36Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-20T13:22:07.915267Z",
              "kind": "allocation",
              "report": "docs/project_review/187.md",
              "token": "535e303753af2fe64a8af8003068abc3"
            },
            {
              "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
              "completed_at": "2026-09-20T13:23:36Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "ee6985a6892f73514264c82fd0a984f0ab93bf6c",
                  "pr": 187,
                  "report": "docs/project_review/175.md"
                }
              ],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/187.md",
              "token": "535e303753af2fe64a8af8003068abc3"
            }
          ],
          "merged_at": "2026-09-20T12:58:57Z",
          "report": "docs/project_review/187.md",
          "status": "findings",
          "title": "Admit reacquiring an image whose presentation is already enqueued"
        },
        "188": {
          "claim": null,
          "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
          "completed_at": "2026-09-20T13:18:22Z",
          "evidence": [],
          "history": [
            {
              "commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
              "completed_at": "2026-09-20T13:18:22Z",
              "fixes": [
                {
                  "key": "PRR-2",
                  "merge_commit": "a89d419aaab9d952d6dc058fb5eec62985010008",
                  "pr": 188,
                  "report": "docs/project_review/175.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "c7455910bf4c3500797de389cd6fbbd0"
            }
          ],
          "merged_at": "2026-09-20T13:13:30Z",
          "report": null,
          "status": "clean",
          "title": "Make a validated GPU budget read-only through the public exports"
        },
        "192": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T05:27:34Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T05:27:34Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "61d8a6faa1fbb1b84f69b3f53fec86d918795658",
                  "pr": 192,
                  "report": "docs/project_review/185.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "d692a48c42bcbbd16645d1b2eaee8cd8"
            }
          ],
          "merged_at": "2026-09-20T14:49:46Z",
          "report": null,
          "status": "clean",
          "title": "Publish the proof's presentation obligation under the same mask as its enqueue"
        },
        "196": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T05:18:35Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T05:18:35Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "5c593e2ac625b014e9bfbbe144d37a84d7d830d4",
                  "pr": 196,
                  "report": "docs/project_review/186.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "b7e170886d1a0ff99012ca53f20ae4f0"
            }
          ],
          "merged_at": "2026-09-20T15:03:42Z",
          "report": null,
          "status": "clean",
          "title": "Make the acquisition-handoff example reject an unprotected handoff"
        },
        "197": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:56:27Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:56:27Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "af4436d7069fce884950335f51e307216dda4e41",
                  "pr": 197,
                  "report": "docs/project_review/177.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "2951182233a3cf842c36e49ae1c8c905"
            }
          ],
          "merged_at": "2026-09-20T15:52:49Z",
          "report": null,
          "status": "clean",
          "title": "Give the Linux-only validation group a satisfiable execution policy on Darwin plans"
        },
        "198": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:48:50Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:48:50Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "9869f1d399cfcce159569a14190353d61989d2c2",
                  "pr": 198,
                  "report": "docs/project_review/179.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "b221f24405491516a6a521242a6021ff"
            }
          ],
          "merged_at": "2026-09-20T16:09:44Z",
          "report": null,
          "status": "clean",
          "title": "Settle a safe failure of observing work after the session has failed"
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
        "203": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:42:40Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:42:40Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "438764e3e9e83339e6aad2ee3e8caceda237a6e7",
                  "pr": 203,
                  "report": "docs/project_review/187.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "6676a5a70b6995d31f9fbd1200054bc5"
            }
          ],
          "merged_at": "2026-09-20T18:09:07Z",
          "report": null,
          "status": "clean",
          "title": "Correct the Frames comment that made submission completion a reacquisition prerequisite"
        },
        "206": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:38:06Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:38:06Z",
              "fixes": [
                {
                  "key": "PRR-2",
                  "merge_commit": "1f0f9805dda1e84400bd46b7dee38be7513db137",
                  "pr": 206,
                  "report": "docs/project_review/179.md"
                }
              ],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "b32510465803ccb893d0a53bc3d7d562"
            }
          ],
          "merged_at": "2026-09-20T18:12:54Z",
          "report": null,
          "status": "clean",
          "title": "Bound the storage a failure reason's detail retains"
        },
        "209": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:31:15Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:31:15Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "ecd2803c37405ecf8b1fa05bcd81278c"
            }
          ],
          "merged_at": "2026-09-20T18:27:09Z",
          "report": null,
          "status": "clean",
          "title": "Correct the Vulkan proof shim header comments to match the C implementation"
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
        "210": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:23:30Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:23:30Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "8f6fa4384a6346c61729446a23803213"
            }
          ],
          "merged_at": "2026-09-20T19:49:55Z",
          "report": null,
          "status": "clean",
          "title": "Qualify owner-loop progress during macOS window interactions"
        },
        "213": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T03:10:20Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T03:08:00.950900Z",
              "kind": "allocation",
              "report": "docs/project_review/213.md",
              "token": "01d6013a4df251688ab0b500e9372012"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T03:10:20Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/213.md",
              "token": "01d6013a4df251688ab0b500e9372012"
            }
          ],
          "merged_at": "2026-09-20T21:51:10Z",
          "report": "docs/project_review/213.md",
          "status": "findings",
          "title": "Add an optional bounded asynchronous logging adapter to the runtime"
        },
        "214": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T02:54:40Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T02:52:54.854796Z",
              "kind": "allocation",
              "report": "docs/project_review/214.md",
              "token": "6d4940c3071cfbf4a817753042133e0e"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T02:54:40Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/214.md",
              "token": "6d4940c3071cfbf4a817753042133e0e"
            }
          ],
          "merged_at": "2026-09-21T03:46:59Z",
          "report": "docs/project_review/214.md",
          "status": "findings",
          "title": "Provision pinned Wayland inputs and an isolated headless compositor"
        },
        "235": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T02:40:28Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T02:40:28Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e9ceb0407e4bd69e37f87ca6cdb35d1f"
            }
          ],
          "merged_at": "2026-09-21T06:15:15Z",
          "report": null,
          "status": "clean",
          "title": "Settle Wayland session selection and the capability contract"
        },
        "236": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T02:25:23Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T02:24:10.256426Z",
              "kind": "allocation",
              "report": "docs/project_review/236.md",
              "token": "bdfa362d465df2128b5de3a301dc18cd"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T02:25:23Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/236.md",
              "token": "bdfa362d465df2128b5de3a301dc18cd"
            }
          ],
          "merged_at": "2026-09-21T13:57:35Z",
          "report": "docs/project_review/236.md",
          "status": "findings",
          "title": "Tell the X server's startup outcomes apart from their own channels"
        },
        "238": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T02:15:36Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T02:11:50.793643Z",
              "kind": "allocation",
              "report": "docs/project_review/238.md",
              "token": "3ea15923fbf20ef39b97d356888baa10"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T02:15:36Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/238.md",
              "token": "3ea15923fbf20ef39b97d356888baa10"
            }
          ],
          "merged_at": "2026-09-22T04:21:32Z",
          "report": "docs/project_review/238.md",
          "status": "findings",
          "title": "Settle the supervised graphics owner's cross-thread contract"
        },
        "239": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T01:52:56Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T01:52:56Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "022ec1e35abc268ec456ac2016bcf623"
            }
          ],
          "merged_at": "2026-09-23T14:59:14Z",
          "report": null,
          "status": "clean",
          "title": "Provision the pinned native Vulkan environment"
        },
        "240": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T01:26:37Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T01:24:47.473199Z",
              "kind": "allocation",
              "report": "docs/project_review/240.md",
              "token": "62127830f78cf559675d56c1c72d4fe7"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T01:26:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/240.md",
              "token": "62127830f78cf559675d56c1c72d4fe7"
            }
          ],
          "merged_at": "2026-09-23T15:07:59Z",
          "report": "docs/project_review/240.md",
          "status": "findings",
          "title": "Separate routine validation from optional local probes"
        },
        "241": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:54:49Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T00:48:02.932869Z",
              "kind": "allocation",
              "report": "docs/project_review/241.md",
              "token": "816713f507b4f0b17e9062ab92a980e4"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:54:49Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/241.md",
              "token": "816713f507b4f0b17e9062ab92a980e4"
            }
          ],
          "merged_at": "2026-09-23T15:27:48Z",
          "report": "docs/project_review/241.md",
          "status": "findings",
          "title": "Correct misleading cancellation and ownership comments"
        },
        "242": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T01:16:45Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T01:16:45Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "96cd385f33990aae11376b50d4608a83"
            }
          ],
          "merged_at": "2026-09-23T15:14:17Z",
          "report": null,
          "status": "clean",
          "title": "Add a durable shared lab for optional probes and flaky tests"
        },
        "243": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T01:07:25Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T01:05:53.368123Z",
              "kind": "allocation",
              "report": "docs/project_review/243.md",
              "token": "f94f5c3635980925cbae79ff61e4de5b"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T01:07:25Z",
              "fixes": [
                {
                  "key": "PRR-1",
                  "merge_commit": "9cd2a591af945a2245116a4f3466f8b0b632096e",
                  "pr": 243,
                  "report": "docs/project_review/176.md"
                }
              ],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/243.md",
              "token": "f94f5c3635980925cbae79ff61e4de5b"
            }
          ],
          "merged_at": "2026-09-23T15:20:38Z",
          "report": "docs/project_review/243.md",
          "status": "findings",
          "title": "Retain each macOS memory step's native buffer"
        },
        "244": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:38:45Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:38:45Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "77a7456e9c49b0da4865fd13459f9e3c"
            }
          ],
          "merged_at": "2026-09-23T15:33:51Z",
          "report": null,
          "status": "clean",
          "title": "Align the attachment protocol's callback restrictions with finite backend progress"
        },
        "245": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:31:52Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:31:52Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "5b69255b2aa1168c22d2bd45d57b6b09"
            }
          ],
          "merged_at": "2026-09-23T15:36:38Z",
          "report": null,
          "status": "clean",
          "title": "Bound the toolchain evidence freshness claim to the revision it establishes"
        },
        "247": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:27:33Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:27:33Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "a8e99fef52577c66b7a193f0c1efc439"
            }
          ],
          "merged_at": "2026-09-23T23:36:57Z",
          "report": null,
          "status": "clean",
          "title": "Preserve timeout outcomes while unreaped group members remain"
        },
        "248": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T17:35:34Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T17:35:34Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "33900cada0011ed22da99505c3bc3eb8"
            }
          ],
          "merged_at": "2026-09-24T00:18:05Z",
          "report": null,
          "status": "clean",
          "title": "Recognize completed X server exits above status 128"
        },
        "249": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T17:23:20Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T17:20:42.839918Z",
              "kind": "allocation",
              "report": "docs/project_review/249.md",
              "token": "f28053ca7317e55ad3d3d165c284e400"
            },
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T17:23:20Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/249.md",
              "token": "f28053ca7317e55ad3d3d165c284e400"
            }
          ],
          "merged_at": "2026-09-24T11:42:30Z",
          "report": "docs/project_review/249.md",
          "status": "findings",
          "title": "Capture Vulkan validation diagnostics in C, drained by an independent worker"
        },
        "252": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T16:04:08Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T16:04:08Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "f5e4b8c41170eaff2703b67550dfc6fb"
            }
          ],
          "merged_at": "2026-09-24T14:07:11Z",
          "report": null,
          "status": "clean",
          "title": "Add the loader-aware GLFW surface bridge (VK-5)"
        },
        "254": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:58:36Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:58:36Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "931fa9b5303cc8d115c9873c59587e74"
            }
          ],
          "merged_at": "2026-09-24T15:12:08Z",
          "report": null,
          "status": "clean",
          "title": "Keep a failed body primary when Vulkan diagnostic finalization is cancelled"
        },
        "255": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:52:08Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:52:08Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e951ff0ad5b9f6b1f5d0050a4f52e0a5"
            }
          ],
          "merged_at": "2026-09-24T19:35:26Z",
          "report": null,
          "status": "clean",
          "title": "Expose which workers a protected drain is still waiting on"
        },
        "256": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:47:52Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:47:52Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "099dba1fb4aa2e7cb0280692978b303e"
            }
          ],
          "merged_at": "2026-09-24T19:41:36Z",
          "report": null,
          "status": "clean",
          "title": "Make Template Haskell shaders reproducible (VK-9)"
        },
        "257": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:42:58Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:42:58Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "4e491f4d80d4dd67296326c20129407c"
            }
          ],
          "merged_at": "2026-09-24T20:41:14Z",
          "report": null,
          "status": "clean",
          "title": "Own Vulkan instance, device and targets under protected retirement"
        },
        "259": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:34:18Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:34:18Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "cd657d082352d935dc44fd715f098926"
            }
          ],
          "merged_at": "2026-09-24T23:04:06Z",
          "report": null,
          "status": "clean",
          "title": "Read graphics-owner destruction and completion coherently during shutdown"
        },
        "260": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:30:10Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T15:29:00.607357Z",
              "kind": "allocation",
              "report": "docs/project_review/260.md",
              "token": "e7c59de1847a603ec4e9251238ce5e8a"
            },
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:30:10Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/260.md",
              "token": "e7c59de1847a603ec4e9251238ce5e8a"
            }
          ],
          "merged_at": "2026-09-25T02:00:40Z",
          "report": "docs/project_review/260.md",
          "status": "findings",
          "title": "Integrate package-native Vulkan fixtures and CI evidence"
        },
        "261": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:18:43Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:18:43Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "ff31a14029906f94abbe863e0c2f97df"
            }
          ],
          "merged_at": "2026-09-25T12:48:36Z",
          "report": null,
          "status": "clean",
          "title": "docs: replace the Vulkan design's stale platform-selector claim"
        },
        "262": {
          "claim": null,
          "commit": "acaa0ff36f17a793ec81daba785f8879693198f5",
          "completed_at": "2026-09-30T14:59:41Z",
          "evidence": [],
          "history": [
            {
              "commit": "acaa0ff36f17a793ec81daba785f8879693198f5",
              "completed_at": "2026-09-30T14:59:41Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "036856fe8868c59661518900ff4e7fd5"
            }
          ],
          "merged_at": "2026-09-25T15:41:43Z",
          "report": null,
          "status": "clean",
          "title": "Manage swapchain generation construction and replacement"
        },
        "263": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:47:03Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:47:03Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "08dec6bad0ebfd19748965f3f2a04076"
            }
          ],
          "merged_at": "2026-09-25T20:11:14Z",
          "report": null,
          "status": "clean",
          "title": "Record through retained managed resources (VK-11)"
        },
        "264": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:41:37Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:41:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "3aa2f22323038257adc1d730f2ccffe5"
            }
          ],
          "merged_at": "2026-09-26T00:12:48Z",
          "report": null,
          "status": "clean",
          "title": "Name native Vulkan objects and label recording regions in validation diagnostics"
        },
        "267": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:33:29Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:33:29Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "fec4f7ea4cd277fe10dde3d82aaf9f87"
            }
          ],
          "merged_at": "2026-09-26T14:56:39Z",
          "report": null,
          "status": "clean",
          "title": "Split Vulkan managed recording into cohesive private modules"
        },
        "270": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:27:37Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:27:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "5348b749d7929ce33e7d35a4fd01d376"
            }
          ],
          "merged_at": "2026-09-26T17:48:02Z",
          "report": null,
          "status": "clean",
          "title": "Give native desktop runs the owner's standing approval"
        },
        "276": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:20:38Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:20:38Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "af8b04e7aaa25e2c6cdc345d17cd1315"
            }
          ],
          "merged_at": "2026-09-26T23:00:30Z",
          "report": null,
          "status": "clean",
          "title": "Separate logging and failure data from their operations"
        },
        "277": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:16:05Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:16:05Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "85029d769dc4ea4237ec48a8ff01ca97"
            }
          ],
          "merged_at": "2026-09-26T23:06:31Z",
          "report": null,
          "status": "clean",
          "title": "Split Vulkan swapchain generation management into cohesive private modules"
        },
        "278": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T14:04:15Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T14:02:14.827169Z",
              "kind": "allocation",
              "report": "docs/project_review/278.md",
              "token": "2967cc6607a800dcdc0bc8565cf99670"
            },
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T14:04:15Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/278.md",
              "token": "2967cc6607a800dcdc0bc8565cf99670"
            }
          ],
          "merged_at": "2026-09-26T23:14:39Z",
          "report": "docs/project_review/278.md",
          "status": "findings",
          "title": "Collect headless native Wayland evidence and confirm connection loss"
        },
        "279": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T09:24:43Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T09:24:43Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "0e574b14309b16a37651a9f4fcde3a5c"
            }
          ],
          "merged_at": "2026-09-27T02:35:03Z",
          "report": null,
          "status": "clean",
          "title": "Separate resource representations and collection types"
        },
        "281": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T09:17:42Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T09:17:42Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "012fc501b4169e6494cbd37576d79df3"
            }
          ],
          "merged_at": "2026-09-27T02:50:55Z",
          "report": null,
          "status": "clean",
          "title": "Make the native wake examples' settle a Wayland barrier"
        },
        "282": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T09:09:20Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T09:09:20Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "c4a8b8aab72a596fa3cafe16b91acb42"
            }
          ],
          "merged_at": "2026-09-27T04:31:40Z",
          "report": null,
          "status": "clean",
          "title": "Separate worker data, requests, startup, observation and group lifetime"
        },
        "283": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:46:28Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:46:28Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e2f5b348f5014794ab9959464d786015"
            }
          ],
          "merged_at": "2026-09-27T13:58:50Z",
          "report": null,
          "status": "clean",
          "title": "Separate recovery policy and outcome types"
        },
        "286": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:59:39Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:59:39Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "5a6cd4c1aa5b258ccc3ff6722cbe975b"
            }
          ],
          "merged_at": "2026-09-27T12:55:00Z",
          "report": null,
          "status": "clean",
          "title": "Stop the glfw-native launcher regression from racing the orphan's reaping"
        },
        "287": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:52:56Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:52:56Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "d0d8fb7a57c3f2cf25bc49e80e26161e"
            }
          ],
          "merged_at": "2026-09-27T13:38:23Z",
          "report": null,
          "status": "clean",
          "title": "Make build-test read the latest attempt's receipts after a re-run"
        },
        "288": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:40:30Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:40:30Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "5dc80e92f784cdce4ac2127d5d14aebb"
            }
          ],
          "merged_at": "2026-09-27T14:36:28Z",
          "report": null,
          "status": "clean",
          "title": "Separate time data and pure arithmetic from clock operations"
        },
        "289": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:34:37Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:34:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "d633ca19eb3881a006b3fda9885306b5"
            }
          ],
          "merged_at": "2026-09-27T14:53:53Z",
          "report": null,
          "status": "clean",
          "title": "Separate messaging types and give its component identity a common owner"
        },
        "290": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:25:44Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T08:24:05.230466Z",
              "kind": "allocation",
              "report": "docs/project_review/290.md",
              "token": "9567c4bc468306c6f51022aee6ad93e3"
            },
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:25:44Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/290.md",
              "token": "9567c4bc468306c6f51022aee6ad93e3"
            }
          ],
          "merged_at": "2026-09-27T16:34:13Z",
          "report": "docs/project_review/290.md",
          "status": "findings",
          "title": "Track frame acquisition, submission and safe abandonment (VK-12)"
        },
        "291": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:17:33Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T08:15:44.070111Z",
              "kind": "allocation",
              "report": "docs/project_review/291.md",
              "token": "49c59e356dd84abe6cbffe1615069bd7"
            },
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:17:33Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/291.md",
              "token": "49c59e356dd84abe6cbffe1615069bd7"
            }
          ],
          "merged_at": "2026-09-27T17:53:57Z",
          "report": "docs/project_review/291.md",
          "status": "findings",
          "title": "Track presentation completion and retire generations (VK-13)"
        },
        "292": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T08:02:33Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T08:02:33Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "0e806dd8c6989d26d627fab77dd041a3"
            }
          ],
          "merged_at": "2026-09-28T03:06:05Z",
          "report": null,
          "status": "clean",
          "title": "Complete terminal graphics failure and device-loss teardown"
        },
        "293": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T07:46:09Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T07:46:09Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "fd9a414df0678b189da217b4e4a7e1cd"
            }
          ],
          "merged_at": "2026-09-28T05:07:34Z",
          "report": null,
          "status": "clean",
          "title": "Apply bounded target and allocation recovery (VK-14)"
        },
        "294": {
          "claim": null,
          "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
          "completed_at": "2026-09-30T07:23:48Z",
          "evidence": [],
          "history": [
            {
              "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
              "completed_at": "2026-09-30T07:23:48Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "0e55eaa192836a3b30deab24b6efe3df"
            }
          ],
          "merged_at": "2026-09-28T18:28:53Z",
          "report": null,
          "status": "clean",
          "title": "Compose rendering demand and retirement with TIME and LIFE (VK-16)"
        },
        "298": {
          "claim": null,
          "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
          "completed_at": "2026-09-30T07:14:25Z",
          "evidence": [],
          "history": [
            {
              "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
              "completed_at": "2026-09-30T07:14:25Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e741515dedd407ffa1deede828c19f77"
            }
          ],
          "merged_at": "2026-09-28T18:45:33Z",
          "report": null,
          "status": "clean",
          "title": "Refuse pull requests that change MEMORY.md together with non-Markdown files"
        },
        "300": {
          "claim": null,
          "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
          "completed_at": "2026-09-30T07:08:11Z",
          "evidence": [],
          "history": [
            {
              "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
              "completed_at": "2026-09-30T07:08:11Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "dab17e1a76a7516be413fae4fe38a1b1"
            }
          ],
          "merged_at": "2026-09-29T02:24:52Z",
          "report": null,
          "status": "clean",
          "title": "Expose consumer-built pipelines and verification capture through the Vulkan host (VK-19)"
        },
        "301": {
          "claim": null,
          "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
          "completed_at": "2026-09-30T06:55:44Z",
          "evidence": [],
          "history": [
            {
              "commit": "ae04949d22516fe2a912cb019ccacd83bde1c5b1",
              "completed_at": "2026-09-30T06:55:44Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "be6fc347dd43370ecbec9e911ae905ee"
            }
          ],
          "merged_at": "2026-09-29T03:26:54Z",
          "report": null,
          "status": "clean",
          "title": "Refuse a callback's call into its own Lua VM instead of hanging the owner"
        },
        "302": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:48:39Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:48:39Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "557e8fe830f2b4714ccc1c9d34c75994"
            }
          ],
          "merged_at": "2026-09-29T12:13:58Z",
          "report": null,
          "status": "clean",
          "title": "Deliver the triangle sample and VK-17's required native profile"
        },
        "309": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:39:13Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:39:13Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e694982cd5c41e627ebab719bbfd86f2"
            }
          ],
          "merged_at": "2026-09-29T13:49:49Z",
          "report": null,
          "status": "clean",
          "title": "Wait for the helper's blocked delivery before releasing the worker (#308)"
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
        "310": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:29:58Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:29:58Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "6c6de307af2ad89f742146dcb7023cd3"
            }
          ],
          "merged_at": "2026-09-29T13:56:22Z",
          "report": null,
          "status": "clean",
          "title": "Keep the triangle sample's pipeline layout when its pipeline is refused"
        },
        "311": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:22:59Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:22:59Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "54d42206fe626be514af2404d0e26346"
            }
          ],
          "merged_at": "2026-09-29T14:02:33Z",
          "report": null,
          "status": "clean",
          "title": "Give a construction's reservation back when its out-of-memory retry raises"
        },
        "312": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:17:06Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:17:06Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "f5650149d31a753a86abfd697e2f44bb"
            }
          ],
          "merged_at": "2026-09-29T14:08:37Z",
          "report": null,
          "status": "clean",
          "title": "Ask for the replacement surface a target retirement's generations step admits"
        },
        "314": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T06:00:26Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T06:00:26Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "fa4f6c5dd5764bf9f0f0682a6fb53ea2"
            }
          ],
          "merged_at": "2026-09-29T14:30:31Z",
          "report": null,
          "status": "clean",
          "title": "Release the lifetime example's announced producer only after closing begins"
        },
        "315": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:55:37Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:55:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "ccfe83f2f0327348f6ee6fa4ccaec398"
            }
          ],
          "merged_at": "2026-09-29T14:41:39Z",
          "report": null,
          "status": "clean",
          "title": "Drive the stalled live-resize example from the scripted clock"
        },
        "316": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:49:43Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:49:43Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "27e68d1d2c5179e44e50e1a4fbf06786"
            }
          ],
          "merged_at": "2026-09-29T15:28:06Z",
          "report": null,
          "status": "clean",
          "title": "Keep the owner's failure records atomic while a diagnostic failure is being published"
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
        "322": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:42:27Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T05:39:46.384569Z",
              "kind": "allocation",
              "report": "docs/project_review/322.md",
              "token": "920be6ad69e0d0764c16bb0c419fa772"
            },
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:42:27Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/322.md",
              "token": "920be6ad69e0d0764c16bb0c419fa772"
            }
          ],
          "merged_at": "2026-09-29T18:02:33Z",
          "report": "docs/project_review/322.md",
          "status": "findings",
          "title": "Move the local test and flake lab to quruntul behind a repository adapter"
        },
        "326": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:30:39Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:30:39Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "e46898be19eec36f25249ce04375bf3d"
            }
          ],
          "merged_at": "2026-09-29T18:07:26Z",
          "report": null,
          "status": "clean",
          "title": "Split the GPU model's state implementation into cohesive private modules"
        },
        "328": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:20:50Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:20:50Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "fb8ae40ea527398cd3523155fc182fde"
            }
          ],
          "merged_at": "2026-09-29T18:43:42Z",
          "report": null,
          "status": "clean",
          "title": "Split the graphics-owner test module into owner fixtures and behavior-group specs"
        },
        "329": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:14:41Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:14:41Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "c0b9276b246addccc1d1e4bd161fdf5c"
            }
          ],
          "merged_at": "2026-09-29T19:23:51Z",
          "report": null,
          "status": "clean",
          "title": "Split the GLFW graphics owner into cohesive private modules"
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
        "332": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:09:37Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:09:37Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "524498de5fa6d986aa42b62865fbd625"
            }
          ],
          "merged_at": "2026-09-29T20:09:43Z",
          "report": null,
          "status": "clean",
          "title": "Split the GLFW main-thread window host into cohesive private modules"
        },
        "339": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T05:02:40Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T05:00:32.309384Z",
              "kind": "allocation",
              "report": "docs/project_review/339.md",
              "token": "774c1c8fe6a1b9671611f2492ac4cdf7"
            },
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T05:02:40Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/339.md",
              "token": "774c1c8fe6a1b9671611f2492ac4cdf7"
            }
          ],
          "merged_at": "2026-09-30T03:02:14Z",
          "report": "docs/project_review/339.md",
          "status": "findings",
          "title": "Activate the pinned GHC for quruntul builds and trials"
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
        "347": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T04:47:59Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T04:47:59Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "5083707444aee249481973216a50a426"
            }
          ],
          "merged_at": "2026-09-30T03:48:38Z",
          "report": null,
          "status": "clean",
          "title": "Split the GLFW window implementation and remove its identity boot cycle"
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
        "351": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T04:41:00Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T04:41:00Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "38af42d395144adfc98fc4c474050327"
            }
          ],
          "merged_at": "2026-09-30T04:13:34Z",
          "report": null,
          "status": "clean",
          "title": "Keep the shader toolchain fingerprints for quruntul's Vulkan trials"
        },
        "352": {
          "claim": null,
          "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
          "completed_at": "2026-09-30T04:36:50Z",
          "evidence": [],
          "history": [
            {
              "commit": "284d782d4e0ab79fb777bc644173b77ab106b725",
              "completed_at": "2026-09-30T04:36:50Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "0a7ce73cd69790e31b797ae88221a4f3"
            }
          ],
          "merged_at": "2026-09-30T04:18:21Z",
          "report": null,
          "status": "clean",
          "title": "Split the Lua protocol session aggregate into focused private modules"
        },
        "353": {
          "claim": null,
          "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
          "completed_at": "2026-09-30T07:35:55Z",
          "evidence": [],
          "history": [
            {
              "commit": "46e6bad6757cc336d5d81e47c211011a713345e6",
              "completed_at": "2026-09-30T07:35:55Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "a71179b58256bcdb42a87a20ab2097c9"
            }
          ],
          "merged_at": "2026-09-30T07:19:24Z",
          "report": null,
          "status": "clean",
          "title": "Split the validation planner into cohesive tool modules"
        },
        "354": {
          "claim": null,
          "commit": "bc758d29a65aa9179bbbeb28e47064145b70b93a",
          "completed_at": "2026-09-30T14:51:38Z",
          "evidence": [],
          "history": [
            {
              "commit": "bc758d29a65aa9179bbbeb28e47064145b70b93a",
              "completed_at": "2026-09-30T14:51:38Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "836d90ab59d8756c573ed0be45c2ad1f"
            }
          ],
          "merged_at": "2026-09-30T14:45:57Z",
          "report": null,
          "status": "clean",
          "title": "Extract the async log adapter's record preparation into a private module"
        },
        "355": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:15:22Z",
          "evidence": [],
          "history": [
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:15:22Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "6fa061dd59ee4709a5495cbb56f17907"
            }
          ],
          "merged_at": "2026-09-30T14:53:16Z",
          "report": null,
          "status": "clean",
          "title": "Establish packages/math with the vectors, matrices and projections the 3D fixture needs"
        },
        "356": {
          "claim": null,
          "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
          "completed_at": "2026-09-30T15:08:30Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T15:05:07.404853Z",
              "kind": "allocation",
              "report": "docs/project_review/356.md",
              "token": "b842499fdee38948fdedb610ab42c9e1"
            },
            {
              "commit": "32eb02e3bcb5c7d99dc09b6edc35c90c42509c56",
              "completed_at": "2026-09-30T15:08:30Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/356.md",
              "token": "b842499fdee38948fdedb610ab42c9e1"
            }
          ],
          "merged_at": "2026-09-30T15:00:26Z",
          "report": "docs/project_review/356.md",
          "status": "findings",
          "title": "Collect Wayland rendering evidence on the pinned Lavapipe stack"
        },
        "358": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:20:01Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T00:17:37.425953Z",
              "kind": "allocation",
              "report": "docs/project_review/358.md",
              "token": "2f16b96486497577545aaee549b1c823"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:20:01Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/358.md",
              "token": "2f16b96486497577545aaee549b1c823"
            }
          ],
          "merged_at": "2026-09-30T20:02:23Z",
          "report": "docs/project_review/358.md",
          "status": "findings",
          "title": "Start the Vulkan device and owner progress without a window"
        },
        "359": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T00:01:27Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T23:59:05.141205Z",
              "kind": "allocation",
              "report": "docs/project_review/359.md",
              "token": "b692dd286950779bcbac4a49e2bbdc1a"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T00:01:27Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/359.md",
              "token": "b692dd286950779bcbac4a49e2bbdc1a"
            }
          ],
          "merged_at": "2026-09-30T21:35:52Z",
          "report": "docs/project_review/359.md",
          "status": "findings",
          "title": "Keep the graphics owner from blocking when a presenting window is hidden on Wayland"
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
        "360": {
          "claim": null,
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-09-30T23:02:36Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-09-30T22:49:05.784485Z",
              "kind": "allocation",
              "report": "docs/project_review/360.md",
              "token": "8020cc348fc210e542792635b7c2d76f"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-09-30T23:02:36Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/360.md",
              "token": "8020cc348fc210e542792635b7c2d76f"
            }
          ],
          "merged_at": "2026-09-30T21:43:03Z",
          "report": "docs/project_review/360.md",
          "status": "findings",
          "title": "Supersede #331 with VMA: record D-38/D-39 and keep the allocator parity evidence"
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
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T06:03:47Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T06:03:47Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "3766ecdcdaa9632fe500eedd293f3f17"
            }
          ],
          "merged_at": "2026-09-11T02:09:34Z",
          "report": null,
          "status": "clean",
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
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T05:54:55Z",
          "evidence": [],
          "history": [
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T05:54:55Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "clean",
              "recurrences": [],
              "repeats": [],
              "report": null,
              "token": "608fdc12c617b158f8719005986adaee"
            }
          ],
          "merged_at": "2026-09-11T02:52:54Z",
          "report": null,
          "status": "clean",
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
          "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
          "completed_at": "2026-10-01T05:49:50Z",
          "evidence": [],
          "history": [
            {
              "at": "2026-10-01T05:47:59.219243Z",
              "kind": "allocation",
              "report": "docs/project_review/7.md",
              "token": "d80ee1ea0a6ed5c82771d4098fef2021"
            },
            {
              "commit": "5b56b17d5eb1af5ec10a1a5a28510f096096c825",
              "completed_at": "2026-10-01T05:49:50Z",
              "fixes": [],
              "kind": "attempt",
              "outcome": "findings",
              "recurrences": [],
              "repeats": [],
              "report": "docs/project_review/7.md",
              "token": "d80ee1ea0a6ed5c82771d4098fef2021"
            }
          ],
          "merged_at": "2026-09-11T03:17:21Z",
          "report": "docs/project_review/7.md",
          "status": "findings",
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
  "version": 4
}
```
