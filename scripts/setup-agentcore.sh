#!/bin/bash
set -e

# Setup AgentCore Gateway for Stache MCP integration
# Usage: ./scripts/setup-agentcore.sh [--prefix <prefix>]
#
# This script deploys agentcore-template.yaml which creates:
#   - MCP Resource Server (Cognito scopes)
#   - MCP OAuth Client (for Claude Web)
#   - IAM Role and Lambda Permission
#   - AgentCore Gateway with Cognito JWT auth
#   - Lambda Target with tool schema
#
# Prerequisites:
#   - Main stache stack must be deployed first (./scripts/deploy.sh)
#
# Environment variables:
#   RESOURCE_PREFIX             Resource prefix (default: stache)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            set_prefix "$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--prefix <prefix>]"
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

print_header "Setting up AgentCore Gateway"

# Check prerequisites
check_aws_credentials || exit 1

# Check that main stack is deployed
if ! stack_exists "$STACK_NAME"; then
    print_error "Main stack '$STACK_NAME' not found"
    echo "Deploy the main stack first: ./scripts/deploy.sh --prefix $RESOURCE_PREFIX"
    exit 1
fi

print_success "Found main stack: $STACK_NAME"

# Deploy AgentCore CloudFormation stack
print_header "Deploying AgentCore stack"

AGENTCORE_STACK="${RESOURCE_PREFIX}-agentcore"

echo "Deploying CloudFormation stack: $AGENTCORE_STACK"

# Deploy in background and tail events
aws cloudformation deploy \
    --stack-name "$AGENTCORE_STACK" \
    --template-file "$PROJECT_DIR/agentcore-template.yaml" \
    --parameter-overrides \
        "ResourcePrefix=$RESOURCE_PREFIX" \
        "MainStackName=$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" \
    --no-fail-on-empty-changeset &

DEPLOY_PID=$!

# Give deploy a moment to start
sleep 3

# Tail stack events while deploy runs
echo ""
echo "Stack events:"
while kill -0 $DEPLOY_PID 2>/dev/null; do
    aws cloudformation describe-stack-events \
        --stack-name "$AGENTCORE_STACK" \
        --region "$AWS_REGION" \
        --query 'StackEvents[?Timestamp>=`'"$(date -u -d '30 seconds ago' '+%Y-%m-%dT%H:%M:%S')"'`].[Timestamp,LogicalResourceId,ResourceStatus]' \
        --output text 2>/dev/null | sort | while read -r line; do
            if [[ -n "$line" ]]; then
                TIMESTAMP=$(echo "$line" | cut -f1)
                RESOURCE=$(echo "$line" | cut -f2)
                STATUS=$(echo "$line" | cut -f3)
                case "$STATUS" in
                    *COMPLETE) echo -e "  \033[32m✓\033[0m $RESOURCE: $STATUS" ;;
                    *IN_PROGRESS) echo -e "  \033[33m→\033[0m $RESOURCE: $STATUS" ;;
                    *FAILED*) echo -e "  \033[31m✗\033[0m $RESOURCE: $STATUS" ;;
                    *) echo "  · $RESOURCE: $STATUS" ;;
                esac
            fi
        done
    sleep 5
done

# Wait for deploy to finish and get exit code
wait $DEPLOY_PID
DEPLOY_EXIT=$?

if [[ $DEPLOY_EXIT -ne 0 ]]; then
    print_error "Stack deployment failed"
    exit 1
fi

print_success "AgentCore stack deployed"

# Get outputs
print_header "Getting stack outputs"

GATEWAY_URL=$(get_stack_output "$AGENTCORE_STACK" "GatewayUrl")
GATEWAY_ID=$(get_stack_output "$AGENTCORE_STACK" "GatewayId")
TARGET_ID=$(get_stack_output "$AGENTCORE_STACK" "TargetId")
MCP_CLIENT_ID=$(get_stack_output "$AGENTCORE_STACK" "MCPClientId")
USER_POOL_ID=$(get_stack_output "$AGENTCORE_STACK" "UserPoolId")
USER_POOL_DOMAIN=$(get_stack_output "$AGENTCORE_STACK" "UserPoolDomain")
LAMBDA_ARN=$(get_stack_output "$AGENTCORE_STACK" "LambdaArn")

# Get MCP client secret (needed for Claude Web configuration)
MCP_CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
    --user-pool-id "$USER_POOL_ID" \
    --client-id "$MCP_CLIENT_ID" \
    --region "$AWS_REGION" \
    --query 'UserPoolClient.ClientSecret' \
    --output text 2>/dev/null || echo "")

# Summary
print_header "AgentCore Gateway Setup Complete"

echo "Gateway ID:    $GATEWAY_ID"
echo "Gateway URL:   $GATEWAY_URL"
echo "Target ID:     $TARGET_ID"
echo "Lambda ARN:    $LAMBDA_ARN"
echo ""
echo "Cognito OAuth:"
echo "  User Pool:     $USER_POOL_ID"
echo "  Domain:        $USER_POOL_DOMAIN"
echo "  MCP Client ID: $MCP_CLIENT_ID"
echo ""

# Save config
CONFIG_FILE="$PROJECT_DIR/.agentcore-config.json"
cat > "$CONFIG_FILE" <<EOF
{
  "gateway_id": "$GATEWAY_ID",
  "gateway_url": "$GATEWAY_URL",
  "target_id": "$TARGET_ID",
  "lambda_arn": "$LAMBDA_ARN",
  "cognito_user_pool_id": "$USER_POOL_ID",
  "cognito_domain": "$USER_POOL_DOMAIN",
  "mcp_client_id": "$MCP_CLIENT_ID",
  "mcp_client_secret": "$MCP_CLIENT_SECRET",
  "agentcore_stack": "$AGENTCORE_STACK",
  "region": "$AWS_REGION",
  "prefix": "$RESOURCE_PREFIX",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

print_success "Configuration saved to: $CONFIG_FILE"

# Claude Web MCP configuration
echo ""
print_header "Claude Web Configuration"
echo ""
echo "Add this MCP server in Claude Web settings (https://claude.ai/settings/mcp):"
echo ""
echo "  Name:            Stache"
echo "  URL:             $GATEWAY_URL"
echo "  Client ID:       $MCP_CLIENT_ID"
echo "  Client Secret:   $MCP_CLIENT_SECRET"
echo ""
echo "When you connect, Claude will redirect to Cognito for login."
echo "Use your Cognito username and password to authenticate."
echo ""
echo "See README.md for more details."
