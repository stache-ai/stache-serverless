#!/bin/bash
set -e

# Setup AgentCore Gateway for Stache MCP integration
# Usage: ./scripts/setup-agentcore.sh [--prefix <prefix>]
#
# This script:
#   1. Deploys IAM role for AgentCore via CloudFormation
#   2. Creates AgentCore Gateway with Cognito JWT auth
#   3. Creates Lambda target with tool schema
#
# Prerequisites:
#   - Main stache stack must be deployed first (./scripts/deploy.sh)
#   - jq must be installed
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

if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed"
    exit 1
fi

# Check that main stack is deployed
if ! stack_exists "$STACK_NAME"; then
    print_error "Main stack '$STACK_NAME' not found"
    echo "Deploy the main stack first: ./scripts/deploy.sh --prefix $RESOURCE_PREFIX"
    exit 1
fi

print_success "Found main stack: $STACK_NAME"

# Get required values from main stack
print_header "Getting configuration from main stack"

LAMBDA_ARN=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='AgentCoreFunctionArn'].OutputValue" \
    --output text 2>/dev/null || echo "")

if [[ -z "$LAMBDA_ARN" ]] || [[ "$LAMBDA_ARN" == "None" ]]; then
    # Fallback: construct the ARN
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${RESOURCE_PREFIX}-agentcore"
    print_warning "AgentCoreFunctionArn not in outputs, using: $LAMBDA_ARN"
else
    print_success "Lambda ARN: $LAMBDA_ARN"
fi

USER_POOL_ID=$(get_stack_output "$STACK_NAME" "UserPoolId")
USER_POOL_CLIENT_ID=$(get_stack_output "$STACK_NAME" "UserPoolClientId")

if [[ -z "$USER_POOL_ID" ]] || [[ "$USER_POOL_ID" == "None" ]]; then
    print_error "Could not get UserPoolId from stack"
    exit 1
fi

print_success "Cognito User Pool: $USER_POOL_ID"
print_success "Cognito Client ID: $USER_POOL_CLIENT_ID"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Step 1: Deploy IAM role via CloudFormation
print_header "Step 1: Deploying IAM role"

AGENTCORE_ROLE_STACK="${RESOURCE_PREFIX}-agentcore-role"

cat > /tmp/agentcore-role.yaml <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: AgentCore Gateway IAM Role for ${RESOURCE_PREFIX}

Parameters:
  LambdaArn:
    Type: String
    Description: ARN of the AgentCore Lambda function
  ResourcePrefix:
    Type: String
    Description: Resource prefix

Resources:
  AgentCoreGatewayRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: !Sub '\${ResourcePrefix}-agentcore-gateway-role'
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service:
                - bedrock.amazonaws.com
                - bedrock-agentcore.amazonaws.com
            Action: sts:AssumeRole
      Policies:
        - PolicyName: InvokeLambda
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - lambda:InvokeFunction
                Resource:
                  - !Ref LambdaArn

  LambdaPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !Select [6, !Split [':', !Ref LambdaArn]]
      Action: lambda:InvokeFunction
      Principal: bedrock.amazonaws.com
      SourceArn: !Sub 'arn:aws:bedrock:\${AWS::Region}:\${AWS::AccountId}:gateway/*'

Outputs:
  GatewayRoleArn:
    Description: IAM Role ARN for AgentCore Gateway
    Value: !GetAtt AgentCoreGatewayRole.Arn
EOF

echo "Deploying CloudFormation stack: $AGENTCORE_ROLE_STACK"
aws cloudformation deploy \
    --stack-name "$AGENTCORE_ROLE_STACK" \
    --template-file /tmp/agentcore-role.yaml \
    --parameter-overrides \
        "LambdaArn=$LAMBDA_ARN" \
        "ResourcePrefix=$RESOURCE_PREFIX" \
    --capabilities CAPABILITY_NAMED_IAM \
    --region "$AWS_REGION" \
    --no-fail-on-empty-changeset

rm /tmp/agentcore-role.yaml

ROLE_ARN=$(get_stack_output "$AGENTCORE_ROLE_STACK" "GatewayRoleArn")
print_success "Role ARN: $ROLE_ARN"

# Step 2: Create or update AgentCore Gateway
print_header "Step 2: Creating AgentCore Gateway"

GATEWAY_NAME="${RESOURCE_PREFIX}-mcp-gateway"
DISCOVERY_URL="https://cognito-idp.${AWS_REGION}.amazonaws.com/${USER_POOL_ID}/.well-known/openid-configuration"

