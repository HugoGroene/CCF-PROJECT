#!/usr/bin/env bash
set -euo pipefail

NAME="inode_stored_png"
SIZE_MB=100

OUTPUT_DIR="."
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

echo ">> Creating image: $IMG_PATH"
rm -f "$IMG_PATH"
dd if=/dev/zero of="$IMG_PATH" bs=1M count="$SIZE_MB"

echo ">> Making ext4 WITHOUT journal, WITH inline_data"
# -O inline_data: enable inline data feature
# ^has_journal: disable journaling
# -I 256: use 256-byte inodes (required for inline_data room)
mkfs.ext4 -O inline_data,^has_journal -I 256 -E lazy_itable_init=0 "$IMG_PATH"

echo ">> Preparing mountpoint"
sudo mkdir -p "$MNT_DIR"
if mountpoint -q "$MNT_DIR"; then
  echo "ERROR: $MNT_DIR is already mounted. Unmount it and retry." >&2
  exit 1
fi

echo ">> Mounting image"
if ! sudo mount -o loop "$IMG_PATH" "$MNT_DIR"; then
  echo "ERROR: mount failed. Check: dmesg | tail" >&2
  exit 1
fi

echo ">> Creating a tiny PNG file intended for inline storage"
# This is a minimal PNG header + tiny payload.
# PNG signature:
#   \x89 P N G \r \n \x1a \n
sudo sh -c "printf '\x89PNG\r\n\x1a\nHIDDEN_INLINE_PNG_PAYLOAD' > '$MNT_DIR/inline.png'"
sync

echo ">> Recording inode number of inline.png"
INODE=$(sudo ls -i "$MNT_DIR/inline.png" | awk '{print $1}')
echo "   inline.png inode: $INODE"
echo "$INODE" > "${OUTPUT_DIR}/${NAME}_inode.txt"

echo ">> Deleting inline.png (inline data remains inside inode until reused)"
sudo rm "$MNT_DIR/inline.png"
sync

echo ">> Cleanly unmounting"
sudo umount "$MNT_DIR"

echo ">> Done."
echo "   Image created        : $IMG_PATH"
echo "   Inline inode stored  : ${OUTPUT_DIR}/${NAME}_inode.txt"
echo "   Inspect with:"
echo "      sudo debugfs -R 'stat <$INODE>' $IMG_PATH"
echo "      sudo debugfs -R 'dump <$INODE> inode_png_dump.bin' $IMG_PATH"
