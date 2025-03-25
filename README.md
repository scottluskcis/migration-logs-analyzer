# Migration Logs Analyzer

Reviews logs generated running [gei migrator](https://docs.github.com/en/migrations/using-ghe-migrator/about-ghe-migrator) to identify any errors.

Example command that produces output this script is looking for:

```console
REPO_FILE="repos.out"
SOURCE_ORG="<your source org>"
TARGET_ORG="<your target org>"

export GITHUB_TOKEN

migrate_repo() {
  local repo=$1
  echo "Starting migration for $repo"
  gh gei migrate-repo \
    --github-source-org $SOURCE_ORG \
    --source-repo "$repo" \
    --github-target-org $TARGET_ORG \
    --target-repo "$repo" \
    --github-target-pat "$GITHUB_TOKEN" \
    --github-source-pat "$GITHUB_TOKEN"
}

export -f migrate_repo

parallel --line-buffer --tag --results migration-logs -j 25 migrate_repo {} < "$REPO_FILE"
```

## Script: `analyze_logs.sh`

The `analyze_logs.sh` script reviews logs generated during the migration process to identify errors and generate a detailed analysis report.

### Setup

Grant permissions to the script:

```bash
chmod +x analyze_logs.sh
```

### Usage

Run the script with default options:

```bash
./analyze_logs.sh
```

This will:
- Scan the `./migrations` directory for logs.
- Identify errors in the logs and classify them as `confirmed` or `potential`.
- Save the results in a timestamped CSV file and a summary text file in the `./logs_analysis` directory.

#### Command-Line Options

You can customize the behavior of the script using the following options:

```bash
Options:
  -b, --base-dir DIR      Specify the base directory containing migration logs (default: ./migrations)
  -o, --output-dir DIR    Specify the output directory for analysis files (default: ./logs_analysis)
  -p, --include-potential Include potential errors in output (default: true)
                          Use --include-potential=false to exclude
  -h, --help              Display this help message
```

#### Example Commands

To use default options:

```bash
./analyze_logs.sh
```

To specify a base directory:

```bash
./analyze_logs.sh --base-dir /path/to/migrations/logs/folder
```

To specify an output directory:

```bash
./analyze_logs.sh --output-dir /path/to/output
```

To exclude potential errors:

```bash
./analyze_logs.sh --include-potential=false
```

### Output

The script generates the following output files:
- A CSV file with the following columns:
  - `repository_name`: The name of the repository.
  - `migration_id`: The migration IDs associated with the repository.
  - `error_message`: The error message extracted from the logs.
  - `error_type`: The type of error (`confirmed` or `potential`).
  - `directory_path`: The path to the repository directory.
- A summary text file with an overview of the analysis, including error counts and unique error patterns.

The files are saved in the specified output directory with timestamped filenames, e.g., `migration_errors_20250325_175911.csv` and `error_summary_20250325_175911.txt`.

## `get_migration_ids.sh`

The `get_migration_ids.sh` script extracts migration IDs from the logs generated during the migration process. It scans both `stdout` and `stderr` files for migration IDs and consolidates them into a CSV file.

### Setup

Grant permissions to the script:

```bash
chmod +x get_migration_ids.sh
```

### Usage

Run the script with default options:

```bash
./get_migration_ids.sh
```

This will:
- Scan the `./migrations` directory for logs.
- Extract migration IDs from `stdout` and `stderr` files.
- Save the results in a timestamped CSV file in the `./logs_analysis` directory.

#### Command-Line Options

You can customize the behavior of the script using the following options:

```bash
Options:
  -b, --base-dir DIR      Specify the base directory containing migration logs (default: ./migrations)
  -o, --output-dir DIR    Specify the output directory for the CSV file (default: ./logs_analysis)
  -h, --help              Display this help message
```

#### Example Commands

To use default options:

```bash
./get_migration_ids.sh
```

To specify a base directory:

```bash
./get_migration_ids.sh --base-dir /path/to/migrations/logs/folder
```

To specify an output directory:

```bash
./get_migration_ids.sh --output-dir /path/to/output
```

To specify both directories:

```bash
./get_migration_ids.sh --base-dir /path/to/migrations/logs/folder --output-dir /path/to/output
```

### Output

The script generates a CSV file with the following columns:
- `repository_name`: The name of the repository.
- `migration_id`: The migration IDs associated with the repository (consolidated into a single entry if multiple IDs are found).

The CSV file is saved in the specified output directory with a timestamped filename, e.g., `migration_ids_20250325_163149.csv`.