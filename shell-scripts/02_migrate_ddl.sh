#!/bin/bash
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

# Test connections before starting
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

exec_dir="exec_ddl"
# Secure directory operations
if [ -d "$PWD/${exec_dir}" ]; then
    rm -rf "$PWD/${exec_dir}"
fi
mkdir -p "$PWD/${exec_dir}"

# Counters for summary
SCHEMAS_CREATED=0
SCHEMAS_FAILED=0
TABLES_CREATED=0
TABLES_FAILED=0
PKS_CREATED=0
PKS_FAILED=0
FKS_CREATED=0
FKS_FAILED=0
FUNCTIONS_CREATED=0
FUNCTIONS_FAILED=0
PROCEDURES_CREATED=0
PROCEDURES_FAILED=0

verify_table_creation() {
    local schema="$1"
    local tables_list
    tables_list=$(psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -t -A -c "
        SELECT c.relname 
        FROM pg_class c 
        JOIN pg_namespace n ON c.relnamespace = n.oid 
        WHERE n.nspname = '$schema' 
        AND c.relkind = 'r' 
        AND c.relname NOT LIKE 'mv_tbl__%'" 2>/dev/null)

    echo "Verifying tables in schema $schema..."
    while IFS= read -r table; do
        [ -z "$table" ] && continue
        echo "Checking table $schema.$table..."
        if ! psql -h "$TARGET_PGHOST" -p "$TARGET_PGPORT" -d "$TARGET_PGDATABASE" -U "$TARGET_PGUSER" -t -A -c "
            SELECT COUNT(*) 
            FROM information_schema.tables 
            WHERE table_schema = '$schema' 
            AND table_name = '$table'" 2>/dev/null | grep -q "^1$"; then
            echo "ERROR: Table $schema.$table not found in target"
            return 1
        fi
    done <<< "$tables_list"
    return 0
}

create_schema()
{
	local prefix="create_schema"
	local i="0"
	local OLDIFS=$IFS
	local obj_count
	local schema_name
	local exec_script
	
	# Validate SCHEMAS format
	if [[ ! "${SCHEMAS}" =~ ^\(.*\)$ ]]; then
		echo "ERROR: SCHEMAS must be in format ('schema1','schema2'). Got: ${SCHEMAS}"
		return 1
	fi
	
	# Set trap to ensure IFS restoration
	trap 'IFS=$OLDIFS' RETURN
	IFS=$'\n'
	
	if ! obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS}"); then
		echo "ERROR: Failed to query source schemas"
		return 1
	fi
	
	echo "INFO: ${prefix}:creating ${obj_count}"
	
	while IFS= read -r schema_name; do
		[[ -z "$schema_name" ]] && continue
		i=$((i+1))
		exec_script="${exec_dir}/${prefix}_${i}.sh"
		echo -e "#!/bin/bash" > ${exec_script}
		echo -e "echo \"Checking if schema ${schema_name} exists...\"" >> ${exec_script}
		echo -e "count=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_namespace WHERE nspname = '${schema_name}'\")" >> ${exec_script}
		echo -e "echo \"Schema count: \$count\"" >> ${exec_script}
		echo -e "if [ \"\${count}\" -gt \"0\" ]; then" >> ${exec_script}
		echo -e "\techo \"INFO: SCHEMA \\\"${schema_name}\\\" already exists in TARGET\"" >> ${exec_script}
		echo -e "else" >> ${exec_script}
		echo -e "\techo \"INFO: Creating Schema \\\"${schema_name}\\\"\"" >> ${exec_script}
		echo -e "\tif psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"CREATE SCHEMA \\\"${schema_name}\\\"\"; then" >> ${exec_script}
		echo -e "\t\techo \"SUCCESS: Schema \\\"${schema_name}\\\" created\"" >> ${exec_script}
		echo -e "\telse" >> ${exec_script}
		echo -e "\t\techo \"ERROR: Failed to create schema \\\"${schema_name}\\\"\"" >> ${exec_script}
		echo -e "\t\texit 1" >> ${exec_script}
		echo -e "\tfi" >> ${exec_script}
		echo -e "fi" >> ${exec_script}
		chmod 755 ${exec_script}

		wait_for_threads "${exec_dir}"
		echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}"
		# Run synchronously and capture output
		if ${exec_script}; then
			echo "Schema creation script completed successfully"
		else
			echo "ERROR: Schema creation script failed"
			return 1
		fi
	done < <(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name")
	
	wait_for_remaining "${exec_dir}"
}

