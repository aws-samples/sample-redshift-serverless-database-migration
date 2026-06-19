#!/bin/bash

# Modified from: AWS team https://github.com/aws-samples/redshift-migrate-db
set -e

# Use secure path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

exec_dir="exec_views"
# Secure directory operations
if [ -d "$PWD/${exec_dir}" ]; then
    rm -rf "$PWD/${exec_dir}"
fi
mkdir -p "$PWD/${exec_dir}"


create_materialized_view()
{
	prefix="create_materialized_view"
	i="0"
	OLDIFS=$IFS
	IFS=$'\n'
	obj_count=$(psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -t -A -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid JOIN svv_all_schemas s ON n.nspname = s.schema_name WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN $SCHEMAS AND c.relkind = 'v' AND LOWER(pg_get_viewdef(c.oid)) LIKE '%materialized%'" 2>/dev/null)
	echo "INFO: ${prefix}:creating ${obj_count}"
	while IFS= read -r schema_name; do
		[ -z "$schema_name" ] && continue
		while IFS= read -r view_name; do
			[ -z "$view_name" ] && continue
			i=$((i+1))
			exec_script="${exec_dir}/${prefix}_${i}.sh"
			{
				echo "#!/bin/bash"
				echo "echo \"INFO: Creating Materialized View \\\"$schema_name\\\".\\\"$view_name\\\"\""
				echo "count=\$(psql -h \"$TARGET_PGHOST\" -p \"$TARGET_PGPORT\" -d \"$TARGET_PGDATABASE\" -U \"$TARGET_PGUSER\" -t -A -c \"SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v' AND n.nspname = '$schema_name' AND c.relname = '$view_name'\" 2>/dev/null)"
				echo "if [ \"\${count}\" -eq \"0\" ]; then"
				echo "\tcreate_view_ddl=\$(psql -h \"$SOURCE_PGHOST\" -p \"$SOURCE_PGPORT\" -d \"$SOURCE_PGDATABASE\" -U \"$SOURCE_PGUSER\" -t -A -c \"SHOW VIEW \\\"$schema_name\\\".\\\"$view_name\\\"\" 2>/dev/null)"
				echo "\tpsql -h \"$TARGET_PGHOST\" -p \"$TARGET_PGPORT\" -d \"$TARGET_PGDATABASE\" -U \"$TARGET_PGUSER\" -c \"\${create_view_ddl}\" -e 2>/dev/null"
			} > "$exec_script"
			echo -e "else" >> ${exec_script}
			echo -e "\techo \"INFO: MATERIALIZED VIEW \\\"${schema_name}\\\".\\\"${view_name}\\\" already exists in TARGET.\"" >> ${exec_script}
			echo -e "fi" >> ${exec_script}
			chmod 755 ${exec_script}

			wait_for_threads "${exec_dir}"
			echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${view_name}"
			${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
		done
	done
	wait_for_remaining "${tag}"
	IFS=$OLDIFS
}

create_view()
{
    prefix="create_view"
    i="0"
    OLDIFS=$IFS
    IFS=$'\n'
    obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid JOIN svv_all_schemas s ON s.schema_name = n.nspname WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN ${SCHEMAS} AND c.relkind = 'v' AND LOWER(pg_get_viewdef(c.oid)) NOT LIKE '%materialized%'")
    echo "INFO: ${prefix}:creating ${obj_count}"
    for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
        for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT c.oid, c.relname FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v' AND n.nspname = '${schema_name}' AND LOWER(pg_get_viewdef(c.oid)) NOT LIKE '%materialized%' ORDER BY c.relname"); do
            oid=$(echo "${x}" | awk -F '|' '{print $1}')
            view_name=$(echo "${x}" | awk -F '|' '{print $2}')
            i=$((i+1))
            exec_script="${exec_dir}/${prefix}_${i}.sh"
            echo -e "count=\$(psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -t -A -c \"SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v' AND n.nspname = '${schema_name}' AND c.relname = '${view_name}'\")" > ${exec_script}
            echo -e "if [ \"\${count}\" -eq \"0\" ]; then" >> ${exec_script}
            echo -e "\tcreate_view_ddl=\$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c \"SELECT CASE WHEN SUBSTRING(UPPER(LTRIM(vw_source)), 1, CHARINDEX('SELECT', UPPER(LTRIM(vw_source)))) LIKE '%CREATE %' THEN vw_source ELSE 'CREATE VIEW \\\"${schema_name}\\\".\\\"${view_name}\\\" AS ' || vw_source END FROM (SELECT oid, pg_get_viewdef(oid) AS vw_source FROM pg_class WHERE oid = ${oid}) AS sub;\")" >> ${exec_script}
            create_view_ddl=$(psql -h "$SOURCE_PGHOST" -p "$SOURCE_PGPORT" -d "$SOURCE_PGDATABASE" -U "$SOURCE_PGUSER" -t -A -c "SELECT CASE WHEN SUBSTRING(UPPER(LTRIM(vw_source)), 1, CHARINDEX('SELECT', UPPER(LTRIM(vw_source)))) LIKE '%CREATE %' THEN vw_source ELSE 'CREATE VIEW \"${schema_name}\".\"${view_name}\" AS ' || vw_source END FROM (SELECT oid, pg_get_viewdef(oid) AS vw_source FROM pg_class WHERE oid = ${oid}) AS sub;")
          	# Print the view DDL
			echo "$create_view_ddl"

            echo "${create_view_ddl}"

            echo -e "\techo \"Generated CREATE VIEW DDL: \\$create_view_ddl\"" >> ${exec_script}
            echo -e "\techo \"\\$create_view_ddl\" > \"\\${PWD}/log/\${prefix}_\${i}_view_ddl.sql\"" >> ${exec_script}
            # Add SET search_path before executing CREATE VIEW
            echo -e "\tpsql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c \"SET search_path TO ${schema_name}; \${create_view_ddl}\" -e" >> ${exec_script}
            echo -e "else" >> ${exec_script}
            echo -e "\techo \"INFO: VIEW \\\"${schema_name}\\\".\\\"${view_name}\\\" already exists in TARGET\"" >> ${exec_script}
            echo -e "fi" >> ${exec_script}
            chmod 755 ${exec_script}

            wait_for_threads "${exec_dir}"
            echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${view_name}"
            ${exec_script} > $PWD/log/${prefix}_${i}.log 2>&1 &
        done
    done
    wait_for_remaining "${exec_dir}"
    IFS=$OLDIFS
}

alter_view_owner()
{
	prefix="alter_view_owner"
	OLDIFS=$IFS
	IFS=$'\n'
	i="0"
	obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid JOIN pg_user u ON c.relowner = u.usesysid JOIN svv_all_schemas s ON s.schema_name = n.nspname WHERE s.database_name = current_database() AND s.schema_type = 'local' AND s.schema_name IN ${SCHEMAS} AND relkind = 'v' AND LOWER(pg_get_viewdef(c.oid)) NOT LIKE '%materialized%'")
	echo "INFO: ${prefix}:creating ${obj_count}"
	for schema_name in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT schema_name FROM svv_all_schemas WHERE database_name = current_database() AND schema_type = 'local' AND schema_name IN ${SCHEMAS} ORDER BY schema_name"); do
		for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT c.relname, u.usename FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid JOIN pg_user u ON c.relowner = u.usesysid WHERE n.nspname = '${schema_name}' AND relkind = 'v' AND LOWER(pg_get_viewdef(c.oid)) NOT LIKE '%materialized%' ORDER BY c.relname"); do
			i=$((i+1))
			table_name=$(echo ${x} | awk -F '|' '{print $1}')
			table_owner=$TARGET_PGUSER
			wait_for_threads "${tag}"
			echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}"
			psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -c "ALTER TABLE \"${schema_name}\".\"${table_name}\" OWNER TO \"${table_owner}\"" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 &
		done
	done
	wait_for_remaining "${tag}" 
	IFS=$OLDIFS
}
grant_user_view()
{
	prefix="grant_user_view"
	i="0"
	previous_schema_name=""
	previous_table_name=""
	exec_sql=""
	OLDIFS=$IFS
	IFS=$'\n'
	obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(DISTINCT sub2.nspname || sub2.relname) FROM (SELECT sub.nspname, sub.relname, split_part(array_to_string(sub.relacl, ','), ',', i) AS acl FROM (SELECT n.nspname, c.relname, generate_series(1, array_upper(c.relacl, 1)) AS i, c.relacl FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v') AS sub WHERE split_part(array_to_string(sub.relacl, ','), ',', i) NOT LIKE 'group %') AS sub2 JOIN pg_user u ON u.usename = split_part(sub2.acl, '=', 1) WHERE u.usename <> 'rdsdb' AND u.usesuper IS FALSE AND sub2.nspname IN ${SCHEMAS}")
	echo "INFO: ${prefix}:creating ${obj_count}"
	for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT sub2.nspname, sub2.relname, split_part(sub2.acl, '=', 1) AS usename, split_part(split_part(sub2.acl, '=', 2), '/', 1) AS usegrant FROM (SELECT sub.nspname, sub.relname, split_part(array_to_string(sub.relacl, ','), ',', i) AS acl FROM (SELECT n.nspname, c.relname, generate_series(1, array_upper(c.relacl, 1)) AS i, c.relacl FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v') AS sub WHERE split_part(array_to_string(sub.relacl, ','), ',', i) NOT LIKE 'group %') AS sub2 JOIN pg_user u ON u.usename = split_part(sub2.acl, '=', 1) WHERE u.usename <> 'rdsdb' AND u.usesuper IS FALSE AND sub2.nspname IN ${SCHEMAS} ORDER BY 1, 2;"); do
		schema_name=$(echo ${x} | awk -F '|' '{print $1}')
		table_name=$(echo ${x} | awk -F '|' '{print $2}')
		grantee=$(echo ${x} | awk -F '|' '{print $3}')
		use_grant=$(echo ${x} | awk -F '|' '{print $4}')
		grant_count=$(echo -n "${use_grant}" | wc -m)
		#change to 0 base
		grant_count=$((grant_count-1))
		counter="0"
		if [ "${i}" -gt "0" ]; then
			if [[ ! "${schema_name}" == "${previous_schema_name}" || ! "${table_name}" == "${previous_table_name}" ]]; then
				wait_for_threads ${tag}
				echo "INFO: ${prefix}:${i}:${obj_count}:${previous_schema_name}.${previous_table_name}"
				psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -f "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 & 
			fi
		fi
		if [[ ! "${schema_name}" == "${previous_schema_name}" || ! "${table_name}" == "${previous_table_name}" ]]; then
			i=$((i+1))
			exec_sql="${exec_dir}/${prefix}_${i}.sql"
		fi
		for y in $(seq 0 ${grant_count}); do
			grant=${use_grant:y:1}
			if [ "${grant}" == "a" ]; then
				grant_action="INSERT"
			elif [ "${grant}" == "w" ]; then
				grant_action="UPDATE"
			elif [ "${grant}" == "d" ]; then
				grant_action="DELETE"
			elif [ "${grant}" == "r" ]; then
				grant_action="SELECT"
			elif [ "${grant}" == "x" ]; then
				grant_action="REFERENCES"
			elif [ "${grant}" == "t" ]; then
				grant_action="TRIGGER"
			elif [ "${grant}" == "R" ]; then
				grant_action="RULE"
			else
				grant_action="NONE"
			fi
			if [ ! "${grant_action}" == "NONE" ]; then
				counter=$((counter+1))
			fi
			if [ ! "$grant_action" == "NONE" ]; then
				if [ "${counter}" -eq "1" ]; then
					sql_cmd="GRANT ${grant_action}"
				else
					sql_cmd+=", ${grant_action}"
				fi;
			fi
		done
		if [ "${counter}" -gt "0" ]; then
			sql_cmd+=" ON TABLE \"${schema_name}\".\"${table_name}\" TO \"${grantee}\";"
			echo "${sql_cmd}" >> ${exec_sql}
		fi
		previous_schema_name="${schema_name}"
		previous_table_name="${table_name}"

	done
	wait_for_threads ${tag}
	echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}"
	psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -f "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 & 
	wait_for_remaining "${tag}" 
	IFS=$OLDIFS
}
grant_group_view()
{
	prefix="grant_group_view"
	i="0"
	previous_schema_name=""
	previous_table_name=""
	exec_sql=""
	OLDIFS=$IFS
	IFS=$'\n'
	obj_count=$(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT COUNT(DISTINCT sub2.nspname || sub2.relname) FROM (SELECT sub.nspname, sub.relname, split_part(split_part(array_to_string(sub.relacl, ','), ',', i), ' ', 2) AS acl FROM (SELECT n.nspname, c.relname, generate_series(1, array_upper(c.relacl, 1)) AS i, c.relacl FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v') AS sub WHERE split_part(array_to_string(sub.relacl, ','), ',', i) LIKE 'group %') AS sub2 WHERE sub2.nspname IN ${SCHEMAS}")
	echo "INFO: ${prefix}:creating ${obj_count}"
	for x in $(psql -h $SOURCE_PGHOST -p $SOURCE_PGPORT -d $SOURCE_PGDATABASE -U $SOURCE_PGUSER -t -A -c "SELECT sub2.nspname, sub2.relname, split_part(sub2.acl, '=', 1) AS groname, split_part(split_part(sub2.acl, '=', 2), '/', 1) AS grogrant FROM (SELECT sub.nspname, sub.relname, split_part(split_part(array_to_string(sub.relacl, ','), ',', i), ' ', 2) AS acl FROM (SELECT n.nspname, c.relname, generate_series(1, array_upper(c.relacl, 1)) AS i, c.relacl FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE c.relkind = 'v') AS sub WHERE split_part(array_to_string(sub.relacl, ','), ',', i) LIKE 'group %') AS sub2 WHERE sub2.nspname IN ${SCHEMAS} ORDER BY 1, 2;"); do
		schema_name=$(echo ${x} | awk -F '|' '{print $1}')
		table_name=$(echo ${x} | awk -F '|' '{print $2}')
		group_name=$(echo ${x} | awk -F '|' '{print $3}')
		group_grant=$(echo ${x} | awk -F '|' '{print $4}')
		grant_count=$(echo -n "${group_grant}" | wc -m)
		#change to 0 base
		grant_count=$((grant_count-1))
		counter="0"
		if [ "${i}" -gt "0" ]; then
			if [[ ! "${schema_name}" == "${previous_schema_name}" || ! "${table_name}" == "${previous_table_name}" ]]; then
				wait_for_threads ${tag}
				echo "INFO: ${prefix}:${i}:${obj_count}:${previous_schema_name}.${previous_table_name}"
				psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -f "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 & 
			fi
		fi
		if [[ ! "${schema_name}" == "${previous_schema_name}" || ! "${table_name}" == "${previous_table_name}" ]]; then
			i=$((i+1))
			exec_sql="${exec_dir}/${prefix}_${i}.sql"
		fi
		for y in $(seq 0 ${grant_count}); do
			grant=${group_grant:y:1}
			if [ "${grant}" == "a" ]; then
				grant_action="INSERT"
			elif [ "${grant}" == "w" ]; then
				grant_action="UPDATE"
			elif [ "${grant}" == "d" ]; then
				grant_action="DELETE"
			elif [ "${grant}" == "r" ]; then
				grant_action="SELECT"
			elif [ "${grant}" == "x" ]; then
				grant_action="REFERENCES"
			elif [ "${grant}" == "t" ]; then
				grant_action="TRIGGER"
			elif [ "${grant}" == "R" ]; then
				grant_action="RULE"
			else
				grant_action="NONE"
			fi
			if [ ! "${grant_action}" == "NONE" ]; then
				counter=$((counter+1))
			fi
			if [ ! "$grant_action" == "NONE" ]; then
				if [ "${counter}" -eq "1" ]; then
					sql_cmd="GRANT ${grant_action}"
				else
					sql_cmd+=", ${grant_action}"
				fi;
			fi
		done
		if [ "${counter}" -gt "0" ]; then
			sql_cmd+=" ON TABLE \"${schema_name}\".\"${table_name}\" TO GROUP \"${group_name}\";"
			echo "${sql_cmd}" >> ${exec_sql}
		fi
		previous_schema_name="${schema_name}"
		previous_table_name="${table_name}"
	done
	wait_for_threads ${tag}
	echo "INFO: ${prefix}:${i}:${obj_count}:${schema_name}.${table_name}"
	psql -h $TARGET_PGHOST -p $TARGET_PGPORT -d $TARGET_PGDATABASE -U $TARGET_PGUSER -f "${exec_sql}" -v tag=${tag} -e > $PWD/log/${prefix}_${i}.log 2>&1 & 
	wait_for_remaining "${tag}" 
	IFS=$OLDIFS
}

create_materialized_view
create_view
alter_view_owner
grant_user_view
grant_group_view

# Count results from logs
MV_CREATED=0
MV_FAILED=0
VIEWS_CREATED=0
VIEWS_FAILED=0
VIEW_OWNERS_FAILED=0
VIEW_GRANTS_FAILED=0
if [ -d "$PWD/log" ]; then
    MV_CREATED=$(grep -rl "INFO: Creating Materialized View\|already exists" $PWD/log/create_materialized_view_*.log 2>/dev/null | wc -l)
    MV_FAILED=$(grep -rl "ERROR:" $PWD/log/create_materialized_view_*.log 2>/dev/null | wc -l)
    VIEWS_CREATED=$(grep -rl "CREATE VIEW\|already exists" $PWD/log/create_view_*.log 2>/dev/null | wc -l)
    VIEWS_FAILED=$(grep -rl "ERROR:" $PWD/log/create_view_*.log 2>/dev/null | wc -l)
    VIEW_OWNERS_FAILED=$(grep -rl "ERROR:" $PWD/log/alter_view_owner_*.log 2>/dev/null | wc -l)
    VIEW_GRANTS_FAILED=$(grep -rl "ERROR:" $PWD/log/grant_*_view_*.log 2>/dev/null | wc -l)
fi

## Summary
echo "============================================"
echo "INFO: Migration Summary - Views"
echo "============================================"
echo "  Materialized views processed: ${MV_CREATED}"
echo "  Materialized views failed:    ${MV_FAILED}"
echo "  Views processed:              ${VIEWS_CREATED}"
echo "  Views failed:                 ${VIEWS_FAILED}"
echo "  View owner changes failed:    ${VIEW_OWNERS_FAILED}"
echo "  View grant operations failed: ${VIEW_GRANTS_FAILED}"
echo "============================================"

TOTAL_FAILED=$((MV_FAILED + VIEWS_FAILED + VIEW_OWNERS_FAILED + VIEW_GRANTS_FAILED))
if [ $TOTAL_FAILED -gt 0 ]; then
    echo "WARN: ${TOTAL_FAILED} view operations failed. Check logs in $PWD/log/ for details."
fi

echo "INFO: Migrate views step complete"
