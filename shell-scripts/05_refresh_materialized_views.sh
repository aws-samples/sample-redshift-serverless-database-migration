#!/bin/bash

# Refresh materialized views after data load
set -e

# Use secure path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/load_secrets.sh" ]; then
    source "$SCRIPT_DIR/load_secrets.sh"
elif [ -f "/tmp/script/load_secrets.sh" ]; then
    source "/tmp/script/load_secrets.sh"
else
    echo "ERROR: load_secrets.sh not found"
    exit 1
fi

if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
elif [ -f "/tmp/script/common.sh" ]; then
    source "/tmp/script/common.sh"
else
    echo "ERROR: common.sh not found"
    exit 1
fi

MAX_RETRIES="${RETRY:-3}"
RETRY_DELAY=5

# Retry wrapper for psql commands
run_psql_with_retry() {
    local description="$1"
    shift
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        echo "WARN: ${description} failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done
    echo "ERROR: ${description} failed after ${MAX_RETRIES} attempts"
    return 1
}

# Test target connection before starting
echo "Testing target connection..."
run_psql_with_retry "Target connection test" \
    psql -h "$TARGET_PGHOST" -p "$TARGET_PGPORT" -d "$TARGET_PGDATABASE" -U "$TARGET_PGUSER" -c "SELECT 1;" || {
    echo "ERROR: Cannot connect to target cluster"
    exit 1
}

refresh_materialized_views()
{
    prefix="refresh_materialized_view"
    i="0"
    exec_dir="exec_refresh"
    # Secure directory operations
    if [ -d "$PWD/${exec_dir}" ]; then
        rm -rf "$PWD/${exec_dir}"
    fi
    mkdir -p "$PWD/${exec_dir}"
    
    OLDIFS=$IFS
    IFS=$'\n'
    
    obj_count=$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid JOIN svv_all_schemas s ON n.nspname = s.schema_name WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN ${SCHEMAS} AND c.relkind = 'v' AND LOWER(pg_get_viewdef(c.oid)) LIKE '%materialized%'")
    
    echo "INFO: ${prefix}: refreshing ${obj_count} materialized views in parallel"
    
    for schema_name in $(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
        for view_name in $(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v' AND n.nspname = '${schema_name}' AND LOWER(pg_get_viewdef(c.oid)) LIKE '%materialized%' ORDER BY 1"); do
            i=$((i+1))
            exec_script="${exec_dir}/${prefix}_${i}.sh"
            
            echo -e "#!/bin/bash" > ${exec_script}
            echo -e "MAX_RETRIES=${MAX_RETRIES}" >> ${exec_script}
            echo -e "RETRY_DELAY=${RETRY_DELAY}" >> ${exec_script}
            echo -e "echo \"INFO: Refreshing materialized view ${schema_name}.${view_name}\"" >> ${exec_script}
            echo -e "attempt=1" >> ${exec_script}
            echo -e "while [ \$attempt -le \$MAX_RETRIES ]; do" >> ${exec_script}
            echo -e "    if psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"REFRESH MATERIALIZED VIEW \\\"${schema_name}\\\".\\\"${view_name}\\\"\" -e 2>&1; then" >> ${exec_script}
            echo -e "        echo \"INFO: Successfully refreshed ${schema_name}.${view_name}\"" >> ${exec_script}
            echo -e "        exit 0" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}
            echo -e "    echo \"WARN: Refresh ${schema_name}.${view_name} failed (attempt \${attempt}/\${MAX_RETRIES}), retrying in \${RETRY_DELAY}s...\"" >> ${exec_script}
            echo -e "    sleep \$RETRY_DELAY" >> ${exec_script}
            echo -e "    attempt=\$((attempt + 1))" >> ${exec_script}
            echo -e "done" >> ${exec_script}
            echo -e "echo \"ERROR: Failed to refresh ${schema_name}.${view_name} after \${MAX_RETRIES} attempts\"" >> ${exec_script}
            echo -e "exit 1" >> ${exec_script}
            chmod 755 ${exec_script}
            
            wait_for_threads "${exec_dir}"
            echo "INFO: ${prefix}:${i}:${obj_count}: ${schema_name}.${view_name}"
            ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
        done
    done
    
    wait_for_remaining "${exec_dir}"
    IFS=$OLDIFS
    echo "INFO: ${prefix}: completed refreshing ${obj_count} materialized views"
}

echo "INFO: Starting materialized view refresh"
refresh_materialized_views

# Count results from logs
REFRESH_SUCCESS=0
REFRESH_FAILED=0
if [ -d "$PWD/log" ]; then
    REFRESH_SUCCESS=$(grep -rl "Successfully refreshed" $PWD/log/refresh_materialized_view_*.log 2>/dev/null | wc -l)
    REFRESH_FAILED=$(grep -rl "ERROR:" $PWD/log/refresh_materialized_view_*.log 2>/dev/null | wc -l)
fi

## Summary
echo "============================================"
echo "INFO: Migration Summary - Materialized View Refresh"
echo "============================================"
echo "  Views refreshed:  ${REFRESH_SUCCESS}"
echo "  Views failed:     ${REFRESH_FAILED}"
echo "============================================"

if [ $REFRESH_FAILED -gt 0 ]; then
    echo "WARN: ${REFRESH_FAILED} materialized view refreshes failed. Check logs in $PWD/log/ for details."
fi

echo "INFO: Materialized view refresh completed"