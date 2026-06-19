#!/bin/bash

# Modified from: AWS team https://github.com/aws-samples/redshift-migrate-db
set -e

# Use secure path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

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

# Test connections to both source and target
echo "Testing source connection..."
run_psql_with_retry "Source connection test" \
    psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -c "SELECT 1;" || {
    echo "ERROR: Cannot connect to source cluster"
    exit 1
}

echo "Testing target connection..."
run_psql_with_retry "Target connection test" \
    psql -h "$TARGET_PGHOST" -p "$TARGET_PGPORT" -d "$TARGET_PGDATABASE" -U "$TARGET_PGUSER" -c "SELECT 1;" || {
    echo "ERROR: Cannot connect to target cluster"
    exit 1
}

exec_dir="exec_users"
# Secure directory operations
if [ -d "$PWD/${exec_dir}" ]; then
    rm -rf "$PWD/${exec_dir}"
fi
mkdir -p "$PWD/${exec_dir}"
tmp_password="$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 16)Aa1#"

# Counters for summary
USERS_CREATED=0
USERS_SKIPPED=0
USERS_FAILED=0
GROUPS_CREATED=0
GROUPS_SKIPPED=0
GROUPS_FAILED=0
MEMBERSHIPS_ADDED=0
MEMBERSHIPS_FAILED=0

