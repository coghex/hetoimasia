#!/bin/sh
# The macOS fixture of the terrain storage probe (TRA-21): one capped, disposable APFS volume.
#
#   tools/terrain-storage/macos-fixture.sh up   <scratch-directory>
#   tools/terrain-storage/macos-fixture.sh down <scratch-directory>
#
# `up` makes a 3 GiB sparse disk image inside the scratch directory, attaches it (not browsable, at a
# mount point inside the scratch directory) and writes the pointer file the probe reads. It needs no
# privilege and no one at the keyboard. `down` detaches it and removes exactly the files `up` made.
# The probe verifies the result itself (a distinct device, owned by the running user, within the
# declared cap) before it consumes any space. One image at a time: `up` refuses if one exists.
set -eu
action=${1:?usage: macos-fixture.sh up|down <scratch-directory>}
scratch=${2:?usage: macos-fixture.sh up|down <scratch-directory>}
image=$scratch/terrain-storage-probe.sparseimage
mount_point=$scratch/mnt
cache=${XDG_CACHE_HOME:-$HOME/.cache}
pointer=$cache/hetoimasia/terrain-storage-probe/fixture
case $action in
  up)
    [ ! -e "$image" ] || { echo "refusing: $image exists" >&2; exit 1; }
    mkdir -p "$scratch" "$mount_point" "$cache/hetoimasia/terrain-storage-probe"
    hdiutil create -type SPARSE -fs APFS -size 3g -volname HetTerrainProbe "$image"
    hdiutil attach -nobrowse -mountpoint "$mount_point" "$image"
    printf '%s\n' "$mount_point" > "$pointer"
    df -k "$mount_point"
    ;;
  down)
    hdiutil detach "$mount_point"
    rm -f "$image"
    rm -f "$pointer"
    rmdir "$mount_point"
    ;;
  *) echo "usage: macos-fixture.sh up|down <scratch-directory>" >&2; exit 2 ;;
esac
