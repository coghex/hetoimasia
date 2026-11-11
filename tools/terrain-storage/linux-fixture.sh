#!/bin/sh
# The Linux fixture of the terrain storage probe (TRA-21): one capped, disposable ext4 volume.
#
#   tools/terrain-storage/linux-fixture.sh up   <scratch-directory>
#   tools/terrain-storage/linux-fixture.sh down <scratch-directory>
#
# Run it in a Linux host or guest that is not the owner's ordinary machine (the owner's Linux probe
# VM, never a host mount: the scratch directory must be local storage). `up` makes a sparse 3 GiB
# image file in the scratch directory, formats it ext4 (no privilege needed to format a file),
# loop-mounts it at a mount point inside the scratch directory, gives the mount to the running user
# and writes the pointer file the probe reads. The mount and the ownership change are the only steps
# that run as root, through sudo, and `down` unmounts it and removes exactly the files `up` made. The
# probe itself runs no privileged operation and verifies the result (a distinct device, owned by the
# running user, within the declared cap) before it consumes any space.
set -eu
action=${1:?usage: linux-fixture.sh up|down <scratch-directory>}
scratch=${2:?usage: linux-fixture.sh up|down <scratch-directory>}
image=$scratch/terrain-storage-probe.img
mount_point=$scratch/mnt
cache=${XDG_CACHE_HOME:-$HOME/.cache}
pointer=$cache/hetoimasia/terrain-storage-probe/fixture
case $action in
  up)
    [ ! -e "$image" ] || { echo "refusing: $image exists" >&2; exit 1; }
    mkdir -p "$scratch" "$mount_point" "$cache/hetoimasia/terrain-storage-probe"
    truncate -s 3G "$image"
    mkfs.ext4 -q -F "$image"
    sudo mount -o loop "$image" "$mount_point"
    sudo chown "$(id -u):$(id -g)" "$mount_point"
    printf '%s\n' "$mount_point" > "$pointer"
    df -hT "$mount_point"
    ;;
  down)
    sudo umount "$mount_point"
    rm -f "$image"
    rm -f "$pointer"
    rmdir "$mount_point"
    ;;
  *) echo "usage: linux-fixture.sh up|down <scratch-directory>" >&2; exit 2 ;;
esac
