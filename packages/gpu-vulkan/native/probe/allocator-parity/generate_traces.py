#!/usr/bin/env python3
"""Regenerate the allocator parity probe's committed traces.

    python3 generate_traces.py --synarchy ~/work/synarchy \
        --revision 9a274311de7596fc971008eb90a3e67eb83fe004 --output traces

Every trace is deterministic: the synthetic ones depend on their seed alone, and
the Synarchy ones on their seed and the PNG headers under `assets/` at the given
Synarchy revision, which they record. The assets are read from that revision
through `git archive`, so the checkout's own state does not matter. Randomness comes from the splitmix64
generator below rather than Python's `random`, whose algorithms may change
between Python versions. Nothing reads Synarchy at build or test time; this
script is run by hand and its output is committed. README.md beside it states
the trace format, the replay protocol and each trace's derivation.
"""

import argparse
import io
import os
import struct
import subprocess
import sys
import tarfile
import tempfile

MIB = 1024 * 1024
KIB = 1024
MASK = (1 << 64) - 1


class SplitMix64:
    """The splitmix64 generator: a 64-bit state advanced by a fixed odd constant
    and mixed. Stable, tiny, and reproducible in any language."""

    def __init__(self, seed):
        self.state = seed & MASK

    def next(self):
        self.state = (self.state + 0x9E3779B97F4A7C15) & MASK
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
        return z ^ (z >> 31)

    def below(self, bound):
        """A value in [0, bound), by rejection so it is unbiased."""
        limit = MASK - (MASK + 1) % bound
        while True:
            value = self.next()
            if value <= limit:
                return value % bound

    def between(self, low, high):
        """A value in [low, high]."""
        return low + self.below(high - low + 1)

    def chance(self, numerator, denominator):
        return self.below(denominator) < numerator

    def choice(self, items):
        return items[self.below(len(items))]

    def log_uniform(self, low, high):
        """A value in [low, high] whose logarithm is uniform, built from an
        integer exponent step and an integer mantissa so no float is involved."""
        # Octaves between low and high, then a uniform value within the octave.
        octaves = []
        edge = low
        while edge < high:
            octaves.append((edge, min(edge * 2, high)))
            edge *= 2
        lo, hi = self.choice(octaves)
        return self.between(lo, hi)


class Trace:
    """A trace being written: allocation identities are issued densely from
    zero, and the generator's own view of what is live drives its decisions,
    never either implementation's outcome."""

    def __init__(self, name, capacity, seed, notes):
        self.name = name
        self.capacity = capacity
        self.seed = seed
        self.notes = notes
        self.lines = []
        self.next_id = 0
        self.live = {}
        self.live_bytes = 0

    def allocate(self, size, alignment):
        identity = self.next_id
        self.next_id += 1
        self.lines.append(f"a {identity} {size} {alignment}")
        self.live[identity] = size
        self.live_bytes += size
        return identity

    def free(self, identity):
        self.lines.append(f"f {identity}")
        self.live_bytes -= self.live.pop(identity)

    def checkpoint(self, label):
        self.lines.append(f"c {label}")

    def write(self, directory):
        path = os.path.join(directory, f"{self.name}.trace")
        with open(path, "w", encoding="ascii", newline="\n") as handle:
            handle.write("# hetoimasia allocator parity trace, format 1; see README.md\n")
            for note in self.notes:
                handle.write(f"# {note}\n")
            handle.write(f"trace {self.name}\n")
            handle.write(f"capacity {self.capacity}\n")
            handle.write(f"seed {self.seed}\n")
            for line in self.lines:
                handle.write(line + "\n")
        allocations = sum(1 for line in self.lines if line.startswith("a "))
        frees = sum(1 for line in self.lines if line.startswith("f "))
        checkpoints = sum(1 for line in self.lines if line.startswith("c "))
        print(f"{path}: {allocations} allocations, {frees} frees, {checkpoints} checkpoints")


# ---------------------------------------------------------------------------
# The Synarchy sheet trace

SHEET_MAXIMUM = 16 * MIB
SHEET_MINIMUM = 1 * MIB
PACKING = (4, 5)  # image bytes fill at most 4/5 of a sheet
SHEET_ALIGNMENT = 64 * KIB


def png_bytes(path):
    """An image's size decoded to RGBA8, from its IHDR chunk alone."""
    with open(path, "rb") as handle:
        header = handle.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise SystemExit(f"{path} is not a PNG with a leading IHDR chunk")
    width, height = struct.unpack(">II", header[16:24])
    return width * height * 4


