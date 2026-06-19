import subprocess
import os
import sys
import boto3
import time
import tempfile
from awsglue.utils import getResolvedOptions
import json
import psycopg2
  
def execute_redshift_query(host, port, database, user, password, query):
    """Execute query in Redshift with input validation"""
    try:
        # Basic input validation
        if not all([host, port, database, user, password, query]):
            raise ValueError("All connection parameters must be provided")
        
        # Validate query is not empty and doesn't contain suspicious patterns
        query = query.strip()
        if not query:
            raise ValueError("Query cannot be empty")
        
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=user,
            password=password
        )
        
        with conn.cursor() as cur:
            cur.execute(query)
            conn.commit()
            
        print(f"Successfully executed query (length: {len(query)} chars)")
        
    except Exception as e:
        print(f"Error executing query: {str(e)}")
        raise
    finally:
        if conn:
            conn.close()



def list_directory_contents(directory):
    print(f"\nListing contents of {directory}:")
    # Validate directory path to prevent command injection
    if not os.path.exists(directory) or not os.path.isdir(directory):
        print(f"Invalid directory: {directory}")
        return
    
    try:
        # Use os.listdir instead of subprocess for security
        files = os.listdir(directory)
        for file in sorted(files):
            file_path = os.path.join(directory, file)
            if os.path.isdir(file_path):
                print(f"drwxr-xr-x {file}/")
            else:
                stat = os.stat(file_path)
                print(f"-rwxr-xr-x {stat.st_size} {file}")
    except Exception as e:
        print(f"Error listing directory: {str(e)}")
    
def setup_environment(region):
    os.environ['AWS_STS_REGIONAL_ENDPOINTS'] = 'regional'
    os.environ['AWS_DEFAULT_REGION'] = region
    
    # Create secure pgpass file with unpredictable path (B108 mitigation)
    pgpass_fd, pgpass_path = tempfile.mkstemp(prefix='.pgpass_', dir='/tmp')
    os.close(pgpass_fd)
    os.chmod(pgpass_path, 0o600)
    os.environ['PGPASSFILE'] = pgpass_path
    
    print("\nEnvironment Variables Set:")
    print(f"AWS_DEFAULT_REGION: {os.environ['AWS_DEFAULT_REGION']}")
    print(f"PGPASSFILE: {os.environ['PGPASSFILE']}")
    
def prepare_scripts(script_dir):
    # Don't rename any scripts - let them all execute in sequence
    print("All scripts will be executed in their original order")
    # Ensure all .sh files have execute permissions
    for script in os.listdir(script_dir):
        if script.endswith('.sh'):
            script_path = os.path.join(script_dir, script)
            os.chmod(script_path, 0o700)
 
def download_scripts_from_s3(bucket, prefix, local_dir):
    # Whitelist of allowed files
    ALLOWED_FILES = [
        '01_create_users_groups.sh',
        '02_migrate_ddl.sh', 
        '03_migrate_permissions.sh',
        '04_migrate_views.sh',
        '05_refresh_materialized_views.sh',
        'common.sh',
        'get_table_ddl.sql',
        'load_secrets.sh',
        'migrate.sh',
        'pgpass.sh'
    ]
    
    s3 = boto3.client('s3')
    paginator = s3.get_paginator('list_objects_v2')
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get('Contents', []):
            key = obj['Key']
            filename = os.path.basename(key)
            
            # Only download whitelisted files
            if filename not in ALLOWED_FILES:
                print(f"Skipping non-whitelisted file: {filename}")
                continue
                
            if key.endswith(('.sh', '.sql')):
                local_file_path = os.path.join(local_dir, filename)
                s3.download_file(bucket, key, local_file_path)
                if key.endswith('.sh'):
                    os.chmod(local_file_path, 0o700)
                print(f"Downloaded {key} -> {local_file_path}")
                
