#!/usr/bin/env bash
set -euo pipefail

NAME="deleted_file"
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

echo ">> Creating a file that will later be deleted"
sudo sh -c "echo 'SECRET FORENSIC PAYLOAD' > '$MNT_DIR/secret_deleted.txt'"
sync

echo ">> Deleting the file (journal will contain creation + deletion metadata)"
sudo rm "$MNT_DIR/secret_deleted.txt"
sync

echo ">> Creating a small extra file to show current live state"
sudo sh -c "echo 'I am still here' > '$MNT_DIR/still_here.txt'"
sync

echo ">> Creating a tiny PNG file"
# Real PNG signature + dummy payload + IEND chunk
sudo sh -c "printf '\x89PNG\r\n\x1a\nFAKEPNGDATA\x00\x00\x00\x00IEND\xaeB\x82' > '$MNT_DIR/testpng.png'"
sync

echo ">> Creating a file that will later be deleted"
sudo sh -c "echo 'SECRET FORENSIC PAYLOAD' > '$MNT_DIR/secret_deleted_at_end.txt'"
sync

echo ">> Deleting the file (journal will contain creation + deletion metadata)"
sudo rm "$MNT_DIR/secret_deleted_at_end.txt"
sync

echo ">> Cleanly unmounting"
sudo umount "$MNT_DIR"

echo ">> Done. Image created at $IMG_PATH"
