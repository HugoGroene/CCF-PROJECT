#!/usr/bin/env bash
set -e

NAME="fragmented"

# Figure out where this script lives (scripts/)
SCRIPT_DIR="$(pwd)"

# Output folder next to scripts/
OUTPUT_DIR="../output"

# Paths
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

# NORMAL OPERATION

# 10 MB test image.
dd if=/dev/zero of="$IMG_PATH" bs=1M count=30

# create filesystem inside image file.
mkfs.ext4 -O ^has_journal -E lazy_itable_init=0,lazy_journal_init=0 "$IMG_PATH"

# Mount point inside output_images
mkdir -p "$MNT_DIR"

# Mount the filesystem using a loop device
sudo mount -o loop "$IMG_PATH" "$MNT_DIR"

# The test
REALFILE="/home/kali/Desktop/CCF proj/F-15C DCS Flaming Cliffs Flight Manual EN.pdf" #paste here the file to copy over to test on
FRAGDIR="$MNT_DIR/fragtest"
mkdir -p "$FRAGDIR"

TARGET="$FRAGDIR/fragmented_real_file.bin"
TARGET2="$FRAGDIR/fragmented_real_file2.bin"

ALTFILE="$FRAGDIR/helper.txt"

CHUNK_SIZE=4096   # 4 KB chunks tend to produce strong fragmentation

echo ">> Splitting real file into fragments..."
split -b $CHUNK_SIZE "$REALFILE" /tmp/fragpiece_

echo ">> Building fragmented file..."
for piece in /tmp/fragpiece_*; do
    cat "$piece" >> "$TARGET"
    cat "$piece" >> "$TARGET2"

    echo "x" >> "$ALTFILE"
done

sync

# cleanup split pieces
rm /tmp/fragpiece_*

# Clean Up
sudo umount "$MNT_DIR"

# Done
echo ">> Image created"
