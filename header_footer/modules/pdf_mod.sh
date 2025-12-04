#!/bin/bash

run_pdf_module() {
    local input_file=$1
    local config="configs/pdf.conf"
    local basename=$(basename "$input_file")
    
    # Define where to save the local copies
    local artifacts_dir="output/artifacts"
    mkdir -p "$artifacts_dir"

    echo "    -> Loading config: $config"
    echo "    -> Saving local copies to: $artifacts_dir"

    # Read Config, Ignore Comments/Empty Lines
    grep -vE '^\s*#' "$config" | grep -vE '^\s*$' | while read -r TYPE TARGET PARAMS; do
        
        # 1. clean
        TYPE=$(echo "$TYPE" | tr -d '\r')
        TARGET=$(echo "$TARGET" | tr -d '\r')
        PARAMS=$(echo "$PARAMS" | tr -d '\r')

        # 2. Prepare Output Filename and Temp File
        # Clean Target (e.g., "<!DOCTYPE html>" -> "_DOCTYPE_html_")
        local clean_target=$(echo "$TARGET" | sed 's/[^a-zA-Z0-9]/_/g')
        
        # Clean Params (e.g., "math:header+50" -> "math_header_50")
        local clean_params=$(echo "$PARAMS" | sed 's/[^a-zA-Z0-9]/_/g')

        # Construct Unique Tag including PARAMS (Critical for your new config)
        local case_tag="${TYPE}_${clean_target}_${clean_params}"
        
        local temp_file="/tmp/ccf_${basename}_${case_tag}.tmp"
        local output_name="PDF_${case_tag}_${basename}"
        
        # Start fresh from input file
        cp "$input_file" "$temp_file"

        # 3. Handle PDF-Specific Logic 
        if [ "$TYPE" == "corrupt_header" ]; then
            if [ "$TARGET" == "version_num" ]; then
                printf "%%PDF-9.9" | dd of="$temp_file" bs=1 seek=0 count=8 conv=notrunc status=none
            else
                printf "\x00\x00\x00\x00" | dd of="$temp_file" bs=1 seek=0 count=4 conv=notrunc status=none
            fi

        elif [ "$TYPE" == "corrupt_xref" ]; then
             sed -i 's/xref/BROK/g' "$temp_file"

        elif [ "$TYPE" == "corrupt_string" ]; then
             local safe_str=$(echo "$TARGET" | sed 's/\//\\\//g')
             sed -i "s/$safe_str/FAIL/g" "$temp_file"

        else
            # 4. Handle Generic Logic (via common.sh helpers)
            local insertion_point=0
            
            # Calculate offset if params contain logic
            if [[ "$PARAMS" == math:* ]]; then
                insertion_point=$(get_calc_offset "$temp_file" "$PARAMS")
            fi
            
            # Apply the generic injection
            apply_fuzz_injection "$TYPE" "$TARGET" "$temp_file" "$insertion_point"
        fi

        # =========================================================
        # Save a local copy before injection/deletion
        # =========================================================
        cp "$temp_file" "$artifacts_dir/$output_name"

        # 5. Finalize
        inject_into_image "$temp_file" "$output_name"
        log_event "$TYPE" "$TARGET ($PARAMS)" "$output_name" "$temp_file"
        
        rm "$temp_file"
    done
}