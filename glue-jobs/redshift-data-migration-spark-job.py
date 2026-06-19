import sys
import subprocess
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from botocore.exceptions import ClientError 
import psycopg2
import time
import boto3
import json
import os
import logging
from logging.config import dictConfig

def get_logger():
    logging_config = {
        'version': 1,
        'formatters': {'f': {'format': '%(asctime)s %(name)-12s %(levelname)-8s %(message)s'}},
        'handlers': {'h': {'class': 'logging.StreamHandler', 'formatter': 'f', 'level': 20}},
        'root': {'handlers': ['h'], 'level': 10}
    }
    dictConfig(logging_config)
    logger = logging.getLogger()
    return logger

import re

def validate_identifier(name, label="identifier"):
    """
    Validate that a database identifier (schema/table name) is safe.
    Allows only alphanumeric characters, underscores, and dots.
    Raises ValueError if the input contains potentially malicious characters.
    """
    if not name or not re.match(r'^[a-zA-Z_][a-zA-Z0-9_]*$', name):
        raise ValueError(
            f"Invalid {label}: '{name}'. "
            f"Only alphanumeric characters and underscores are allowed."
        )
    return name

  
def get_secret(secret_arn):
    """
    Fetch a secret from AWS Secrets Manager using ARN
    """
    try:
        # Initialize Secrets Manager client
        session = boto3.session.Session()
        region_name = session.region_name
        client = session.client("secretsmanager", region_name=region_name)
        logger.info("Successfully created Secrets Manager client")
        
        # Get the secret value using ARN
        response = client.get_secret_value(SecretId=secret_arn)
        logger.info("Successfully retrieved secret from Secrets Manager")
        
        # Parse the secret value (stored as JSON)
        secret = json.loads(response["SecretString"])
        return secret

    except Exception as e:
        logger.error(f"Error fetching secret: {str(e)}")
        raise e


def get_cluster_identifier_from_host(host):
    """
    Extract cluster identifier from a provisioned Redshift cluster host.
    Host format: <cluster-identifier>.<random>.<region>.redshift.amazonaws.com
    """
    try:
        if 'redshift-serverless' not in host and 'redshift.amazonaws.com' in host:
            cluster_id = host.split('.')[0]
            logger.info(f"Extracted cluster identifier: {cluster_id}")
            return cluster_id
        return None
    except Exception as e:
        logger.error(f"Error extracting cluster identifier from host {host}: {str(e)}")
        raise


def get_workgroup_from_host(host):
    """
    Extract workgroup name from Redshift Serverless host
    """
    try:
        if 'redshift-serverless' in host:
            workgroup = host.split('.')[0]
            logger.info(f"Extracted workgroup name: {workgroup}")
            return workgroup
        else:
            logger.warning(f"Not a Redshift Serverless host: {host}")
            return None
    except Exception as e:
        logger.error(f"Error extracting workgroup name from host {host}: {str(e)}")
        raise
    
