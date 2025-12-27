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

## AgentCore Gateway (Claude MCP)

AgentCore Gateway enables Claude to access Stache via MCP (Model Context Protocol). This works with Claude Web using OAuth auto-authentication.

### Setup

```bash
# After deploying the main stack
./scripts/setup-agentcore.sh

# With custom prefix
./scripts/setup-agentcore.sh --prefix myapp
```

This deploys a separate CloudFormation stack (`{prefix}-agentcore`) containing:
1. **MCP Resource Server** - Cognito resource server with custom scopes
2. **MCP OAuth Client** - Cognito app client configured for Claude's OAuth flow
3. **IAM Role** - Allows Bedrock to invoke the Lambda function
4. **Lambda Permission** - Allows Bedrock gateway to invoke Lambda
5. **AgentCore Gateway** - MCP gateway with Cognito OAuth authentication
6. **Gateway Target** - Lambda target with tool schema

Configuration is saved to `.agentcore-config.json`.

### Claude Web Configuration

To use Stache with Claude Web:

1. Run `./scripts/setup-agentcore.sh` to get the credentials
2. Go to [Claude Settings > MCP](https://claude.ai/settings/mcp)
3. Click **Add MCP Server**
4. Enter the values shown in the setup script output:
   - **Name**: Stache (or any name you prefer)
   - **URL**: The gateway URL (e.g., `https://stache-mcp-gateway-xxxxx.gateway.bedrock-agentcore.us-east-1.amazonaws.com/mcp`)
   - **Client ID**: The MCP client ID from setup
   - **Client Secret**: The MCP client secret from setup
5. Click **Connect**
6. Claude will redirect to Cognito login - enter your username and password
7. After authentication, you're connected!

The credentials are also saved to `.agentcore-config.json` for reference.

### Available MCP Tools

| Tool | Description |
|------|-------------|
| `search` | Semantic search with reranking |
| `ingest_text` | Add text content to knowledge base |
| `list_namespaces` | List all namespaces |
| `list_documents` | List documents (with pagination) |
| `get_document` | Get document metadata by ID |
| `create_namespace` | Create a new namespace |
| `get_namespace` | Get namespace details |
| `update_namespace` | Update namespace name/description |
| `delete_namespace` | Delete a namespace |

### How OAuth Works

The AgentCore gateway is configured with:
- **CUSTOM_JWT authorizer** pointing to Cognito's OIDC discovery URL
- **MCP OAuth client** with `https://claude.ai/api/mcp/auth_callback` as the callback URL
- **Custom scopes**: `{prefix}-mcp/read` and `{prefix}-mcp/write`

When you connect Claude to the gateway:
1. Claude uses the client ID and secret you provided to initiate OAuth
2. You're redirected to Cognito's hosted UI for login
3. After login, Cognito redirects back to Claude with an authorization code
4. Claude exchanges the code for access tokens
5. Tokens are used for all subsequent MCP requests

### Troubleshooting

**"Invalid redirect_uri" error**

The Cognito MCP client must have `https://claude.ai/api/mcp/auth_callback` in its callback URLs. This is configured automatically by the agentcore template. If you're getting this error, redeploy the agentcore stack:

```bash
./scripts/setup-agentcore.sh
```

**"Access denied" after login**

Ensure your Cognito user exists and the password is correct. Create a user if needed:

```bash
./scripts/create-user.sh user@example.com
```

**Gateway not responding**

Check the gateway status:

```bash
aws bedrock-agentcore-control get-gateway \
  --gateway-identifier $(jq -r .gateway_id .agentcore-config.json) \
  --query 'status'
```

## What Gets Created

Resources are named with the prefix (default: `stache`):

| Resource | Name Pattern |
|----------|--------------|
| CloudFormation Stack (main) | `{prefix}-serverless` |
| CloudFormation Stack (agentcore) | `{prefix}-agentcore` |
| Lambda Functions | `{prefix}-api`, `{prefix}-agentcore` |
| S3 Buckets | `{prefix}-vectors-{account}`, `{prefix}-frontend-{account}` |
| DynamoDB Tables | `{prefix}-namespaces`, `{prefix}-documents` |
| CloudFront Distribution | Auto-generated or custom domain |
| Cognito User Pool | `{prefix}-serverless-users` |
| Cognito MCP Client | `{prefix}-mcp-client` |
| SQS Dead Letter Queue | `{prefix}-lambda-dlq` |
| AgentCore Gateway | `{prefix}-mcp-gateway` |

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
