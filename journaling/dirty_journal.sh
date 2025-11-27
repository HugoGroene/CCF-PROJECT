#!/usr/bin/env bash
set -euo pipefail

NAME="ext4_journal_dirty"
SIZE_MB=100

OUTPUT_DIR="."
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

echo ">> Creating image: $IMG_PATH"
rm -f "$IMG_PATH"
dd if=/dev/zero of="$IMG_PATH" bs=1M count="$SIZE_MB"

echo ">> Making ext4 with journal"
mkfs.ext4 -O has_journal -E lazy_itable_init=0,lazy_journal_init=0 "$IMG_PATH"

echo ">> Preparing mountpoint"
sudo mkdir -p "$MNT_DIR"
if mountpoint -q "$MNT_DIR"; then
  echo "ERROR: $MNT_DIR is already mounted. Unmount it and retry." >&2
  exit 1
fi

echo ">> Mounting image"
sudo mount -o loop "$IMG_PATH" "$MNT_DIR"

echo ">> Creating some normal files (journal activity)"
sudo sh -c "echo 'This is a committed file' > '$MNT_DIR/committed.txt'"
sudo sh -c "mkdir -p '$MNT_DIR/subdir'"
sudo sh -c "echo 'Another file' > '$MNT_DIR/subdir/another.txt'"
sync

echo ">> Cleanly unmounting"
sudo umount "$MNT_DIR"

echo ">> Marking filesystem as NEEDS RECOVERY (dirty journal flag)"
sudo tune2fs -E force_recovery "$IMG_PATH"

echo ">> Done. Image created at $IMG_PATH"
