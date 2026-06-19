#!/bin/bash

# Disable debug mode for security
set -e

load_secret() {
    local secret_arn="$1"
    local prefix="$2"  # Will be either "SOURCE_" or "TARGET_"
    
    echo "Loading secrets from $secret_arn with prefix $prefix..."
    
    # First, verify AWS CLI configuration
    echo "Verifying AWS configuration..."
    aws sts get-caller-identity || {
        echo "ERROR: AWS credentials not properly configured"
        return 1
    }

    # Get the secret value with error suppression
    local secret_string
    if ! secret_string=$(aws secretsmanager get-secret-value \
        --secret-id "$secret_arn" \
        --query 'SecretString' \
        --output text 2>/dev/null); then
        echo "ERROR: Failed to fetch secret"
        return 1
    fi
    
    # Debug: Show what fields are in the secret
    echo "Secret fields for $prefix:"
    echo "$secret_string" | jq -r 'keys[]' || echo "Failed to parse secret as JSON"

    # Define mapping for key renaming with variations
    declare -A key_mapping=(
        ["host"]="${prefix}PGHOST"
        ["hostname"]="${prefix}PGHOST"
        ["dbname"]="${prefix}PGDATABASE"
        ["database"]="${prefix}PGDATABASE"
        ["db"]="${prefix}PGDATABASE"
        ["username"]="${prefix}PGUSER"
        ["user"]="${prefix}PGUSER"
        ["password"]="${prefix}PGPASSWORD"
        ["pass"]="${prefix}PGPASSWORD"
    )

    # Parse and export each value with renamed keys
    while read -r line; do
        [ -z "$line" ] && continue
        
        key=$(echo "$line" | cut -d= -f1)
        value=$(echo "$line" | cut -d= -f2-)
        
        # Clean the key and value
        key=$(echo "$key" | tr -d '"' | tr -d ' ' | tr '[:upper:]' '[:lower:]')
        value=$(echo "$value" | tr -d '"' | tr -d ' ' | tr -d ',')
        
        # Map the key if it exists in our mapping
        if [[ -n "${key_mapping[$key]}" ]]; then
            mapped_key="${key_mapping[$key]}"
            if [[ "$key" == *"password"* || "$key" == *"pass"* ]]; then
                echo "Exporting: $mapped_key = ****"
            else
                echo "Exporting: $mapped_key = $value"
            fi
            export "$mapped_key"="$value"
        fi
        
    done < <(echo "$secret_string" | jq -r 'to_entries | .[] | "\(.key)=\(.value)"')

    # Set default port 5439
    port_var="${prefix}PGPORT"
    export "$port_var"="5439"
    echo "Exporting: $port_var = 5439 (default)"
    
    # Set default database if not set (especially for source)
    db_var="${prefix}PGDATABASE"
    if [ -z "${!db_var}" ]; then
        export "$db_var"="dev"
        echo "Exporting: $db_var = dev (default)"
    fi
}

# Main script execution
echo "Checking secret ARNs..."
echo "SOURCE_SECRET_ARN=$SOURCE_SECRET_ARN"
echo "TARGET_SECRET_ARN=$TARGET_SECRET_ARN"

if [ -z "$SOURCE_SECRET_ARN" ] || [ -z "$TARGET_SECRET_ARN" ]; then
    echo "ERROR: Secret ARNs not provided"
    exit 1
fi

# Load secrets with prefixes
echo "Loading source cluster secrets..."
if ! load_secret "$SOURCE_SECRET_ARN" "SOURCE_"; then
    echo "ERROR: Failed to load source secrets"
    exit 1
fi

echo "Loading target cluster secrets..."
if ! load_secret "$TARGET_SECRET_ARN" "TARGET_"; then
    echo "ERROR: Failed to load target secrets"
    exit 1
fi

# Verify critical variables
echo "Verifying credentials..."
for var in SOURCE_PGHOST SOURCE_PGPORT SOURCE_PGUSER SOURCE_PGPASSWORD SOURCE_PGDATABASE \
           TARGET_PGHOST TARGET_PGPORT TARGET_PGUSER TARGET_PGPASSWORD TARGET_PGDATABASE; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var is not set"
        exit 1
    fi
    if [[ "$var" == *"PASSWORD"* ]]; then
        echo "$var is set (value masked)"
    else
        echo "$var = ${!var}"
    fi
done

echo "All credentials verified successfully"