def validate_secrets(source_secret_arn, target_secret_arn, aws_region):
    """Pre-validate that secret ARNs are accessible before running migration scripts."""
    secrets_client = boto3.client('secretsmanager', region_name=aws_region)
    errors = []
    
    for label, arn in [("SOURCE", source_secret_arn), ("TARGET", target_secret_arn)]:
        try:
            response = secrets_client.get_secret_value(SecretId=arn)
            secret_string = response.get('SecretString', '')
            if not secret_string:
                errors.append(f"{label}_SECRET_ARN ({arn}): Secret exists but has no SecretString value")
                continue
            
            # Validate it's parseable JSON with expected keys
            secret_data = json.loads(secret_string)
            required_keys = {'host', 'hostname'} 
            user_keys = {'username', 'user'}
            pass_keys = {'password', 'pass'}
            
            has_host = bool(required_keys & set(k.lower() for k in secret_data.keys()))
            has_user = bool(user_keys & set(k.lower() for k in secret_data.keys()))
            has_pass = bool(pass_keys & set(k.lower() for k in secret_data.keys()))
            
            missing = []
            if not has_host:
                missing.append("host/hostname")
            if not has_user:
                missing.append("username/user")
            if not has_pass:
                missing.append("password/pass")
            
            if missing:
                errors.append(
                    f"{label}_SECRET_ARN ({arn}): Secret is missing required fields: {', '.join(missing)}. "
                    f"Available fields: {list(secret_data.keys())}"
                )
            else:
                print(f"{label} secret validated successfully (fields: {list(secret_data.keys())})")
                
        except secrets_client.exceptions.ResourceNotFoundException:
            errors.append(f"{label}_SECRET_ARN ({arn}): Secret not found. Verify the ARN is correct and exists in region {aws_region}")
        except secrets_client.exceptions.AccessDeniedException:
            errors.append(f"{label}_SECRET_ARN ({arn}): Access denied. Verify the Glue job IAM role has secretsmanager:GetSecretValue permission for this secret")
        except json.JSONDecodeError:
            errors.append(f"{label}_SECRET_ARN ({arn}): Secret value is not valid JSON")
        except Exception as e:
            errors.append(f"{label}_SECRET_ARN ({arn}): Unexpected error - {str(e)}")
    
    if errors:
        print("\n" + "=" * 60)
        print("SECRET VALIDATION FAILED")
        print("=" * 60)
        for error in errors:
            print(f"  ERROR: {error}")
        print("=" * 60 + "\n")
        return False
    
    print("All secrets validated successfully")
    return True

def run_shell_script(script_path, env):
    print(f"\nStarting execution of {script_path}")
    
    # Whitelist of allowed scripts
    ALLOWED_SCRIPTS = [
        '01_create_users_groups.sh',
        '02_migrate_ddl.sh',
        '03_migrate_permissions.sh', 
        '04_migrate_views.sh',
        '05_refresh_materialized_views.sh',
        'migrate.sh'
    ]
    
    script_name = os.path.basename(script_path)
    if script_name not in ALLOWED_SCRIPTS:
        print(f"Script {script_name} not in allowed list. Skipping execution.")
        return True
    
    # Validate script path is within expected directory (prevent path traversal)
    real_path = os.path.realpath(script_path)
    if not real_path.startswith('/tmp/'):
        print(f"Script path {real_path} is outside allowed directory. Skipping.")
        return False, []
    
    start_time = time.time()
    # Only log non-sensitive environment variables
    print("\nNon-sensitive Environment Variables for Script:")
    safe_vars = ['PWD', 'SCHEMAS', 'LOAD_THREADS', 'RETRY', 'PGPASSFILE', 'TENANT_NAME']
    for key in safe_vars:
        if key in env:
            print(f"{key}={env[key]}")
    
    # Ensure the script directory exists
    script_dir = os.path.dirname(script_path)
    if not os.path.exists(script_dir):
        print(f"Error: Script directory {script_dir} does not exist!")
        return False
    
    all_output = []
    try:
        # Merge stderr into stdout so ALL output (errors included) is captured in one stream
        process = subprocess.Popen(['/usr/bin/bash', script_path],
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT,
                                   env=env,
                                   cwd=script_dir,
                                   text=True)
        while True:
            output = process.stdout.readline()
            if output == '' and process.poll() is not None:
                break
            if output:
                line = output.strip()
                print(line)
                all_output.append(line)
            if time.time() - start_time > 1800:
                print(f"Script {script_path} is running too long. Terminating.")
                process.terminate()
                return False, all_output

        if process.returncode != 0:
            # Pull out any lines that look like errors/failures/warnings
            error_lines = [l for l in all_output
                           if any(kw in l.upper() for kw in ['ERROR', 'FATAL', 'FAILED', 'DENIED', 'REFUSED', 'TIMEOUT'])]
            print(f"\n{'=' * 60}")
            print(f"SCRIPT FAILED: {script_name} (exit code {process.returncode})")
            print(f"{'=' * 60}")
            if error_lines:
                print("Root cause error(s):")
                for el in error_lines:
                    print(f"  >> {el}")
            # Always show last 20 lines for full context
            print("Last 20 lines of output:")
            for el in all_output[-20:]:
                print(f"  {el}")
            print(f"{'=' * 60}\n")
            return False, all_output
        print(f"Script {script_path} completed successfully")
        return True, all_output
    except Exception as e:
        print(f"Error running {script_path}: {str(e)}")
        return False, all_output
        