# Check if gateway exists
EXISTING_GATEWAY=$(aws bedrock-agentcore-control list-gateways \
    --region "$AWS_REGION" \
    --query "items[?name=='$GATEWAY_NAME'].gatewayId" \
    --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_GATEWAY" ]] && [[ "$EXISTING_GATEWAY" != "None" ]]; then
    print_warning "Gateway '$GATEWAY_NAME' already exists: $EXISTING_GATEWAY"
    GATEWAY_ID="$EXISTING_GATEWAY"

    echo "Updating gateway..."
    aws bedrock-agentcore-control update-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --name "$GATEWAY_NAME" \
        --role-arn "$ROLE_ARN" \
        --protocol-type MCP \
        --authorizer-type CUSTOM_JWT \
        --authorizer-configuration "customJWTAuthorizer={discoveryUrl=${DISCOVERY_URL},allowedClients=[${USER_POOL_CLIENT_ID}]}" \
        --region "$AWS_REGION" > /dev/null

    print_success "Gateway updated"
else
    echo "Creating new gateway: $GATEWAY_NAME"

    GATEWAY_OUTPUT=$(aws bedrock-agentcore-control create-gateway \
        --name "$GATEWAY_NAME" \
        --description "Stache AI MCP Gateway" \
        --role-arn "$ROLE_ARN" \
        --protocol-type MCP \
        --authorizer-type CUSTOM_JWT \
        --authorizer-configuration "customJWTAuthorizer={discoveryUrl=${DISCOVERY_URL},allowedClients=[${USER_POOL_CLIENT_ID}]}" \
        --region "$AWS_REGION" 2>&1)

    GATEWAY_ID=$(echo "$GATEWAY_OUTPUT" | jq -r '.gatewayId')
    print_success "Gateway created: $GATEWAY_ID"
fi

# Wait for gateway to be ready
echo "Waiting for gateway to be ready..."
for i in {1..30}; do
    STATUS=$(aws bedrock-agentcore-control get-gateway \
        --gateway-identifier "$GATEWAY_ID" \
        --region "$AWS_REGION" \
        --query 'status' \
        --output text 2>/dev/null || echo "PENDING")

    if [[ "$STATUS" == "READY" ]]; then
        break
    elif [[ "$STATUS" == "FAILED" ]]; then
        print_error "Gateway creation failed"
        exit 1
    fi
    sleep 2
done

GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
    --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" \
    --query 'gatewayUrl' \
    --output text)

print_success "Gateway URL: $GATEWAY_URL"

# Step 3: Create or update Lambda target
print_header "Step 3: Creating Lambda target"

TARGET_NAME="${RESOURCE_PREFIX}-tools"

# Create target config with tool schema
cat > /tmp/target-config.json <<EOF
{
  "mcp": {
    "lambda": {
      "lambdaArn": "$LAMBDA_ARN",
      "toolSchema": {
        "inlinePayload": $(cat "$PROJECT_DIR/agentcore-tools.json" | jq '.tools')
      }
    }
  }
}
EOF

# Check if target exists
EXISTING_TARGET=$(aws bedrock-agentcore-control list-gateway-targets \
    --gateway-identifier "$GATEWAY_ID" \
    --region "$AWS_REGION" \
    --query "items[?name=='$TARGET_NAME'].targetId" \
    --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_TARGET" ]] && [[ "$EXISTING_TARGET" != "None" ]]; then
    print_warning "Target '$TARGET_NAME' already exists: $EXISTING_TARGET"
    TARGET_ID="$EXISTING_TARGET"

    echo "Updating target..."
    aws bedrock-agentcore-control update-gateway-target \
        --gateway-identifier "$GATEWAY_ID" \
        --target-id "$TARGET_ID" \
        --name "$TARGET_NAME" \
        --description "Stache AI MCP tools" \
        --target-configuration "file:///tmp/target-config.json" \
        --region "$AWS_REGION" > /dev/null 2>&1 || true

    print_success "Target updated"
else
    echo "Creating new target: $TARGET_NAME"

    TARGET_OUTPUT=$(aws bedrock-agentcore-control create-gateway-target \
        --gateway-identifier "$GATEWAY_ID" \
        --name "$TARGET_NAME" \
        --description "Stache AI MCP tools" \
        --target-configuration "file:///tmp/target-config.json" \
        --region "$AWS_REGION" 2>&1)

    TARGET_ID=$(echo "$TARGET_OUTPUT" | jq -r '.targetId')
    print_success "Target created: $TARGET_ID"
fi

rm /tmp/target-config.json

# Wait for target to be ready
echo "Waiting for target to be ready..."
for i in {1..30}; do
    STATUS=$(aws bedrock-agentcore-control get-gateway-target \
        --gateway-identifier "$GATEWAY_ID" \
        --target-id "$TARGET_ID" \
        --region "$AWS_REGION" \
        --query 'status' \
        --output text 2>/dev/null || echo "PENDING")

    if [[ "$STATUS" == "READY" ]]; then
        break
    elif [[ "$STATUS" == "FAILED" ]]; then
        print_error "Target creation failed"
        exit 1
    fi
    sleep 2
done

print_success "Target is ready"

# Summary
print_header "AgentCore Gateway Setup Complete"

echo "Gateway ID:    $GATEWAY_ID"
echo "Gateway URL:   $GATEWAY_URL"
echo "Target ID:     $TARGET_ID"
echo "Lambda ARN:    $LAMBDA_ARN"
echo ""
echo "Cognito:"
echo "  User Pool:   $USER_POOL_ID"
echo "  Client ID:   $USER_POOL_CLIENT_ID"
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
  "cognito_client_id": "$USER_POOL_CLIENT_ID",
  "region": "$AWS_REGION",
  "prefix": "$RESOURCE_PREFIX",
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

print_success "Configuration saved to: $CONFIG_FILE"

echo ""
echo "Next steps:"
echo "  1. Configure Claude Desktop with the gateway URL"
echo "  2. Get OAuth token from Cognito for authentication"
echo "  3. See README.md for Claude Desktop configuration"