create_table()
{
    prefix="create_table"
    i="0"
    OLDIFS=$IFS
    IFS=$'\n'

    echo "Starting table creation process..."
    
    #function dynamically creates the exec_script file and when run, this script dynamically creates exec_sql.
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "
        SELECT COUNT(*) 
        FROM pg_class c 
        JOIN pg_namespace n ON c.relnamespace = n.oid 
        JOIN svv_all_schemas s ON n.nspname = s.schema_name 
        LEFT JOIN (SELECT attrelid, MIN(attsortkeyord) AS min_attsortkeyord 
              FROM pg_attribute GROUP BY attrelid) a ON a.attrelid = c.oid 
        WHERE s.schema_type='local' 
        AND s.database_name = current_database() 
        AND s.schema_name IN ${SCHEMAS} 
        AND c.relkind = 'r' 
        AND c.relname NOT LIKE 'mv_tbl__%' 
        AND (a.min_attsortkeyord >= 0 OR a.min_attsortkeyord IS NULL)")
    
    echo "INFO: ${prefix}:creating ${obj_count} tables"

    for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "
        SELECT schema_name 
        FROM svv_all_schemas 
        WHERE database_name = current_database() 
        AND schema_type = 'local' 
        AND schema_name IN ${SCHEMAS} 
        ORDER BY schema_name"); do
        
        echo "Processing schema: ${schema_name}"

        # First verify schema exists in target
        schema_exists=$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c "
            SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '${schema_name}'")
        
        if [ "$schema_exists" -eq "0" ]; then
            echo "ERROR: Schema ${schema_name} does not exist in target database"
            return 1
        fi

        for table_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "
            SELECT REPLACE(c.relname, '\\\$', '\\\\\$') 
            FROM pg_class c 
            JOIN pg_namespace n ON c.relnamespace = n.oid 
            WHERE c.relkind = 'r' 
            AND n.nspname = '${schema_name}' 
            AND c.relname NOT LIKE 'mv_tbl__%' 
            ORDER BY REPLACE(c.relname, '\\\$', '\\\\\$')"); do
            
            echo "Processing table: ${schema_name}.${table_name}"
            
            i=$((i+1))
            exec_script="${exec_dir}/${prefix}_${i}.sh"
            exec_sql="${exec_dir}/${prefix}_${i}.sql"

            # Create execution script with error handling
            echo -e "#!/bin/bash" > ${exec_script}
            echo -e "set -e" >> ${exec_script}

            # Add logging function
            echo -e "log_message() { echo \"\$(date '+%Y-%m-%d %H:%M:%S') \$1\"; }" >> ${exec_script}
            
            echo -e "log_message \"Creating table \\\"${schema_name}\\\".\\\"${table_name}\\\"\"" >> ${exec_script}

            # Check if table exists
            echo -e "target_table_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'r' AND n.nspname = '${schema_name}' AND c.relname = '${table_name}'\")" >> ${exec_script}

            # Handle table creation or update
            echo -e "if [ \"\${target_table_exists}\" -gt \"0\" ]; then" >> ${exec_script}
            echo -e "    log_message \"Table exists, checking identity columns...\"" >> ${exec_script}
            
            # Your existing identity column logic here
            # ... [previous identity column logic remains the same]

            echo -e "else" >> ${exec_script}
            echo -e "    log_message \"Generating table DDL...\"" >> ${exec_script}
            echo -e "    if ! table_ddl=\$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -f get_table_ddl.sql -v schema_name=\"'${schema_name}'\" -v table_name=\"'${table_name}'\"); then" >> ${exec_script}
            echo -e "        log_message \"ERROR: Failed to get table DDL\"" >> ${exec_script}
            echo -e "        exit 1" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}
            
            echo -e "    echo \"\${table_ddl}\" > ${exec_sql}" >> ${exec_script}
            echo -e "    log_message \"Creating table...\"" >> ${exec_script}
            
            # Execute CREATE TABLE with verification
            echo -e "    for attempt in \$(seq 1 3); do" >> ${exec_script}
            echo -e "        if psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -f ${exec_sql}; then" >> ${exec_script}
            echo -e "            log_message \"Table creation command executed, verifying...\"" >> ${exec_script}
            echo -e "            if psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"SELECT 1 FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}';\" >/dev/null 2>&1; then" >> ${exec_script}
            echo -e "                log_message \"Table created successfully\"" >> ${exec_script}
            echo -e "                break" >> ${exec_script}
            echo -e "            fi" >> ${exec_script}
            echo -e "        fi" >> ${exec_script}
            echo -e "        log_message \"Attempt \${attempt}: Table creation failed or verification failed, retrying...\"" >> ${exec_script}
            echo -e "        sleep 5" >> ${exec_script}
            echo -e "    done" >> ${exec_script}

            # Final verification
            echo -e "    if ! psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"SELECT 1 FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}';\" >/dev/null 2>&1; then" >> ${exec_script}
            echo -e "        log_message \"ERROR: Failed to create table ${schema_name}.${table_name} after all attempts\"" >> ${exec_script}
            echo -e "        exit 1" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}

            # Verify table structure
            echo -e "    log_message \"Verifying table structure...\"" >> ${exec_script}
            echo -e "    psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"\\d+ \\\"${schema_name}\\\".\\\"${table_name}\\\"\"" >> ${exec_script}
            
            echo -e "fi" >> ${exec_script}

            chmod 755 ${exec_script}

            # Execute with proper waiting
            wait_for_threads "${exec_dir}"
            echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}"
            ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
        done
    done
    
    wait_for_remaining "${exec_dir}"
    
    # Final verification of all tables
    echo "Performing final verification of all tables..."
    for schema_name in $(echo ${SCHEMAS} | tr -d "()" | tr "," "\n"); do
        schema_name=$(echo $schema_name | tr -d "'" | xargs)
        
        source_tables=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "
            SELECT LISTAGG(c.relname, ',')
            FROM pg_class c 
            JOIN pg_namespace n ON c.relnamespace = n.oid 
            WHERE n.nspname = '${schema_name}' 
            AND c.relkind = 'r' 
            AND c.relname NOT LIKE 'mv_tbl__%'")
        
        for table_name in $(echo $source_tables | tr ',' '\n'); do
            if ! psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "
                SELECT 1 FROM information_schema.tables 
                WHERE table_schema = '${schema_name}' 
                AND table_name = '${table_name}';" >/dev/null 2>&1; then
                echo "ERROR: Table ${schema_name}.${table_name} missing in target after creation"
                return 1
            fi
        done
    done
    
    echo "All tables verified successfully"
    
    IFS=$OLDIFS
}

