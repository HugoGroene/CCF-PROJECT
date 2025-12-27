#!/usr/bin/env bash
set -euo pipefail

NAME="inode_stored"
SIZE_MB=100

OUTPUT_DIR="."
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

echo ">> Creating image: $IMG_PATH"
rm -f "$IMG_PATH"
dd if=/dev/zero of="$IMG_PATH" bs=1M count="$SIZE_MB"

echo ">> Making ext4 WITHOUT journal, WITH inline_data"
# -O inline_data enables inline-data feature
# ^has_journal disables journaling
# -I 256 ensures 256-byte inodes (needed for inline_data)
mkfs.ext4 -O inline_data,^has_journal -I 256 -E lazy_itable_init=0 "$IMG_PATH"

echo ">> Preparing mountpoint"
sudo mkdir -p "$MNT_DIR"
if mountpoint -q "$MNT_DIR"; then
  echo "ERROR: $MNT_DIR is already mounted. Unmount it and retry." >&2
  exit 1
fi

echo ">> Mounting image"
if ! sudo mount -o loop "$IMG_PATH" "$MNT_DIR"; then
  echo "ERROR: mount failed. Your kernel might not support ext4 inline_data," >&2
  echo "       or there is another issue. Check: dmesg | tail" >&2
  exit 1
fi

echo ">> Creating a very small file that should be stored inline"
sudo sh -c "printf 'INLINE_INODE_PAYLOAD_123' > '$MNT_DIR/inline.txt'"
sync

echo ">> Recording inode number of inline.txt for later analysis"
INODE=$(sudo ls -i "$MNT_DIR/inline.txt" | awk '{print $1}')
echo "   inline.txt inode: $INODE"
echo "$INODE" > "${OUTPUT_DIR}/${NAME}_inode.txt"

echo ">> Deleting inline.txt (inode data likely remains until reused)"
sudo rm "$MNT_DIR/inline.txt"
sync

echo ">> Cleanly unmounting"
sudo umount "$MNT_DIR"

echo ">> Done."
echo "   Image              : $IMG_PATH"
echo "   Inline inode id in : ${OUTPUT_DIR}/${NAME}_inode.txt"
echo "   Example inspection : sudo debugfs -R 'stat <$INODE>' '$IMG_PATH'"
