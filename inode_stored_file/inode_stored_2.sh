#!/usr/bin/env bash
set -euo pipefail

NAME="inode_stored_2"
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

echo ">> Creating a larger file that should NOT be stored inline (and will NOT be deleted)"
# 64 KiB file -> definitely too big for inline data
sudo dd if=/dev/zero of="$MNT_DIR/noninline.bin" bs=4096 count=16 status=none
sync

echo ">> Recording inode number of noninline.bin for later analysis"
NONINLINE_INODE=$(sudo ls -i "$MNT_DIR/noninline.bin" | awk '{print $1}')
echo "   noninline.bin inode: $NONINLINE_INODE"
echo "$NONINLINE_INODE" > "${OUTPUT_DIR}/${NAME}_noninline_inode.txt"

echo ">> Creating a very small file that SHOULD be stored inline (will be deleted)"
# Keep it small (< 60 bytes) so it fits comfortably into inline data
sudo sh -c "printf 'INLINE_INODE_PAYLOAD_123' > '$MNT_DIR/inline.txt'"
sync

echo ">> Recording inode number of inline.txt for later analysis"
INLINE_INODE=$(sudo ls -i "$MNT_DIR/inline.txt" | awk '{print $1}')
echo "   inline.txt inode: $INLINE_INODE"
echo "$INLINE_INODE" > "${OUTPUT_DIR}/${NAME}_inline_inode.txt"

echo ">> Deleting inline.txt (inline data likely remains until inode is reused)"
sudo rm "$MNT_DIR/inline.txt"
sync

echo ">> Cleanly unmounting"
sudo umount "$MNT_DIR"

echo ">> Done."
echo "   Image                  : $IMG_PATH"
echo "   Inline inode id file   : ${OUTPUT_DIR}/${NAME}_inline_inode.txt"
echo "   Non-inline inode id    : ${OUTPUT_DIR}/${NAME}_noninline_inode.txt"
echo "   Example inspections:"
echo "     sudo debugfs -R 'stat <$(cat ${OUTPUT_DIR}/${NAME}_inline_inode.txt)>'  $IMG_PATH"
echo "     sudo debugfs -R 'stat <$(cat ${OUTPUT_DIR}/${NAME}_noninline_inode.txt)>' $IMG_PATH"
