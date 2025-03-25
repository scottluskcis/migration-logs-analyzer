#!/bin/bash   

# Default directory settings
DEFAULT_BASE_DIR="./migrations"
DEFAULT_OUTPUT_DIR="./logs_analysis"

# Initialize with defaults
BASE_DIR="$DEFAULT_BASE_DIR"
OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"

# Display help function
display_help() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -b, --base-dir DIR      Specify the base directory containing migration logs (default: $DEFAULT_BASE_DIR)"
    echo "  -o, --output-dir DIR    Specify the output directory for analysis files (default: $DEFAULT_OUTPUT_DIR)"
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

# Output file with timestamp
MIGRATION_IDS_CSV="$OUTPUT_DIR/migration_ids_$TIMESTAMP.csv"

# Create CSV file with headers
echo "repository_name,migration_id" > "$MIGRATION_IDS_CSV"

# Function to process a repository's stdout and stderr files
process_repo_stdout_and_stderr() {
    local repo_path="$1"
    local repo_name="$(basename "$repo_path")"
    local stdout_file="$repo_path/stdout"
    local stderr_file="$repo_path/stderr"
    local migration_ids=()

    # Check if stdout file exists
    if [[ -f "$stdout_file" && -s "$stdout_file" ]]; then
        # Extract migration IDs from stdout file with different patterns
        local migration_id_array=()
        while read -r line; do
            migration_id_array+=("$line")
        done < <(grep -o "Migration ID: RM_[a-zA-Z0-9_-]*" "$stdout_file" | sed 's/Migration ID: //' | sort -u)

        local migration_id_array2=()
        while read -r line; do
            migration_id_array2+=("$line")
        done < <(grep -o "migration RM_[a-zA-Z0-9_-]*" "$stdout_file" | sed 's/migration //' | sort -u)

        local migration_id_array3=()
        while read -r line; do
            migration_id_array3+=("$line")
        done < <(grep -o "\(ID: RM_[a-zA-Z0-9_-]*\)" "$stdout_file" | sed -E 's/\(ID: (RM_[a-zA-Z0-9_-]*)\)/\1/' | sort -u)

        # Combine all unique migration IDs
        for id in "${migration_id_array[@]}" "${migration_id_array2[@]}" "${migration_id_array3[@]}"; do
            migration_ids+=("$id")
        done
    fi

    # If no migration IDs were found in stdout, check stderr
    if [[ ${#migration_ids[@]} -eq 0 && -f "$stderr_file" && -s "$stderr_file" ]]; then
        # Extract migration IDs from stderr file with different patterns
        local migration_id_array_stderr=()
        while read -r line; do
            migration_id_array_stderr+=("$line")
        done < <(grep -o "Migration ID: RM_[a-zA-Z0-9_-]*" "$stderr_file" | sed 's/Migration ID: //' | sort -u)

        local migration_id_array2_stderr=()
        while read -r line; do
            migration_id_array2_stderr+=("$line")
        done < <(grep -o "migration RM_[a-zA-Z0-9_-]*" "$stderr_file" | sed 's/migration //' | sort -u)

        local migration_id_array3_stderr=()
        while read -r line; do
            migration_id_array3_stderr+=("$line")
        done < <(grep -o "\(ID: RM_[a-zA-Z0-9_-]*\)" "$stderr_file" | sed -E 's/\(ID: (RM_[a-zA-Z0-9_-]*)\)/\1/' | sort -u)

        # Combine all unique migration IDs from stderr
        for id in "${migration_id_array_stderr[@]}" "${migration_id_array2_stderr[@]}" "${migration_id_array3_stderr[@]}"; do
            migration_ids+=("$id")
        done
    fi

    # Remove duplicates and filter out incomplete IDs
    migration_ids=($(echo "${migration_ids[@]}" | tr ' ' '\n' | grep -E '^RM_[a-zA-Z0-9_-]+$' | sort -u | tr '\n' ' '))

    # Write to CSV - if there are migration IDs, write one row per ID
    # Otherwise write a single row with empty migration_id
    if [ ${#migration_ids[@]} -eq 0 ]; then
        echo "\"$repo_name\",\"\"" >> "$MIGRATION_IDS_CSV"
    else
        # Consolidate all IDs into a single entry for the repository
        local consolidated_ids=$(IFS=","; echo "${migration_ids[*]}")
        echo "\"$repo_name\",\"$consolidated_ids\"" >> "$MIGRATION_IDS_CSV"
    fi

    return 0  # Successfully processed
}

echo "Starting migration ID extraction..."
echo "Analyzing files in $BASE_DIR..."

# Initialize counters
repo_count=0
repo_with_id_count=0
total_migration_id_count=0

# Process all repositories checking for specific migration-logs directory structure
migration_log_dirs=()
while IFS= read -r dir; do
  migration_log_dirs+=("$dir")
done < <(find "$BASE_DIR" -type d -name "migration-logs" 2>/dev/null)

# If migration-logs directories exist, process them
if [ ${#migration_log_dirs[@]} -gt 0 ]; then
    for migration_log_dir in "${migration_log_dirs[@]}"; do
        # Look for directories inside migration-logs
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
                process_repo_stdout_and_stderr "$repo_dir"
            done
        done
    done
else
    # If no specific migration-logs structure, look for directories that might contain octoshift logs
    # Assume we're directly in a directory with repository log directories
    repo_dirs=()
    while IFS= read -r dir; do
        repo_dirs+=("$dir")
    done < <(find "$BASE_DIR" -maxdepth 1 -type d)

    for repo_dir in "${repo_dirs[@]}"; do
        # Skip the base directory itself
        if [[ "$repo_dir" == "$BASE_DIR" ]]; then
            continue
        fi

        ((repo_count++))
        process_repo_stdout_and_stderr "$repo_dir"
    done

    # Also check if the base directory itself contains octoshift logs (not within subdirectories)
    octoshift_logs=()
    while IFS= read -r log_file; do
        octoshift_logs+=("$log_file")
    done < <(find "$BASE_DIR" -maxdepth 1 -name "*.octoshift.log" 2>/dev/null)

    if [ ${#octoshift_logs[@]} -gt 0 ]; then
        # Extract migration IDs from these log files
        migration_ids=()

        for log_file in "${octoshift_logs[@]}"; do
            local temp_ids=()
            while read -r line; do
                temp_ids+=("$line")
            done < <(grep -o "Migration ID: RM_[a-zA-Z0-9_-]*" "$log_file" | sed 's/Migration ID: //' | sort -u)

            # Extract the repository name from the log file name
            local repo_name=$(basename "$log_file" | sed 's/\.octoshift\.log$//')

            # Write each ID to CSV
            for id in "${temp_ids[@]}"; do
                echo "\"$repo_name\",\"$id\",\"$BASE_DIR\"" >> "$MIGRATION_IDS_CSV"
            done

            # If no IDs found, write an empty entry
            if [ ${#temp_ids[@]} -eq 0 ]; then
                echo "\"$repo_name\",\"\",\"$BASE_DIR\"" >> "$MIGRATION_IDS_CSV"
            fi
        done
    fi
fi

# Count statistics for the summary
repo_with_id_count=$(grep -v ',""' "$MIGRATION_IDS_CSV" | cut -d',' -f1 | sort -u | wc -l | tr -d ' ')
total_migration_id_count=$(grep -v ',""' "$MIGRATION_IDS_CSV" | wc -l | tr -d ' ')

# Generate summary
echo "
==== MIGRATION ID SUMMARY ====
Total repositories analyzed: $repo_count
Repositories with migration IDs: $repo_with_id_count
Total migration IDs found: $total_migration_id_count

Output file: $MIGRATION_IDS_CSV"

echo "Migration ID extraction complete! Results saved to:"
echo "- $MIGRATION_IDS_CSV"