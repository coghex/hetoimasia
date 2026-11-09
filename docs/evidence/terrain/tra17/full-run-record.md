# The TRA-17 terrain material evidence record

Verdict: **pass**.

## A surface-free session drawing the terrain arena's cell quads over a D32_SFLOAT depth image

- windows: 0
- roots at the end of the body: RootsView {viewInstance = RootLive, viewMessenger = RootLive, viewDevice = RootLive, viewAllocator = RootLive, viewDeviceName = Just "Apple M3 Max", viewDriverName = Just "MoltenVK", viewDriverInfo = Just "1.4.2", viewSubPixelPrecisionBits = Just 8, viewQueueFamily = Just 0, viewTargets = [], viewAdmitting = True, viewLoss = Nothing}
- target standing: no target
- actions: ran the terrain evidence
- device calls, in order: vkCreateInstance, vkCreateDebugUtilsMessengerEXT, vkEnumeratePhysicalDevices, vkCreateDevice, vkDestroyDevice, vkDestroyDebugUtilsMessengerEXT, vkDestroyInstance
- Vulkan calls: 3889, on 1 thread(s)
- frames presented: 0, presentations retired: 0
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 66.098887
- probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_full17/terrain/tra17-terrain-probes.json
- failure: none
- depth format: Depth32Float
- matrix-FaceSouth-0.25: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceWest-0.25: pass, 10560 probes, 9504 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceNorth-0.25: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceEast-0.25: pass, 10560 probes, 9696 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- native-scale-FaceSouth-1: pass, 14280 probes, 14280 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- mixed-FaceSouth@0.25: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceWest@0.25: pass, 2640 probes, 2268 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceNorth@0.25: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceEast@0.25: pass, 2640 probes, 2367 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceSouth-0.25-single-images: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceWest-0.25-single-images: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceNorth-0.25-single-images: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceEast-0.25-single-images: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceSouth@0.25-single-images: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceWest@0.25-single-images: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceNorth@0.25-single-images: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceEast@0.25-single-images: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- roof-cut2-FaceSouth@0.125: pass, 1260 probes, 1260 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- roof-cut1-FaceSouth@0.125: pass, 1176 probes, 1176 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
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
- spans-FaceNorth@0.125: pass, 768 probes, 768 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- ramps-FaceEast@0.125: pass, 1404 probes, 1197 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
    - pass the lighting and the art differ across the covered surface