create_user()
{
    prefix="create_user"
    i="0"
    obj_count=$(psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -t -A -c "SELECT COUNT(*) FROM pg_user_info WHERE usename LIKE '%${TENANT_NAME}%'" 2>/dev/null)
    echo "INFO: ${prefix}:creating ${obj_count}"
    
    while IFS= read -r usename; do
        [ -z "$usename" ] && continue
        i=$((i+1))
        exec_script="${exec_dir}/${prefix}_${i}.sh"
        cat > ${exec_script} << 'SCRIPT_HEADER'
#!/bin/bash
set -e
MAX_RETRIES=RETRY_PLACEHOLDER
RETRY_DELAY=5

run_psql() {
    local desc="$1"; shift
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        echo "WARN: ${desc} failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done
    echo "ERROR: ${desc} failed after ${MAX_RETRIES} attempts"
    return 1
}
SCRIPT_HEADER
        # Replace retry placeholder with actual value
        sed -i.bak "s/RETRY_PLACEHOLDER/${MAX_RETRIES}/" ${exec_script} && rm -f ${exec_script}.bak

        echo -e "echo \"INFO: Creating user \\\"${usename}\\\"\"" >> ${exec_script}
        echo -e "count=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_user_info WHERE usename = '${usename}'\" 2>/dev/null)" >> ${exec_script}
        echo -e "if [ \"\${count}\" -eq \"1\" ]; then" >> ${exec_script}
        echo -e "\techo \"INFO: User \\\"${usename}\\\" already exists. Skipping.\"" >> ${exec_script}
        echo -e "else" >> ${exec_script}
        
        echo -e "\tfor i in \$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c \"
            SELECT 
                CASE WHEN usecreatedb THEN 'CREATEDB' ELSE 'NOCREATEDB' END,
                CASE WHEN usesuper THEN 'CREATEUSER' ELSE 'NOCREATEUSER' END,
                'UNRESTRICTED' AS syslogaccess, 
                COALESCE(CAST(useconnlimit AS TEXT), '0') as useconnlimit,
                '0' as sessiontimeout
            FROM pg_user_info 
            WHERE usename = '${usename}'\" 2>/dev/null); do" >> ${exec_script}
        
        echo -e "\t\tusecreatedb=\$(echo \$i | awk -F '|' '{print \$1}')" >> ${exec_script}
        echo -e "\t\tusesuper=\$(echo \$i | awk -F '|' '{print \$2}')" >> ${exec_script}
        echo -e "\t\tsyslogaccess=\$(echo \$i | awk -F '|' '{print \$3}')" >> ${exec_script}
        echo -e "\t\tuseconnlimit=\$(echo \$i | awk -F '|' '{print \$4}')" >> ${exec_script}
        echo -e "\t\tsessiontimeout=\$(echo \$i | awk -F '|' '{print \$5}')" >> ${exec_script}
        
        echo -e "\t\tif [ \"\${sessiontimeout}\" -eq \"0\" ]; then" >> ${exec_script}
        echo -e "\t\t\ttimeout=\"\"" >> ${exec_script}
        echo -e "\t\telse" >> ${exec_script}
        echo -e "\t\t\ttimeout=\"TIMEOUT ${sessiontimeout}\"" >> ${exec_script}
        echo -e "\t\tfi" >> ${exec_script}
        
        echo -e "\t\texec_sql=\"CREATE USER \\\"${usename}\\\" PASSWORD '${tmp_password}' \${usecreatedb} \${usesuper} SYSLOG ACCESS \${syslogaccess} CONNECTION LIMIT \${useconnlimit} \${timeout} VALID UNTIL 'infinity';\"" >> ${exec_script}
        echo -e "\t\trun_psql \"Create user ${usename}\" psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"\${exec_sql}\" -e" >> ${exec_script}
        echo -e "\tdone" >> ${exec_script}
        echo -e "fi" >> ${exec_script}
        
        echo -e "echo \"Set user config\"" >> ${exec_script}
        echo -e "for i in \$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c \"SELECT split_part(array_to_string(sub.useconfig, ','), ',', i) AS useconfig FROM (SELECT generate_series(1, array_upper(useconfig, 1)) AS i, useconfig FROM pg_user WHERE usename = '${usename}' AND useconfig IS NOT NULL) AS sub ORDER BY 1;\" 2>/dev/null); do" >> ${exec_script}
        echo -e "\tuseconfig=\$(echo \${i} | awk -F '|' '{print \$1}')" >> ${exec_script}
        echo -e "\tcount=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM (SELECT usename, generate_series(1, array_upper(useconfig, 1)) AS i, useconfig FROM pg_user WHERE useconfig IS NOT NULL) AS sub WHERE sub.usename = '${usename}' AND split_part(array_to_string(sub.useconfig, ','), ',', i) = '\${useconfig}'\" 2>/dev/null)" >> ${exec_script}
        echo -e "\tif [ \"\${count}\" -eq \"1\" ]; then" >> ${exec_script}
        echo -e "\t\techo \"INFO: User ${usename} config \\\"\${useconfig}\\\" already set.\"" >> ${exec_script}
        echo -e "\telse" >> ${exec_script}
        echo -e "\t\trun_psql \"Set config for ${usename}\" psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"ALTER USER \\\"${usename}\\\" SET \${useconfig};\" -e" >> ${exec_script}
        echo -e "\tfi" >> ${exec_script}
        echo -e "done" >> ${exec_script}
        chmod 755 ${exec_script}

        wait_for_threads "${exec_dir}"
        echo "INFO: ${prefix}:${i}:${obj_count}:${usename}"
        ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
    done < <(psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -t -A -c "SELECT usename FROM pg_user_info WHERE usename LIKE '%${TENANT_NAME}%' ORDER BY usename" 2>/dev/null)
    wait_for_remaining "${exec_dir}"

    # Check results from logs
    if [ -d "$PWD/log" ]; then
        USERS_CREATED=$(grep -l "INFO: Creating user" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        USERS_SKIPPED=$(grep -l "already exists. Skipping" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        USERS_FAILED=$(grep -l "ERROR:" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        # Adjust: created = total attempted - skipped - failed
        USERS_CREATED=$((USERS_CREATED - USERS_SKIPPED))
    fi
}

create_group()
{
    prefix="create_group"
    i="0"
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_group" 2>/dev/null)
    echo "INFO: ${prefix}:creating ${obj_count}"
    for groname in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT groname FROM pg_group ORDER BY groname" 2>/dev/null); do
        i=$((i+1))
        exec_script="${exec_dir}/${prefix}_${i}.sh"
        cat > ${exec_script} << 'SCRIPT_HEADER'
#!/bin/bash
set -e
MAX_RETRIES=RETRY_PLACEHOLDER
RETRY_DELAY=5

run_psql() {
    local desc="$1"; shift
    local attempt=1
    while [ $attempt -le $MAX_RETRIES ]; do
        if "$@" 2>/dev/null; then
            return 0
        fi
        echo "WARN: ${desc} failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        attempt=$((attempt + 1))
    done
    echo "ERROR: ${desc} failed after ${MAX_RETRIES} attempts"
    return 1
}
SCRIPT_HEADER
        sed -i.bak "s/RETRY_PLACEHOLDER/${MAX_RETRIES}/" ${exec_script} && rm -f ${exec_script}.bak

        echo -e "echo \"INFO: Creating group \\\"${groname}\\\"\"" >> ${exec_script}
        echo -e "count=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_group WHERE groname = '${groname}'\" 2>/dev/null)" >> ${exec_script}
        echo -e "if [ \"\${count}\" -eq \"1\" ]; then" >> ${exec_script}
        echo -e "\techo \"INFO: Group \\\"${groname}\\\" already exists. Skipping.\"" >> ${exec_script}
        echo -e "else" >> ${exec_script}
        echo -e "\trun_psql \"Create group ${groname}\" psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"CREATE GROUP \\\"${groname}\\\";\" -e" >> ${exec_script}
        echo -e "fi" >> ${exec_script}
        chmod 755 ${exec_script}

        wait_for_threads "${exec_dir}"
        echo "INFO: ${prefix}:${i}:${obj_count}:${groname}"
        ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
    done
    wait_for_remaining "${exec_dir}"

    # Check results from logs
    if [ -d "$PWD/log" ]; then
        GROUPS_CREATED=$(grep -l "INFO: Creating group" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        GROUPS_SKIPPED=$(grep -l "already exists. Skipping" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        GROUPS_FAILED=$(grep -l "ERROR:" $PWD/log/${prefix}_*.log 2>/dev/null | wc -l)
        # Adjust: created = total attempted - skipped - failed
        GROUPS_CREATED=$((GROUPS_CREATED - GROUPS_SKIPPED))
    fi
}

add_user_to_group()
{
    prefix="add_user_to_group"
    i="0"
    OLDIFS=$IFS
    IFS=$'\n'
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM (SELECT groname, grolist, generate_series(1, array_upper(grolist, 1)) AS i FROM pg_group) AS g JOIN pg_user u ON g.grolist[i] = u.usesysid" 2>/dev/null)
    echo "INFO: ${prefix}:creating ${obj_count}"
    for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT u.usename, g.groname FROM (SELECT groname, grolist, generate_series(1, array_upper(grolist, 1)) AS i FROM pg_group) AS g JOIN pg_user u ON g.grolist[i] = u.usesysid ORDER BY u.usename, g.groname" 2>/dev/null); do
        i=$((i+1))
        usename=$(echo ${x} | awk -F '|' '{print $1}')
        groname=$(echo ${x} | awk -F '|' '{print $2}')
        wait_for_threads "${tag}"
        echo "INFO: ${prefix}:${i}:${obj_count}:${groname}:${usename}"

        # Retry logic for group membership
        attempt=1
        success=false
        while [ $attempt -le $MAX_RETRIES ]; do
            if psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER \
                -c "ALTER GROUP \"${groname}\" ADD USER \"${usename}\"" -e > $PWD/log/${prefix}_${i}.log 2>&1; then
                success=true
                MEMBERSHIPS_ADDED=$((MEMBERSHIPS_ADDED + 1))
                break
            fi
            echo "WARN: Add ${usename} to ${groname} failed (attempt ${attempt}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
            sleep $RETRY_DELAY
            attempt=$((attempt + 1))
        done

        if [ "$success" = false ]; then
            echo "ERROR: Failed to add ${usename} to group ${groname} after ${MAX_RETRIES} attempts"
            MEMBERSHIPS_FAILED=$((MEMBERSHIPS_FAILED + 1))
        fi
    done
    wait_for_remaining "${tag}"
    IFS=$OLDIFS
}

## Execute with error handling via exec_fn from common.sh
exec_fn create_user
exec_fn create_group
exec_fn add_user_to_group

## Summary
echo "============================================"
echo "INFO: Migration Summary - Users & Groups"
echo "============================================"
echo "  Users created:        ${USERS_CREATED}"
echo "  Users skipped:        ${USERS_SKIPPED}"
echo "  Users failed:         ${USERS_FAILED}"
echo "  Groups created:       ${GROUPS_CREATED}"
echo "  Groups skipped:       ${GROUPS_SKIPPED}"
echo "  Groups failed:        ${GROUPS_FAILED}"
echo "  Memberships added:    ${MEMBERSHIPS_ADDED}"
echo "  Memberships failed:   ${MEMBERSHIPS_FAILED}"
echo "============================================"

if [ $USERS_FAILED -gt 0 ] || [ $GROUPS_FAILED -gt 0 ] || [ $MEMBERSHIPS_FAILED -gt 0 ]; then
    echo "WARN: Some operations failed. Check logs in $PWD/log/ for details."
fi

echo "INFO: Migrate users and groups step complete"
