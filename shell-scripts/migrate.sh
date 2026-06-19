#!/bin/bash
set -e
exec 2>&1

echo "Starting migration process..."

# Use secure path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source load_secrets.sh FIRST to get database credentials
if [ -f "$SCRIPT_DIR/load_secrets.sh" ]; then
    echo "Loading database credentials..."
    source "$SCRIPT_DIR/load_secrets.sh"
else
    echo "ERROR: load_secrets.sh not found"
    exit 1
fi

# Now source common.sh which will set up PGPASSFILE with the loaded credentials
source "$SCRIPT_DIR/common.sh"

# Validate environment variables
validate_env_vars

# Require SSL for all psql connections
export PGSSLMODE="require"

echo "Testing database connections..."
psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -c "SELECT 1;" || exit 1
psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "SELECT 1;" || exit 1

# Rest of your script...

# Check if any 0*.sh files exist
if ls 0*.sh 1> /dev/null 2>&1; then
    for i in $(ls 0*.sh); do
        now=$(date "+%Y-%m-%d %T")
        echo "Starting ${i} at ${now}"
        
        if [ -x "$PWD/${i}" ]; then
            echo "Executing: $PWD/${i}"
            if ! $PWD/${i}; then
                echo "ERROR: Script ${i} failed"
                exit 1
            fi
        else
            echo "ERROR: ${i} is not executable"
            ls -la ${i}
            exit 1
        fi
    done
else
    echo "No migration scripts (0*.sh) found"
    echo "Current directory contents:"
    ls -la
fi
