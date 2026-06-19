# Security Policy

## Reporting a Vulnerability

If you discover a potential security issue in this project, we ask that you
notify AWS/Amazon Security via our
[vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/)
or directly via email to [aws-security@amazon.com](mailto:aws-security@amazon.com).

Please do **not** create a public GitHub issue for security vulnerabilities.

## Project-Specific Security Notes

This repository contains an automated AWS-native solution for migrating tenants
between Amazon Redshift environments (Provisioned Clusters and Serverless
Workgroups). It processes sensitive database credentials, tenant business data,
and IAM roles.

### Security Controls Implemented

- **Credential Management**: All database credentials stored in AWS Secrets Manager. No hardcoded credentials. `.pgpass` files use unpredictable paths (`tempfile.mkstemp()`) with `0o600` permissions.
- **Network Isolation**: All compute resources (Glue jobs, Lambda functions) run in private VPC subnets with no internet access. AWS services accessed via VPC endpoints only.
- **Encryption**: KMS-encrypted CloudWatch logs, Glue job bookmarks (SSE-KMS/CSE-KMS), S3 server-side encryption, and SSL/TLS required for all Redshift connections (`PGSSLMODE=require`).
- **IAM Least Privilege**: Permission boundaries on Lambda roles, resource-scoped policies, `iam:PassedToService` conditions on PassRole.
- **SQL Injection Prevention**: `validate_identifier()` with strict regex whitelist applied to all dynamic schema/table name inputs before SQL construction.
- **Supply Chain Protection**: File whitelist for S3 script downloads, path traversal validation on execution paths.
- **Data Retention**: S3 lifecycle policy auto-expires intermediate UNLOAD data (7-day expiry on `unload/` prefix, 3-day on `temporary/`). Pre-UNLOAD cleanup removes stale data from previous runs.
- **Audit Trail**: Step Functions logging at ALL level, CloudWatch log groups with 30-day retention, CloudTrail captures all `StartExecution` API calls.

### Before Deploying

- Replace all placeholder parameter values (Secret ARNs, bucket names, VPC/subnet/security group SSM parameter names) with values appropriate to your environment.
- Review the IAM policies in `cloudformation/redshift_tenant_migration.yaml` against your organization's security requirements.
- Ensure AWS CloudTrail is enabled in the deployment account with management events logging active.
- Verify S3 buckets used for data and code artifacts have appropriate bucket policies and public access blocks enabled.
- Confirm VPC endpoints are configured for all required services (S3, Secrets Manager, STS, SSM, Redshift, Lambda, CloudFormation).

### Security Assessments

This project has undergone the following security assessments:

- **Threat Model**: Comprehensive threat model with 10 identified threats, 11 mitigations, and residual risk analysis. See `.threatmodel/threat-model-redshift-migration.md`.
- **HOMES Scan**: Static analysis via Checkov, cfn-guard, Semgrep OSS, and Bandit. 16 findings remediated, 93 remaining documented as exceptions with compensating controls. See `homes-unfixable-findings-report.md`.
- **IAM Access Analyzer**: Policy validation confirming least-privilege adherence. See `iam-access-analyzer-v2.json`.

### Data Classification

| Data Type | Classification | Protection |
|-----------|---------------|------------|
| Redshift superuser credentials | Restricted | Secrets Manager, encrypted at rest, never logged |
| Tenant business data | Confidential | Encrypted in transit (SSL) and at rest (S3 SSE, Redshift encryption) |
| IAM roles and KMS keys | Restricted | Permission boundaries, resource-scoped policies |
| Schema definitions (DDL) | Confidential | Encrypted in transit, VPC-isolated |
| Intermediate S3 data | Confidential | SSE encryption, lifecycle auto-expiry, IAM-scoped access |

### Known Limitations

- `.pgpass` file exists on Glue job `/tmp` filesystem during active execution. Mitigated by unpredictable paths, restrictive permissions, and ephemeral Glue container lifecycle.
- Dynamic SQL f-strings used for Redshift UNLOAD/COPY commands (parameterized identifiers not supported by Redshift). Mitigated by `validate_identifier()` input validation.
- Shell scripts use global `IFS` modification for psql output parsing. Mitigated by save/restore pattern and isolated Glue container execution.
