#!/bin/bash   

# Default directory settings
DEFAULT_BASE_DIR="./migrations"
DEFAULT_OUTPUT_DIR="./logs_analysis"
DEFAULT_INCLUDE_POTENTIAL=true

# Initialize with defaults
BASE_DIR="$DEFAULT_BASE_DIR"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
INCLUDE_POTENTIAL="$DEFAULT_INCLUDE_POTENTIAL"

# Display help function
display_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -b, --base-dir DIR      Specify the base directory containing migration logs (default: $DEFAULT_BASE_DIR)"
    echo "  -o, --output-dir DIR    Specify the output directory for analysis files (default: $DEFAULT_OUTPUT_DIR)"
    echo "  -p, --include-potential Include potential errors in output (default: $DEFAULT_INCLUDE_POTENTIAL)"
    echo "                          Use --include-potential=false to exclude"
    echo "  -h, --help              Display this help message"
    exit 1
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        -o|--output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -p|--include-potential)
            if [[ "$2" == "false" ]]; then
                INCLUDE_POTENTIAL=false
            else
                INCLUDE_POTENTIAL=true
            fi
            shift 2
            ;;
        -p=*|--include-potential=*)
            val="${key#*=}"
            if [[ "$val" == "false" ]]; then
                INCLUDE_POTENTIAL=false
            else
                INCLUDE_POTENTIAL=true
            fi
            shift
            ;;
        -h|--help)
            display_help
            ;;
        *)
            # Unknown option
            echo "Unknown option: $1"
            display_help
            ;;
    esac
done

# Create timestamp for unique output files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Output files with timestamp
ERROR_CSV="$OUTPUT_DIR/migration_errors_$TIMESTAMP.csv"
ERROR_SUMMARY="$OUTPUT_DIR/error_summary_$TIMESTAMP.txt"

# Clear or create output files
> "$ERROR_SUMMARY"

# Create CSV file with headers
echo "repository_name,migration_id,error_message,error_type,directory_path" > "$ERROR_CSV"

# Create a temporary file to store all error messages for later processing
TEMP_ERROR_MESSAGES=$(mktemp)
TEMP_NORMALIZED_ERRORS=$(mktemp)
TEMP_ERROR_COUNT=$(mktemp)

echo "Starting migration log analysis..."
echo "Analyzing files in $BASE_DIR..."
echo "Include potential errors: $INCLUDE_POTENTIAL"

