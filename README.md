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

# Skip backend deployment (frontend only)
./scripts/deploy.sh --skip-backend

# Skip Lambda layer build (use existing)
./scripts/deploy.sh --skip-layer

# Just redeploy SAM (skip layer, sam build, and frontend)
./scripts/deploy.sh -s
# or
./scripts/deploy.sh --sam-only

# Build from local source instead of PyPI
./scripts/deploy.sh --from-source
./scripts/deploy.sh --from-source /path/to/stache
```

Environment variables:
- `RESOURCE_PREFIX` - Same as `--prefix` (default: `stache`)
- `STACHE_FROM_SOURCE` - Path to stache-ai repo for source builds (or `true` for `../stache`)
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
| `AWS_ACCESS_KEY_ID` | IAM access key (not needed if using OIDC) |
| `AWS_SECRET_ACCESS_KEY` | IAM secret key (not needed if using OIDC) |
| `AWS_ACCOUNT_ID` | AWS account ID (required only for OIDC authentication) |
| `STACHE_REPO_TOKEN` | GitHub token with access to stache-ai/stache-ai (if private) |

#### OIDC Authentication (Recommended)

All workflows support OIDC authentication as an alternative to access keys. To use OIDC:

1. Deploy `github-oidc.yaml` to create the OIDC provider and IAM role
2. Set the `AWS_ACCOUNT_ID` secret
3. Enable `use_oidc: true` when running workflows

See [github-oidc.yaml](github-oidc.yaml) for the CloudFormation template.

#### Available Workflows

**Deploy Stache** (`deploy.yml`)
- Combined workflow for all deployment actions
- Action options:
  - `full` (default) - Deploy main stack + AgentCore + create user (if email provided)
  - `stack-only` - Deploy main stack and frontend only
  - `agentcore-only` - Deploy AgentCore gateway only (requires main stack)
  - `user-only` - Create Cognito user only (requires main stack)
  - `delete` - Delete both stacks (AgentCore first, then main)
- Inputs:
  - `action` - What to deploy (full, stack-only, agentcore-only, user-only, delete)
  - `resource_prefix` - Resource prefix (default: stache)
  - `app_domain` - Custom domain (optional)
  - `certificate_arn` - ACM certificate ARN (auto-detected from domain)
  - `use_oidc` - Use OIDC instead of access keys
  - `frontend_source` - "latest" (default), version (e.g., "0.1.0"), or "build" for source
  - `frontend_package` - npm package name (default: @stache-ai/frontend)
  - `user_email` - Email for new Cognito user (optional, used with `full` or `user-only`)

**Setup Custom Domain** (`setup-custom-domain.yml`)
- Creates ACM certificate and outputs DNS validation records
- Must be run separately before deploy (requires DNS validation wait)
- Inputs: `resource_prefix`, `domain`, `use_oidc`

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

Or use the **Deploy Stache** GitHub workflow with `action: user-only`.

## stache-tools CLI & MCP

The `stache-tools` package provides a CLI and MCP server for accessing Stache from the command line or Claude Desktop.

### Installation

```bash
# HTTP transport only
pip install stache-tools

# With Lambda transport support (recommended)
pip install stache-tools[lambda]
```

### Transport Options

stache-tools supports two transport modes:

| Transport | Authentication | Best For |
|-----------|----------------|----------|
| **Lambda** (recommended) | AWS IAM | CLI, Claude Desktop MCP, local development |
| **HTTP** | OAuth (Cognito) | Web apps, multi-tenant scenarios |

### Lambda Transport (Recommended)

Uses direct Lambda invocation with your AWS credentials. No OAuth setup needed.

```bash
# Set environment variables
export STACHE_LAMBDA_FUNCTION=stache-api
export AWS_REGION=us-east-1

# Test the connection
stache health

# Search
stache search "your query"
```

**Required IAM Permission:**
```json
{
    "Effect": "Allow",
    "Action": "lambda:InvokeFunction",
    "Resource": "arn:aws:lambda:us-east-1:ACCOUNT:function:stache-api"
}
```

### HTTP Transport (OAuth)

Uses API Gateway with Cognito OAuth. The deploy script outputs the credentials:

```bash
# Set environment variables (shown in deploy.sh output)
export STACHE_API_URL=https://xxx.execute-api.us-east-1.amazonaws.com/Prod/
export STACHE_COGNITO_CLIENT_ID=abc123...
export STACHE_COGNITO_CLIENT_SECRET=xyz789...
export STACHE_COGNITO_TOKEN_URL=https://xxx.auth.us-east-1.amazoncognito.com/oauth2/token
export STACHE_COGNITO_SCOPE="stache-serverless-api/read stache-serverless-api/write"

# Test the connection
stache health
```

### Claude Desktop MCP (Lambda)

Add to `~/.config/claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "stache": {
      "command": "stache-mcp",
      "env": {
        "STACHE_LAMBDA_FUNCTION": "stache-api",
        "AWS_REGION": "us-east-1"
      }
    }
  }
}
```

#### Using a Wrapper Script (Recommended)

Instead of inline env vars, use a wrapper script for cleaner configuration and venv support:

1. Create `~/.stache.env`:
   ```bash
   STACHE_LAMBDA_FUNCTION=stache-api
   AWS_REGION=us-east-1
   # Optional: AWS_PROFILE=my-profile
   ```

2. Create `~/.local/bin/stache-mcp-wrapper`:
   ```bash
   #!/bin/bash
   source ~/.stache.env

   # Optional: activate venv if stache-tools is installed there
   # source ~/venvs/stache/bin/activate

   exec stache-mcp "$@"
   ```

3. Make it executable:
   ```bash
   chmod +x ~/.local/bin/stache-mcp-wrapper
   ```

4. Update Claude config:
   ```json
   {
     "mcpServers": {
       "stache": {
         "command": "/home/user/.local/bin/stache-mcp-wrapper"
       }
     }
   }
   ```

This approach lets you manage configuration separately and supports virtual environments.

### Deployment Output

After running `./scripts/deploy.sh`, the complete stache-tools configuration is shown:

```
=== stache-tools Configuration ===

Option 1: Lambda Transport (Recommended)
  export STACHE_LAMBDA_FUNCTION=stache-api
  export AWS_REGION=us-east-1

Option 2: HTTP Transport (OAuth)
  export STACHE_API_URL=https://...
  export STACHE_COGNITO_CLIENT_ID=...
  ...
```

---

## AgentCore Gateway (Claude Web MCP)

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
| `delete_document` | Delete a document and its chunks |
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
| `RERANKER_PROVIDER` | simple | Reranking provider |
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
