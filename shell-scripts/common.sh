#!/bin/bash
set -e

# Require SSL for all psql connections (Redshift requires SSL)
export PGSSLMODE="require"

# Use secure path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pgpass.sh"

# Validate required environment variables
validate_env_vars() {
    # Required variables
    local required_vars=(
        "SOURCE_PGHOST"
        "SOURCE_PGPORT"
        "SOURCE_PGUSER"
        "SOURCE_PGPASSWORD"
        "SOURCE_PGDATABASE"
        "TARGET_PGHOST"
        "TARGET_PGPORT"
        "TARGET_PGUSER"
        "TARGET_PGPASSWORD"
        "TARGET_PGDATABASE"
        "SCHEMAS"
        "LOAD_THREADS"
        "RETRY"
    )

    # Check required variables
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo "ERROR: Required environment variable $var is not set"
            exit 1
        fi
    done

    # TENANT_NAME is optional
    if [ -z "$TENANT_NAME" ]; then
        echo "INFO: TENANT_NAME is not set, will process all users"
        export TENANT_NAME=""
    fi
}

# Call validation function after secrets are loaded
# validate_env_vars

# Setup pgpass file once (only if credentials are available)
if [ ! -f "$PGPASSFILE" ] && [ -n "$SOURCE_PGPASSWORD" ] && [ -n "$TARGET_PGPASSWORD" ]; then
    setup_pgpass
fi


LOCALPWD=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )
tag="7461670A"

#functions are executed in parallel either in a script in the exec_dir or individual psql commands identified with a tag.
wait_for_threads()
{
	thread_check="${1}"
	# Use pgrep if available, otherwise no wait needed
	if command -v pgrep >/dev/null 2>&1; then
		thread_count=$(pgrep -f "${thread_check}" | wc -l)
		while [ "${thread_count}" -gt "${LOAD_THREADS}" ]; do
			sleep 1
			thread_count=$(pgrep -f "${thread_check}" | wc -l)
		done
	fi
	# No fallback wait - not needed for sequential execution
}

wait_for_completion() {
    local prefix=$1
    echo "Waiting for ${prefix} operations to complete..."
    if command -v pgrep >/dev/null 2>&1; then
        while true; do
            running=$(pgrep -f "${prefix}" | wc -l)
            if [ "$running" -eq 0 ]; then
                break
            fi
            sleep 1
        done
    fi
    # No fallback wait - operations complete when function returns
    echo "${prefix} operations completed"
}


wait_for_remaining()
{
    thread_check="${1}"
    if command -v pgrep >/dev/null 2>&1; then
        thread_count=$(pgrep -f "${thread_check}" | wc -l)
        if [ "${thread_count}" -gt "0" ]; then
            echo -ne "INFO: ${thread_count} remaining threads."
            while [ "${thread_count}" -gt "0" ]; do
                echo -ne "."
                sleep 1
                thread_count=$(pgrep -f "${thread_check}" | wc -l)
            done
            echo "."
        fi
    fi
    # No error checking here - let exec_fn handle it
}

exec_fn()
{
	fn="${1}"
	echo "Starting ${fn}..."
	${fn}
	
	# Wait for all background processes to complete
	echo "Waiting for ${fn} to complete..."
	wait_for_remaining "${fn}"
	
	# Check for errors in log files - only for this specific function
	if [ -d "$LOCALPWD/log" ]; then
		fatal_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "FATAL" {} \; 2>/dev/null | wc -l)
		error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "^ERROR:" {} \; 2>/dev/null | wc -l)
		syntax_error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "syntax error" {} \; 2>/dev/null | wc -l)
		
		# Show actual errors from this function's logs only
		if [ "${error_count}" -gt "0" ]; then
			echo "Errors found in ${fn} logs:"
			find $LOCALPWD/log -name "${fn}_*.log" -exec grep "^ERROR:" {} \; 2>/dev/null
		fi
	else
		fatal_count=0
		error_count=0
		syntax_error_count=0
	fi

	if [[ "${error_count}" -eq "0" && "${fatal_count}" -eq "0" && "${syntax_error_count}" -eq "0" ]]; then
		echo "INFO: No errors found with ${fn}."
	else
		echo "INFO: Errors found! Starting retries."
		for retry in $(seq 1 ${RETRY}); do
			#remove old logs for retry
			rm -f $LOCALPWD/log/${fn}_*.log
			${fn}
			wait_for_remaining "${fn}"
			
			if [ -d "$LOCALPWD/log" ]; then
				fatal_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "FATAL" {} \; 2>/dev/null | wc -l)
				error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "^ERROR:" {} \; 2>/dev/null | wc -l)
				syntax_error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "syntax error" {} \; 2>/dev/null | wc -l)
			else
				fatal_count=0
				error_count=0
				syntax_error_count=0
			fi
			
			if [[ "${error_count}" -eq "0" && "${fatal_count}" -eq "0" && "${syntax_error_count}" -eq "0" ]]; then
				echo "INFO: No more errors found. Exiting after ${retry} retries."
				break
			fi
		done
	fi
	
	# Final error check
	if [ -d "$LOCALPWD/log" ]; then
		fatal_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "FATAL" {} \; 2>/dev/null | wc -l)
		error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "^ERROR:" {} \; 2>/dev/null | wc -l)
		syntax_error_count=$(find $LOCALPWD/log -name "${fn}_*.log" -exec grep -l "syntax error" {} \; 2>/dev/null | wc -l)
	else
		fatal_count=0
		error_count=0
		syntax_error_count=0
	fi
	
	if [[ "${error_count}" -gt "0" || "${fatal_count}" -gt "0" || "${syntax_error_count}" -gt "0" ]]; then
		echo "ERROR: Errors still found after ${RETRY} retries in ${fn}."
		# Print actual error lines so they surface in Glue job output
		if [ -d "$LOCALPWD/log" ]; then
			echo "ERROR details from ${fn}:"
			find $LOCALPWD/log -name "${fn}_*.log" -exec grep -h "ERROR:\|FATAL:\|syntax error" {} \; 2>/dev/null | head -20
		fi
		return 1
	fi
	
	echo "INFO: ${fn} completed successfully."
	return 0
}