- stairs-cut1-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- stairs-cut3-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- stairs-cut5-FaceSouth@0.125: pass, 1440 probes, 1440 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-0-FaceSouth-beside-ordinary: pass, 10212 probes, 9842 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-5-FaceSouth-beside-ordinary: pass, 10212 probes, 9842 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-15-FaceWest-beside-ordinary: pass, 10212 probes, 9842 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-9-FaceEast-beside-ordinary: pass, 10212 probes, 9842 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-0-FaceSouth@0.125-beside-ordinary: pass, 7865 probes, 7800 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-15-FaceEast@0.125-beside-ordinary: pass, 7865 probes, 7800 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-0-FaceSouth@0.5-beside-ordinary: pass, 10325 probes, 9753 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-9-FaceWest@0.5-beside-ordinary: pass, 10325 probes, 9753 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-0-FaceSouth@1.0-beside-ordinary: pass, 16293 probes, 14411 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- edges-5-FaceNorth@1.0-beside-ordinary: pass, 16293 probes, 14411 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-FaceSouth: pass, 51408 probes, 51408 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-FaceWest: pass, 71280 probes, 71280 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-FaceNorth: pass, 51408 probes, 51408 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-FaceEast: pass, 71280 probes, 71280 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-zero-FaceSouth: pass, 38352 probes, 38352 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- seams-zero-FaceNorth: pass, 35088 probes, 35088 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- extremes-max-FaceSouth: pass, 39984 probes, 39984 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- extremes-max-FaceEast: pass, 43344 probes, 43344 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- extremes-min-FaceSouth: pass, 39984 probes, 39984 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- extremes-min-FaceEast: pass, 43344 probes, 43344 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- pending-FaceSouth: pass, 59856 probes, 59856 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- pending-FaceWest: pass, 58800 probes, 58800 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- pending-FaceNorth: pass, 59856 probes, 59856 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- pending-FaceEast: pass, 58800 probes, 58800 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- shape-5-FaceSouth@1.0-colour-holes: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- shape-9-FaceWest@1.0-colour-holes: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- shape-0-FaceEast@1.0-colour-holes: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceSouth-0.25-colour-holes: pass, 10560 probes, 10560 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125-colour-holes: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- mixed-FaceSouth@0.25-colour-holes: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceSouth-0.25: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceSouth-0.25-single-images: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceWest-0.25: pass, 9900 probes, 8910 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceWest-0.25-single-images: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceNorth-0.25: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceNorth-0.25-single-images: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceEast-0.25: pass, 9900 probes, 9090 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-mixed-FaceEast-0.25-single-images: pass, 9900 probes, 9900 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-fog-FaceSouth-0.25: pass, 10664 probes, 10664 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceSouth-0.25-single-images: pass, 10664 probes, 10664 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceWest-0.25: pass, 10952 probes, 9944 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceWest-0.25-single-images: pass, 10952 probes, 10952 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceNorth-0.25: pass, 10664 probes, 10664 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceNorth-0.25-single-images: pass, 10664 probes, 10664 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceEast-0.25: pass, 10952 probes, 10124 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- matrix-fog-FaceEast-0.25-single-images: pass, 10952 probes, 10952 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- sequence-pan: pass, 6384 probes, 6384 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-zoom: pass, 21924 probes, 20793 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-rotation: pass, 5748 probes, 5311 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-manual-follow-manual: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-jump: pass, 6384 probes, 6384 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-reveal: pass, 7920 probes, 7920 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- sequence-unload-reload: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- follow-FaceSouth@0.125: pass, 6372 probes, 6372 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- deep-FaceSouth: pass, 5096 probes, 5096 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- zoom-0.125: pass, 2392 probes, 2392 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- zoom-8.0: pass, 6144 probes, 5501 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- fractional@0.1875: pass, 2808 probes, 2312 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- viewport@0.125: pass, 1344 probes, 1344 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass a viewport away from the corner clips the scene and leaves the rest of the target clear
- scaled@0.125: pass, 4992 probes, 4785 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped: pass, 6144 probes, 6144 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-1-8: pass, 6144 probes, 5942 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass pixel snapping moves the image: a pixel covered only when snapping, against one covered only when not
- snapped-9-8: pass, 6144 probes, 4886 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-5-4: pass, 6144 probes, 5038 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-63-8: pass, 6144 probes, 5235 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-8: pass, 6144 probes, 4328 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- ramps-FaceSouth@0.125: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceWest@0.125: pass, 1404 probes, 1174 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@sun-only: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@ambient-only: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@horizon: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@below-horizon: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@west-low: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@north-high: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125@dark-beside-default: pass, 3192 probes, 3192 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass two views sharing one registered material keep their own lighting
- depth-stack-FaceSouth@0.25@neither-effect: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@darkening-only: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@haze-only: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@both-short-range: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@black-under-haze: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@haze-no-light-beside-default: pass, 9576 probes, 9576 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass two views sharing one registered material keep their own lighting
- depth-stack-FaceNorth@0.25@black-under-haze: pass, 12852 probes, 12852 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- spans-FaceSouth@0.125-control-reversed-overlap: pass, 1008 probes, 1008 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- ramps-FaceSouth@0.125-control-whole-cell-mask: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceWest@0.125-control-wrong-facing-light: pass, 1404 probes, 1174 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@neither-effect-haze-control-depth-reset: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- depth-stack-FaceSouth@0.25@both-short-range-control-wrong-composition-order: pass, 4788 probes, 4788 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- matrix-FaceSouth-1.0@0.25-control-swapped-region-origins: pass, 8664 probes, 8664 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125-control-whole-atlas-clamping: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125-control-normal-as-colour: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125-control-half-texel-inset: pass, 1596 probes, 1514 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- ramps-FaceSouth@0.125-control-wrong-map-region: pass, 1596 probes, 1596 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- fog-over-known-FaceSouth@0.25-control-pick-through-fog: pass, 1020 probes, 1020 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- spans-FaceSouth@0.125-control-pick-through-nearer: pass, 1008 probes, 1008 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- pending-FaceSouth-control-loading-as-miss: pass, 59856 probes, 59856 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- shape-5-FaceSouth@1.0-control-colour-holes-ignored: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface
- exact-boundary-0-FaceSouth-beside-ordinary-control-unbiased-index: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-5-FaceSouth-beside-ordinary-control-unbiased-index: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-15-FaceWest-beside-ordinary-control-unbiased-index: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- exact-boundary-9-FaceEast-beside-ordinary-control-unbiased-index: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-9-8-beside-ordinary-control-stale-bias-1e-4: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- snapped-5-4-beside-ordinary-control-stale-bias-1e-4: pass, 7140 probes, 7140 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
- roof-cut1-FaceWest@0.125-retained-released-while-pending: pass, 1176 probes, 936 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the nearer quad hides the farther where their canvases overlap
- mixed-FaceSouth@0.25-released-while-pending: pass, 2640 probes, 2640 determinate
    - pass a quad's art covers the pixels its colour and map hold and nothing beside them
    - pass the lighting and the art differ across the covered surface