create_primary_key()
{
    prefix="create_primary_key"
    i="0"
    OLDIFS=$IFS
    IFS=$'\n'
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'p' AND n.nspname IN ${SCHEMAS}")
    echo "INFO: ${prefix}:creating ${obj_count}"
    for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
        for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT con.oid, con.conname, c.relname AS table_name FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'p' AND n.nspname = '${schema_name}' ORDER BY c.relname;"); do
            oid=$(echo ${x} | awk -F '|' '{print $1}')
            conname=$(echo ${x} | awk -F '|' '{print $2}')
            table_name=$(echo ${x} | awk -F '|' '{print $3}')
            i=$((i+1))
            exec_script="${exec_dir}/${prefix}_${i}.sh"
            echo -e "#!/bin/bash" > ${exec_script}
            # First check if table exists in target
            echo -e "table_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}'\")" >> ${exec_script}
            echo -e "if [ \"\${table_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "\techo \"INFO: Skipping primary key creation for ${schema_name}.${table_name} as table does not exist in target\"" >> ${exec_script}
            echo -e "else" >> ${exec_script}
            echo -e "\tconstraint_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'p' AND n.nspname = '${schema_name}' AND c.relname = '${table_name}'\")" >> ${exec_script}
            echo -e "\tif [ \"\${constraint_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "\t\texec_sql=\"ALTER TABLE \\\"${schema_name}\\\".\\\"${table_name}\\\" ADD CONSTRAINT \\\"${conname}\\\" \"" >> ${exec_script}
            echo -e "\t\texec_sql+=\$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c \"SELECT pg_get_constraintdef(${oid});\")" >> ${exec_script}
            echo -e "\t\texec_sql+=\";\"" >> ${exec_script}
            echo -e "\t\tpsql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"\${exec_sql}\" -e" >> ${exec_script}
            echo -e "\telse" >> ${exec_script}
            echo -e "\t\techo \"INFO: Primary key ${conname} ON ${schema_name}.${table_name} already exists.\"" >> ${exec_script}
            echo -e "\tfi" >> ${exec_script}
            echo -e "fi" >> ${exec_script}
            chmod 755 ${exec_script}

            wait_for_threads "${exec_dir}"
            echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}:${conname}"
            ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
        done
    done
    wait_for_remaining "${exec_dir}"
    IFS=$OLDIFS
}

