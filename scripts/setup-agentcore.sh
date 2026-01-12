#!/bin/bash
set -e

# Setup AgentCore Gateway for Stache MCP integration
# Usage: ./scripts/setup-agentcore.sh [--prefix <prefix>]
#
# This script deploys agentcore-template.yaml which creates:
#   - MCP Resource Server (Cognito scopes)
#   - MCP OAuth Client (for Claude Web)
#   - OAuth metadata API (for MCP discovery)
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

# Portable date function (GNU vs BSD/macOS)
get_date_30s_ago() {
    if date --version >/dev/null 2>&1; then
        # GNU date
        date -u -d '30 seconds ago' '+%Y-%m-%dT%H:%M:%S'
    else
        # BSD date (macOS)
        date -u -v-30S '+%Y-%m-%dT%H:%M:%S'
    fi
}

while kill -0 $DEPLOY_PID 2>/dev/null; do
    aws cloudformation describe-stack-events \
        --stack-name "$AGENTCORE_STACK" \
        --region "$AWS_REGION" \
        --query 'StackEvents[?Timestamp>=`'"$(get_date_30s_ago)"'`].[Timestamp,LogicalResourceId,ResourceStatus]' \
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
OAUTH_METADATA_URL=$(get_stack_output "$AGENTCORE_STACK" "OAuthMetadataUrl")
USER_POOL_ID=$(get_stack_output "$AGENTCORE_STACK" "UserPoolId")
USER_POOL_DOMAIN=$(get_stack_output "$AGENTCORE_STACK" "UserPoolDomain")
LAMBDA_ARN=$(get_stack_output "$AGENTCORE_STACK" "LambdaArn")

# Summary
print_header "AgentCore Gateway Setup Complete"

echo "Gateway ID:       $GATEWAY_ID"
echo "Gateway URL:      $GATEWAY_URL"
echo "OAuth Metadata:   $OAUTH_METADATA_URL"
echo "Target ID:        $TARGET_ID"
echo "Lambda ARN:       $LAMBDA_ARN"
echo ""

# Save config using jq for safe JSON generation
CONFIG_FILE="$PROJECT_DIR/.agentcore-config.json"
jq -n \
    --arg gateway_id "$GATEWAY_ID" \
    --arg gateway_url "$GATEWAY_URL" \
    --arg oauth_metadata_url "$OAUTH_METADATA_URL" \
    --arg target_id "$TARGET_ID" \
    --arg lambda_arn "$LAMBDA_ARN" \
    --arg cognito_user_pool_id "$USER_POOL_ID" \
    --arg cognito_domain "$USER_POOL_DOMAIN" \
    --arg agentcore_stack "$AGENTCORE_STACK" \
    --arg region "$AWS_REGION" \
    --arg prefix "$RESOURCE_PREFIX" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      gateway_id: $gateway_id,
      gateway_url: $gateway_url,
      oauth_metadata_url: $oauth_metadata_url,
      target_id: $target_id,
      lambda_arn: $lambda_arn,
      cognito_user_pool_id: $cognito_user_pool_id,
      cognito_domain: $cognito_domain,
      agentcore_stack: $agentcore_stack,
      region: $region,
      prefix: $prefix,
      created_at: $created_at
    }' > "$CONFIG_FILE"

chmod 600 "$CONFIG_FILE"
print_success "Configuration saved to: $CONFIG_FILE"

# Claude configuration (simplified with DCR)
echo ""
print_header "Connect Claude to Stache"
echo ""
echo "MCP URL: $GATEWAY_URL"
echo ""
echo "Claude Web:"
echo "  1. Go to https://claude.ai/settings/mcp"
echo "  2. Add MCP Server"
echo "  3. Enter URL: $GATEWAY_URL"
echo "  4. Click Connect - login when prompted"
echo ""
echo "Claude Code:"
echo "  claude mcp add --transport http stache $GATEWAY_URL"
echo "  Then run /mcp and click Authenticate"
echo ""
echo "OAuth clients are created automatically via Dynamic Client Registration."
echo "No client ID or secret needed!"