# Function to process a repository's stderr file
process_repo_stderr() {
    local repo_path="$1"
    local repo_name="$(basename "$repo_path")"
    local stderr_file="$repo_path/stderr"
    local parent_dir="$(dirname "$repo_path")"
    
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
        fi
        
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
        
        # Extract and store error messages and write to CSV
        while IFS= read -r line; do
            # Save the original message for detailed reporting
            error_message=$(echo "$line" | sed 's/.*\[ERROR\] //')
            echo "$error_message" >> "$TEMP_ERROR_MESSAGES"
            
            # Add to normalized errors for pattern counting
            if [[ "$error_message" =~ Migration\ Failed\.|Failed\ to\ get\ migration\ state\ for\ migration ]]; then
                normalized=$(echo "$error_message" | sed -E 's/(RM_[a-zA-Z0-9_-]+)/RM_ID/g')
                echo "$normalized" >> "$TEMP_NORMALIZED_ERRORS"
            elif [[ "$error_message" =~ "Repository with name" && "$error_message" =~ "already exists" ]]; then
                # Handle repository name conflict errors consistently
                # First normalize the repo name
                normalized=$(echo "$error_message" | sed -E 's/Repository with name ([a-zA-Z0-9_-]+) already exists/Repository with name {REPO_NAME} already exists/g')
                
                # Then handle the metadata part if present
                if [[ "$normalized" =~ "meta:" ]]; then
                    normalized=$(echo "$normalized" | sed -E 's/meta:.*$/meta: {REPO_DETAILS}/')
                fi
                
                echo "$normalized" >> "$TEMP_NORMALIZED_ERRORS"
            else
                echo "$error_message" >> "$TEMP_NORMALIZED_ERRORS"
            fi
            
            # Write to CSV - if there are migration IDs, write one row per ID
            # Otherwise write a single row with empty migration_id
            if [ ${#migration_ids[@]} -eq 0 ]; then
                # Escape double quotes in error message and enclose in quotes
                escaped_error=$(echo "$error_message" | sed 's/"/""/g')
                echo "\"$repo_name\",\"\",\"$escaped_error\",\"$error_type\",\"$parent_dir\"" >> "$ERROR_CSV"
            else
                for id in "${migration_ids[@]}"; do
                    escaped_error=$(echo "$error_message" | sed 's/"/""/g')
                    echo "\"$repo_name\",\"$id\",\"$escaped_error\",\"$error_type\",\"$parent_dir\"" >> "$ERROR_CSV"
                done
            fi
        done < <(grep "\[ERROR\]" "$stderr_file")
        
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

# Count unique migration IDs in the CSV file
confirmed_migration_id_count=$(grep -c ",\"confirmed\"," "$ERROR_CSV" || echo 0)
potential_migration_id_count=$(grep -c ",\"potential\"," "$ERROR_CSV" || echo 0)

# Process and count unique error patterns
unique_error_count=0
unique_errors=""

if [[ -f "$TEMP_NORMALIZED_ERRORS" && -s "$TEMP_NORMALIZED_ERRORS" ]]; then
    # Create a list of unique errors with their counts
    sort "$TEMP_NORMALIZED_ERRORS" | uniq -c | sort -nr > "$TEMP_ERROR_COUNT"
    unique_error_count=$(wc -l < "$TEMP_ERROR_COUNT" | tr -d ' ')
    
    # Format the list of unique errors directly into a temporary file
    TEMP_UNIQUE_ERRORS=$(mktemp)
    while IFS= read -r line; do
        count=$(echo "$line" | awk '{print $1}')
        error=$(echo "$line" | cut -d' ' -f2-)
        echo "- $count occurrences: $error" >> "$TEMP_UNIQUE_ERRORS"
    done < "$TEMP_ERROR_COUNT"
fi

# Create a filtered CSV if we're not including potential errors
FINAL_ERROR_CSV="$ERROR_CSV"
if [ "$INCLUDE_POTENTIAL" = "false" ]; then
    FILTERED_CSV="${ERROR_CSV%.csv}_confirmed_only.csv"
    # Copy header from original CSV
    head -n 1 "$ERROR_CSV" > "$FILTERED_CSV"
    # Only include confirmed errors
    grep ",\"confirmed\"," "$ERROR_CSV" >> "$FILTERED_CSV"
    # Use this as our final CSV
    FINAL_ERROR_CSV="$FILTERED_CSV"
    
    # Update counts for summary
    potential_error_count=0
    potential_migration_id_count=0
fi

# Generate summary and save to summary file
summary_content="
==== ERROR SUMMARY ====
Total repositories analyzed: $repo_count
Repositories with confirmed errors: $confirmed_error_count"

# Only include potential errors in summary if INCLUDE_POTENTIAL is true
if [ "$INCLUDE_POTENTIAL" = "true" ]; then
    summary_content+="
Repositories with potential issues: $potential_error_count
Total repositories with errors/issues: $((confirmed_error_count + potential_error_count))"
else
    summary_content+="
Note: Potential errors are excluded based on --include-potential=false option"
fi

summary_content+="

Migration IDs in confirmed errors: $confirmed_migration_id_count"

if [ "$INCLUDE_POTENTIAL" = "true" ]; then
    summary_content+="
Migration IDs in potential issues: $potential_migration_id_count"
fi

summary_content+="
Unique error patterns found: $unique_error_count

==== ERROR CATEGORIES ====
CONFIRMED ERRORS - These indicate definite migration failures:
- \"Migration Failed\" messages
- \"Git source migration failed\" messages
- \"An unexpected system error has caused the migration to fail\" messages
- \"API rate limit exceeded\" messages"

if [ "$INCLUDE_POTENTIAL" = "true" ]; then
    summary_content+="

POTENTIAL ISSUES - These may not indicate actual failures:
- \"Failed to lookup the Organization ID\" messages
- \"Failed to get migration state\" messages
- Other error messages that don't clearly indicate migration failure"
fi

summary_content+="

==== UNIQUE ERROR PATTERNS ===="

# Write the summary content to the file
echo "$summary_content" > "$ERROR_SUMMARY"

# Append unique errors directly from the temp file if it exists
if [[ -f "$TEMP_UNIQUE_ERRORS" && -s "$TEMP_UNIQUE_ERRORS" ]]; then
    cat "$TEMP_UNIQUE_ERRORS" >> "$ERROR_SUMMARY"
else
    echo -e "\nNo unique error patterns found." >> "$ERROR_SUMMARY"
fi

# Add the output files section
echo -e "\n==== OUTPUT FILES ====" >> "$ERROR_SUMMARY"
echo "CSV error report: $FINAL_ERROR_CSV" >> "$ERROR_SUMMARY"
echo "Error summary: $ERROR_SUMMARY" >> "$ERROR_SUMMARY"

# Clean up temporary files
rm -f "$TEMP_ERROR_MESSAGES" "$TEMP_NORMALIZED_ERRORS" "$TEMP_ERROR_MESSAGES.tmp" "$TEMP_ERROR_COUNT" "$TEMP_UNIQUE_ERRORS"

echo "Analysis complete! Results saved to:"
echo "- $FINAL_ERROR_CSV"
echo "- $ERROR_SUMMARY"