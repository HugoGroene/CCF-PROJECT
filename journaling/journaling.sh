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

# Space for normal filesystem calls/operations.

# Adding directories [ph] #


# Adding files [ph] #


# Adding file permissions [ph] #


# Manipulate the ext4 structures directly in the image file using debugfs


# Clean Up
sudo umount "$MNT_DIR"

# Done
echo ">> Image created"