create_foreign_key()
{
    prefix="create_foreign_key"
    i="0"
    OLDIFS=$IFS
    IFS=$'\n'
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'f' AND n.nspname IN ${SCHEMAS} AND c.relname NOT LIKE 'mv_tbl__%';")
    echo "INFO: ${prefix}:creating ${obj_count}"
    for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
        for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT con.oid, con.conname, c.relname AS table_name, p.relname AS reference_table_name FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_class AS p ON p.oid = con.confrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'f' AND n.nspname = '${schema_name}' ORDER BY con.oid"); do
            oid=$(echo ${x} | awk -F '|' '{print $1}')
            conname=$(echo ${x} | awk -F '|' '{print $2}')
            table_name=$(echo ${x} | awk -F '|' '{print $3}')
            reference_table_name=$(echo ${x} | awk -F '|' '{print $4}')
            i=$((i+1))
            exec_script="${exec_dir}/${prefix}_${i}.sh"
            echo -e "#!/bin/bash" > ${exec_script}
            
            # Check both tables exist with detailed logging
            echo -e "echo \"Checking existence of tables ${schema_name}.${table_name} and ${schema_name}.${reference_table_name}\"" >> ${exec_script}
            
            # Check primary table
            echo -e "primary_table_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${table_name}'\")" >> ${exec_script}
            
            # Check referenced table
            echo -e "referenced_table_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '${schema_name}' AND table_name = '${reference_table_name}'\")" >> ${exec_script}
            
            # Check if both tables exist
            echo -e "if [ \"\${primary_table_exists}\" -eq \"0\" ] || [ \"\${referenced_table_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "    if [ \"\${primary_table_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "        echo \"INFO: Primary table ${schema_name}.${table_name} does not exist in target\"" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}
            echo -e "    if [ \"\${referenced_table_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "        echo \"INFO: Referenced table ${schema_name}.${reference_table_name} does not exist in target\"" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}
            echo -e "    echo \"INFO: Skipping foreign key creation for ${conname}\"" >> ${exec_script}
            echo -e "else" >> ${exec_script}
            echo -e "    echo \"Both tables exist, proceeding with foreign key creation\"" >> ${exec_script}
            echo -e "    constraint_exists=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_constraint AS con JOIN pg_class AS c ON c.relnamespace = con.connamespace AND c.oid = con.conrelid JOIN pg_class AS p ON p.oid = con.confrelid JOIN pg_namespace AS n ON n.oid = c.relnamespace WHERE c.relkind = 'r' AND con.contype = 'f' AND n.nspname = '${schema_name}' AND c.relname = '${table_name}' AND p.relname = '${reference_table_name}' AND con.conname = '${conname}'\")" >> ${exec_script}
            echo -e "    if [ \"\${constraint_exists}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "        exec_sql=\"ALTER TABLE \\\"${schema_name}\\\".\\\"${table_name}\\\" ADD CONSTRAINT \\\"${conname}\\\" \"" >> ${exec_script}
            echo -e "        exec_sql+=\$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c \"SELECT pg_get_constraintdef(${oid});\")" >> ${exec_script}
            echo -e "        exec_sql+=\";\"" >> ${exec_script}
            echo -e "        echo \"Executing: \${exec_sql}\"" >> ${exec_script}
            echo -e "        psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"\${exec_sql}\" -e" >> ${exec_script}
            echo -e "    else" >> ${exec_script}
            echo -e "        echo \"INFO: Foreign key ${conname} ON ${schema_name}.${table_name} already exists.\"" >> ${exec_script}
            echo -e "    fi" >> ${exec_script}
            echo -e "fi" >> ${exec_script}
            
            chmod 755 ${exec_script}

            wait_for_threads "${exec_dir}"
            echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}:${conname}"
            ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
        done
    done
    wait_for_remaining "${exec_dir}"
    IFS=$OLDIFS
}

