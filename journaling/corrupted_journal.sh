#!/usr/bin/env bash
set -euo pipefail

NAME="corrupted_journal"
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

echo ">> Creating some files to generate journal activity"
sudo sh -c "echo 'file one' > '$MNT_DIR/one.txt'"
sudo sh -c "echo 'file two' > '$MNT_DIR/two.txt'"
sync

echo ">> Creating a tiny PNG file"
# Real PNG signature + dummy payload + IEND chunk
sudo sh -c "printf '\x89PNG\r\n\x1a\nFAKEPNGDATA\x00\x00\x00\x00IEND\xaeB\x82' > '$MNT_DIR/testpng.png'"
sync

echo ">> Cleanly unmounting before corruption"
sudo umount "$MNT_DIR"

echo ">> Determining block size"
BLOCK_SIZE=$(sudo dumpe2fs -h "$IMG_PATH" 2>/dev/null | \
  awk -F: '/Block size:/ {gsub(/ /,"",$2); print $2}')
if [ -z "${BLOCK_SIZE:-}" ]; then
  echo "ERROR: Could not determine block size." >&2
  exit 1
fi
echo "   Block size: $BLOCK_SIZE"

echo ">> Locating first journal block via debugfs bmap (inode 8 is the journal)"
JBLK=$(sudo debugfs -R "bmap <8> 0" "$IMG_PATH" 2>/dev/null | tail -n 1 | tr -d ' ')
if ! [[ "$JBLK" =~ ^[0-9]+$ ]]; then
  echo "ERROR: debugfs did not return a numeric block for journal inode." >&2
  echo "       Try running: sudo debugfs -R \"bmap <8> 0\" \"$IMG_PATH\" manually." >&2
  exit 1
fi
echo "   First journal block (physical): $JBLK"

# To avoid the very first header block, nudge one block forward
CORRUPT_BLK=$((JBLK + 1))
echo "   Will corrupt journal block number: $CORRUPT_BLK"

echo ">> Corrupting one journal block with zeros"
sudo dd if=/dev/zero of="$IMG_PATH" bs="$BLOCK_SIZE" seek="$CORRUPT_BLK" count=1 conv=notrunc

echo ">> Done. Image created at $IMG_PATH (journal block $CORRUPT_BLK zeroed)"