## Transcript

```
## TRA-17: a surface-free session draws the cell-quad plans of the terrain arena, adapted through the existing fixed-quad and material ABI over a packed colour atlas and a packed normal atlas, into offscreen targets that have a D32_SFLOAT depth image, reads each back after its batch completed and judges every pixel against the render-2d oracle given the terrain material's model and against a hand-stated expectation: the 16 shape identities in each of 4 facings, mixed and fog cells, roofs over cavities, disconnected spans, ramps, cutaways, the automatic follow, a deep floor, the zoom endpoints, a fractional camera, a viewport, a content scale and pixel snapping, lighting and depth-effect settings, equivalent submissions, ordered and cutout wrappers and retained chunks, and nine negative controls
the terrain evidence is written into /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_full17/terrain
terrain probe record: /private/tmp/claude-501/-Users-vincentcoghlan-work-hetoimasia/f0831c1c-5b48-4100-8206-6b8ef038b217/scratchpad/ev_full17/terrain/tra17-terrain-probes.json
terrain depth format: Depth32Float
terrain fixture matrix-FaceSouth-0.25: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture matrix-FaceWest-0.25: 10560 probes, 9504 determinate, 1056 not counted; passed
terrain fixture matrix-FaceNorth-0.25: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture matrix-FaceEast-0.25: 10560 probes, 9696 determinate, 864 not counted; passed
terrain fixture native-scale-FaceSouth-1: 14280 probes, 14280 determinate, 0 not counted; passed
terrain fixture mixed-FaceSouth@0.25: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture mixed-FaceWest@0.25: 2640 probes, 2268 determinate, 372 not counted; passed
terrain fixture mixed-FaceNorth@0.25: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture mixed-FaceEast@0.25: 2640 probes, 2367 determinate, 273 not counted; passed
terrain fixture matrix-FaceSouth-0.25-single-images: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture matrix-FaceWest-0.25-single-images: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture matrix-FaceNorth-0.25-single-images: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture matrix-FaceEast-0.25-single-images: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture mixed-FaceSouth@0.25-single-images: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture mixed-FaceWest@0.25-single-images: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture mixed-FaceNorth@0.25-single-images: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture mixed-FaceEast@0.25-single-images: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture roof-cut2-FaceSouth@0.125: 1260 probes, 1260 determinate, 0 not counted; passed
terrain fixture roof-cut1-FaceSouth@0.125: 1176 probes, 1176 determinate, 0 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-scrambled: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-two-materials: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-retained: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-ordered-wrapper: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture spans-FaceNorth@0.125: 768 probes, 768 determinate, 0 not counted; passed
terrain fixture ramps-FaceEast@0.125: 1404 probes, 1197 determinate, 207 not counted; passed
terrain fixture stairs-cut1-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture stairs-cut3-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture stairs-cut5-FaceSouth@0.125: 1440 probes, 1440 determinate, 0 not counted; passed
terrain fixture exact-boundary-0-FaceSouth-beside-ordinary: 10212 probes, 9842 determinate, 370 not counted; passed
terrain fixture exact-boundary-5-FaceSouth-beside-ordinary: 10212 probes, 9842 determinate, 370 not counted; passed
terrain fixture exact-boundary-15-FaceWest-beside-ordinary: 10212 probes, 9842 determinate, 370 not counted; passed
terrain fixture exact-boundary-9-FaceEast-beside-ordinary: 10212 probes, 9842 determinate, 370 not counted; passed
terrain fixture edges-0-FaceSouth@0.125-beside-ordinary: 7865 probes, 7800 determinate, 65 not counted; passed
terrain fixture edges-15-FaceEast@0.125-beside-ordinary: 7865 probes, 7800 determinate, 65 not counted; passed
terrain fixture edges-0-FaceSouth@0.5-beside-ordinary: 10325 probes, 9753 determinate, 572 not counted; passed
terrain fixture edges-9-FaceWest@0.5-beside-ordinary: 10325 probes, 9753 determinate, 572 not counted; passed
terrain fixture edges-0-FaceSouth@1.0-beside-ordinary: 16293 probes, 14411 determinate, 1882 not counted; passed
terrain fixture edges-5-FaceNorth@1.0-beside-ordinary: 16293 probes, 14411 determinate, 1882 not counted; passed
terrain fixture seams-FaceSouth: 51408 probes, 51408 determinate, 0 not counted; passed
terrain fixture seams-FaceWest: 71280 probes, 71280 determinate, 0 not counted; passed
terrain fixture seams-FaceNorth: 51408 probes, 51408 determinate, 0 not counted; passed
terrain fixture seams-FaceEast: 71280 probes, 71280 determinate, 0 not counted; passed
terrain fixture seams-zero-FaceSouth: 38352 probes, 38352 determinate, 0 not counted; passed
terrain fixture seams-zero-FaceNorth: 35088 probes, 35088 determinate, 0 not counted; passed
terrain fixture extremes-max-FaceSouth: 39984 probes, 39984 determinate, 0 not counted; passed
terrain fixture extremes-max-FaceEast: 43344 probes, 43344 determinate, 0 not counted; passed
terrain fixture extremes-min-FaceSouth: 39984 probes, 39984 determinate, 0 not counted; passed
terrain fixture extremes-min-FaceEast: 43344 probes, 43344 determinate, 0 not counted; passed
terrain fixture pending-FaceSouth: 59856 probes, 59856 determinate, 0 not counted; passed
terrain fixture pending-FaceWest: 58800 probes, 58800 determinate, 0 not counted; passed
terrain fixture pending-FaceNorth: 59856 probes, 59856 determinate, 0 not counted; passed
terrain fixture pending-FaceEast: 58800 probes, 58800 determinate, 0 not counted; passed
terrain fixture shape-5-FaceSouth@1.0-colour-holes: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture shape-9-FaceWest@1.0-colour-holes: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture shape-0-FaceEast@1.0-colour-holes: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture matrix-FaceSouth-0.25-colour-holes: 10560 probes, 10560 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-colour-holes: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture mixed-FaceSouth@0.25-colour-holes: 2640 probes, 2640 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceSouth-0.25: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceSouth-0.25-single-images: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceWest-0.25: 9900 probes, 8910 determinate, 990 not counted; passed
terrain fixture matrix-mixed-FaceWest-0.25-single-images: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceNorth-0.25: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceNorth-0.25-single-images: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-mixed-FaceEast-0.25: 9900 probes, 9090 determinate, 810 not counted; passed
terrain fixture matrix-mixed-FaceEast-0.25-single-images: 9900 probes, 9900 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceSouth-0.25: 10664 probes, 10664 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceSouth-0.25-single-images: 10664 probes, 10664 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceWest-0.25: 10952 probes, 9944 determinate, 1008 not counted; passed
terrain fixture matrix-fog-FaceWest-0.25-single-images: 10952 probes, 10952 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceNorth-0.25: 10664 probes, 10664 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceNorth-0.25-single-images: 10664 probes, 10664 determinate, 0 not counted; passed
terrain fixture matrix-fog-FaceEast-0.25: 10952 probes, 10124 determinate, 828 not counted; passed
terrain fixture matrix-fog-FaceEast-0.25-single-images: 10952 probes, 10952 determinate, 0 not counted; passed
terrain fixture sequence-pan: 6384 probes, 6384 determinate, 0 not counted; passed
terrain fixture sequence-zoom: 21924 probes, 20793 determinate, 1131 not counted; passed
terrain fixture sequence-rotation: 5748 probes, 5311 determinate, 437 not counted; passed
terrain fixture sequence-manual-follow-manual: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture sequence-jump: 6384 probes, 6384 determinate, 0 not counted; passed
terrain fixture sequence-reveal: 7920 probes, 7920 determinate, 0 not counted; passed
terrain fixture sequence-unload-reload: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture follow-FaceSouth@0.125: 6372 probes, 6372 determinate, 0 not counted; passed
terrain fixture deep-FaceSouth: 5096 probes, 5096 determinate, 0 not counted; passed
terrain fixture zoom-0.125: 2392 probes, 2392 determinate, 0 not counted; passed
terrain fixture zoom-8.0: 6144 probes, 5501 determinate, 643 not counted; passed
terrain fixture fractional@0.1875: 2808 probes, 2312 determinate, 496 not counted; passed
terrain fixture viewport@0.125: 1344 probes, 1344 determinate, 0 not counted; passed
terrain fixture scaled@0.125: 4992 probes, 4785 determinate, 207 not counted; passed
terrain fixture snapped: 6144 probes, 6144 determinate, 0 not counted; passed
terrain fixture snapped-1-8: 6144 probes, 5942 determinate, 202 not counted; passed
terrain fixture snapped-9-8: 6144 probes, 4886 determinate, 1258 not counted; passed
terrain fixture snapped-5-4: 6144 probes, 5038 determinate, 1106 not counted; passed
terrain fixture snapped-63-8: 6144 probes, 5235 determinate, 909 not counted; passed
terrain fixture snapped-8: 6144 probes, 4328 determinate, 1816 not counted; passed
terrain fixture ramps-FaceSouth@0.125: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceWest@0.125: 1404 probes, 1174 determinate, 230 not counted; passed
terrain fixture ramps-FaceSouth@0.125@sun-only: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@ambient-only: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@horizon: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@below-horizon: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@west-low: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@north-high: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125@dark-beside-default: 3192 probes, 3192 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@neither-effect: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@darkening-only: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@haze-only: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@both-short-range: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@black-under-haze: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@haze-no-light-beside-default: 9576 probes, 9576 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceNorth@0.25@black-under-haze: 12852 probes, 12852 determinate, 0 not counted; passed
terrain fixture spans-FaceSouth@0.125-control-reversed-overlap: 1008 probes, 1008 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-whole-cell-mask: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceWest@0.125-control-wrong-facing-light: 1404 probes, 1174 determinate, 230 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@neither-effect-haze-control-depth-reset: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture depth-stack-FaceSouth@0.25@both-short-range-control-wrong-composition-order: 4788 probes, 4788 determinate, 0 not counted; passed
terrain fixture matrix-FaceSouth-1.0@0.25-control-swapped-region-origins: 8664 probes, 8664 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-whole-atlas-clamping: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-normal-as-colour: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-half-texel-inset: 1596 probes, 1514 determinate, 82 not counted; passed
terrain fixture ramps-FaceSouth@0.125-control-wrong-map-region: 1596 probes, 1596 determinate, 0 not counted; passed
terrain fixture fog-over-known-FaceSouth@0.25-control-pick-through-fog: 1020 probes, 1020 determinate, 0 not counted; passed
terrain fixture spans-FaceSouth@0.125-control-pick-through-nearer: 1008 probes, 1008 determinate, 0 not counted; passed
terrain fixture pending-FaceSouth-control-loading-as-miss: 59856 probes, 59856 determinate, 0 not counted; passed
terrain fixture shape-5-FaceSouth@1.0-control-colour-holes-ignored: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture exact-boundary-0-FaceSouth-beside-ordinary-control-unbiased-index: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture exact-boundary-5-FaceSouth-beside-ordinary-control-unbiased-index: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture exact-boundary-15-FaceWest-beside-ordinary-control-unbiased-index: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture exact-boundary-9-FaceEast-beside-ordinary-control-unbiased-index: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture snapped-9-8-beside-ordinary-control-stale-bias-1e-4: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture snapped-5-4-beside-ordinary-control-stale-bias-1e-4: 7140 probes, 7140 determinate, 0 not counted; passed
terrain fixture roof-cut1-FaceWest@0.125-retained-released-while-pending: 1176 probes, 936 determinate, 240 not counted; passed
terrain fixture mixed-FaceSouth@0.25-released-while-pending: 2640 probes, 2640 determinate, 0 not counted; passed
```
