# Migrate Tenants Between Redshift Clusters and Redshift Serverless Workgroups

An automated AWS-native solution for migrating tenants between Amazon Redshift environments (Provisioned Clusters and Serverless Workgroups). This tool orchestrates complete schema, data, and permission migrations while minimizing downtime and ensuring data integrity.

## Overview

### Purpose

This migration solution provides:
- **Complete tenant migration** of schemas and database objects between Redshift environments
- **Automatic endpoint repointing** to redirect tenant connections to new clusters/workgroups
- **ETL pipeline integration** for continuous data loading to new endpoints
- **Minimal downtime** with automated orchestration and parallel processing
- **Data integrity** through validation and error handling mechanisms

### Key Features

✅ **Schema Migration**: Tables, views, materialized views, stored procedures  
✅ **User & Permission Migration**: Users, groups, roles, and granular permissions  
✅ **Data Migration**: Parallel UNLOAD/COPY operations with Spark optimization  
✅ **Automated Orchestration**: AWS Step Functions workflow coordination  
✅ **Security**: KMS encryption, IAM roles, Secrets Manager integration  
✅ **Monitoring**: CloudWatch logs with detailed execution tracking  
✅ **Error Handling**: Automatic retries and graceful failure recovery  

## Architecture

### High-Level Architecture

![High-Level Architecture](extracted_images/High-level-arch%20(1).png)

![Architecture Diagram](extracted_images/Picture%201.png)

### Components

```
┌─────────────────────┐
│  CloudFormation     │  One-click deployment
│  Template           │  Infrastructure as Code
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  AWS Step Functions │  Orchestration Layer
│  State Machine      │  - CreateSchemaObjects
└──────────┬──────────┘  - FetchTables (Lambda)
           │              - DataMigration (Map State)
           │              - RefreshViews
           ▼
┌─────────────────────┐
│  AWS Glue Jobs      │  Execution Layer
├─────────────────────┤
│ 1. Schema Migration │  Python Shell Job
│ 2. Data Migration   │  Spark Job (Parallel)
│ 3. View Refresh     │  Python Shell Job
└──────────┬──────────┘
           │
           ▼
┌─────────────────────┐
│  Shell Scripts      │  Migration Logic
├─────────────────────┤
│ 01_create_users_    │  Users & Groups
│    groups.sh        │
│ 02_migrate_ddl.sh   │  Tables & Schemas
│ 03_migrate_         │  Permissions
│    permissions.sh   │
│ 04_migrate_views.sh │  Views & Procedures
│ 05_refresh_         │  Materialized Views
│    materialized_    │
│    views.sh         │
└─────────────────────┘
           │
           ▼
┌─────────────────────┐
│  Supporting         │
│  Services           │
├─────────────────────┤
│ • S3 Buckets        │  Script & Data Storage
│ • Secrets Manager   │  Credentials
│ • IAM Roles         │  Access Control
│ • KMS Keys          │  Encryption
│ • CloudWatch Logs   │  Monitoring
│ • Lambda Functions  │  Table Discovery
└─────────────────────┘
```

### Workflow Execution

```
Step 1: CreateSchemaObjects (Glue Python Shell)
   ├─ Load credentials from Secrets Manager
   ├─ Execute 01_create_users_groups.sh
   ├─ Execute 02_migrate_ddl.sh
   ├─ Execute 03_migrate_permissions.sh
   └─ Execute 04_migrate_views.sh

Step 2: Lambda Invoke (FetchRedshiftTables)
   └─ Query source database for table list

Step 3: Map State (Parallel Data Migration)
   ├─ Process tables in parallel (max 10 concurrent)
   ├─ Each table: Glue Spark Job
   │  ├─ UNLOAD from source to S3
   │  └─ COPY from S3 to target
   └─ Tolerate 100% failures (continue on error)

Step 4: RefreshMaterializedViews (Glue Python Shell)
   └─ Execute 05_refresh_materialized_views.sh
```

## Prerequisites

### AWS Account Requirements

- AWS CLI configured with appropriate permissions
- CloudFormation deployment permissions
- VPC with private subnets for Glue jobs
- Existing S3 buckets for scripts and data storage

### Network Requirements

- **VPC**: Private subnets with NAT Gateway or VPC Endpoints
- **S3 Gateway Endpoint**: Required for Redshift UNLOAD/COPY operations
- **Security Groups**: Allow Redshift port (5439) access
- **Route Tables**: Properly configured for S3 endpoint

