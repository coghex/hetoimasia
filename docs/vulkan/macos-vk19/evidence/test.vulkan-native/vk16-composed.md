# The VK-16 composed loop record

Verdict: **pass**.

## Two targets through the composed loop

- frames before the first window was hidden (first, second): (5,5)
- the hidden window's target was suspended: True
- frames while it was hidden (first, second): (0,3)
- frames the first presented once shown again: 1
- presentations made: 19; retired on their present fences: 19
- Vulkan calls: 352, on 1 thread(s)
- verdict issues: []
- error reports: 0
- seconds, from the loader integration to the verdict: 0.382954

## Transcript

```
## VK-16: two targets rendered through the composed loop, one suspended and resumed while the other presents
presented 19 frames; 19 presentations retired on their present fences
```