def associate_role_with_workgroup(workgroup_name, role_arn):
    """
    Associate IAM role with Redshift Serverless workgroup
    """
    try:
        session = boto3.session.Session()
        client = session.client('redshift-serverless')
        
        try:
            workgroup_response = client.get_workgroup(
                workgroupName=workgroup_name
            )
            
            namespace = workgroup_response['workgroup'].get('namespaceName')
            if not namespace:
                raise ValueError(f"No namespace found for workgroup {workgroup_name}")
            
            # Get current namespace configuration
            namespace_response = client.get_namespace(
                namespaceName=namespace
            )
            
            # Get roles from namespace configuration
            raw_roles = namespace_response.get('namespace', {}).get('iamRoles', [])
            logger.info(f"Raw roles from namespace: {raw_roles}")
            
            # Extract existing role ARN from the IamRole object string
            existing_roles = []
            for role in raw_roles:
                role_str = str(role)
                if 'iamRoleArn=' in role_str:
                    arn = role_str.split('iamRoleArn=')[1].rstrip(')')
                    existing_roles.append(arn)
            
            logger.info(f"Existing roles extracted: {existing_roles}")
            
            # Combine existing roles with new role
            updated_roles = existing_roles.copy()
            if role_arn not in updated_roles:
                updated_roles.append(role_arn)
            
            logger.info(f"Combined role list: {updated_roles}")
            
            # Update namespace with combined roles
            update_params = {
                'namespaceName': namespace,
                'iamRoles': updated_roles
            }
            
            logger.info(f"Updating namespace with parameters: {update_params}")
            
            # Update namespace
            namespace_response = client.update_namespace(**update_params)
            
            # Wait for the update to propagate
            time.sleep(15)
            
            # Verify the update
            verify_response = client.get_namespace(namespaceName=namespace)
            final_roles = []
            for role in verify_response.get('namespace', {}).get('iamRoles', []):
                role_str = str(role)
                if 'iamRoleArn=' in role_str:
                    arn = role_str.split('iamRoleArn=')[1].rstrip(')')
                    final_roles.append(arn)
            
            logger.info(f"Final roles after update: {final_roles}")
            
            if role_arn not in final_roles:
                raise Exception(f"Role {role_arn} was not successfully associated")
            
            if not all(role in final_roles for role in existing_roles):
                raise Exception("Some existing roles were lost during update")
            
            return True
            
        except client.exceptions.ResourceNotFoundException:
            logger.error(f"Workgroup {workgroup_name} not found")
            raise
            
    except Exception as e:
        logger.error(f"Error associating role with workgroup {workgroup_name}: {str(e)}")
        raise

def verify_workgroup_role(workgroup_name, role_arn, max_retries=3, wait_time=15):
    """
    Verify that the IAM role is properly associated with the workgroup's namespace
    """
    try:
        session = boto3.session.Session()
        client = session.client('redshift-serverless')
        
        for attempt in range(max_retries):
            try:
                response = client.get_workgroup(
                    workgroupName=workgroup_name
                )
                
                namespace = response['workgroup'].get('namespaceName')
                if not namespace:
                    logger.error(f"No namespace found for workgroup {workgroup_name}")
                    return False
                
                namespace_response = client.get_namespace(
                    namespaceName=namespace
                )
                
                current_roles = []
                raw_roles = namespace_response.get('namespace', {}).get('iamRoles', [])
                logger.info(f"Verification attempt {attempt + 1} - Raw roles: {raw_roles}")
                
                for role in raw_roles:
                    role_str = str(role)
                    if 'iamRoleArn=' in role_str:
                        arn = role_str.split('iamRoleArn=')[1].rstrip(')')
                        current_roles.append(arn)
                
                logger.info(f"Verification attempt {attempt + 1} - Extracted roles: {current_roles}")
                
                if role_arn in current_roles:
                    logger.info(f"Verified: Role {role_arn} is associated with namespace {namespace}")
                    logger.info(f"All current roles: {current_roles}")
                    return True
                    
                logger.warning(f"Attempt {attempt + 1}: Role {role_arn} not yet associated. Current roles: {current_roles}")
                if attempt < max_retries - 1:
                    logger.info(f"Waiting {wait_time} seconds before next attempt...")
                    time.sleep(wait_time)
                    
            except Exception as e:
                logger.warning(f"Attempt {attempt + 1} failed: {str(e)}")
                if attempt < max_retries - 1:
                    time.sleep(wait_time)
        
        logger.error(f"Role {role_arn} is NOT associated with namespace {namespace} after {max_retries} attempts")
        return False
            
    except Exception as e:
        logger.error(f"Error verifying role association: {str(e)}")
        return False