### Redshift Requirements

- **Source**: Redshift Provisioned Cluster or Serverless Workgroup
- **Target**: Redshift Provisioned Cluster or Serverless Workgroup
- **Credentials**: Stored in AWS Secrets Manager with required format
- **IAM Roles**: Associated with target workgroup for S3 access

## Deployment

### Step 1: Pre-Deployment Setup

#### 1.1 Create S3 Gateway Endpoint (if not exists)

```bash
# Via AWS Console
AWS Console > VPC > Endpoints > Create Endpoint
- Service: com.amazonaws.<region>.s3 (Gateway type)
- VPC: Select VPC where Redshift is located
- Route Tables: Select route tables for Redshift subnets

# Via AWS CLI
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-xxxxxxxxx \
  --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids rtb-xxxxxxxx rtb-yyyyyyyy
```

#### 1.2 Create Secrets Manager Secrets

Secrets must contain the following key-value pairs:

```json
{
  "host": "cluster-name.region.redshift.amazonaws.com",
  "port": "5439",
  "database": "database_name",
  "username": "admin_user",
  "password": "secure_password"
}
```

Create secrets:

```bash
# Source cluster/workgroup secret
aws secretsmanager create-secret \
  --name "redshift-source-cluster" \
  --description "Source Redshift credentials" \
  --secret-string '{
    "host": "source-cluster.us-east-1.redshift.amazonaws.com",
    "port": "5439",
    "database": "dev",
    "username": "admin",
    "password": "YourSecurePassword123!"
  }'

# Target cluster/workgroup secret (Producer)
aws secretsmanager create-secret \
  --name "redshift-target-producer" \
  --description "Target Redshift producer credentials" \
  --secret-string '{
    "host": "target-workgroup.us-east-1.redshift-serverless.amazonaws.com",
    "port": "5439",
    "database": "dev",
    "username": "admin",
    "password": "YourSecurePassword456!"
  }'

# Consumer secret (optional, for reader users)
aws secretsmanager create-secret \
  --name "redshift-target-consumer" \
  --description "Target Redshift consumer credentials" \
  --secret-string '{
    "host": "target-workgroup.us-east-1.redshift-serverless.amazonaws.com",
    "port": "5439",
    "database": "dev",
    "username": "reader",
    "password": "YourSecurePassword789!"
  }'
```

#### 1.3 Create SSM Parameters

```bash
# VPC ID
aws ssm put-parameter \
  --name "/migration/VpcId" \
  --value "vpc-xxxxxxxxx" \
  --type "String"

# Private Subnets (comma-separated)
aws ssm put-parameter \
  --name "/migration/Subnet" \
  --value "subnet-xxxxxxxx,subnet-yyyyyyyy" \
  --type "StringList"

# Security Group ID
aws ssm put-parameter \
  --name "/migration/SecurityGroupId" \
  --value "sg-xxxxxxxxx" \
  --type "String"
```

#### 1.4 Upload Migration Scripts to S3

```bash
# Create S3 bucket structure
aws s3 mb s3://your-migration-bucket

# Upload all files maintaining folder structure
cd /path/to/redshift-migration
aws s3 sync glue-jobs/ s3://your-migration-bucket/redshift-migrate/glue-jobs/
aws s3 sync shell-scripts/ s3://your-migration-bucket/redshift-migrate/shell-scripts/
aws s3 sync sql/ s3://your-migration-bucket/redshift-migrate/sql/

# Verify structure
aws s3 ls s3://your-migration-bucket/redshift-migrate/ --recursive
```

Expected S3 structure:
```
s3://your-migration-bucket/
└── redshift-migrate/
    ├── glue-jobs/
    │   ├── redshift_schema_migration_job.py
    │   ├── redshift-data-migration-spark-job.py
    │   └── refresh_views_glue_job.py
    ├── shell-scripts/
    │   ├── 01_create_users_groups.sh
    │   ├── 02_migrate_ddl.sh
    │   ├── 03_migrate_permissions.sh
    │   ├── 04_migrate_views.sh
    │   ├── 05_refresh_materialized_views.sh
    │   ├── common.sh
    │   ├── load_secrets.sh
    │   ├── pgpass.sh
    │   └── migrate.sh
    ├── sql/
    │   └── get_table_ddl.sql
    ├── lambda/
    │   └── fetch_redshift_tables_list.zip
    ├── lambda-layers/
    │   └── redshift_connector.zip
    └── libraries/
        ├── glue-psycopg2-dependencies.zip
        └── psycopg2_binary-2.9.10-cp311-cp311-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
```

