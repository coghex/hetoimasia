# The VK-17 required profile record, two frame slots

Verdict: **pass**.

## The triangle sample in two windows, with 2 frame slot(s)

- both windows, first, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- both windows, second, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window, resized, AttachmentId (WindowId 1) 1: captured SurfaceExtent {extentWidth = 400, extentHeight = 300} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the second window, after the first closed, AttachmentId (WindowId 2) 2: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
- the first window was resized from SurfaceExtent {extentWidth = 320, extentHeight = 240}
- the first window's target had retired before the second's last capture: True
- generations seen (usage, clipped): [(17,False)]
- color formats the sample built pipelines for: [50]
- expected (red, green, blue, alpha) within 6: background (63,63,124,255), triangle (243,203,89,255)
- Vulkan calls: 192, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.300462

## Transcript

```
## VK-17: the triangle sample in two windows, resized and closed, with 2 frame slot(s)
both windows, first: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
both windows, second: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the first window, resized: captured SurfaceExtent {extentWidth = 400, extentHeight = 300} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
the second window, after the first closed: captured SurfaceExtent {extentWidth = 320, extentHeight = 240} in format 50; background Just (63,63,124,255), triangle Just (243,203,89,255)
```
