# The TRA-17 bounded terrain material evidence record

Verdict: **pass**.

## A surface-free session drawing the bounded selection of the terrain arena's cell quads over a D32_SFLOAT depth image

- windows: 0
- roots at the end of the body: RootsView {viewInstance = RootLive, viewMessenger = RootLive, viewDevice = RootLive, viewAllocator = RootLive, viewDeviceName = Just "Apple M3 Max", viewQueueFamily = Just 0, viewTargets = [], viewAdmitting = True, viewLoss = Nothing}
- target standing: no target
- actions: ran the terrain-ci evidence
- device calls, in order: vkCreateInstance, vkCreateDebugUtilsMessengerEXT, vkEnumeratePhysicalDevices, vkCreateDevice, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
- Vulkan calls: 992, on 1 thread(s)
- frames presented: 0, presentations retired: 0
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 1.392628
- probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_ci7/terrain-ci/tra17-terrain-ci-probes.json
- failure: none
- depth format: Depth32Float
- matrix-FaceSouth-0.25: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceSouth@0.25: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceSouth@0.25-single-images: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- roof-cut1-FaceWest@0.125: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- roof-cut1-FaceWest@0.125-scrambled: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- roof-cut1-FaceWest@0.125-two-materials: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- roof-cut1-FaceWest@0.125-retained: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- roof-cut1-FaceWest@0.125-ordered-wrapper: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- ramps-FaceEast@0.125: pass, 1404 probes, 1197 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@black-under-haze: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- spans-FaceSouth@0.125-control-reversed-overlap: pass, 1008 probes, 1008 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap

## Transcript

```
## TRA-17: the bounded required selection of the terrain material's evidence: the 16 shape identities in the south facing, mixed and fog cells, a roof over a cavity in four submissions and both wrappers, ramps, a depth-effect stack, and a reversed-order control, judged as the complete qualification is
the terrain-ci evidence is written into /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_ci7/terrain-ci
terrain-ci probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_ci7/terrain-ci/tra17-terrain-ci-probes.json
terrain-ci depth format: Depth32Float
terrain-ci fixture matrix-FaceSouth-0.25: 10560 probes, 10560 determinate, 0 not counted; passed
terrain-ci fixture mixed-FaceSouth@0.25: 2640 probes, 2640 determinate, 0 not counted; passed
terrain-ci fixture mixed-FaceSouth@0.25-single-images: 2640 probes, 2640 determinate, 0 not counted; passed
terrain-ci fixture roof-cut1-FaceWest@0.125: 1176 probes, 936 determinate, 240 not counted; passed
terrain-ci fixture roof-cut1-FaceWest@0.125-scrambled: 1176 probes, 936 determinate, 240 not counted; passed
terrain-ci fixture roof-cut1-FaceWest@0.125-two-materials: 1176 probes, 936 determinate, 240 not counted; passed
terrain-ci fixture roof-cut1-FaceWest@0.125-retained: 1176 probes, 936 determinate, 240 not counted; passed
terrain-ci fixture roof-cut1-FaceWest@0.125-ordered-wrapper: 1176 probes, 936 determinate, 240 not counted; passed
terrain-ci fixture ramps-FaceEast@0.125: 1404 probes, 1197 determinate, 207 not counted; passed
terrain-ci fixture depth-stack-FaceSouth@0.25@black-under-haze: 4788 probes, 4788 determinate, 0 not counted; passed
terrain-ci fixture spans-FaceSouth@0.125-control-reversed-overlap: 1008 probes, 1008 determinate, 0 not counted; passed
```