def atlas_family(relative_directory):
    """Units are atlased and streamed per unit type; everything else is
    atlased per top-level texture category and stays resident."""
    parts = relative_directory.split("/")
    if len(parts) >= 3 and parts[0] == "textures" and parts[1] == "units":
        return ("streamed", "/".join(parts[:3]))
    if len(parts) >= 2 and parts[0] == "textures":
        return ("resident", "/".join(parts[:2]))
    return ("resident", parts[0])


def sheet_size(content):
    """The smallest power-of-two sheet, between 1 and 16 MiB, whose packed
    four-fifths holds the content."""
    size = SHEET_MINIMUM
    while size * PACKING[0] < content * PACKING[1]:
        size *= 2
    if size > SHEET_MAXIMUM:
        raise AssertionError("a sheet's content exceeds the largest sheet")
    return size


def pack(images):
    """Pack images, largest first, into sheets of at most 16 MiB, first fit."""
    budget = SHEET_MAXIMUM * PACKING[0] // PACKING[1]
    sheets = []
    for image in sorted(images, reverse=True):
        for index, content in enumerate(sheets):
            if content + image <= budget:
                sheets[index] += image
                break
        else:
            sheets.append(image)
    return [sheet_size(content) for content in sheets]


def synarchy_families(checkout):
    assets = os.path.join(checkout, "assets")
    families = {}
    count = 0
    total = 0
    for root, directories, files in os.walk(assets):
        directories.sort()
        for name in sorted(files):
            if not name.lower().endswith(".png"):
                continue
            size = png_bytes(os.path.join(root, name))
            relative = os.path.relpath(root, assets).replace(os.sep, "/")
            families.setdefault(atlas_family(relative), []).append(size)
            count += 1
            total += size
    return families, count, total


