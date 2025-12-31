#!/usr/bin/env bash
set -e

NAME="deleted"

# Figure out where this script lives (scripts/)
SCRIPT_DIR="$(pwd)"

# Output folder next to scripts/
OUTPUT_DIR="../output"

# Paths
IMG_PATH="${OUTPUT_DIR}/${NAME}.img"
MNT_DIR="/mnt/fs"

# NORMAL OPERATION

# 10 MB test image.
dd if=/dev/zero of="$IMG_PATH" bs=1M count=20

# create filesystem inside image file.
mkfs.ext4 -O ^has_journal -E lazy_itable_init=0,lazy_journal_init=0 "$IMG_PATH"

# Mount point inside output_images
mkdir -p "$MNT_DIR"

# Mount the filesystem using a loop device
sudo mount -o loop "$IMG_PATH" "$MNT_DIR"

# The test
REALFILE="/home/kali/Desktop/CCF proj/F-15C DCS Flaming Cliffs Flight Manual EN.pdf" #paste here the file to copy over to test on
REALFILE2="/home/kali/Desktop/CCF proj/jet.jpg"

DELDIR="$MNT_DIR/deletetest"
mkdir -p "$DELDIR"

cp "$REALFILE" "$DELDIR/f15_file_to_be_deleted.pdf"
sleep 5
sync

cp "$REALFILE2" "$DELDIR/jet.jpg"
sleep 2
sync

echo "Hello I am deleted right?" > "$DELDIR/deleted.txt"
mkdir "$DELDIR/test_dir_del"
echo "Hello I will also be deleted, but I am in a directory" > "$DELDIR/test_dir_del/deleted2.txt"

sync

rm -f "$DELDIR/f15_file_to_be_deleted.pdf"
rm -f "$DELDIR/jet.jpg"
rm -f "$DELDIR/deleted.txt"
rm -rf "$DELDIR/test_dir_del"

sync

# Clean Up
sudo umount "$MNT_DIR"

# Done
echo ">> Image created"
