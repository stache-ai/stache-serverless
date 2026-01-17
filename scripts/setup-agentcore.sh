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

# Get outputs needed for tool discovery
print_header "Getting stack outputs"

GATEWAY_URL=$(get_stack_output "$AGENTCORE_STACK" "GatewayUrl")
GATEWAY_ID=$(get_stack_output "$AGENTCORE_STACK" "GatewayId")
# TargetId from CloudFormation is composite (gateway|target), extract just the target part
TARGET_ID_RAW=$(get_stack_output "$AGENTCORE_STACK" "TargetId")
TARGET_ID="${TARGET_ID_RAW##*|}"  # Extract part after pipe
OAUTH_METADATA_URL=$(get_stack_output "$AGENTCORE_STACK" "OAuthMetadataUrl")
USER_POOL_ID=$(get_stack_output "$AGENTCORE_STACK" "UserPoolId")
USER_POOL_DOMAIN=$(get_stack_output "$AGENTCORE_STACK" "UserPoolDomain")
LAMBDA_ARN=$(get_stack_output "$AGENTCORE_STACK" "LambdaArn")

# Query Lambda for available tools
print_header "Discovering available tools"

RESPONSE_FILE=$(mktemp)
# Clean up temp file on exit (append to existing trap if any)
trap "rm -f $RESPONSE_FILE" EXIT

# Invoke Lambda with _list_tools action
aws lambda invoke \
    --function-name "${RESOURCE_PREFIX}-agentcore" \
    --payload '{"action": "_list_tools"}' \
    --cli-binary-format raw-in-base64-out \
    --region "$AWS_REGION" \
    "$RESPONSE_FILE" >/dev/null

# Validate response has tools array
if ! jq -e '.tools' "$RESPONSE_FILE" >/dev/null 2>&1; then
    print_warning "Failed to get tools from Lambda - using CloudFormation-defined tools"
    cat "$RESPONSE_FILE" >&2
else
    TOOL_COUNT=$(jq '.tools | length' "$RESPONSE_FILE")
    echo "Found $TOOL_COUNT tools from Lambda"

    # Lambda returns tools in camelCase format (name, description, inputSchema)
    # AgentCore CLI only accepts: type, properties, required, items, description
    # Must strip unsupported JSON Schema properties: maxLength, minimum, maximum, default, enum
    TOOL_SCHEMA=$(jq '[.tools[] | {
        name: .name,
        description: .description,
        inputSchema: {
            type: .inputSchema.type,
            properties: (
                .inputSchema.properties // {} | to_entries | map({
                    (.key): {
                        type: .value.type,
                        description: (.value.description // "")
                    }
                }) | add // {}
            ),
            required: (.inputSchema.required // [])
        }
    }]' "$RESPONSE_FILE")

    # Update gateway target with discovered tools
    echo "Updating gateway target with dynamic tools..."

    if aws bedrock-agentcore-control update-gateway-target \
        --gateway-identifier "$GATEWAY_ID" \
        --target-id "$TARGET_ID" \
        --name "${RESOURCE_PREFIX}-tools" \
        --target-configuration "{
            \"mcp\": {
                \"lambda\": {
                    \"lambdaArn\": \"$LAMBDA_ARN\",
                    \"toolSchema\": {
                        \"inlinePayload\": $TOOL_SCHEMA
                    }
                }
            }
        }" \
        --credential-provider-configurations '[{"credentialProviderType": "GATEWAY_IAM_ROLE"}]' \
        --region "$AWS_REGION" >/dev/null 2>&1; then
        print_success "Gateway target updated with $TOOL_COUNT tools"
    else
        print_warning "Failed to update gateway target - using CloudFormation-defined tools"
    fi
fi

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
