#!/usr/bin/env bash
set -euo pipefail

NAME="ext4_journal_corrupt"
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

echo ">> Cleanly unmounting before corruption"
sudo umount "$MNT_DIR"

echo ">> Determining block size"
BLOCK_SIZE=$(sudo dumpe2fs -h "$IMG_PATH" 2>/dev/null | awk -F: '/Block size:/ {gsub(/ /,\"\",$2); print $2}')
echo "   Block size: $BLOCK_SIZE"

echo ">> Locating a journal data block (using inode 8)"
JBLK=$(sudo debugfs -R "stat <8>" "$IMG_PATH" 2>/dev/null | \
  awk '
    /BLOCKS:/ { inblocks=1; next }
    inblocks && NF {
      # Extract the first numeric block id on this line
      for (i=1;i<=NF;i++) {
        gsub(/\(|\)|:[0-9]+/,"",$i);
        if ($i ~ /^[0-9]+$/) {
          print $i;
          exit;
        }
      }
    }
  ')

if [ -z "${JBLK:-}" ]; then
  echo "ERROR: Could not determine a journal block from debugfs output." >&2
  exit 1
fi

echo "   Will corrupt journal block number: $JBLK"

echo ">> Corrupting one journal block with zeros"
sudo dd if=/dev/zero of="$IMG_PATH" bs="$BLOCK_SIZE" seek="$JBLK" count=1 conv=notrunc

echo ">> Done. Image created at $IMG_PATH (journal block $JBLK zeroed)"
