#!/bin/bash   

# Set the base directory
BASE_DIR="./migrations"

# Create timestamp for unique output files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create output directory if it doesn't exist
OUTPUT_DIR="./output"
mkdir -p "$OUTPUT_DIR"

# Output files with timestamp
ERROR_DETAILS="$OUTPUT_DIR/error_details_$TIMESTAMP.txt"
CONFIRMED_ERRORS="$OUTPUT_DIR/confirmed_errors_$TIMESTAMP.txt"
POTENTIAL_ERRORS="$OUTPUT_DIR/potential_errors_$TIMESTAMP.txt"
ERROR_SUMMARY="$OUTPUT_DIR/error_summary_$TIMESTAMP.txt"
UNIQUE_ERRORS="$OUTPUT_DIR/unique_errors_$TIMESTAMP.txt"

# Clear or create output files
> "$ERROR_DETAILS"
> "$CONFIRMED_ERRORS"
> "$POTENTIAL_ERRORS"
> "$ERROR_SUMMARY"
> "$UNIQUE_ERRORS"

# Create a temporary file to store all error messages for later processing
TEMP_ERROR_MESSAGES=$(mktemp)
TEMP_NORMALIZED_ERRORS=$(mktemp)

echo "Starting migration log analysis..." | tee -a "$ERROR_DETAILS"
echo "Analyzing stderr files in $BASE_DIR..." | tee -a "$ERROR_DETAILS"
echo "--------------------------------------------" | tee -a "$ERROR_DETAILS"