class SynarchyAssets:
    """Synarchy's assets at one revision, extracted once into a temporary
    directory."""

    def __init__(self, checkout, revision):
        self.revision = subprocess.run(
            ["git", "-C", checkout, "rev-parse", "--verify", f"{revision}^{{commit}}"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()
        self.directory = tempfile.TemporaryDirectory(prefix="synarchy-assets-")
        archive = subprocess.run(
            ["git", "-C", checkout, "archive", "--format=tar", self.revision, "assets"],
            check=True, capture_output=True,
        ).stdout
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            tar.extractall(self.directory.name, filter="data")
        self.families = synarchy_families(self.directory.name)


def synarchy_trace(assets, name="synarchy-sheets", streaming_tenths=7, retire=(1, 3), budget_mib=200,
                   variant=None):
    """The Synarchy sheet trace. The defaults are the gated trace; the churn
    sweep varies one invented churn parameter at a time and says which in its
    header, leaving the sizes, the seed and every other parameter alone."""
    revision = assets.revision
    families, count, total = assets.families
    resident = []
    streamed = []
    for (kind, family), images in sorted(families.items()):
        sheets = pack(images)
        (resident if kind == "resident" else streamed).append((family, sheets))
    sheet_count = sum(len(sheets) for _, sheets in resident + streamed)
    sheet_bytes = sum(sum(sheets) for _, sheets in resident + streamed)

    capacity = 256 * MIB
    streaming_budget = budget_mib * MIB
    seed = 331
    rng = SplitMix64(seed)
    notes = [
        f"Derived from Synarchy {revision}: {count} PNGs under assets/, {total} bytes as RGBA8,",
        f"packed into {sheet_count} sheets totalling {sheet_bytes} bytes; {len(streamed)} streamed unit families.",
        "Every sheet is an optimally tiled image aligned to 64 KiB.",
    ]
    if variant is not None:
        notes.append(f"Churn sensitivity variant, hypothetical: {variant}; every other parameter as synarchy-sheets.")
    trace = Trace(name, capacity, seed, notes)

    for _, sheets in resident:
        for size in sheets:
            trace.allocate(size, SHEET_ALIGNMENT)

    loaded = {}  # family index -> live sheet identities

    def family_bytes(index):
        return sum(streamed[index][1])

    def streamed_live():
        return sum(trace.live[i] for ids in loaded.values() for i in ids)

    def load(index):
        loaded[index] = [trace.allocate(size, SHEET_ALIGNMENT) for size in streamed[index][1]]

    def unload(index):
        for identity in loaded.pop(index):
            trace.free(identity)

    # Load unit families in a seeded order until the streaming budget is met.
    order = list(range(len(streamed)))
    for position in range(len(order) - 1, 0, -1):
        other = rng.below(position + 1)
        order[position], order[other] = order[other], order[position]
    for index in order:
        if streamed_live() + family_bytes(index) <= streaming_budget:
            load(index)
    trace.checkpoint("after-load")

    pending = []  # (step to free at, identity) for hot-reloaded sheets
    steps = 1500
    for step in range(1, steps + 1):
        for due, identity in [p for p in pending if p[0] <= step]:
            pending.remove((due, identity))
            trace.free(identity)
        if rng.chance(streaming_tenths, 10):
            # Streaming: unload a random family, then load random unloaded
            # families while the budget allows.
            if loaded:
                unload(rng.choice(sorted(loaded)))
            candidates = [i for i in range(len(streamed)) if i not in loaded]
            while candidates:
                index = rng.choice(candidates)
                candidates.remove(index)
                if streamed_live() + family_bytes(index) <= streaming_budget:
                    load(index)
        else:
            # Hot reload: a new version of one live sheet is placed before the
            # old one retires, one to three steps later.
            owners = [(f, n) for f, ids in sorted(loaded.items()) for n in range(len(ids))]
            if owners:
                family, slot = rng.choice(owners)
                old = loaded[family][slot]
                loaded[family][slot] = trace.allocate(trace.live[old], SHEET_ALIGNMENT)
                # The old sheet is no longer the family's; it is freed when due.
                pending.append((step + rng.between(*retire), old))
        if step % 100 == 0:
            trace.checkpoint(f"churn-{step}")

    for _, identity in sorted(pending):
        trace.free(identity)
    for index in sorted(loaded):
        unload(index)
    trace.checkpoint("residents-only")
    return trace


# ---------------------------------------------------------------------------
# Synthetic traces of many small allocations

BUFFER_ALIGNMENTS = [16, 64, 256]


def small_size(rng, low, high):
    """A buffer size, log-uniform, rounded up to 16 bytes."""
    return (rng.log_uniform(low, high) + 15) // 16 * 16


def free_random(rng, trace):
    trace.free(rng.choice(sorted(trace.live)))


def small_steady():
    """Steady churn of vertex, index and uniform buffers around a live target
    near the block's capacity."""
    seed = 1
    rng = SplitMix64(seed)
    capacity = 16 * MIB
    target = 14 * MIB
    trace = Trace("small-steady", capacity, seed, [
        "Synthetic: 256 B to 256 KiB buffers, log-uniform, alignments 16, 64 or 256;",
        "allocations and frees alternate around a live target of 14 MiB in a 16 MiB block.",
    ])
    operations = 20000
    for operation in range(1, operations + 1):
        allocate = not trace.live or rng.chance(3 if trace.live_bytes < target else 1, 4)
        if allocate:
            trace.allocate(small_size(rng, 256, 256 * KIB), rng.choice(BUFFER_ALIGNMENTS))
        else:
            free_random(rng, trace)
        if operation % 2000 == 0:
            trace.checkpoint(f"op-{operation}")
    return trace


def small_bursty():
    """Level loads and unloads: bursts of allocation, churn, then most of the
    level freed at once."""
    seed = 2
    rng = SplitMix64(seed)
    capacity = 32 * MIB
    trace = Trace("small-bursty", capacity, seed, [
        "Synthetic: five levels, each a burst of 1,500 buffers of 256 B to 128 KiB, 2,000 churn",
        "operations, then 70% of the live buffers freed; alignments 16, 64 or 256; 32 MiB block.",
    ])
    for level in range(1, 6):
        for _ in range(1500):
            trace.allocate(small_size(rng, 256, 128 * KIB), rng.choice(BUFFER_ALIGNMENTS))
        trace.checkpoint(f"level-{level}-loaded")
        for _ in range(2000):
            if trace.live and rng.chance(1, 2):
                free_random(rng, trace)
            else:
                trace.allocate(small_size(rng, 256, 128 * KIB), rng.choice(BUFFER_ALIGNMENTS))
        trace.checkpoint(f"level-{level}-churned")
        for _ in range(len(trace.live) * 7 // 10):
            free_random(rng, trace)
        trace.checkpoint(f"level-{level}-unloaded")
    return trace


def small_mixed():
    """Mostly small buffers with occasional meshes of up to 4 MiB, at a demand
    above the block's capacity, so both allocators refuse."""
    seed = 3
    rng = SplitMix64(seed)
    capacity = 64 * MIB
    target = 60 * MIB
    trace = Trace("small-mixed", capacity, seed, [
        "Synthetic: nine in ten allocations 256 B to 64 KiB, one in ten 256 KiB to 4 MiB;",
        "alignments 16, 64 or 256; churn around a 60 MiB live target in a 64 MiB block.",
    ])
    operations = 20000
    for operation in range(1, operations + 1):
        allocate = not trace.live or rng.chance(3 if trace.live_bytes < target else 1, 4)
        if allocate:
            if rng.chance(1, 10):
                size = small_size(rng, 256 * KIB, 4 * MIB)
            else:
                size = small_size(rng, 256, 64 * KIB)
            trace.allocate(size, rng.choice(BUFFER_ALIGNMENTS))
        else:
            free_random(rng, trace)
        if operation % 2000 == 0:
            trace.checkpoint(f"op-{operation}")
    return trace


# ---------------------------------------------------------------------------
# Diagnostic traces: the churn sensitivity sweep and the occupancy sweep

def churn_sweep(assets):
    """One invented churn parameter of the Synarchy trace varied at a time."""
    return [
        synarchy_trace(assets, "churn-retire-1", retire=(1, 1),
                       variant="old sheets retire exactly one step after their replacement (default 1-3)"),
        synarchy_trace(assets, "churn-retire-8-16", retire=(8, 16),
                       variant="old sheets retire 8-16 steps after their replacement (default 1-3)"),
        synarchy_trace(assets, "churn-reload-0", streaming_tenths=10,
                       variant="no hot reload, every step streams (default 30% hot reload)"),
        synarchy_trace(assets, "churn-reload-70", streaming_tenths=3,
                       variant="70% of steps hot-reload a sheet (default 30%)"),
        synarchy_trace(assets, "churn-budget-150", budget_mib=150,
                       variant="a 150 MiB streaming budget in the 256 MiB block (default 200 MiB)"),
        synarchy_trace(assets, "churn-budget-240", budget_mib=240,
                       variant="a 240 MiB streaming budget in the 256 MiB block (default 200 MiB)"),
    ]


def occupancy_sweep():
    """Steady small-buffer churn at a fixed live count and block occupancy: the
    block is sized so the initial live bytes fill the given share of it, then
    5,000 steps each free a random live buffer and allocate a new one."""
    traces = []
    for index, (live, occupancy) in enumerate(
        (live, occupancy) for live in (100, 1000, 10000) for occupancy in (50, 75, 95)
    ):
        seed = 1000 + index
        rng = SplitMix64(seed)
        requests = [(small_size(rng, 256, 64 * KIB), rng.choice(BUFFER_ALIGNMENTS)) for _ in range(live)]
        filled = sum(size for size, _ in requests)
        capacity = -(-filled * 100 // occupancy // (64 * KIB)) * (64 * KIB)
        trace = Trace(f"sweep-live-{live:05d}-occupancy-{occupancy}", capacity, seed, [
            f"Synthetic, hypothetical: {live} live buffers of 256 B to 64 KiB, log-uniform, alignments 16, 64 or 256,",
            f"filling {occupancy}% of the block, then 5,000 steps of one random free and one allocation.",
        ])
        for size, alignment in requests:
            trace.allocate(size, alignment)
        trace.checkpoint("filled")
        for step in range(1, 5001):
            free_random(rng, trace)
            trace.allocate(small_size(rng, 256, 64 * KIB), rng.choice(BUFFER_ALIGNMENTS))
            if step % 500 == 0:
                trace.checkpoint(f"step-{step}")
        traces.append(trace)
    return traces


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--synarchy", required=True, help="a Synarchy checkout")
    parser.add_argument("--revision", required=True, help="the Synarchy revision whose assets are read")
    parser.add_argument("--output", required=True, help="the directory the traces are written to")
    arguments = parser.parse_args()
    os.makedirs(arguments.output, exist_ok=True)
    assets = SynarchyAssets(arguments.synarchy, arguments.revision)
    for trace in [synarchy_trace(assets), small_steady(), small_bursty(), small_mixed()]:
        trace.write(arguments.output)
    for directory, traces in [("churn", churn_sweep(assets)), ("sweep", occupancy_sweep())]:
        os.makedirs(os.path.join(arguments.output, directory), exist_ok=True)
        for trace in traces:
            trace.write(os.path.join(arguments.output, directory))
    return 0


if __name__ == "__main__":
    sys.exit(main())