create_function()
{
	prefix="create_function"
	i="0"
	OLDIFS=$IFS
	IFS=$'\n'
	obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_proc_info p JOIN pg_namespace n ON p.pronamespace = n.oid JOIN pg_language l ON p.prolang = l.oid JOIN pg_user u ON p.proowner = u.usesysid JOIN svv_all_schemas s ON s.schema_name = n.nspname WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN ${SCHEMAS} AND l.lanname IN ('sql', 'plpythonu') AND u.usename <> 'rdsdb' AND p.prokind = 'f'")
	echo "INFO: ${prefix}:creating ${obj_count}"
	for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
		#using OID because the function name can be overloaded
		for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT p.prooid, p.proname, CASE WHEN p.proallargtypes IS NULL THEN CASE WHEN oidvectortypes(p.proargtypes) = '' THEN 0 ELSE regexp_count(oidvectortypes(p.proargtypes), ',')+1 END ELSE array_upper(proallargtypes, 1) END FROM pg_proc_info p JOIN pg_namespace n ON p.pronamespace = n.oid JOIN pg_language l ON p.prolang = l.oid JOIN pg_user u ON p.proowner = u.usesysid WHERE n.nspname = '${schema_name}' AND l.lanname IN ('sql', 'plpythonu') AND u.usename <> 'rdsdb' AND p.prokind = 'f' ORDER BY p.proname"); do
			oid=$(echo ${x} | awk -F '|' '{print $1}')
			proname=$(echo ${x} | awk -F '|' '{print $2}')
			param_count=$(echo ${x} | awk -F '|' '{print $3}')
			#get parameters
			if [ "${param_count}" -eq "0" ]; then
				exec_sql="CREATE OR REPLACE FUNCTION \"${schema_name}\".\"${proname}\"("
			else
				for y in $(seq 1 ${param_count}); do
					if [ "${y}" -eq "1" ]; then
						param=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT CASE WHEN p.proargmodes IS NULL THEN ' IN' WHEN (p.proargmodes[${y}]) = 'i' THEN ' IN' WHEN (p.proargmodes[${y}]) = 'o' THEN ' OUT' WHEN (p.proargmodes[${y}]) = 'b' THEN ' INOUT' END || ' ' || COALESCE(p.proargnames[${y}], '') || ' ' || COALESCE(t.typname, split_part(oidvectortypes(p.proargtypes), ',', ${y})) FROM pg_proc_info p LEFT JOIN pg_type t ON t.oid = p.proallargtypes[${y}] WHERE p.prooid = ${oid}")
						exec_sql="CREATE OR REPLACE FUNCTION \"${schema_name}\".\"${proname}\"(${param}"
					else
						param=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT CASE WHEN p.proargmodes IS NULL THEN ' IN' WHEN (p.proargmodes[${y}]) = 'i' THEN ' IN' WHEN (p.proargmodes[${y}]) = 'o' THEN ' OUT' WHEN (p.proargmodes[${y}]) = 'b' THEN ' INOUT' END || ' ' || COALESCE(p.proargnames[${y}], '') || ' ' || COALESCE(t.typname, split_part(oidvectortypes(p.proargtypes), ',', ${y})) FROM pg_proc_info p LEFT JOIN pg_type t ON t.oid = p.proallargtypes[${y}] WHERE p.prooid = ${oid}")
						exec_sql+=", ${param}"
					fi
				done
			fi
			return_type=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT t.typname FROM pg_proc_info p JOIN pg_type t ON p.prorettype = t.oid WHERE p.prooid = ${oid};")
			exec_sql+=") returns ${return_type} AS \$\$"
			body=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT p.prosrc FROM pg_proc_info p WHERE p.prooid = ${oid}")
			exec_sql+="${body}"
			exec_sql+=" \$\$ "
			for y in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT l.lanname, CASE WHEN p.provolatile = 'i' THEN 'immutable' WHEN p.provolatile = 's' THEN 'stable' WHEN p.provolatile = 'v' THEN 'volatile' END FROM pg_proc_info p JOIN pg_language l ON p.prolang = l.oid WHERE p.prooid = ${oid}"); do
				language=$(echo $y | awk -F '|' '{print $1}')
				vol=$(echo $y | awk -F '|' '{print $2}')
			done
			exec_sql+="LANGUAGE ${language} ${vol};"

			wait_for_threads "${tag}"
			i=$((i+1))
			echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${proname}"
			psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 & 
		done
	done
	wait_for_remaining "create_function"
	IFS=$OLDIFS
}
create_procedure()
{
	prefix="create_procedure"
	i="0"
	OLDIFS=$IFS
	IFS=$'\n'
	obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_proc_info p JOIN pg_namespace n ON p.pronamespace = n.oid JOIN pg_language l ON p.prolang = l.oid JOIN pg_user u ON p.proowner = u.usesysid JOIN svv_all_schemas s ON s.schema_name = n.nspname WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN ${SCHEMAS} AND l.lanname = 'plpgsql' AND u.usename <> 'rdsdb' AND p.prokind = 'p'")
	echo "INFO: ${prefix}:creating ${obj_count}"
	for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
		#using OID because the function name can be overloaded
		for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT p.prooid, p.proname, CASE WHEN p.proallargtypes IS NULL THEN CASE WHEN oidvectortypes(p.proargtypes) = '' THEN 0 ELSE regexp_count(oidvectortypes(p.proargtypes), ',')+1 END ELSE array_upper(proallargtypes, 1) END FROM pg_proc_info p JOIN pg_namespace n ON p.pronamespace = n.oid JOIN pg_language l ON p.prolang = l.oid JOIN pg_user u ON p.proowner = u.usesysid WHERE n.nspname = '${schema_name}' AND l.lanname = 'plpgsql' AND u.usename <> 'rdsdb' AND p.prokind = 'p' ORDER BY p.proname"); do
			oid=$(echo ${x} | awk -F '|' '{print $1}')
			proname=$(echo ${x} | awk -F '|' '{print $2}')
			param_count=$(echo ${x} | awk -F '|' '{print $3}')
			#get parameters
			if [ "${param_count}" -eq "0" ]; then
				exec_sql="CREATE OR REPLACE PROCEDURE \"${schema_name}\".\"${proname}\"("
			else
				for y in $(seq 1 ${param_count}); do
					if [ "${y}" -eq "1" ]; then
						param=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT CASE WHEN p.proargmodes IS NULL THEN ' IN' WHEN (p.proargmodes[${y}]) = 'i' THEN ' IN' WHEN (p.proargmodes[${y}]) = 'o' THEN ' OUT' WHEN (p.proargmodes[${y}]) = 'b' THEN ' INOUT' END || ' ' || COALESCE(p.proargnames[${y}], '') || ' ' || COALESCE(t.typname, split_part(oidvectortypes(p.proargtypes), ',', ${y})) FROM pg_proc_info p LEFT JOIN pg_type t ON t.oid = p.proallargtypes[${y}] WHERE p.prooid = ${oid}")
						exec_sql="CREATE OR REPLACE PROCEDURE \"${schema_name}\".\"${proname}\"(${param}"
					else
						param=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT CASE WHEN p.proargmodes IS NULL THEN ' IN' WHEN (p.proargmodes[${y}]) = 'i' THEN ' IN' WHEN (p.proargmodes[${y}]) = 'o' THEN ' OUT' WHEN (p.proargmodes[${y}]) = 'b' THEN ' INOUT' END || ' ' || COALESCE(p.proargnames[${y}], '') || ' ' || COALESCE(t.typname, split_part(oidvectortypes(p.proargtypes), ',', ${y})) FROM pg_proc_info p LEFT JOIN pg_type t ON t.oid = p.proallargtypes[${y}] WHERE p.prooid = ${oid}")
						exec_sql+=", ${param}"
					fi
				done
			fi
			exec_sql+=") AS \$\$"
			body=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT p.prosrc FROM pg_proc_info p WHERE p.prooid = ${oid}")
			exec_sql+="${body}"
			exec_sql+=" \$\$ "
			security=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT CASE WHEN p.prosecdef THEN 'SECURITY DEFINER' ELSE 'SECURITY INVOKER' END FROM pg_proc_info p WHERE p.prooid = ${oid}")
			exec_sql+="LANGUAGE plpgsql ${security};"

			wait_for_threads "${tag}"
			i=$((i+1))
			echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${proname}"
			psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 &
		done
	done
	wait_for_remaining "create_procedure"
	IFS=$OLDIFS
}
# Replace the existing exec_fn calls with:
echo "Starting schema creation..."
if ! exec_fn "create_schema"; then
    echo "Schema creation failed"
    exit 1
