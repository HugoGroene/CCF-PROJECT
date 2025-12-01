#!/usr/bin/env bash
set -e

NAME="--NAME--"

# Figure out where this script lives (scripts/)
SCRIPT_DIR="$(pwd)"

# Output folder next to scripts/
OUTPUT_DIR="."

# Paths
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

# NORMAL OPERATION

# 100 MB test image.
dd if=/dev/zero of="$IMG_PATH" bs=1M count=--SIZE--

# create filesystem inside image file.
mkfs.ext4 -O ^has_journal -E lazy_itable_init=0,lazy_journal_init=0 "$IMG_PATH"

# Mount point inside output_images
mkdir -p "$MNT_DIR"

# Mount the filesystem using a loop device
sudo mount -o loop "$IMG_PATH" "$MNT_DIR"

echo ">> Creating fragmentation edge case..."

FRAGDIR="$MNT_DIR/fragtest"
mkdir -p "$FRAGDIR"

# Step 1: Fill disk with small files to fragment free space
echo ">> Generating scatter files..."
for i in $(seq 1 2000); do
    dd if=/dev/zero of="$FRAGDIR/junk_$i.bin" bs=4K count=1 &>/dev/null
done

# Step 2: Delete every 2nd file to create interleaved free blocks
echo ">> Deleting half to create holes..."
for i in $(seq 2 2 2000); do
    rm "$FRAGDIR/junk_$i.bin"
done

sync

# Step 3: Create a final file that must span scattered free blocks
echo ">> Creating fragmented target file..."
TARGET="$FRAGDIR/fragmented_file.bin"

# Write in many chunks so allocator constantly searches free space
for i in $(seq 1 300); do
    dd if=/dev/urandom bs=8K count=1 >> "$TARGET" 2>/dev/null
done

sync

# Optional: Verify fragmentation using debugfs (safe read-only)
echo ">> Checking extent map..."
sudo debugfs -R "stat $TARGET" "$IMG_PATH" | grep -E "EXTENTS|LEVEL"

# Clean Up
sudo umount "$MNT_DIR"

# Done
echo ">> Image created"