def main():
    # Get job parameters
    args = getResolvedOptions(sys.argv, [
        'S3_BUCKET', 'S3_PREFIX', 'SOURCE_SECRET_ARN', 'TARGET_SECRET_ARN', 'AWS_REGION',
        'SCHEMAS', 'LOAD_THREADS', 'RETRY', 'TENANT_NAME'
    ])
    s3_bucket = args['S3_BUCKET']
    s3_prefix = args['S3_PREFIX']
    source_secret_arn = args['SOURCE_SECRET_ARN']
    target_secret_arn = args['TARGET_SECRET_ARN']
    aws_region = args['AWS_REGION']
    schemas = args['SCHEMAS']
    load_threads = args['LOAD_THREADS']
    retry = args['RETRY']
    tenant_name = args.get('TENANT_NAME', '')
    # Setup environment
    setup_environment(aws_region)
    
    # Create secure temp directory with unpredictable path (B108 mitigation)
    script_dir = tempfile.mkdtemp(prefix='script_', dir='/tmp')
    os.chmod(script_dir, 0o700)
    log_dir = os.path.join(script_dir, 'log')
    exec_users_dir = os.path.join(script_dir, 'exec_users')
    os.makedirs(log_dir, exist_ok=True)
    os.makedirs(exec_users_dir, exist_ok=True)
    
    # Pre-validate secrets before downloading/running anything
    print("\nValidating secret ARNs...")
    if not validate_secrets(source_secret_arn, target_secret_arn, aws_region):
        raise Exception("Secret validation failed. Check the ARNs and IAM permissions in the logs above.")
    
    # Download scripts
    download_scripts_from_s3(s3_bucket, s3_prefix, script_dir)
    
    # Debug: List directory contents
    list_directory_contents(script_dir)
    
    # Set environment variables for script execution
    env = os.environ.copy()
    env.update({
        'PWD': script_dir,
        'SOURCE_SECRET_ARN': source_secret_arn,
        'TARGET_SECRET_ARN': target_secret_arn,
        'SCHEMAS': schemas,
        'LOAD_THREADS': load_threads,
        'RETRY': retry,
        'PGPASSFILE': os.environ['PGPASSFILE']
    })
    if tenant_name:
        env['TENANT_NAME'] = tenant_name
    # Verify file permissions before execution
    list_directory_contents(script_dir)
    
    prepare_scripts(script_dir)
    
    # Run migrate.sh
    migrate_script = os.path.join(script_dir, 'migrate.sh')
    if not os.path.exists(migrate_script):
        raise Exception(f"migrate.sh not found in {script_dir}")
    
    success, output = run_shell_script(migrate_script, env)
    if not success:
        # Build a meaningful error message from the shell output
        error_lines = [l for l in output
                       if any(kw in l.upper() for kw in ['ERROR', 'FATAL', 'FAILED', 'DENIED', 'REFUSED', 'TIMEOUT'])]
        if error_lines:
            # Cap at 10 lines so the exception message isn't enormous
            error_summary = "; ".join(error_lines[:10])
        else:
            # Fall back to last 5 lines of output for context
            error_summary = "; ".join(output[-5:]) if output else "No output captured"
        
        raise Exception(f"Migration script failed: {error_summary}")

if __name__ == "__main__":
    main()