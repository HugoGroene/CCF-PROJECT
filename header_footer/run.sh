#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/ccf_output"
MOUNT_POINT="${OUTPUT_DIR}/mnt"

TEST_PDF="${SCRIPT_DIR}/test2.pdf"
BLOCK_SIZE=4096
IMAGE_SIZE_MB=50

mkdir -p "$OUTPUT_DIR"
mkdir -p "$MOUNT_POINT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================
# MODE HANDLING
# ============================================================
DELETE_MODE=false
if [[ "$1" == "--deleted" ]]; then
    DELETE_MODE=true
fi

echo "[*] Mode: $([[ $DELETE_MODE == true ]] && echo DELETED || echo NORMAL)"

# ============================================================
# CLEANUP
# ============================================================
cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null
    for l in $(losetup -j "$OUTPUT_DIR"/*.img 2>/dev/null | cut -d: -f1); do
        sudo losetup -d "$l" 2>/dev/null
    done
}
trap cleanup EXIT


# ============================================================
# IMAGE CREATION
# ============================================================
create_ext4_image() {
    local img="$1"
    rm -f "$img"
    dd if=/dev/zero of="$img" bs=1M count=$IMAGE_SIZE_MB status=none
    mkfs.ext4 -F -b $BLOCK_SIZE "$img" >/dev/null 2>&1
}

# ============================================================
# MOUNT + UNMOUNT
# ============================================================
mount_img() {
    local img="$1"
    local loopdev
    loopdev=$(sudo losetup -f --show "$img")
    sudo mount "$loopdev" "$MOUNT_POINT"
    echo "$loopdev"
}

unmount_img() {
    local loopdev="$1"
    sudo sync
    sudo umount "$MOUNT_POINT"
    sudo losetup -d "$loopdev"
    sync
}

# ============================================================
# GET PDF BLOCK
# ============================================================
get_pdf_start_block() {
    local loopdev="$1"
    local filepath="$2"
    local frag_info
    frag_info=$(sudo filefrag -v "$filepath" 2>/dev/null | grep -E "^\s+0:")
    
    if [[ -n "$frag_info" ]]; then
        local phys_block
        phys_block=$(echo "$frag_info" | awk '{print $4}' | tr -d '.')
        echo "$phys_block"
        return
    fi
    # Fallback: use debugfs
    local inode
    inode=$(sudo stat -c %i "$filepath")
    
    local blk
    blk=$(sudo debugfs -R "stat <$inode>" "$loopdev" 2>/dev/null | \
          grep -oP '$\d+-\d+$' | head -1 | grep -oP '\d+' | head -1)
    
    if [[ -z "$blk" ]]; then
        blk=$(sudo debugfs -R "stat <$inode>" "$loopdev" 2>/dev/null | \
              grep -oP 'BLOCKS:.*' | grep -oP '\d+' | head -1)
    fi
    
    echo "$blk"
}

# ============================================================
# RAW OPERATIONS
# ============================================================
raw_write_block() {
    local img="$1"
    local block="$2"
    local datafile="$3"
    local desc="${4:-data}"
    
    if [[ -z "$block" ]] || [[ "$block" -lt 1 ]]; then
        echo -e "${RED}    ERROR: Invalid block number: '$block'${NC}"
        return 1
    fi
    
    local offset=$((block * BLOCK_SIZE))
    
    echo "    Writing $desc to block $block (offset $offset)"
    
    sudo dd if="$datafile" of="$img" bs=$BLOCK_SIZE seek=$block conv=notrunc status=none
    
    # Verify write
    local written=$(sudo dd if="$img" bs=$BLOCK_SIZE skip=$block count=1 status=none | head -c 20 | xxd -p)
    local expected=$(head -c 20 "$datafile" | xxd -p)
    
    if [[ "$written" == "$expected" ]]; then
        echo -e "${GREEN}    ✓ Verified write at block $block${NC}"
    else
        echo -e "${RED}    ✗ Write verification FAILED at block $block${NC}"
        echo "      Expected: $expected"
        echo "      Got:      $written"
    fi
}

raw_write_at_offset() {
    local img="$1"
    local offset="$2"
    local datafile="$3"
    local desc="${4:-data}"
    
    echo "    Writing $desc at offset $offset"
    
    sudo dd if="$datafile" of="$img" bs=1 seek=$offset conv=notrunc status=none
}

raw_overwrite_block_with_pattern() {
    local img="$1"
    local block="$2"
    local pattern="$3"
    
    local tmpfile=$(mktemp)
    
    # Create full block of pattern
    yes "$pattern" | head -c $BLOCK_SIZE > "$tmpfile"
    
    raw_write_block "$img" "$block" "$tmpfile" "corruption pattern"
    
    rm -f "$tmpfile"
}

# ============================================================
# PRINT BANNER
# ============================================================
print_banner() {
    echo ""
    echo -e "${YELLOW}================================================${NC}"
    echo -e "${YELLOW} $1${NC}"
    echo -e "${YELLOW}================================================${NC}"
}

# ======================================================
# SCENARIO 1: Header Collision
# JPEG header written just before PDF start
# ======================================================
scenario1_header_collision() {
    print_banner "Scenario 1: Header Collision"
    
    local img="${OUTPUT_DIR}/scenario1_header_collision.img"
    create_ext4_image "$img"
    
    local loopdev=$(mount_img "$img")
    
    # Copy PDF to filesystem
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    sudo sync
    
    # Get the starting block
    local pdf_block=$(get_pdf_start_block "$loopdev" "$MOUNT_POINT/document.pdf")
    echo "  PDF starts at block: $pdf_block"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
    
    # Write JPEG header 20 bytes before PDF block
    local jpeg_header=$(mktemp)
    printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00' > "$jpeg_header"
    
    local jpeg_offset=$((pdf_block * BLOCK_SIZE - 20))
    
    if [[ $jpeg_offset -gt 0 ]]; then
        raw_write_at_offset "$img" "$jpeg_offset" "$jpeg_header" "JPEG header"
        echo -e "${GREEN}  ✓ JPEG header written at offset $jpeg_offset${NC}"
    else
        echo -e "${RED}  ✗ Cannot write JPEG header (PDF at block 0?)${NC}"
    fi
    
    rm -f "$jpeg_header"
}

# ======================================================
# SCENARIO 2: Truncated PDF
# Last 30% of PDF blocks zeroed out
# ======================================================
scenario2_truncated() {
    print_banner "Scenario 2: Truncated PDF (70%)"
    
    local img="${OUTPUT_DIR}/scenario2_truncated.img"
    create_ext4_image "$img"
    
    local loopdev=$(mount_img "$img")
    
    # Copy PDF
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    sudo sync
    
    local pdf_block=$(get_pdf_start_block "$loopdev" "$MOUNT_POINT/document.pdf")
    echo "  PDF starts at block: $pdf_block"
    echo "  PDF total blocks: $PDF_BLOCKS"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
    
    # Calculate truncation point
    local keep_blocks=$((PDF_BLOCKS * 70 / 100))
    local truncate_start=$((pdf_block + keep_blocks))
    local truncate_count=$((PDF_BLOCKS - keep_blocks))
    
    echo "  Keeping blocks: $keep_blocks (70%)"
    echo "  Truncating from block: $truncate_start"
    echo "  Blocks to zero: $truncate_count"
    
    # Zero out the remaining blocks
    local zeros=$(mktemp)
    dd if=/dev/zero of="$zeros" bs=$BLOCK_SIZE count=1 status=none
    
    for ((i=0; i<truncate_count; i++)); do
        local blk=$((truncate_start + i))
        sudo dd if="$zeros" of="$img" bs=$BLOCK_SIZE seek=$blk conv=notrunc status=none
    done
    
    echo -e "${GREEN}  ✓ Zeroed $truncate_count blocks starting at $truncate_start${NC}"
    
    # Verify
    local last_block=$((truncate_start + truncate_count - 1))
    local check=$(sudo dd if="$img" bs=$BLOCK_SIZE skip=$last_block count=1 status=none | xxd -p | head -c 20)
    echo "  Verification (last truncated block): $check"
    
    rm -f "$zeros"
}

# ======================================================
# SCENARIO 3: Fragmented PDF
# ======================================================
scenario3_fragmented() {
    print_banner "Scenario 3: Fragmented PDF (Aggressive)"
    
    local img="${OUTPUT_DIR}/scenario3_fragmented.img"
    
    # Use SMALLER image to force fragmentation
    dd if=/dev/zero of="$img" bs=1M count=20 status=none
    mkfs.ext4 -F -b $BLOCK_SIZE "$img" >/dev/null 2>&1
    
    local loopdev=$(mount_img "$img")
    
    # Fill disk almost completely with small files
    echo "  Filling disk with small files..."
    local i=1
    while sudo dd if=/dev/urandom of="$MOUNT_POINT/fill_$i.bin" bs=4096 count=10 status=none 2>/dev/null; do
        i=$((i+1))
        [[ $i -gt 400 ]] && break
    done
    sudo sync
    
    echo "  Created $i filler files"
    
    # Delete every 3rd file to create small gaps
    echo "  Creating small gaps..."
    for j in $(seq 1 3 $i); do
        sudo rm -f "$MOUNT_POINT/fill_$j.bin"
    done
    sudo sync
    
    # Now write PDF - MUST fragment across small gaps
    echo "  Writing PDF into gaps..."
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf" 2>/dev/null
    
    if [[ $? -ne 0 ]]; then
        echo "  Not enough space, removing more files..."
        for j in $(seq 2 3 $i); do
            sudo rm -f "$MOUNT_POINT/fill_$j.bin"
        done
        sudo sync
        sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    fi
    sudo sync
    
    # Check fragmentation
    echo "  Fragmentation result:"
    sudo filefrag -v "$MOUNT_POINT/document.pdf" | head -30
    
    local extents=$(sudo filefrag "$MOUNT_POINT/document.pdf" 2>/dev/null | grep -oP '\d+ extent' | grep -oP '\d+')
    
    if [[ "$extents" -gt 1 ]]; then
        echo -e "${GREEN}  ✓ PDF fragmented into $extents extents${NC}"
    else
        echo -e "${RED}  ✗ Still not fragmented - filesystem too efficient${NC}"
    fi
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
}

# ======================================================
# SCENARIO 4: Middle Overwrite
# Corrupt middle blocks of PDF
# ======================================================
scenario4_middle_overwrite() {
    print_banner "Scenario 4: Middle Overwrite"
    
    local img="${OUTPUT_DIR}/scenario4_middle_overwrite.img"
    create_ext4_image "$img"
    
    local loopdev=$(mount_img "$img")
    
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    sudo sync
    
    local pdf_block=$(get_pdf_start_block "$loopdev" "$MOUNT_POINT/document.pdf")
    echo "  PDF starts at block: $pdf_block"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
    
    # Calculate middle blocks
    local middle_start=$((pdf_block + PDF_BLOCKS / 3))
    local corrupt_count=5
    
    echo "  Corrupting blocks $middle_start to $((middle_start + corrupt_count - 1))"
    
    # Create corruption pattern
    local corrupt=$(mktemp)
    yes "=== CORRUPTED BLOCK ===" | head -c $BLOCK_SIZE > "$corrupt"
    
    for ((i=0; i<corrupt_count; i++)); do
        local blk=$((middle_start + i))
        raw_write_block "$img" "$blk" "$corrupt" "corruption"
    done
    
    rm -f "$corrupt"
    
    echo -e "${GREEN}  ✓ Corrupted $corrupt_count blocks in middle${NC}"
}

# ======================================================
# SCENARIO 5: Interleaved Files
# ======================================================
scenario5_interleaved_files() {
    print_banner "Scenario 5: Interleaved Files (Fixed)"
    
    local img="${OUTPUT_DIR}/scenario5_interleaved_files.img"
    
    # Very small image to force interleaving
    dd if=/dev/zero of="$img" bs=1M count=15 status=none
    mkfs.ext4 -F -b $BLOCK_SIZE "$img" >/dev/null 2>&1
    
    local loopdev=$(mount_img "$img")
    
    # Fill 80% of disk with tiny files
    echo "  Filling disk almost completely..."
    local i=1
    while sudo dd if=/dev/urandom of="$MOUNT_POINT/fill_$i.bin" bs=4096 count=1 status=none 2>/dev/null; do
        i=$((i+1))
        [[ $i -gt 3000 ]] && break
    done
    sudo sync
    
    # Delete every other file - creates 4KB gaps
    echo "  Creating tiny gaps..."
    for j in $(seq 1 2 $i); do
        sudo rm -f "$MOUNT_POINT/fill_$j.bin"
    done
    sudo sync
    
    # Write JPEG and PDF simultaneously using background processes
    echo "  Writing JPEG and PDF simultaneously..."
    
    # Create JPEG slightly larger than PDF
    {
        printf '\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00'
        dd if=/dev/urandom bs=1 count=$((PDF_SIZE + 100000)) status=none
        printf '\xFF\xD9'
    } | sudo tee "$MOUNT_POINT/image.jpg" > /dev/null &
    pid1=$!
    
    # Small delay then write PDF
    sleep 0.1
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf" &
    pid2=$!
    
    wait $pid1 $pid2
    sudo sync
    
    echo "  JPEG extents:"
    sudo filefrag "$MOUNT_POINT/image.jpg"
    
    echo "  PDF extents:"
    sudo filefrag "$MOUNT_POINT/document.pdf"
    
    # Check if actually interleaved
    local jpg_first=$(sudo filefrag -v "$MOUNT_POINT/image.jpg" 2>/dev/null | grep "0:" | awk '{print $4}')
    local pdf_first=$(sudo filefrag -v "$MOUNT_POINT/document.pdf" 2>/dev/null | grep "0:" | awk '{print $4}')
    
    echo "  JPEG first block: $jpg_first"
    echo "  PDF first block: $pdf_first"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf" "$MOUNT_POINT/image.jpg"
        sudo sync
    fi
    
    unmount_img "$loopdev"
}
# ======================================================
# SCENARIO 6: Non-Standard Offset
# PDF header shifted within first block
# ======================================================
scenario6_nonstandard_offset() {
    print_banner "Scenario 6: Non-Standard Offset"
    
    local img="${OUTPUT_DIR}/scenario6_nonstandard_offset.img"
    create_ext4_image "$img"
    
    local loopdev=$(mount_img "$img")
    
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    sudo sync
    
    local pdf_block=$(get_pdf_start_block "$loopdev" "$MOUNT_POINT/document.pdf")
    echo "  PDF starts at block: $pdf_block"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
    
    # Read original first block
    local orig_block=$(mktemp)
    sudo dd if="$img" of="$orig_block" bs=$BLOCK_SIZE skip=$pdf_block count=1 status=none
    
    echo "  Original first bytes: $(head -c 10 "$orig_block" | xxd -p)"
    
    # Create shifted block: garbage + PDF content
    local shifted_block=$(mktemp)
    local garbage_size=1234
    
    # Random garbage prefix
    dd if=/dev/urandom of="$shifted_block" bs=1 count=$garbage_size status=none
    
    # Append truncated original content
    dd if="$orig_block" bs=1 count=$((BLOCK_SIZE - garbage_size)) >> "$shifted_block" 2>/dev/null
    
    # Write back
    sudo dd if="$shifted_block" of="$img" bs=$BLOCK_SIZE seek=$pdf_block conv=notrunc status=none
    
    # Verify
    local new_first=$(sudo dd if="$img" bs=$BLOCK_SIZE skip=$pdf_block count=1 status=none | head -c 20 | xxd -p)
    echo "  New first bytes: $new_first"
    
    # Check for %PDF at offset
    local pdf_at_offset=$(sudo dd if="$img" bs=1 skip=$((pdf_block * BLOCK_SIZE + garbage_size)) count=5 status=none)
    echo "  Content at offset $garbage_size: '$pdf_at_offset'"
    
    rm -f "$orig_block" "$shifted_block"
    
    if [[ "$pdf_at_offset" == "%PDF-"* ]]; then
        echo -e "${GREEN}  ✓ PDF header shifted by $garbage_size bytes${NC}"
    else
        echo -e "${RED}  ✗ Shift verification failed${NC}"
    fi
}


# ======================================================
# SCENARIO 7: Null Padded Header
# Null bytes prepended to PDF header
# ======================================================
scenario7_null_padded_header() {
    print_banner "Scenario 7: Null Padded Header"
    
    local img="${OUTPUT_DIR}/scenario7_null_padded.img"
    create_ext4_image "$img"
    
    local loopdev=$(mount_img "$img")
    
    sudo cp "$TEST_PDF" "$MOUNT_POINT/document.pdf"
    sudo sync
    
    local pdf_block=$(get_pdf_start_block "$loopdev" "$MOUNT_POINT/document.pdf")
    echo "  PDF starts at block: $pdf_block"
    
    if $DELETE_MODE; then
        sudo rm "$MOUNT_POINT/document.pdf"
        sudo sync
    fi
    
    unmount_img "$loopdev"
    
    # Read original first block
    local orig_block=$(mktemp)
    sudo dd if="$img" of="$orig_block" bs=$BLOCK_SIZE skip=$pdf_block count=1 status=none
    
    echo "  Original start: $(head -c 10 "$orig_block" | xxd -p)"
    
    # Create null-padded block
    local null_block=$(mktemp)
    local null_size=100
    
    # Null prefix
    dd if=/dev/zero of="$null_block" bs=1 count=$null_size status=none
    
    # Append original content (truncated to fit)
    dd if="$orig_block" bs=1 count=$((BLOCK_SIZE - null_size)) >> "$null_block" 2>/dev/null
    
    # Write back
    sudo dd if="$null_block" of="$img" bs=$BLOCK_SIZE seek=$pdf_block conv=notrunc status=none
    
    # Verify
    local new_start=$(sudo dd if="$img" bs=$BLOCK_SIZE skip=$pdf_block count=1 status=none | head -c 10 | xxd -p)
    echo "  New start: $new_start"
    
    local pdf_after_null=$(sudo dd if="$img" bs=1 skip=$((pdf_block * BLOCK_SIZE + null_size)) count=5 status=none)
    echo "  After $null_size nulls: '$pdf_after_null'"
    
    rm -f "$orig_block" "$null_block"
    
    if [[ "$new_start" == "00000000"* ]]; then
        echo -e "${GREEN}  ✓ Null padding applied ($null_size bytes)${NC}"
    else
        echo -e "${RED}  ✗ Null padding failed${NC}"
    fi
}

# ======================================================
# RUN ALL SCENARIOS
# ======================================================

echo ""
echo "=============================================="
echo " CCF SCENARIO GENERATOR"
echo "=============================================="
echo ""

scenario1_header_collision
scenario2_truncated
scenario3_fragmented
scenario4_middle_overwrite
scenario5_interleaved_files
scenario6_nonstandard_offset
scenario7_missing_fragment
scenario7_null_padded_header

echo ""
echo "========================================"
echo " COMPLETE "
echo "========================================"
echo ""
ls -la "$OUTPUT_DIR"/*.img