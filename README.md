# Stache AI - Serverless Deployment

AWS Lambda deployment for Stache AI using SAM (Serverless Application Model).

## What This Is

This repository contains the AWS Lambda deployment configuration for Stache AI. It wraps the `stache-ai` Python packages and deploys a full-stack application to AWS with:

- **Vue.js Frontend** served via CloudFront
- **API Gateway** with Cognito JWT authentication
- **Cognito User Pool** for user management
- **AWS Bedrock** for LLM and embeddings (Claude + Cohere)
- **S3 Vectors** for vector storage
- **DynamoDB** for namespace and document indexing

## Prerequisites

1. AWS CLI configured with credentials
2. [AWS SAM CLI](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html) installed
3. Python 3.12+
4. Node.js 20+ (for frontend build)
5. Access to the `stache-ai/stache-ai` repository

## Quick Start

### Option 1: GitHub Actions (Recommended)

1. Fork this repository
2. Set up GitHub secrets (see [GitHub Actions Setup](#github-actions-setup))
3. Run the **Deploy to AWS** workflow from the Actions tab

### Option 2: Local Deployment

```bash
# Clone this repo and the main stache repo
git clone https://github.com/stache-ai/stache-serverless.git
git clone https://github.com/stache-ai/stache-ai.git ../stache

# Deploy (builds Lambda layer, SAM stack, and frontend)
./scripts/deploy.sh
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                          AWS Cloud                               │
│                                                                  │
│  Vue Frontend ──► CloudFront ──► S3 Bucket                      │
│       │                                                          │
│       ▼                                                          │
│  API Gateway ──► Cognito JWT Auth ──► Lambda (FastAPI)          │
│                                           │                      │
│  Claude Desktop ──► AgentCore Gateway ────┘                     │
│                                           │                      │
│                                           ▼                      │
│                          ┌────────────────────────────┐         │
│                          │    Shared Resources        │         │
│                          ├────────────────────────────┤         │
│                          │ • Bedrock (Claude + Cohere)│         │
│                          │ • S3 Vectors               │         │
│                          │ • DynamoDB                 │         │
│                          └────────────────────────────┘         │
└─────────────────────────────────────────────────────────────────┘
```

### Two Lambda Functions

1. **{prefix}-api** - HTTP API via API Gateway with Cognito auth
2. **{prefix}-agentcore** - Direct invocation for Claude Desktop MCP

## Deployment

### Local Scripts

All scripts support a `--prefix` flag for multiple deployments in the same AWS account:

```bash
# Deploy with default prefix (stache)
./scripts/deploy.sh

# Deploy with custom prefix
./scripts/deploy.sh --prefix myapp

# Skip frontend build (faster for backend-only changes)
./scripts/deploy.sh --skip-frontend

# Skip Lambda layer build (use existing)
./scripts/deploy.sh --skip-layer
```

Environment variables:
- `RESOURCE_PREFIX` - Same as `--prefix` (default: `stache`)
- `STACHE_REPO` - Path to stache-ai repo (default: `../stache`)
- `AWS_REGION` - AWS region (default: `us-east-1`)
- `AWS_PROFILE` - AWS CLI profile to use (optional)

```bash
# Example with profile
AWS_PROFILE=myprofile ./scripts/deploy.sh --prefix prod
```

### GitHub Actions Setup

#### Required Secrets

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM access key |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key |
| `STACHE_REPO_TOKEN` | GitHub token with access to stache-ai/stache-ai (if private) |

#### Available Workflows

**Deploy to AWS** (`deploy.yml`)
- Builds Lambda layer, deploys SAM stack, builds and deploys frontend
- Inputs: `resource_prefix`, `app_domain`, `certificate_arn`

**Setup Custom Domain** (`setup-custom-domain.yml`)
- Creates ACM certificate and outputs DNS validation records
- Inputs: `resource_prefix`, `domain`

**Create Cognito User** (`create-user.yml`)
- Creates a user in Cognito with auto-generated password
- Inputs: `resource_prefix`, `email`

#### Running a Workflow

1. Go to **Actions** tab
2. Select the workflow
3. Click **Run workflow**
4. Fill in inputs and click **Run workflow**

## Custom Domain Setup

### Step 1: Create Certificate

```bash
./scripts/setup-custom-domain.sh stache.example.com
```

This creates an ACM certificate and outputs DNS validation records.

### Step 2: Add DNS Records

Add the CNAME record shown in the output to validate the certificate. Wait for validation (can take a few minutes).

```bash
# Check certificate validation status
./scripts/check-certificate.sh stache.example.com
```

### Step 3: Deploy

```bash
# Deploy with custom domain - certificate auto-detected by domain name
./scripts/deploy.sh --domain stache.example.com
```

### Step 4: Point Domain to CloudFront

After deployment, add a CNAME record pointing your domain to the CloudFront distribution shown in the output.

## User Management

### Create a User

```bash
# Local script
./scripts/create-user.sh user@example.com

# With custom prefix
./scripts/create-user.sh --prefix myapp user@example.com

# With specific password
./scripts/create-user.sh user@example.com "MyP@ssw0rd!"
```

Or use the **Create Cognito User** GitHub workflow.

## AgentCore Gateway (Claude Desktop MCP)

AgentCore Gateway enables Claude Desktop to access Stache via MCP (Model Context Protocol).

### Setup

```bash
# After deploying the main stack
./scripts/setup-agentcore.sh

# With custom prefix
./scripts/setup-agentcore.sh --prefix myapp
```

This creates:
1. **IAM Role** - Allows Bedrock to invoke the Lambda function
2. **AgentCore Gateway** - MCP gateway with Cognito JWT authentication
3. **Lambda Target** - Connects the gateway to the Stache Lambda with tool schema

Configuration is saved to `.agentcore-config.json`.

### Claude Desktop Configuration

Add to `~/.config/claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "stache": {
      "url": "<gateway_url_from_setup>",
      "headers": {
        "Authorization": "Bearer <cognito_jwt_token>"
      }
    }
  }
}
```

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `search` | Semantic search with reranking |
| `ingest_text` | Add text content to knowledge base |
| `list_namespaces` | List all namespaces |
| `list_documents` | List documents (with pagination) |
| `get_document` | Get document metadata by ID |

### Get OAuth Token for MCP

```bash
# Get stack outputs
STACK_NAME="stache-serverless"

CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' \
  --output text)

# Authenticate and get token
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=user@example.com,PASSWORD=YourPassword! \
  --query 'AuthenticationResult.IdToken' \
  --output text)

echo "Token: $TOKEN"
```

### Get JWT Token

```bash
# Get stack outputs
STACK_NAME="stache-serverless"  # or "${prefix}-serverless"

CLIENT_ID=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`UserPoolClientId`].OutputValue' \
  --output text)

# Authenticate
aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --client-id $CLIENT_ID \
  --auth-parameters USERNAME=user@example.com,PASSWORD=YourPassword123! \
  --query 'AuthenticationResult.IdToken' \
  --output text
```

## What Gets Created

Resources are named with the prefix (default: `stache`):

| Resource | Name Pattern |
|----------|--------------|
| CloudFormation Stack | `{prefix}-serverless` |
| Lambda Functions | `{prefix}-api`, `{prefix}-agentcore` |
| S3 Buckets | `{prefix}-vectors-{account}`, `{prefix}-frontend-{account}` |
| DynamoDB Tables | `{prefix}-namespaces`, `{prefix}-documents` |
| CloudFront Distribution | Auto-generated or custom domain |
| Cognito User Pool | `{prefix}-serverless-users` |
| SQS Dead Letter Queue | `{prefix}-lambda-dlq` |
| AgentCore Gateway | `{prefix}-mcp-gateway` |
| AgentCore IAM Role Stack | `{prefix}-agentcore-role` |

## Multiple Deployments

Deploy multiple instances in the same AWS account using different prefixes:

```bash
# Production
./scripts/deploy.sh --prefix stache-prod

# Staging
./scripts/deploy.sh --prefix stache-staging

# Development
./scripts/deploy.sh --prefix stache-dev
```

Each deployment is completely isolated with its own resources.

## Useful Commands

```bash
# Get all stack outputs
aws cloudformation describe-stacks \
  --stack-name stache-serverless \
  --query 'Stacks[0].Outputs' \
  --output table

# View Lambda logs
sam logs -n stache-api --tail

# Delete stack (CAUTION: deletes all data)
sam delete --stack-name stache-serverless
```

## Environment Variables

Configured in `template.yaml` Globals section:

| Variable | Value | Description |
|----------|-------|-------------|
| `LLM_PROVIDER` | bedrock | LLM provider |
| `EMBEDDING_PROVIDER` | bedrock | Embedding provider |
| `VECTORDB_PROVIDER` | s3vectors | Vector database |
| `NAMESPACE_PROVIDER` | dynamodb | Namespace storage |
| `DOCUMENT_INDEX_PROVIDER` | dynamodb | Document index |
| `BEDROCK_LLM_MODEL` | anthropic.claude-3-5-sonnet-20241022-v2:0 | Claude model |
| `BEDROCK_EMBEDDING_MODEL` | cohere.embed-english-v3 | Cohere embeddings |

## Cost Considerations

This deployment uses pay-per-use AWS services:

| Service | Pricing |
|---------|---------|
| Lambda | $0.20 per 1M requests |
| API Gateway | $3.50 per 1M requests |
| Cognito | Free tier: 50,000 MAU |
| CloudFront | $0.085 per GB (first 10TB) |
| S3 | $0.023 per GB storage |
| S3 Vectors | Pay per index + requests |
| DynamoDB | On-demand (pay per request) |
| Bedrock | Pay per token (varies by model) |

For light usage, this stays within or near AWS free tier limits.

## Local Development

For local development, use the main `stache-ai` package:

```bash
cd ../stache/backend
pip install -e ".[dev]"
uvicorn stache.api.main:app --reload
```

## License

MIT (same as main Stache AI package)