# Function to process a repository's stderr file
process_repo_stderr() {
    local repo_path="$1"
    local repo_name="$(basename "$repo_path")"
    local stderr_file="$repo_path/stderr"
    
    # Check if stderr file exists and has content with ERROR
    if [[ -f "$stderr_file" && -s "$stderr_file" ]] && grep -q "\[ERROR\]" "$stderr_file"; then
        local is_confirmed_error=0
        local error_type="potential"
        local migration_ids=()
        
        # Check for confirmed error patterns
        if grep -q "Migration Failed" "$stderr_file" || 
           grep -q "An unexpected system error has caused the migration to fail" "$stderr_file" ||
           grep -q "Git source migration failed" "$stderr_file" ||
           grep -q "API rate limit exceeded" "$stderr_file"; then
            is_confirmed_error=1
            error_type="confirmed"
            output_file="$CONFIRMED_ERRORS"
        else
            output_file="$POTENTIAL_ERRORS"
        fi
        
        # Record error details
        echo "Errors found in repository: $repo_name ($error_type error)" | tee -a "$ERROR_DETAILS"
        echo "Error details:" | tee -a "$ERROR_DETAILS"
        grep "\[ERROR\]" "$stderr_file" | tee -a "$ERROR_DETAILS"
        
        # Extract and store error messages for later processing
        grep "\[ERROR\]" "$stderr_file" | sed 's/.*\[ERROR\] //' > "$TEMP_ERROR_MESSAGES.tmp"
        
        # Normalize error messages by replacing specific IDs with placeholders
        while IFS= read -r line; do
            # Save the original message for detailed reporting
            echo "$line" >> "$TEMP_ERROR_MESSAGES"
            
            # Normalize messages with Migration ID patterns
            if [[ "$line" =~ Migration\ Failed\.|Failed\ to\ get\ migration\ state\ for\ migration ]]; then
                # Replace RM_... with RM_ID
                normalized=$(echo "$line" | sed -E 's/(RM_[a-zA-Z0-9_-]+)/RM_ID/g')
                echo "$normalized" >> "$TEMP_NORMALIZED_ERRORS"
            elif [[ "$line" =~ Repository\ with\ name ]]; then
                # Replace repository names with REPO_NAME
                normalized=$(echo "$line" | sed -E 's/Repository with name ([a-zA-Z0-9_-]+) already exists/Repository with name REPO_NAME already exists/g')
                echo "$normalized" >> "$TEMP_NORMALIZED_ERRORS"
            else
                # Keep other messages as is
                echo "$line" >> "$TEMP_NORMALIZED_ERRORS"
            fi
        done < "$TEMP_ERROR_MESSAGES.tmp"
        
        # Extract migration IDs from error messages - replacing mapfile with a more compatible approach
        local migration_id_array=()
        while read -r line; do
            migration_id_array+=("$line")
        done < <(grep -o "Migration ID: RM_[a-zA-Z0-9_-]*" "$stderr_file" | sed 's/Migration ID: //' | sort -u)
        
        local migration_id_array2=()
        while read -r line; do
            migration_id_array2+=("$line")
        done < <(grep -o "migration RM_[a-zA-Z0-9_-]*" "$stderr_file" | sed 's/migration //' | sort -u)
        
        # Combine all unique migration IDs
        for id in "${migration_id_array[@]}" "${migration_id_array2[@]}"; do
            migration_ids+=("$id")
        done
        
        # Remove duplicates
        migration_ids=($(echo "${migration_ids[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        
        # Write repository and its migration IDs to the appropriate output file
        {
            echo "Repository: $repo_name"
            echo "  Migration IDs:"
            if [ ${#migration_ids[@]} -eq 0 ]; then
                echo "    No migration IDs found"
            else
                for id in "${migration_ids[@]}"; do
                    echo "    - $id"
                done
            fi
            echo "--------------------------------------------"
        } >> "$output_file"
        
        echo "--------------------------------------------" | tee -a "$ERROR_DETAILS"
        return $is_confirmed_error  # Return 1 for confirmed error, 0 for potential
    fi
    return 255  # No error found
}

# Find all repository directories and process them
confirmed_error_count=0
potential_error_count=0
repo_count=0
confirmed_migration_id_count=0
potential_migration_id_count=0

# Add headers to output files
echo "CONFIRMED ERRORS" > "$CONFIRMED_ERRORS"
echo "============================================" >> "$CONFIRMED_ERRORS"
echo "" >> "$CONFIRMED_ERRORS"

echo "POTENTIAL ERRORS" > "$POTENTIAL_ERRORS"
echo "============================================" >> "$POTENTIAL_ERRORS"
echo "" >> "$POTENTIAL_ERRORS"

echo "UNIQUE ERROR MESSAGES" > "$UNIQUE_ERRORS"
echo "============================================" >> "$UNIQUE_ERRORS"
echo "" >> "$UNIQUE_ERRORS"

# Handle the nested directory structure - avoid using pipes with while loops
# to prevent subshell variable scope issues
migration_log_dirs=()
while IFS= read -r dir; do
  migration_log_dirs+=("$dir")
done < <(find "$BASE_DIR" -type d -name "migration-logs")

for migration_log_dir in "${migration_log_dirs[@]}"; do
    # Look for directories inside migration-logs (which could be numbers or other identifiers)
    sub_dirs=()
    while IFS= read -r dir; do
      sub_dirs+=("$dir")
    done < <(find "$migration_log_dir" -maxdepth 1 -type d)
    
    for sub_dir in "${sub_dirs[@]}"; do
        # Skip the migration-logs directory itself
        if [[ "$sub_dir" == "$migration_log_dir" ]]; then
            continue
        fi
        
        # Find repository directories within these subdirectories
        repo_dirs=()
        while IFS= read -r dir; do
          repo_dirs+=("$dir")
        done < <(find "$sub_dir" -maxdepth 1 -type d)
        
        for repo_dir in "${repo_dirs[@]}"; do
            # Skip the parent directory
            if [[ "$repo_dir" == "$sub_dir" ]]; then
                continue
            fi
            
            ((repo_count++))
            process_repo_stderr "$repo_dir"
            result_code=$?
            
            if [[ $result_code -eq 1 ]]; then
                ((confirmed_error_count++))
            elif [[ $result_code -eq 0 ]]; then
                ((potential_error_count++))
            fi
        done
    done
done

# Count unique migration IDs in the output files
confirmed_migration_id_count=$(grep -c "    - RM_" "$CONFIRMED_ERRORS" || echo 0)
potential_migration_id_count=$(grep -c "    - RM_" "$POTENTIAL_ERRORS" || echo 0)

# Process and count unique error messages
unique_error_count=0
if [[ -f "$TEMP_NORMALIZED_ERRORS" && -s "$TEMP_NORMALIZED_ERRORS" ]]; then
    # echo "CONSOLIDATED ERROR MESSAGES:" >> "$UNIQUE_ERRORS"
    # echo "============================================" >> "$UNIQUE_ERRORS"
    #echo "" >> "$UNIQUE_ERRORS"
    
    # Sort normalized error messages, count unique occurrences, sort by count in descending order
    sort "$TEMP_NORMALIZED_ERRORS" | uniq -c | sort -nr | while read -r count message; do
        # For all messages, just show the count and message
        echo "[$count occurrences] $message" >> "$UNIQUE_ERRORS"
        ((unique_error_count++))
    done
fi

# Generate summary and save to summary file and error details
summary_content="
==== ERROR SUMMARY ====
Total repositories analyzed: $repo_count
Repositories with confirmed errors: $confirmed_error_count
Repositories with potential issues: $potential_error_count
Total repositories with errors/issues: $((confirmed_error_count + potential_error_count))

Migration IDs in confirmed errors: $confirmed_migration_id_count
Migration IDs in potential issues: $potential_migration_id_count
Unique error patterns found: $unique_error_count

==== ERROR CATEGORIES ====
CONFIRMED ERRORS - These indicate definite migration failures:
- \"Migration Failed\" messages
- \"Git source migration failed\" messages
- \"An unexpected system error has caused the migration to fail\" messages
- \"API rate limit exceeded\" messages

POTENTIAL ISSUES - These may not indicate actual failures:
- \"Failed to lookup the Organization ID\" messages
- \"Failed to get migration state\" messages
- Other error messages that don't clearly indicate migration failure

==== OUTPUT FILES ====
Detailed error log: $ERROR_DETAILS
Confirmed errors (repos + migration IDs): $CONFIRMED_ERRORS
Potential issues (repos + migration IDs): $POTENTIAL_ERRORS
Consolidated error messages: $UNIQUE_ERRORS
Error summary: $ERROR_SUMMARY
"

echo "$summary_content" | tee -a "$ERROR_DETAILS" > "$ERROR_SUMMARY"

# Clean up temporary files
rm -f "$TEMP_ERROR_MESSAGES" "$TEMP_NORMALIZED_ERRORS" "$TEMP_ERROR_MESSAGES.tmp"

echo "Analysis complete! Results saved to:"
echo "- $ERROR_DETAILS"
echo "- $CONFIRMED_ERRORS"
echo "- $POTENTIAL_ERRORS"
echo "- $UNIQUE_ERRORS"
echo "- $ERROR_SUMMARY"