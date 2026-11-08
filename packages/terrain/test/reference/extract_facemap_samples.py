#!/usr/bin/env python3
"""Extract the reference-defect samples that Test.Terrain.Reference records (TRA-13, #655).

The terrain tests never read a PNG and never need a Synarchy checkout or the
network: the samples below are committed in test/Test/Terrain/Reference.hs. This
script is how they were obtained, kept so that anyone can reproduce them:

    python3 -I extract_facemap_samples.py /path/to/synarchy

It reads two blobs of the reference repository at its pinned revision
(read-only, through git, nothing is checked out or written), refuses any blob
whose Git object id is not the pinned one, decodes them with Pillow and prints
the samples in the form the Haskell module holds:

* the E mask's texel (48, 2), as RGBA;
* for each of the first eight columns of the N mask, the number of leading
  transparent rows (the first opaque row is that number) and the alpha of the
  first opaque texel.

The output is deterministic. Run it again and diff it against the module's
`eTexel` and `nColumns` to check the committed samples.
"""

import subprocess
import sys
from io import BytesIO

from PIL import Image

REVISION = "3777d437ea00e1302bf55162ad5693fee4879187"
BLOBS = {
    "assets/textures/facemap/isoface_slope_n.png": "effc21564c7a653605dcbafca23ce7bc560e262d",
    "assets/textures/facemap/isoface_slope_e.png": "5ed533b4d9467fa3b371a4cb489a87844fa64611",
}


def blob(repository: str, path: str) -> bytes:
    data = subprocess.run(
        ["git", "-C", repository, "cat-file", "blob", f"{REVISION}:{path}"],
        check=True,
        capture_output=True,
    ).stdout
    object_id = subprocess.run(
        ["git", "hash-object", "--stdin"], input=data, check=True, capture_output=True
    ).stdout.decode().strip()
    if object_id != BLOBS[path]:
        sys.exit(f"{path}: Git blob {object_id} is not the pinned {BLOBS[path]}")
    return data


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    repository = sys.argv[1]
    north = Image.open(BytesIO(blob(repository, "assets/textures/facemap/isoface_slope_n.png"))).convert("RGBA")
    east = Image.open(BytesIO(blob(repository, "assets/textures/facemap/isoface_slope_e.png"))).convert("RGBA")
    print("-- E texel (48, 2) as RGBA:")
    print(f"eTexel = {east.getpixel((48, 2))}")
    print("-- N columns 0..7: (column, leading transparent rows, alpha of the first opaque texel):")
    rows = []
    for column in range(8):
        alphas = [north.getpixel((column, row))[3] for row in range(north.size[1])]
        first = next(row for row, alpha in enumerate(alphas) if alpha != 0)
        assert all(alpha == 0 for alpha in alphas[:first])
        rows.append((column, first, alphas[first]))
    print("nColumns = " + repr(rows))


if __name__ == "__main__":
    main()
