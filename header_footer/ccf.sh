#!/bin/bash

# Load Shared Library
source lib/common.sh

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input_file>"
    exit 1
fi

INPUT_FILE="$1"

if [ ! -f "$INPUT_FILE" ]; then
    echo "[!] Error: File '$INPUT_FILE' not found."
    exit 1
fi

# ==============================================================================
# PRE-FLIGHT CHECKS
# ==============================================================================

# 1. Check for required tools
if ! command -v mkfs.ext4 &> /dev/null; then
    echo "[!] Error: 'mkfs.ext4' not found. Please install e2fsprogs."
    exit 1
fi

if ! command -v debugfs &> /dev/null; then
    echo "[!] Warning: 'debugfs' not found. Files will be copied to folder only, not injected into IMG."
fi

# 2. Ensure Output Directory Exists (Fixes the missing disk image issue)
mkdir -p output

FILENAME=$(basename "$INPUT_FILE")
EXT="${FILENAME##*.}"
EXT_LOWER=$(echo "$EXT" | tr '[:upper:]' '[:lower:]')

# 3. Calculate Hash
echo "[*] Calculating hash for $FILENAME..."
FILE_HASH=$(md5sum "$INPUT_FILE" | awk '{print $1}')
echo "    MD5SUM: $FILE_HASH"

# 4. Initialize Disk and Log
# Now safe to run because output/ exists
init_disk_image
init_log_file "$FILENAME" "$FILE_HASH"

echo "[*] CCF Wrapper Started"

# 5. Module Selector
case "$EXT_LOWER" in
    png|jpg|jpeg|gif|bmp)
        echo "    -> Detected IMAGE format."
        # Ensure module exists
        if [ -f "modules/image_mod.sh" ]; then
            source modules/image_mod.sh
            run_image_module "$INPUT_FILE"
        else
            echo "[!] Error: modules/image_mod.sh missing."
        fi
        ;;
    
    pdf)
        echo "    -> Detected PDF format."
        if [ -f "modules/pdf_mod.sh" ]; then
            source modules/pdf_mod.sh
            run_pdf_module "$INPUT_FILE"
        else
            echo "[!] Error: modules/pdf_mod.sh missing."
        fi
        ;;
        
    zip|docx|xlsx|jar)
        echo "    -> Detected ZIP/ARCHIVE format."
        if [ -f "modules/zip_mod.sh" ]; then
            source modules/zip_mod.sh
            run_zip_module "$INPUT_FILE"
        else
            echo "[!] Error: modules/zip_mod.sh missing."
        fi
        ;;
        
    *)
        echo "[!] Error: No module found for extension .$EXT"
        exit 1
        ;;
esac

echo "======================================================"
echo "[+] Processing Complete."
if [ -f "$OUTPUT_IMG" ]; then
    echo "[+] Disk Image: $OUTPUT_IMG ($(du -h "$OUTPUT_IMG" | cut -f1))"
else
    echo "[!] Error: Disk Image was not created."
fi
echo "[+] Audit Log:  $LOG_FILE"
echo "======================================================"