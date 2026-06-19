#!/bin/bash

setup_pgpass() {
    echo "Setting up .pgpass file..."
    
    # Use PGPASSFILE if already set, otherwise default to /tmp/.pgpass
    PGPASS_FILE="${PGPASSFILE:-/tmp/.pgpass}"
    echo "Creating .pgpass at: $PGPASS_FILE"
    
    # Ensure parent directory exists
    mkdir -p "$(dirname "$PGPASS_FILE")" 2>/dev/null || true
    
    # Set umask for secure file creation
    local old_umask
    old_umask=$(umask)
    umask 077
    
    # Create the file securely (truncate if exists to avoid stale entries)
    : > "$PGPASS_FILE" || {
        echo "ERROR: Failed to create .pgpass file"
        umask "$old_umask"
        return 1
    }
    
    # Restore umask
    umask "$old_umask"
    
    # Add source cluster details
    echo "Adding source cluster details..."
    printf "%s:%s:%s:%s:%s\n" "$SOURCE_PGHOST" "$SOURCE_PGPORT" "$SOURCE_PGDATABASE" "$SOURCE_PGUSER" "$SOURCE_PGPASSWORD" >> "$PGPASS_FILE"
    
    # Add target cluster details
    echo "Adding target cluster details..."
    printf "%s:%s:%s:%s:%s\n" "$TARGET_PGHOST" "$TARGET_PGPORT" "$TARGET_PGDATABASE" "$TARGET_PGUSER" "$TARGET_PGPASSWORD" >> "$PGPASS_FILE"
    
    # Add wildcard entries for database flexibility (same host/user, any database)
    printf "%s:%s:*:%s:%s\n" "$SOURCE_PGHOST" "$SOURCE_PGPORT" "$SOURCE_PGUSER" "$SOURCE_PGPASSWORD" >> "$PGPASS_FILE"
    printf "%s:%s:*:%s:%s\n" "$TARGET_PGHOST" "$TARGET_PGPORT" "$TARGET_PGUSER" "$TARGET_PGPASSWORD" >> "$PGPASS_FILE"
    
    # Set strict permissions
    chmod 600 "$PGPASS_FILE"
    
    # Verify file exists and has correct permissions
    if [ ! -f "$PGPASS_FILE" ]; then
        echo "ERROR: Failed to create .pgpass file"
        return 1
    fi
    
    # Debug information (without showing file contents)
    echo "File permissions:"
    ls -l "$PGPASS_FILE"
    echo "Entry count: $(wc -l < "$PGPASS_FILE")"
    echo "Hosts in .pgpass:"
    awk -F: '{print $1":"$2":"$3":"$4":****"}' "$PGPASS_FILE"
    
    echo "File created successfully (contents hidden for security)"
    
    # Export PGPASSFILE for other scripts to use
    export PGPASSFILE="$PGPASS_FILE"
    
    echo ".pgpass setup completed successfully"
    return 0
}

# Call setup function and check result
if ! setup_pgpass; then
    echo "Failed to setup .pgpass file"
    exit 1
fi
