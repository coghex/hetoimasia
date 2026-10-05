# hetoimasia-asset

The core every Hetoimasia codec package builds on: an asset's identity and
provenance, the decoded-asset types, and the decoder interface. It holds no
codec. Codecs live one package per kind — images in
[`hetoimasia-asset-image`](../asset-image/README.md) — so a program depends
on this core and only the codec packages it needs
([asset design](../../docs/designs/asset_design.md), D-1).

| Module | Contents |
| --- | --- |
| `Hetoimasia.Asset` | `AssetId`, `Provenance` (`FromFile`, `FromMemory`), `Asset`; `Decoder` (`runDecoder`) and `AssetRefusal` (`refusedAsset`, `refusalReason`) |
| `Hetoimasia.Asset.Image` | `ImageKind` (`ColourImage`, `DataImage`), `TexelFormat` (`TexelRgba8Srgb`, `TexelRgba8Linear`), `DecodedImage` |

## Boundary

The library depends on `base`, `bytestring`, `deepseq` and `text`, and on no
GPU, GLFW, render or runtime package. It runs in the CPU project
(`cabal.project.cpu`).

## Decoding

A decoder is a pure function from an asset and its bytes to the decoded value,
or to an `AssetRefusal` naming the asset and the reason:

```haskell
newtype Decoder a = Decoder { runDecoder ∷ Asset → ByteString → Either AssetRefusal a }
```

The caller reads the bytes and supplies the identity (`AssetId`, whatever key
its catalogue uses) and the provenance (the file, or a description of where
in-memory bytes came from). The same asset and bytes always give the same
result, no exception escapes a decoder, and a refusal never comes with a
partial value.

## Decoded images

A `DecodedImage` is shaped for the GPU upload endpoint (#342), with no
conversion layer between them: its format, its width and height as `Word32`,
its levels as the endpoint's `UploadImage` takes them — every mip level, base
level first, each a strict `ByteString` tightly packed in the format's blocks,
rows top row first with no padding — and its cutout mark. A consumer passes
`decodedLevels` to the endpoint unchanged and maps only the format:

| `TexelFormat` | Endpoint `ImageFormat` | Texels |
| --- | --- | --- |
| `TexelRgba8Srgb` | `Rgba8Srgb` | R, G, B, A bytes; colour sRGB-encoded and premultiplied in linear light |
| `TexelRgba8Linear` | `Rgba8Linear` | R, G, B, A bytes; linear UNORM, not premultiplied |

This package does not import `hetoimasia-gpu-vulkan-native`, which builds only
through `cabal.project.vulkan`, so the mapping is the consumer's.

`decodedBinaryAlpha` is true exactly when every texel of level 0 has alpha 0
or 255. The 2D renderer takes it as a texture's default cutout mark (design
D-5, D-10).

## Owned state, threads and lifetimes

None. Every value here is immutable data; nothing is acquired, started,
retained or released. A decoded image's bytes are the caller's to keep or drop.
