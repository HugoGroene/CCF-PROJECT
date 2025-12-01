#!/bin/bash

# ==============================================================================
# CONFIGURATION & INFRASTRUCTURE
# ==============================================================================
OUTPUT_IMG="output/test_disk.img"
LOG_FILE="output/audit_log.txt"
SIZE_MB=64

# Initialize the Disk Image (Create fresh Ext4)
init_disk_image() {
    echo "[*] Initializing Ext4 Image ($SIZE_MB MB)..."
    dd if=/dev/zero of="$OUTPUT_IMG" bs=1M count="$SIZE_MB" status=none
    mkfs.ext4 -F -O ^has_journal "$OUTPUT_IMG" > /dev/null 2>&1
}

# Initialize Log File
init_log_file() {
    local filename=$1
    local hash=$2
    
    # Create output directory if it doesn't exist
    mkdir -p output

    echo "========================================================" > "$LOG_FILE"
    echo " CCF EXECUTION AUDIT LOG" >> "$LOG_FILE"
    echo "========================================================" >> "$LOG_FILE"
    echo "Date:             $(date)" >> "$LOG_FILE"
    echo "Input File:       $filename" >> "$LOG_FILE"
    echo "Original Hash:    $hash" >> "$LOG_FILE"
    echo "----------------------------------------------------------------------------------------------------------------" >> "$LOG_FILE"
    echo -e "TYPE\t\tPARAMS\t\t\tCORRUPT_HASH\t\t\t\tOUTPUT_FILENAME" >> "$LOG_FILE"
    echo "----------------------------------------------------------------------------------------------------------------" >> "$LOG_FILE"
}

# Helper to calculate hash and append to log
log_event() {
    local type=$1
    local params=$2
    local output_name=$3
    local temp_file=$4 
    
    local corrupt_hash="ERROR"
    
    if [ -f "$temp_file" ]; then
        corrupt_hash=$(md5sum "$temp_file" | awk '{print $1}')
    fi

    # Formatting with tabs
    echo -e "${type}\t${params}\t${corrupt_hash}\t${output_name}" >> "$LOG_FILE"
}

# Inject file into the Ext4 image using debugfs
inject_into_image() {
    local src=$1
    local dest_name=$2
    # Check if debugfs is available, otherwise copy to output folder
    if command -v debugfs &> /dev/null; then
        debugfs -w -R "write $src $dest_name" "$OUTPUT_IMG" > /dev/null 2>&1
    else
        # Fallback if user doesn't have permissions or tools
        cp "$src" "output/$dest_name"
    fi
}

# ==============================================================================
# UNIVERSAL MATH & LOGIC HELPERS
# ==============================================================================

# Calculates byte offset based on file size and keywords
# Supports: math:divX, math:eof-X, math:header+X, math:random, math:xref (PDF), math:stream (PDF/Zip)
get_calc_offset() {
    local file=$1
    local logic=$2
    local filesize=$(stat -c%s "$file")
    local offset=0

    # 1. DIVISORS (e.g., math:div2)
    if [[ "$logic" == *"math:div"* ]]; then
        local divisor=$(echo "$logic" | grep -o '[0-9]*$')
        offset=$(( filesize / divisor ))
    
    # 2. EOF RELATIVE (e.g., math:eof-100)
    elif [[ "$logic" == *"math:eof"* ]]; then
        if [[ "$logic" == *"-"* ]]; then
            local sub=$(echo "$logic" | cut -d'-' -f2)
            offset=$(( filesize - sub ))
        else
            offset=$filesize
        fi

    # 3. HEADER RELATIVE (e.g., math:header+5)
    elif [[ "$logic" == *"math:header"* ]]; then
        if [[ "$logic" == *"+"* ]]; then
            local add=$(echo "$logic" | cut -d'+' -f2)
            offset=$(( 0 + add ))
        else
            offset=0
        fi

    # 4. RANDOM
    elif [[ "$logic" == *"math:random"* ]]; then
        offset=$(shuf -i 0-"$filesize" -n 1)

    # 5. KEYWORD SEARCH (PDF/General)
    elif [[ "$logic" == *"math:xref"* ]]; then
        offset=$(grep -aob "startxref" "$file" | head -n1 | cut -d: -f1)
        [ -z "$offset" ] && offset=$(( filesize - 50 ))
        if [[ "$logic" == *"-"* ]]; then
            local sub=$(echo "$logic" | cut -d'-' -f2)
            offset=$(( offset - sub ))
        fi
    elif [[ "$logic" == *"math:stream_start"* ]]; then
        offset=$(grep -aob "stream" "$file" | head -n1 | cut -d: -f1)
        [ -z "$offset" ] && offset=$(( filesize / 4 ))
    elif [[ "$logic" == *"math:obj_def"* ]]; then
        offset=$(grep -aob " obj" "$file" | head -n1 | cut -d: -f1)
        [ -z "$offset" ] && offset=100
    else
        offset=0
    fi
    
    if [ "$offset" -lt 0 ]; then offset=0; fi
    echo "$offset"
}

# Applies the actual corruption logic (Bit flip, Hex injection, Replacement)
apply_fuzz_injection() {
    local type=$1
    local target=$2
    local file=$3
    local offset=$4

    if [ "$type" == "inject_string" ] || [ "$type" == "inject_byte" ]; then
        # printf interprets \xFF hex codes automatically
        printf "$target" | dd of="$file" bs=1 seek="$offset" conv=notrunc status=none

    elif [ "$type" == "replace_byte" ]; then
        printf "$target" | dd of="$file" bs=1 seek="$offset" count=1 conv=notrunc status=none

    elif [ "$type" == "flip_bit" ]; then
        # Read byte, XOR 0xFF, Write back
        local current_byte=$(dd if="$file" bs=1 skip="$offset" count=1 status=none | xxd -p)
        local new_byte=$(perl -e "print sprintf('%02x', hex('$current_byte') ^ 0xFF)")
        printf "\x$new_byte" | dd of="$file" bs=1 seek="$offset" count=1 conv=notrunc status=none

    elif [ "$type" == "delete_range" ]; then
        if [ "$target" == "last_10_bytes" ]; then
             local sz=$(stat -c%s "$file")
             truncate -s $(( sz - 10 )) "$file"
        elif [ "$target" == "first_entry" ]; then
             dd if=/dev/zero of="$file" bs=1 seek="$offset" count=10 conv=notrunc status=none
        fi
    
    elif [ "$type" == "delete_byte" ]; then
        printf "\x00" | dd of="$file" bs=1 seek="$offset" count=1 conv=notrunc status=none
    fi
}