fi

echo "Verifying schemas were created..."
for schema_name in $(echo ${SCHEMAS} | tr -d "()" | tr "," "\n"); do
    schema_name=$(echo $schema_name | tr -d "'" | xargs)
    echo "Checking if schema ${schema_name} exists..."
    
    # Debug: Show what schemas exist
    echo "Current schemas in target database:"
    psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname != 'information_schema';"
    
    count=$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_namespace WHERE nspname = '${schema_name}'")
    echo "Schema count for '${schema_name}': $count"
    
    if [ "$count" -eq "0" ]; then
        echo "ERROR: Schema ${schema_name} was not created successfully"
        echo "Checking schema creation log..."
        if [ -f "$PWD/log/create_schema_1.log" ]; then
            echo "Schema creation log contents:"
            cat "$PWD/log/create_schema_1.log"
        else
            echo "No schema creation log found"
        fi
        exit 1
    else
        echo "SUCCESS: Schema ${schema_name} exists"
    fi
done

echo "Starting table creation..."
if ! exec_fn "create_table"; then
    echo "Table creation failed"
    exit 1
fi

echo "Verifying tables before creating primary keys..."
for schema_name in $(echo ${SCHEMAS} | tr -d "()" | tr "," "\n"); do
    schema_name=$(echo $schema_name | tr -d "'" | xargs)
    echo "Checking tables in schema ${schema_name}..."
    if ! psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "
        SELECT table_name 
        FROM information_schema.tables 
        WHERE table_schema = '${schema_name}';" >/dev/null 2>&1; then
        echo "ERROR: Unable to verify tables in schema ${schema_name}"
        exit 1
    fi
