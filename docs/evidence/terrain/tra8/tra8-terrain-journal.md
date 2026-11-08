# The TRA-8 terrain material evidence record

Verdict: **pass**.

## A surface-free session drawing the terrain arena's faces over a D32_SFLOAT depth image

- windows: 0
- roots at the end of the body: RootsView {viewInstance = RootLive, viewMessenger = RootLive, viewDevice = RootLive, viewAllocator = RootLive, viewDeviceName = Just "Apple M3 Max", viewQueueFamily = Just 0, viewTargets = [], viewAdmitting = True, viewLoss = Nothing}
- target standing: no target
- actions: ran the terrain evidence
- device calls, in order: vkCreateInstance, vkCreateDebugUtilsMessengerEXT, vkEnumeratePhysicalDevices, vkCreateDevice, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
- Vulkan calls: 794, on 1 thread(s)
- frames presented: 0, presentations retired: 0
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 9.389997
- probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/031b4ebb-935c-4584-bbfa-56623775a271/scratchpad/evidM/terrain/tra8-terrain-probes.json
- failure: none
- depth format: Depth32Float
- matrix-FaceSouth-0.25: pass, 10560 probes, 10040 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- matrix-FaceWest-0.25: pass, 10560 probes, 9840 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- matrix-FaceNorth-0.25: pass, 10560 probes, 10026 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- matrix-FaceEast-0.25: pass, 10560 probes, 9851 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- native-scale-FaceSouth-1: pass, 14280 probes, 12700 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- roof-cut2-FaceSouth@0.125: pass, 1260 probes, 1260 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
- roof-cut1-FaceSouth@0.125: pass, 1176 probes, 1176 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a cutaway cap shows its cell's top at the cut
- roof-cut1-FaceWest@0.125: pass, 1176 probes, 1162 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a cutaway cap shows its cell's top at the cut
- roof-cut1-FaceWest@0.125-scrambled: pass, 1176 probes, 1162 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a cutaway cap shows its cell's top at the cut
- roof-cut1-FaceWest@0.125-two-materials: pass, 1176 probes, 1162 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a cutaway cap shows its cell's top at the cut
- roof-cut1-FaceWest@0.125-retained: pass, 1176 probes, 1162 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a cutaway cap shows its cell's top at the cut
- spans-FaceNorth@0.125: pass, 768 probes, 768 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
- ramps-FaceEast@0.125: pass, 1404 probes, 1333 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
- stairs-cut1-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass a cutaway cap shows its cell's top at the cut
- stairs-cut3-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass a cutaway cap shows its cell's top at the cut
- stairs-cut5-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- follow-FaceSouth@0.125: pass, 6372 probes, 6372 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass a cutaway cap shows its cell's top at the cut
- deep-FaceSouth: pass, 5096 probes, 5096 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- zoom-0.125: pass, 2392 probes, 2349 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- zoom-8.0: pass, 6144 probes, 4325 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- fractional@0.1875: pass, 2808 probes, 2463 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- viewport@0.125: pass, 1344 probes, 1271 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass a viewport away from the corner clips the scene and leaves the rest of the target clear
- scaled@0.125: pass, 4992 probes, 4921 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- snapped: pass, 6144 probes, 4719 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- diagnostic-FaceSouth@0.25: pass, 2964 probes, 2795 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a transparent part of a nearer face shows what lies behind it, not the face
- diagnostic-FaceWest@0.25: pass, 2700 probes, 2368 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
    - pass a transparent part of a nearer face shows what lies behind it, not the face
- spans-FaceSouth@0.125-control-reversed-overlap: pass, 1008 probes, 1008 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap
- ramps-FaceSouth@0.125-control-whole-quad-mask: pass, 1596 probes, 1549 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
- spans-FaceSouth@0.125-control-pick-through-nearer-face: pass, 1008 probes, 1008 determinate
    - pass a face's art covers the pixels its coverage holds and nothing beside them
    - pass the nearer face hides the farther where their projections overlap

## Transcript

```
## TRA-8: a surface-free session draws plans of the terrain arena's faces, adapted through the existing fixed-quad and material ABI, into offscreen targets that have a D32_SFLOAT depth image, reads each back after its batch completed and judges every pixel against the render-2d oracle given the terrain material's model and against a hand-stated line-of-sight expectation: the 16 shape identities in each of 4 facings, roofs over cavities, disconnected spans, ramps and corners, cutaways, the automatic follow, a deep floor, the zoom endpoints, a fractional camera, a viewport, a content scale and pixel snapping, equivalent submissions and retained chunks, transparent coverage and three negative controls
the terrain evidence is written into /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/031b4ebb-935c-4584-bbfa-56623775a271/scratchpad/evidM/terrain
terrain probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/031b4ebb-935c-4584-bbfa-56623775a271/scratchpad/evidM/terrain/tra8-terrain-probes.json
terrain depth format: Depth32Float
terrain fixture matrix-FaceSouth-0.25: 10560 probes, 10040 determinate, 520 not counted; passed
terrain fixture matrix-FaceWest-0.25: 10560 probes, 9840 determinate, 720 not counted; passed
terrain fixture matrix-FaceNorth-0.25: 10560 probes, 10026 determinate, 534 not counted; passed
terrain fixture matrix-FaceEast-0.25: 10560 probes, 9851 determinate, 709 not counted; passed
terrain fixture native-scale-FaceSouth-1: 14280 probes, 12700 determinate, 1580 not counted; passed
terrain fixture roof-cut2-FaceSouth@0.125: 1260 probes, 1260 determinate, 0 not counted; passed
terrain fixture roof-cut1-FaceSouth@0.125: 1176 probes, 1176 determinate, 0 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125: 1176 probes, 1162 determinate, 14 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-scrambled: 1176 probes, 1162 determinate, 14 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-two-materials: 1176 probes, 1162 determinate, 14 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-retained: 1176 probes, 1162 determinate, 14 not counted; passed
terrain fixture spans-FaceNorth@0.125: 768 probes, 768 determinate, 0 not counted; passed
terrain fixture ramps-FaceEast@0.125: 1404 probes, 1333 determinate, 71 not counted; passed
terrain fixture stairs-cut1-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture stairs-cut3-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture stairs-cut5-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture follow-FaceSouth@0.125: 6372 probes, 6372 determinate, 0 not counted; passed
terrain fixture deep-FaceSouth: 5096 probes, 5096 determinate, 0 not counted; passed
terrain fixture zoom-0.125: 2392 probes, 2349 determinate, 43 not counted; passed
terrain fixture zoom-8.0: 6144 probes, 4325 determinate, 1819 not counted; passed
terrain fixture fractional@0.1875: 2808 probes, 2463 determinate, 345 not counted; passed
terrain fixture viewport@0.125: 1344 probes, 1271 determinate, 73 not counted; passed
terrain fixture scaled@0.125: 4992 probes, 4921 determinate, 71 not counted; passed
terrain fixture snapped: 6144 probes, 4719 determinate, 1425 not counted; passed
terrain fixture diagnostic-FaceSouth@0.25: 2964 probes, 2795 determinate, 169 not counted; passed
terrain fixture diagnostic-FaceWest@0.25: 2700 probes, 2368 determinate, 332 not counted; passed
terrain fixture spans-FaceSouth@0.125-control-reversed-overlap: 1008 probes, 1008 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-whole-quad-mask: 1596 probes, 1549 determinate, 47 not counted; passed
terrain fixture spans-FaceSouth@0.125-control-pick-through-nearer-face: 1008 probes, 1008 determinate, 0 not counted; passed
```
