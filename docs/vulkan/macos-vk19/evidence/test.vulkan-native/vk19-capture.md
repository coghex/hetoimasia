# The VK-19 consumer pipeline and capture record

Verdict: **pass**.

## A consumer-built triangle captured from two targets

- AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255); generations (usage, clipped): [(17,False)]
- AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255); generations (usage, clipped): [(17,False)]
- expected (red, green, blue, alpha) within 6: background (0,0,255,255), triangle (255,188,0,255)
- Vulkan calls: 134, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.258935

## Transcript

```
## VK-19: a consumer-built triangle captured from two targets through the production host
AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255)
AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (0,0,255,255), triangle Just (255,188,0,255)
```