done

echo "Waiting for all table creations to complete..."
sleep 10  

echo "Starting primary key creation..."
if ! exec_fn "create_primary_key"; then
    echo "Primary key creation failed"
    exit 1
fi

echo "Starting foreign key creation..."
if ! exec_fn "create_foreign_key"; then
    echo "Foreign key creation failed"
    exit 1
fi

echo "Starting function creation..."
if ! exec_fn "create_function"; then
    echo "Function creation failed"
    exit 1
fi

echo "Starting procedure creation..."
if ! exec_fn "create_procedure"; then
    echo "Procedure creation failed"
    PROCEDURES_FAILED=1
fi

# Count results from logs
if [ -d "$PWD/log" ]; then
    TABLES_CREATED=$(grep -rl "Table created successfully\|Table creation command executed" $PWD/log/create_table_*.log 2>/dev/null | wc -l)
    TABLES_FAILED=$(grep -rl "ERROR:" $PWD/log/create_table_*.log 2>/dev/null | wc -l)
    PKS_CREATED=$(grep -rl "Primary key\|ADD CONSTRAINT" $PWD/log/create_primary_key_*.log 2>/dev/null | wc -l)
    PKS_FAILED=$(grep -rl "ERROR:" $PWD/log/create_primary_key_*.log 2>/dev/null | wc -l)
    FKS_CREATED=$(grep -rl "Foreign key\|ADD CONSTRAINT" $PWD/log/create_foreign_key_*.log 2>/dev/null | wc -l)
    FKS_FAILED=$(grep -rl "ERROR:" $PWD/log/create_foreign_key_*.log 2>/dev/null | wc -l)
    FUNCTIONS_CREATED=$(grep -rl "CREATE FUNCTION" $PWD/log/create_function_*.log 2>/dev/null | wc -l)
    FUNCTIONS_FAILED=$(grep -rl "ERROR:" $PWD/log/create_function_*.log 2>/dev/null | wc -l)
    PROCEDURES_CREATED=$(grep -rl "CREATE PROCEDURE" $PWD/log/create_procedure_*.log 2>/dev/null | wc -l)
    PROCEDURES_FAILED=$(grep -rl "ERROR:" $PWD/log/create_procedure_*.log 2>/dev/null | wc -l)
fi

## Summary
echo "============================================"
echo "INFO: Migration Summary - DDL Objects"
echo "============================================"
echo "  Tables created:       ${TABLES_CREATED}"
echo "  Tables failed:        ${TABLES_FAILED}"
echo "  Primary keys created: ${PKS_CREATED}"
echo "  Primary keys failed:  ${PKS_FAILED}"
echo "  Foreign keys created: ${FKS_CREATED}"
echo "  Foreign keys failed:  ${FKS_FAILED}"
echo "  Functions created:    ${FUNCTIONS_CREATED}"
echo "  Functions failed:     ${FUNCTIONS_FAILED}"
echo "  Procedures created:   ${PROCEDURES_CREATED}"
echo "  Procedures failed:    ${PROCEDURES_FAILED}"
echo "============================================"

TOTAL_FAILED=$((TABLES_FAILED + PKS_FAILED + FKS_FAILED + FUNCTIONS_FAILED + PROCEDURES_FAILED))
if [ $TOTAL_FAILED -gt 0 ]; then
    echo "WARN: ${TOTAL_FAILED} operations failed. Check logs in $PWD/log/ for details."
fi

echo "INFO: Migrate DDL step complete"
