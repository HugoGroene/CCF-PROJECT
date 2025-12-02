#!/usr/bin/env bash
set -euo pipefail

NAME="ext4_corrupt_dirty"
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
BLOCK_SIZE=$(sudo dumpe2fs -h "$IMG_PATH" 2>/dev/null | awk -F: '/Block size:/ {gsub(/ /,"",$2); print $2}')
if [ -z "${BLOCK_SIZE:-}" ]; then
  echo "ERROR: Could not determine block size." >&2
  exit 1
fi
echo "   Block size: $BLOCK_SIZE"

echo ">> Locating a journal data block (inode 8 is the journal)"
JBLK=$(sudo debugfs -R "stat <8>" "$IMG_PATH" 2>/dev/null | awk '
  $1 == "EXTENTS:" {mode="extents"; next}
  mode=="extents" {
    # find first start-end extent like "12345-12400"
    for (i=1;i<=NF;i++) {
      if ($i ~ /^[0-9]+-[0-9]+$/) {
        split($i,a,"-");
        print a[1];
        exit;
      }
    }
  }
  $1 == "BLOCKS:" {mode="blocks"; next}
  mode=="blocks" {
    # older style "BLOCKS:" listing: first numeric is fine
    for (i=1;i<=NF;i++) {
      gsub(/[(),]/,"",$i);
      if ($i ~ /^[0-9]+$/) {
        print $i;
        exit;
      }
    }
  }
')

if [ -z "${JBLK:-}" ]; then
  echo "ERROR: Could not determine a journal block from debugfs output." >&2
  echo "       Try running: sudo debugfs -R \"stat <8>\" \"$IMG_PATH\" manually."
  exit 1
fi

# To avoid the very first header block, nudge one block forward
CORRUPT_BLK=$((JBLK + 1))
echo "   Will corrupt journal block number: $CORRUPT_BLK"

echo ">> Corrupting one journal block with zeros"
sudo dd if=/dev/zero of="$IMG_PATH" bs="$BLOCK_SIZE" seek="$CORRUPT_BLK" count=1 conv=notrunc

echo ">> Marking filesystem as NEEDS RECOVERY (dirty journal flag)"
sudo tune2fs -E force_recovery "$IMG_PATH"

echo ">> Done. Image created at $IMG_PATH (journal block $CORRUPT_BLK zeroed)"
