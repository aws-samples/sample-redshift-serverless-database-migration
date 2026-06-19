import boto3
import json
import os
import re
from datetime import datetime


def parse_failed_cause(cause_str):
    """
    Parse the Cause string from the Fail state.
    Format: table=<name>, schema=<schema>, error=<err>, cause=<cause>
    """
    result = {'table': 'unknown', 'schema': 'unknown', 'error': 'unknown', 'cause': 'unknown'}
    try:
        # Extract table=..., schema=..., error=..., cause=...
        match = re.match(r'table=([^,]*),\s*schema=([^,]*),\s*error=([^,]*),\s*cause=(.*)', cause_str)
        if match:
            result['table'] = match.group(1).strip()
            result['schema'] = match.group(2).strip()
            result['error'] = match.group(3).strip()
            result['cause'] = match.group(4).strip()
        else:
            result['cause'] = cause_str
    except Exception:
        result['cause'] = str(cause_str)
    return result


def handler(event, context):
    print(f"Event: {json.dumps(event, indent=2)}")

    s3 = boto3.client('s3')
    bucket = os.environ['S3_BUCKET']

    map_results = event.get('MapResults', [])
    schemas = event.get('SCHEMAS', '')
    tenant = event.get('TENANT_NAME', '')
    source_secret = event.get('SOURCE_SECRET_ARN', '')
    target_secret = event.get('TARGET_SECRET_ARN', '')
    # For threshold breach path, get total from input tables if MapResults is sparse
    input_tables = event.get('InputTables', [])

    failed_tables = []
    succeeded_tables = []

    for result in map_results:
        if isinstance(result, dict):
            # Succeeded items from HandleSuccess Pass state
            if result.get('status') == 'succeeded':
                succeeded_tables.append(result.get('table', 'unknown'))
            # Failed items from HandleError Fail state (inline map error entries)
            elif result.get('Error') == 'TableMigrationFailed':
                parsed = parse_failed_cause(result.get('Cause', ''))
                failed_tables.append(parsed)
            # Legacy format support
            elif result.get('status') == 'failed':
                failed_tables.append({
                    'table': result.get('table', 'unknown'),
                    'schema': result.get('schema', 'unknown'),
                    'error': result.get('error', 'unknown'),
                    'cause': result.get('cause', 'unknown')
                })

    timestamp = datetime.utcnow().strftime('%Y-%m-%dT%H-%M-%S')
    total = len(succeeded_tables) + len(failed_tables)
    # If total is 0 but we have input tables info, use that
    if total == 0 and input_tables:
        total = len(input_tables)
    failed_count = len(failed_tables)
    succeeded_count = len(succeeded_tables)

    report = {
        'timestamp': timestamp,
        'tenant': tenant,
        'schemas': schemas,
        'total_tables': total,
        'succeeded_count': succeeded_count,
        'failed_count': failed_count,
        'succeeded_tables': succeeded_tables,
        'failed_tables': failed_tables
    }

    report_key = f"migration-reports/{tenant}/{timestamp}/migration_report.json"
    s3.put_object(
        Bucket=bucket,
        Key=report_key,
        Body=json.dumps(report, indent=2),
        ContentType='application/json'
    )
    print(f"Migration report written to s3://{bucket}/{report_key}")

    retry_input = None
    retry_key = None
    if failed_tables:
        retry_payload = {
            'tables': [
                {
                    'SCHEMAS': ft['schema'],
                    'TABLE_NAME': ft['table'],
                    'SOURCE_SECRET_ARN': source_secret,
                    'TARGET_SECRET_ARN': target_secret
                }
                for ft in failed_tables
            ]
        }
        retry_key = f"migration-reports/{tenant}/{timestamp}/retry_failed_tables.json"
        s3.put_object(
            Bucket=bucket,
            Key=retry_key,
            Body=json.dumps(retry_payload, indent=2),
            ContentType='application/json'
        )
        print(f"Retry input written to s3://{bucket}/{retry_key}")
        retry_input = f"s3://{bucket}/{retry_key}"

    return {
        'timestamp': timestamp,
        'tenant': tenant,
        'schemas': schemas,
        'total_tables': total,
        'succeeded_count': succeeded_count,
        'failed_count': failed_count,
        'failed_tables': [ft['table'] for ft in failed_tables],
        'report_location': f"s3://{bucket}/{report_key}",
        'retry_input_location': retry_input
    }
