# Claude Instructions – dev-docs

This directory contains development documentation for the andreas-services monorepo.
For monorepo-wide coding patterns and conventions, see the root `CLAUDE.md`.

## AWS Authentication Best Practices

### Never Use Hardcoded Access Keys

- **Production (Lambda)**: Use IAM roles attached to Lambda functions
- **Local Development**: Use AWS CLI credentials (`aws configure`)
- **boto3**: When no credentials are passed, it automatically uses:
  1. Lambda IAM role (in AWS)
  2. AWS CLI credentials from `~/.aws/credentials` (locally)
  3. Environment variables (if set)

```python
# CORRECT
boto3.client('s3', region_name='us-east-1')

# WRONG — never hardcode keys
boto3.client('s3',
    aws_access_key_id='AKIA...',
    aws_secret_access_key='...')
```

## Services in this Repo

See root `CLAUDE.md` for the full service index.

- Humbugg moved to its own repo (`ansavva/humbugg`) on 2026-09-30

## Shared Infrastructure

`infra/` at the repo root owns the shared Route53 zone, ACM wildcard cert, VPC,
and DocumentDB. See `infra/README.md` for full documentation.
**Never recreate these resources inside a service.**
