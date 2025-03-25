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

## Setup

Grant permissions

```
chmod +x analyze_logs.sh
```

## Usage

There are some optional arguments you can provide to the script but if not specified these will have default values:

Run `./analyze_logs.sh --help` to see the following output:

```
Options:
  -b, --base-dir DIR      Specify the base directory containing migration logs (default: ./migrations)
  -o, --output-dir DIR    Specify the output directory for analysis files (default: ./logs_analysis)
  -p, --include-potential Include potential errors in output (default: true)
                          Use --include-potential=false to exclude
  -h, --help              Display this help message
```

To use default options:

```
./analyze_logs.sh
```

To specify a base directory (defaults to `./migrations` if not specified):

```
./analyze_logs.sh --base-dir /path/to/migrations/logs/folder
```

To specify an output directory (defaults to `./logs_analysis` if not specified):

```
./analyze_logs.sh --output-dir /path/to/output
```

To specify both directories:

```
./analyze_logs.sh --base-dir /path/to/migrations/logs/folder --output-dir /path/to/output
```

### Error Types

Some of the errors that are identified may be transitive errors and are actually successes. These errors are indicated in the csv output with a type of `potential`. Anything that is believed to be a hard error has a type of `confirmed`.

You can optionally filter out the ones that are potential by using the `--include-potential=false` option

```
./analyze_logs.sh --include-potential=false
```

Using the above command will produce results that filter out any that were marked with a type of `potential` and likely are transitive errors.