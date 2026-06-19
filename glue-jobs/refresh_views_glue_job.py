import subprocess
import os
import sys
import boto3
import time
import tempfile
from awsglue.utils import getResolvedOptions

def get_job_arguments():
    try:
        # First, get the required arguments
        required_args = getResolvedOptions(sys.argv, [
            'S3_BUCKET',
            'S3_PREFIX',
            'SOURCE_SECRET_ARN',
            'TARGET_SECRET_ARN',
            'AWS_REGION',
            'LOAD_THREADS',
            'RETRY'
        ])
        # Then, check and get optional arguments
        optional_args = {}
        if '--SCHEMAS' in sys.argv:
            optional_args.update(getResolvedOptions(sys.argv, ['SCHEMAS']))
        else:
            optional_args['SCHEMAS'] = ''  # Default empty string
        if '--TENANT_NAME' in sys.argv:
            optional_args.update(getResolvedOptions(sys.argv, ['TENANT_NAME']))
        else:
            optional_args['TENANT_NAME'] = ''  # Default empty string
        # Merge required and optional arguments
        required_args.update(optional_args)
        return required_args
    except Exception as e:
        print(f"Error getting job arguments: {str(e)}")
        raise
    
def list_directory_contents(directory):
    print(f"\nListing contents of {directory}:")
    if not os.path.exists(directory) or not os.path.isdir(directory):
        print(f"Invalid directory: {directory}")
        return
    try:
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
    
def download_scripts_from_s3(bucket, prefix, local_dir):
    # Whitelist of allowed files
    ALLOWED_FILES = [
        '05_refresh_materialized_views.sh',
        'load_secrets.sh',
        'common.sh',
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
                
def run_shell_script(script_path, env):
    print(f"\nStarting execution of {script_path}")
    
    # Whitelist of allowed scripts
    ALLOWED_SCRIPTS = ['05_refresh_materialized_views.sh']
    script_name = os.path.basename(script_path)
    
    if script_name not in ALLOWED_SCRIPTS:
        print(f"Script {script_name} not in allowed list. Skipping execution.")
        return True, []
    
    # Validate script path is within expected directory (prevent path traversal)
    real_path = os.path.realpath(script_path)
    if not real_path.startswith('/tmp/'):
        print(f"Script path {real_path} is outside allowed directory. Skipping.")
        return False, []
        
    start_time = time.time()
    print("\nNon-sensitive Environment Variables for Script:")
    safe_vars = ['PWD', 'SCHEMAS', 'LOAD_THREADS', 'RETRY', 'PGPASSFILE']
    for key in safe_vars:
        if key in env:
            print(f"{key}={env[key]}")
    
    script_dir = os.path.dirname(script_path)
    if not os.path.exists(script_dir):
        print(f"Error: Script directory {script_dir} does not exist!")
        return False, []
    
    all_output = []
    try:
        # Merge stderr into stdout so ALL output (errors included) is captured
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
            if time.time() - start_time > 3600:  # 1 hour timeout for refresh
                print(f"Script {script_path} is running too long. Terminating.")
                process.terminate()
                return False, all_output

        if process.returncode != 0:
            error_lines = [l for l in all_output
                           if any(kw in l.upper() for kw in ['ERROR', 'FATAL', 'FAILED', 'DENIED', 'REFUSED', 'TIMEOUT'])]
            print(f"\n{'=' * 60}")
            print(f"SCRIPT FAILED: {script_name} (exit code {process.returncode})")
            print(f"{'=' * 60}")
            if error_lines:
                print("Root cause error(s):")
                for el in error_lines:
                    print(f"  >> {el}")
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
    
    args = get_job_arguments()
    
    # Assign parameters
    s3_bucket = args['S3_BUCKET']
    s3_prefix = args['S3_PREFIX']
    source_secret_arn = args['SOURCE_SECRET_ARN']
    target_secret_arn = args['TARGET_SECRET_ARN']
    aws_region = args['AWS_REGION']
    load_threads = args['LOAD_THREADS']
    retry = args['RETRY']
    schemas = args['SCHEMAS']  # Will be empty string if not provided
    tenant_name = args['TENANT_NAME'] 
    
    # Setup environment
    setup_environment(aws_region)
    
    # Create secure temp directory with unpredictable path (B108 mitigation)
    script_dir = tempfile.mkdtemp(prefix='script_', dir='/tmp')
    os.chmod(script_dir, 0o700)
    log_dir = os.path.join(script_dir, 'log')
    exec_users_dir = os.path.join(script_dir, 'exec_users')
    os.makedirs(log_dir, exist_ok=True)
    os.makedirs(exec_users_dir, exist_ok=True)
    
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
    
    # Load secrets to set database connection variables
    load_secrets_script = os.path.join(script_dir, 'load_secrets.sh')
    if os.path.exists(load_secrets_script):
        print("Loading secrets to set database connection variables")
        # Merge stderr into stdout for secret loading too
        result = subprocess.run(['/usr/bin/bash', load_secrets_script], env=env, cwd=script_dir,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if result.stdout:
            print(result.stdout)
        if result.returncode != 0:
            raise Exception(f"Failed to load secrets: {result.stdout}")
        
        # Whitelist of allowed environment variables
        ALLOWED_ENV_VARS = [
            'SOURCE_HOST', 'SOURCE_PORT', 'SOURCE_DB', 'SOURCE_USER', 'SOURCE_PASSWORD',
            'TARGET_HOST', 'TARGET_PORT', 'TARGET_DB', 'TARGET_USER', 'TARGET_PASSWORD'
        ]
        
        # Parse only whitelisted environment variables
        for line in result.stdout.split('\n'):
            if '=' in line and 'export' in line:
                key_value = line.replace('export ', '').strip()
                if '=' in key_value:
                    key, value = key_value.split('=', 1)
                    key = key.strip()
                    if key in ALLOWED_ENV_VARS:
                        env[key] = value.strip('"\'')
                    else:
                        print(f"Ignoring non-whitelisted environment variable: {key}")

    # Run only the refresh materialized views script
    refresh_script = os.path.join(script_dir, '05_refresh_materialized_views.sh')
    if not os.path.exists(refresh_script):
        raise Exception(f"05_refresh_materialized_views.sh not found in {script_dir}")
    
    success, output = run_shell_script(refresh_script, env)
    if not success:
        error_lines = [l for l in output
                       if any(kw in l.upper() for kw in ['ERROR', 'FATAL', 'FAILED', 'DENIED', 'REFUSED', 'TIMEOUT'])]
        if error_lines:
            error_summary = "; ".join(error_lines[:10])
        else:
            error_summary = "; ".join(output[-5:]) if output else "No output captured"
        raise Exception(f"Materialized view refresh failed: {error_summary}")

    print("Materialized view refresh completed successfully")

if __name__ == "__main__":
    main()