def associate_role_with_cluster(cluster_identifier, role_arn):
    """
    Associate IAM role with a provisioned Redshift cluster
    """
    try:
        session = boto3.session.Session()
        client = session.client('redshift')

        # Check current roles on the cluster
        response = client.describe_clusters(ClusterIdentifier=cluster_identifier)
        cluster = response['Clusters'][0]
        existing_roles = [r['IamRoleArn'] for r in cluster.get('IamRoles', [])]
        logger.info(f"Existing roles on cluster {cluster_identifier}: {existing_roles}")

        if role_arn in existing_roles:
            logger.info(f"Role {role_arn} already associated with cluster {cluster_identifier}")
            return True

        # Add the role
        logger.info(f"Adding role {role_arn} to cluster {cluster_identifier}")
        client.modify_cluster_iam_roles(
            ClusterIdentifier=cluster_identifier,
            AddIamRoles=[role_arn]
        )

        # Wait and verify
        max_retries = 6
        wait_time = 15
        for attempt in range(max_retries):
            time.sleep(wait_time)
            response = client.describe_clusters(ClusterIdentifier=cluster_identifier)
            current_roles = [r['IamRoleArn'] for r in response['Clusters'][0].get('IamRoles', [])]
            # Check role is present and in-sync (not adding/removing)
            for r in response['Clusters'][0].get('IamRoles', []):
                if r['IamRoleArn'] == role_arn:
                    status = r.get('ApplyStatus', '')
                    logger.info(f"Role {role_arn} status: {status} (attempt {attempt + 1})")
                    if status == 'in-sync':
                        logger.info(f"Role {role_arn} successfully associated with cluster {cluster_identifier}")
                        return True
                    break
            else:
                logger.warning(f"Attempt {attempt + 1}: Role {role_arn} not found on cluster yet")

        raise Exception(f"Role {role_arn} not in-sync with cluster {cluster_identifier} after {max_retries} attempts")

    except ClientError as e:
        if 'ClusterNotFound' in str(e):
            logger.error(f"Cluster {cluster_identifier} not found")
        raise
    except Exception as e:
        logger.error(f"Error associating role with cluster {cluster_identifier}: {str(e)}")
        raise


def setup_workgroup_roles(secret_values, role_arn, prefix):
    """
    Setup IAM role association for a Redshift Serverless workgroup or provisioned cluster
    """
    try:
        host = secret_values.get('host')
        if not host:
            logger.error(f"No host found in {prefix} secret values")
            raise ValueError(f"No host found in {prefix} secret values")

        # Try Serverless first
        workgroup_name = get_workgroup_from_host(host)
        if workgroup_name:
            logger.info(f"Setting up {prefix} Serverless workgroup role association...")
            associate_role_with_workgroup(workgroup_name, role_arn)

            max_retries = 3
            for attempt in range(max_retries):
                if verify_workgroup_role(workgroup_name, role_arn):
                    logger.info(f"Completed {prefix} workgroup role association")
                    return True
                elif attempt < max_retries - 1:
                    logger.warning(f"Verification attempt {attempt + 1} failed, retrying...")
                    time.sleep(10)

            raise Exception(f"Failed to verify role association for {prefix} workgroup after {max_retries} attempts")

        # Try provisioned cluster
        cluster_id = get_cluster_identifier_from_host(host)
        if cluster_id:
            logger.info(f"Setting up {prefix} provisioned cluster role association...")
            associate_role_with_cluster(cluster_id, role_arn)
            logger.info(f"Completed {prefix} cluster role association")
            return True

        logger.warning(f"Could not identify Redshift type for {prefix} host: {host}")
        return False

    except Exception as e:
        logger.error(f"Error setting up {prefix} role association: {str(e)}")
        raise

    
    
def get_connection(secret_values, prefix):
    """
    Create Redshift connection based on secrets manager values
    """
    try:
        # Get connection parameters from secrets
        host = secret_values.get('host')
        port = int(secret_values.get('port', 5439))
        database = secret_values.get('database')
        username = secret_values.get('username')
        password = secret_values.get('password')
        
        logger.info(f"Attempting to connect to {prefix} database")

        # Create connection using psycopg2
        conn = psycopg2.connect(
            host=host,
            port=port,
            database=database,
            user=username,
            password=password
            #sslmode='require'  # Enable SSL
        )
        
        conn.autocommit = True
            
        # Test connection
        with conn.cursor() as cursor:
            cursor.execute('SELECT 1')
            logger.info(f"Successfully connected to {prefix} database")

        return conn
            
    except Exception as e:
        logger.error(f"Error connecting to {prefix} database: {str(e)}")
        raise