#### 1.5 Create Data Bucket with Folders

```bash
# Create data bucket
aws s3 mb s3://your-data-bucket

# Create required folders
aws s3api put-object --bucket your-data-bucket --key redshift-migrate/unload/
aws s3api put-object --bucket your-data-bucket --key redshift-migrate/temporary/
```

### Step 2: Deploy CloudFormation Stack

#### Option A: AWS Console Deployment

1. Navigate to [AWS CloudFormation Console](https://console.aws.amazon.com/cloudformation/)
2. Click **Create stack** → **With new resources (standard)**
3. Upload template: `redshift_tenant_migration.yaml`
4. Configure parameters (see table below)
5. Acknowledge IAM resource creation
6. Click **Create stack**

#### Option B: AWS CLI Deployment

```bash
aws cloudformation create-stack \
  --stack-name redshift-tenant-migration \
  --template-body file://redshift_tenant_migration.yaml \
  --parameters \
    ParameterKey=BucketName,ParameterValue=your-migration-bucket \
    ParameterKey=DataBucketName,ParameterValue=your-data-bucket \
    ParameterKey=SourceSecretArn,ParameterValue=arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-source-cluster-abc123 \
    ParameterKey=TargetSecretArn,ParameterValue=arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-target-producer-def456 \
    ParameterKey=Schema,ParameterValue="('tenant_schema')" \
    ParameterKey=TenantName,ParameterValue=tenant_name \
    ParameterKey=TenantStackName,ParameterValue=tenant-cloudformation-stack \
    ParameterKey=SecurityGroupSSM,ParameterValue=/migration/SecurityGroupId \
    ParameterKey=SubnetSSM,ParameterValue=/migration/Subnet \
    ParameterKey=VpcSSM,ParameterValue=/migration/VpcId \
    ParameterKey=Region,ParameterValue=us-east-1 \
  --capabilities CAPABILITY_IAM

# Monitor stack creation
aws cloudformation wait stack-create-complete \
  --stack-name redshift-tenant-migration

# Get outputs
aws cloudformation describe-stacks \
  --stack-name redshift-tenant-migration \
  --query 'Stacks[0].Outputs'
```

### CloudFormation Parameters

| Parameter | Description | Required | Example |
|-----------|-------------|----------|---------|
| `BucketName` | S3 bucket for code artifacts | Yes | `my-migration-bucket` |
| `DataBucketName` | S3 bucket for Redshift data (with unload/temporary folders) | Yes | `my-data-bucket` |
| `SourceSecretArn` | ARN of source cluster credentials | Yes | `arn:aws:secretsmanager:...` |
| `TargetSecretArn` | ARN of target cluster credentials | Yes | `arn:aws:secretsmanager:...` |
| `Schema` | Schema name in SQL format | Yes | `"('sales_data')"` |
| `TenantName` | Name of the tenant | Yes | `acme_corp` |
| `TenantStackName` | CloudFormation stack name of tenant | Yes | `acme-corp-stack` |
| `Region` | AWS Region | Yes | `us-east-1` |
| `SecurityGroupSSM` | SSM parameter for security group ID | Yes | `/migration/SecurityGroupId` |
| `SubnetSSM` | SSM parameter for subnet IDs | Yes | `/migration/Subnet` |
| `VpcSSM` | SSM parameter for VPC ID | Yes | `/migration/VpcId` |
| `RedshiftServerlessPort` | Redshift port | No | `5439` (default) |

## Execution

### Start Migration via Step Functions

#### Option A: AWS Console

1. Navigate to [AWS Step Functions Console](https://console.aws.amazon.com/states/)
2. Select **MigrationStateMachine**
3. Click **Start execution**
4. Provide input JSON:

```json
{
  "SCHEMAS": "('tenant_schema')",
  "SOURCE_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-source-cluster-abc123",
  "TARGET_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-target-producer-def456",
  "TENANT_NAME": "tenant_name",
  "CONSUMER_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-target-consumer-ghi789",
  "TENANT_STACK_NAME": "tenant-cloudformation-stack"
}
```

5. Click **Start execution**

#### Option B: AWS CLI

```bash
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:us-east-1:123456789012:stateMachine:MigrationStateMachine" \
  --name "migration-$(date +%Y%m%d-%H%M%S)" \
  --input '{
    "SCHEMAS": "('\''tenant_schema'\'')",
    "SOURCE_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-source-cluster-abc123",
    "TARGET_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-target-producer-def456",
    "TENANT_NAME": "tenant_name",
    "CONSUMER_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret:redshift-target-consumer-ghi789",
    "TENANT_STACK_NAME": "tenant-cloudformation-stack"
  }'
```

### Monitor Execution

```bash
# Get execution status
aws stepfunctions describe-execution \
  --execution-arn "arn:aws:states:us-east-1:123456789012:execution:MigrationStateMachine:migration-20260202-120000"

# Get execution history
aws stepfunctions get-execution-history \
  --execution-arn "arn:aws:states:us-east-1:123456789012:execution:MigrationStateMachine:migration-20260202-120000" \
  --max-results 100
```

## Migration Process Details

### Phase 1: Create Schema Objects (Glue Python Shell Job)

**Duration**: 5-30 minutes (depending on schema complexity)

**Tasks**:
1. **Load Secrets**: Retrieve credentials from Secrets Manager
2. **Create Users & Groups** (`01_create_users_groups.sh`):
   - Extract users from `pg_user_info` (Serverless compatible)
   - Create users with proper attributes (CREATEDB, CREATEUSER, etc.)
   - Create groups and assign memberships
3. **Migrate DDL** (`02_migrate_ddl.sh`):
   - Create schemas
   - Extract table DDL using `get_table_ddl.sql`
   - Create tables with proper data types and constraints
   - Handle data type conversions (Provisioned → Serverless)
4. **Migrate Permissions** (`03_migrate_permissions.sh`):
   - Schema-level grants
   - Table-level permissions
   - Column-level permissions
   - Default privileges
5. **Migrate Views** (`04_migrate_views.sh`):
   - Standard views
   - Stored procedures and functions
   - Handle view dependencies

**Logs**: `/aws-glue/jobs/output` and `/aws-glue/jobs/error`

### Phase 2: Fetch Tables (Lambda Function)

**Duration**: < 1 minute

**Tasks**:
- Query source database for table list in specified schemas
- Exclude materialized view backing tables (`mv_tbl__%`)
- Return array of table names for parallel processing

**Logs**: `/aws/lambda/FetchRedshiftTablesFunction`

### Phase 3: Data Migration (Distributed Map State)

**Duration**: Variable (depends on data volume)

**Configuration**:
- **Max Concurrency**: 10 tables in parallel
- **Tolerated Failure**: 100% (continues even if tables fail)
- **Execution Type**: STANDARD (distributed processing)

**Per-Table Process** (Glue Spark Job):
1. **Associate IAM Role**: Attach S3 access role to target workgroup
2. **UNLOAD**: Export table data from source to S3
   ```sql
   UNLOAD ('SELECT * FROM schema.table')
   TO 's3://bucket/unload/schema/table/'
   IAM_ROLE 'arn:aws:iam::account:role/RedshiftS3Role'
   PARALLEL ON
   GZIP
   ALLOWOVERWRITE
   ```
3. **COPY**: Import data from S3 to target
   ```sql
   COPY schema.table
   FROM 's3://bucket/unload/schema/table/'
   IAM_ROLE 'arn:aws:iam::account:role/RedshiftS3Role'
   GZIP
   COMPUPDATE ON
   STATUPDATE ON
   ```

**Error Handling**:
- Failed tables logged but don't stop execution
- Review Map State results for failed tables
- Retry individual tables if needed

**Logs**: `/aws-glue/jobs/output` (per table execution)

### Phase 4: Refresh Materialized Views (Glue Python Shell Job)

**Duration**: 5-60 minutes (depends on view complexity)

**Tasks**:
1. Execute `05_refresh_materialized_views.sh`
2. Identify materialized views in target schemas
3. Refresh views in dependency order
4. Update statistics

**Logs**: `/aws-glue/jobs/output` and `/aws-glue/jobs/error`

## Monitoring & Troubleshooting

### CloudWatch Logs

| Component | Log Group | Log Stream |
|-----------|-----------|------------|
| Step Functions | `/aws/stepfunctions/<stack-name>` | Execution ID |
| Schema Migration Job | `/aws-glue/jobs/output` | Job run ID |
| Data Migration Job | `/aws-glue/jobs/output` | Job run ID (per table) |
| View Refresh Job | `/aws-glue/jobs/output` | Job run ID |
| Lambda Function | `/aws/lambda/FetchRedshiftTablesFunction` | Date-based |

### Troubleshooting Steps

#### 1. Step Function Failures

```bash
# View failed step details
AWS Console > Step Functions > Select execution > Click failed step

# Check associated resource (Glue/Lambda) in right pane
# Navigate to that resource's logs
```

#### 2. Glue Job Failures

```bash
# Via Console
AWS Console > Glue > Jobs > Select job > Runs tab > View logs

# Via CLI
aws glue get-job-runs --job-name <job-name> --max-results 10

# View specific run logs
aws logs tail /aws-glue/jobs/output --follow \
  --log-stream-name-prefix <job-run-id>
```

#### 3. Lambda Function Errors

```bash
# Via Console
AWS Console > Lambda > Select function > Monitor > View CloudWatch Logs

# Via CLI
aws logs tail /aws/lambda/FetchRedshiftTablesFunction --follow
```

#### 4. Map State (Parallel Data Migration) Errors

```bash
# Via Console
Step Functions > Select execution > Click Map State > Click "Map Run" (top right)

# View individual table execution results
# Check failed tables in execution details
```

#### 5. Data Migration Errors (UNLOAD/COPY)

```bash
# Check Glue Spark job logs
aws logs filter-log-events \
  --log-group-name /aws-glue/jobs/error \
  --filter-pattern "ERROR"

# Common issues:
# - IAM role not associated with workgroup
# - S3 permissions issues
# - Network connectivity (VPC endpoint)
# - Table doesn't exist in source
```

### Common Issues & Solutions

| Issue | Cause | Solution |
|-------|-------|----------|
| **Connection timeout** | Security group or network issue | Verify security group allows port 5439, check VPC endpoint |
| **IAM role not found** | Role not associated with workgroup | Glue job automatically associates role; check CloudWatch logs |
| **S3 access denied** | Missing S3 permissions | Verify IAM role has S3 read/write permissions |
| **Table already exists** | Previous partial migration | Scripts skip existing objects; safe to re-run |
| **User creation fails** | User already exists | Scripts check existence before creation |
| **View dependency error** | Views created out of order | `04_migrate_views.sh` handles dependencies automatically |
| **Materialized view refresh fails** | Base tables not migrated | Ensure Phase 3 completed successfully |

### Retry Failed Executions

If a Step Function execution fails:

1. **Review logs** to identify root cause
2. **Fix the issue** (permissions, network, etc.)
3. **Restart execution** with same input parameters

```bash
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:region:account:stateMachine:MigrationStateMachine" \
  --name "migration-retry-$(date +%Y%m%d-%H%M%S)" \
  --input '<same-input-json-as-before>'
```

Scripts are **idempotent** - they check for existing objects and skip creation if already present.

## Alternative: Snapshot Restore Migration

For large-scale migrations, use Redshift's native snapshot restore capability:

### Process

1. **Create snapshot** of source cluster
2. **Restore snapshot** to target cluster/workgroup
3. **Update tenant configuration** using Lambda function

### Post-Restore Steps

Execute the `tenant_cloudformation_stack_update` Lambda function:

```json
{
  "source_secret_arn": "arn:aws:secretsmanager:us-east-1:account:secret:source-secret-abc123",
  "target_secret_arn": "arn:aws:secretsmanager:us-east-1:account:secret:target-secret-def456",
  "consumer_secret_arn": "arn:aws:secretsmanager:us-east-1:account:secret:consumer-secret-ghi789",
  "tenant_name": "tenant_name",
  "tenant_stack_name": "tenant-stack-name",
  "schemas": "('schema_name')"
}
```

This updates the tenant's CloudFormation stack to point to the new endpoint.

## Key Differences: Provisioned vs Serverless

### System Tables

| Provisioned | Serverless | Usage |
|-------------|------------|-------|
| `svl_user_info` | `pg_user_info` | User information |
| `svv_all_schemas` | `svv_all_schemas` | Schema listing |

**Note**: Scripts automatically use Serverless-compatible system tables (`pg_user_info`).

### IAM Role Association

- **Provisioned**: Roles attached at cluster level
- **Serverless**: Roles attached at workgroup level
- **Migration**: Glue Spark job automatically associates roles with target workgroup

## Security Features

### Encryption

- **KMS Keys**: Customer-managed keys for Glue jobs and CloudWatch logs
- **Secrets Manager**: Encrypted credential storage
- **S3**: Server-side encryption for data in transit
- **CloudWatch Logs**: Encrypted with KMS

### Network Security

- **VPC Isolation**: All Glue jobs run in private subnets
- **Security Groups**: Restrictive inbound/outbound rules
- **S3 Gateway Endpoint**: Private connectivity to S3
- **No Internet Access**: Glue jobs don't require internet connectivity

### Access Control

- **IAM Roles**: Principle of least privilege
- **Resource Policies**: Fine-grained access control
- **Service-Linked Roles**: Secure service-to-service communication
- **Secrets Manager Policies**: Restricted secret access

## Cost Optimization

### Resource Usage

| Resource | Pricing Model | Optimization |
|----------|---------------|--------------|
| **AWS Glue** | Per-second billing (Python Shell: 0.44 DPU, Spark: configurable) | Use Python Shell for lightweight tasks |
| **Step Functions** | Per state transition | Minimize state transitions |
| **Lambda** | Per invocation + duration | Single invocation for table discovery |
| **CloudWatch Logs** | Per GB ingested + storage | 30-day retention policy |
| **S3** | Per GB stored + requests | Lifecycle policies for temporary data |

### Best Practices

- **Parallel Processing**: Leverage Map State concurrency (max 10)
- **Glue DPU**: Right-size Spark job DPUs based on data volume
- **S3 Lifecycle**: Delete temporary UNLOAD data after migration
- **Log Retention**: Adjust CloudWatch retention based on compliance needs

## Cleanup

### Delete CloudFormation Stack

```bash
# Delete stack (removes all resources)
aws cloudformation delete-stack --stack-name redshift-tenant-migration

# Wait for deletion
aws cloudformation wait stack-delete-complete \
  --stack-name redshift-tenant-migration
```

### Clean Up S3 Data

```bash
# Remove migration scripts
aws s3 rm s3://your-migration-bucket/redshift-migrate/ --recursive

# Remove temporary data
aws s3 rm s3://your-data-bucket/redshift-migrate/unload/ --recursive
aws s3 rm s3://your-data-bucket/redshift-migrate/temporary/ --recursive
```

### Remove Secrets and Parameters

```bash
# Delete secrets (30-day recovery window)
aws secretsmanager delete-secret \
  --secret-id redshift-source-cluster \
  --recovery-window-in-days 30

aws secretsmanager delete-secret \
  --secret-id redshift-target-producer \
  --recovery-window-in-days 30

# Delete SSM parameters
aws ssm delete-parameter --name /migration/VpcId
aws ssm delete-parameter --name /migration/Subnet
aws ssm delete-parameter --name /migration/SecurityGroupId
```

## File Structure

```
redshift-migration/
├── cloudformation/
│   └── redshift_tenant_migration.yaml    # CloudFormation template
├── glue-jobs/
│   ├── redshift_schema_migration_job.py  # Schema migration orchestrator
│   ├── redshift-data-migration-spark-job.py  # Data migration (UNLOAD/COPY)
│   └── refresh_views_glue_job.py         # Materialized view refresh
├── shell-scripts/
│   ├── migrate.sh                        # Main orchestration script
│   ├── common.sh                         # Shared functions
│   ├── load_secrets.sh                   # Secrets Manager integration
│   ├── pgpass.sh                         # PostgreSQL password file
│   ├── 01_create_users_groups.sh         # User/group creation
│   ├── 02_migrate_ddl.sh                 # Table DDL migration
│   ├── 03_migrate_permissions.sh         # Permission migration
│   ├── 04_migrate_views.sh               # View/procedure migration
│   └── 05_refresh_materialized_views.sh  # Materialized view refresh
├── sql/
│   └── get_table_ddl.sql                 # DDL extraction queries
├── requirements.txt                       # Python dependencies
└── README.md                              # This file
```

## Support & Contributing

### Getting Help

1. **CloudWatch Logs**: Check detailed execution logs
2. **Step Function History**: Review execution flow
3. **AWS Support**: Contact AWS Support for infrastructure issues

### Contributing

When contributing:
1. Follow AWS security best practices
2. Update CloudFormation templates for new features
3. Add comprehensive error handling and logging
4. Test in isolated environments before production
5. Update documentation for any changes

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgments

- Based on AWS Redshift migration best practices
- Adapted from [AWS Redshift Migration Samples](https://github.com/aws-samples/redshift-migrate-db)
- Optimized for Serverless Workgroup compatibility

---

**Version**: 1.0  
**Last Updated**: February 2026  
**Maintained By**: AWS Migration Team