def get_table_columns(conn, schema, table_name):
    """
    Get column names and data types for a table to handle SUPER columns.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(f"""
            SELECT column_name, data_type
            FROM information_schema.columns
            WHERE table_schema = '{schema}' AND table_name = '{table_name}'
            ORDER BY ordinal_position
        """)
        columns = cursor.fetchall()
        return columns
    finally:
        cursor.close()

def has_identity_column(conn, schema, table_name):
    """
    Check if a table has any IDENTITY columns.
    """
    cursor = conn.cursor()
    try:
        cursor.execute(f"""
            SELECT COUNT(*) FROM information_schema.columns
            WHERE table_schema = '{schema}' AND table_name = '{table_name}'
            AND column_default LIKE '"identity"%%'
        """)
        count = cursor.fetchone()[0]
        return count > 0
    finally:
        cursor.close()



def build_unload_select(schema, table_name, columns):
    """
    Build SELECT statement that casts SUPER columns to VARCHAR for CSV compatibility.
    """
    col_expressions = []
    for col_name, data_type in columns:
        if data_type.lower() == 'super':
            col_expressions.append(f"CAST({col_name} AS VARCHAR) AS {col_name}")
        else:
            col_expressions.append(col_name)
    return f"SELECT {', '.join(col_expressions)} FROM {schema}.{table_name}"


def unload_tables(source_conn, s3_bucket, schema, iam_role, table_name=None):
    """
    Unload tables from source Redshift to S3 using IAM role authentication.
    """
    start = time.time()
    cursor = source_conn.cursor()
    try:
        # Clean up old files at the S3 path to avoid stale data from previous runs
        s3_path = f"{s3_bucket}/{table_name}/"
        s3_prefix = s3_path.replace("s3://", "")
        bucket_name = s3_prefix.split("/", 1)[0]
        prefix = s3_prefix.split("/", 1)[1] if "/" in s3_prefix else ""
        
        s3_client = boto3.client('s3')
        logger.info(f"Cleaning up old files at {s3_path}")
        paginator = s3_client.get_paginator('list_objects_v2')
        for page in paginator.paginate(Bucket=bucket_name, Prefix=prefix):
            if 'Contents' in page:
                objects = [{'Key': obj['Key']} for obj in page['Contents']]
                s3_client.delete_objects(Bucket=bucket_name, Delete={'Objects': objects})
                logger.info(f"Deleted {len(objects)} old files from {s3_path}")

        # Get columns to handle SUPER types
        columns = get_table_columns(source_conn, schema, table_name)
        select_stmt = build_unload_select(schema, table_name, columns)

        sql = f"""
            UNLOAD('{select_stmt}')
            TO '{s3_bucket}/{table_name}/'
            IAM_ROLE '{iam_role}'
            ALLOWOVERWRITE
            PARALLEL ON
            FORMAT CSV GZIP
            NULL AS 'nullstring';
        """
        logger.info(f"Unloading table: {schema}.{table_name}")
        cursor.execute(sql)
        logger.info(f"Successfully unloaded {schema}.{table_name}")
    except Exception as e:
        logger.error(f"Error unloading table {table_name}: {str(e)}")
        raise e

    finally:
        cursor.close()

    end = time.time()
    logger.info(f"Finished unloading in {end - start} seconds")

def load_tables(target_conn, s3_bucket, schema, iam_role_arn, table_name=None):
    """
    Load tables from S3 to target Redshift using COPY with IAM role authentication.
    """
    start = time.time()
    cursor = target_conn.cursor()

    try:
        cursor.execute("SELECT current_user, current_database();")
        current_user, current_db = cursor.fetchone()
        logger.info(f"Connected as user: {current_user} to database: {current_db}")
        logger.info(f"Truncating table: {schema}.{table_name}")
        cursor.execute(f"TRUNCATE table {schema}.{table_name}")

        # Check if table has identity columns
        identity = has_identity_column(target_conn, schema, table_name)
        explicit_ids = "EXPLICIT_IDS" if identity else ""
        if identity:
            logger.info(f"Table {schema}.{table_name} has IDENTITY columns, using EXPLICIT_IDS")

        # Construct the COPY command with IAM role
        sql = f"""
            COPY {schema}.{table_name}
            FROM '{s3_bucket}/{table_name}/'
            IAM_ROLE '{iam_role_arn}'
            COMPUPDATE OFF
            STATUPDATE OFF
            CSV GZIP
            {explicit_ids}
            NULL AS 'nullstring';
        """
        logger.info(f"Loading table: {schema}.{table_name}")
        cursor.execute(sql)
        target_conn.commit()
        logger.info(f"Successfully loaded {schema}.{table_name}")

    except Exception as e:
        target_conn.rollback()
        logger.error(f"Error loading table {table_name}: {str(e)}")

        # Query sys_load_error_detail for the actual error
        try:
            err_cursor = target_conn.cursor()
            err_cursor.execute("""
                SELECT query_id, table_name, col_name, col_length, type, error_code, error_message, file_name, line_number
                FROM sys_load_error_detail
                ORDER BY query_id DESC
                LIMIT 10
            """)
            errors = err_cursor.fetchall()
            if errors:
                col_names = [desc[0] for desc in err_cursor.description]
                logger.error(f"=== COPY errors from sys_load_error_detail for {table_name} ===")
                for row in errors:
                    error_dict = dict(zip(col_names, row))
                    logger.error(f"  {error_dict}")
                # Include first error detail in the exception
                first_err = dict(zip(col_names, errors[0]))
                raise Exception(
                    f"COPY failed for {schema}.{table_name}: "
                    f"col={first_err.get('col_name')}, "
                    f"error_code={first_err.get('error_code')}, "
                    f"error_message={first_err.get('error_message')}, "
                    f"file={first_err.get('file_name')}, "
                    f"line={first_err.get('line_number')}"
                ) from e
            err_cursor.close()
        except Exception as inner_e:
            if inner_e.__cause__ is e:
                raise
            logger.error(f"Could not query sys_load_error_detail: {str(inner_e)}")

        raise e

    finally:
        cursor.close()

    end = time.time()
    logger.info(f"Finished loading in {end - start} seconds")
    
logger = get_logger()
# Get job parameters
args = getResolvedOptions(sys.argv, [
    'JOB_NAME',
    'SCHEMAS',
    'TABLE_NAME',
    'S3_BUCKET',
    'IAM_ROLE',
    'SOURCE_SECRET_ARN',
    'TARGET_SECRET_ARN'
])

source_secret_arn = args['SOURCE_SECRET_ARN']
target_secret_arn = args['TARGET_SECRET_ARN']

# Validate schema and table name inputs to prevent SQL injection
validate_identifier(args['SCHEMAS'], "schema")
validate_identifier(args['TABLE_NAME'], "table name")

# Initialize Glue job
sc = SparkContext()
glueContext = GlueContext(sc)
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

try:
    # Get secrets using ARNs
    source_secret = get_secret(source_secret_arn)
    target_secret = get_secret(target_secret_arn)
    
    # Setup IAM role associations for both workgroups
    logger.info("Setting up IAM role associations...")
    
    # Source role setup (handles both Serverless and provisioned clusters)
    setup_workgroup_roles(source_secret, args['IAM_ROLE'], "SOURCE")

    # Target role setup (handles both Serverless and provisioned clusters)
    setup_workgroup_roles(target_secret, args['IAM_ROLE'], "TARGET")
    
    # Create connections
    logger.info("Creating source connection...")
    source_conn = get_connection(source_secret, "SOURCE")
    logger.info("Source connection established")

    logger.info("Creating target connection...")
    target_conn = get_connection(target_secret, "TARGET")
    logger.info("Target connection established")
    
    try:
        logger.info("Starting unload process...")
        unload_tables(
            source_conn, 
            args['S3_BUCKET'], 
            args['SCHEMAS'],
            args['IAM_ROLE'],
            args['TABLE_NAME']
        )
        logger.info("completed unload process...")

        logger.info("Starting load process...")
        load_tables(
            target_conn, 
            args['S3_BUCKET'], 
            args['SCHEMAS'],
            args['IAM_ROLE'],
            args['TABLE_NAME']
        )
        logger.info("Completed load process...")

    finally:
        if 'source_conn' in locals():
            source_conn.close()
            logger.info("Source connection closed")
        if 'target_conn' in locals():
            target_conn.close()
            logger.info("Target connection closed")

    job.commit()
    logger.info("Job completed successfully")
    
except Exception as e:
    logger.error(f"Job failed: {str(e)}")
    raise e
