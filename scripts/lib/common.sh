#!/bin/bash
# Common functions and configuration for stache-serverless scripts
# Source this file: source "$(dirname "$0")/lib/common.sh"

# Colors (disabled if not a terminal or if NO_COLOR is set)
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}! $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

# Default configuration
AWS_REGION="${AWS_REGION:-us-east-1}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-stache}"

# Derive stack names from prefix
derive_stack_names() {
    STACK_NAME="${STACK_NAME:-${RESOURCE_PREFIX}-serverless}"
    CERT_STACK_NAME="${CERT_STACK_NAME:-${RESOURCE_PREFIX}-certificate}"
}

# Update prefix and re-derive stack names
set_prefix() {
    RESOURCE_PREFIX="$1"
    derive_stack_names
}

# Initialize with current prefix
derive_stack_names

# Check AWS credentials
check_aws_credentials() {
    if ! aws sts get-caller-identity &>/dev/null; then
        print_error "AWS credentials not configured"
        return 1
    fi
    print_success "AWS credentials configured"
}

# Get CloudFormation stack output
get_stack_output() {
    local stack_name="$1"
    local output_key="$2"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Outputs[?OutputKey==\`$output_key\`].OutputValue" \
        --output text 2>/dev/null || echo ""
}

# Get CloudFormation stack parameter
get_stack_parameter() {
    local stack_name="$1"
    local param_key="$2"
    aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$AWS_REGION" \
        --query "Stacks[0].Parameters[?ParameterKey==\`$param_key\`].ParameterValue" \
        --output text 2>/dev/null || echo ""
}

# Check if stack exists
stack_exists() {
    local stack_name="$1"
    aws cloudformation describe-stacks --stack-name "$stack_name" --region "$AWS_REGION" &>/dev/null
}

# Get certificate status
get_certificate_status() {
    local cert_arn="$1"
    aws acm describe-certificate \
        --certificate-arn "$cert_arn" \
        --region "$AWS_REGION" \
        --query 'Certificate.Status' \
        --output text 2>/dev/null || echo ""
}

# Find certificate by domain name and verify it's validated
# Sets CERT_ARN variable if certificate is valid
# Returns 0 if valid, 1 if not found or not validated
find_certificate_for_domain() {
    local domain="$1"
    echo "Looking for certificate for domain: $domain"

    # List all certificates and find one matching the domain
    local cert_arn=$(aws acm list-certificates \
        --region "$AWS_REGION" \
        --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn | [0]" \
        --output text 2>/dev/null || echo "")

    if [[ -z "$cert_arn" ]] || [[ "$cert_arn" == "None" ]]; then
        print_error "No certificate found for domain: $domain"
        echo "Create one with: ./scripts/setup-custom-domain.sh $domain"
        return 1
    fi

    # Check certificate status
    local cert_status=$(get_certificate_status "$cert_arn")

    if [[ "$cert_status" == "ISSUED" ]]; then
        CERT_ARN="$cert_arn"
        print_success "Found validated certificate for: $domain"
        return 0
    else
        print_error "Certificate for $domain is not validated (status: $cert_status)"
        echo "Check status with: ./scripts/check-certificate.sh"
        return 1
    fi
}

# Get existing domain config from main stack
get_existing_domain_config() {
    if stack_exists "$STACK_NAME"; then
        local existing_domain=$(get_stack_parameter "$STACK_NAME" "AppDomain")
        local existing_cert=$(get_stack_parameter "$STACK_NAME" "CertificateArn")

        if [[ -n "$existing_domain" ]] && [[ "$existing_domain" != "None" ]]; then
            DOMAIN="${DOMAIN:-$existing_domain}"
        fi
        if [[ -n "$existing_cert" ]] && [[ "$existing_cert" != "None" ]]; then
            CERT_ARN="${CERT_ARN:-$existing_cert}"
        fi
    fi
}

# Build SAM parameter string
build_sam_params() {
    local params="ResourcePrefix=$RESOURCE_PREFIX"

    if [[ -n "${DOMAIN:-}" ]] && [[ "$DOMAIN" != "None" ]]; then
        params="$params AppDomain=$DOMAIN"
    fi
    if [[ -n "${CERT_ARN:-}" ]] && [[ "$CERT_ARN" != "None" ]]; then
        params="$params CertificateArn=$CERT_ARN"
    fi

    echo "$params"
}

# Deploy SAM stack
deploy_sam_stack() {
    local params=$(build_sam_params)

    print_header "Deploying to AWS"
    sam deploy \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --capabilities CAPABILITY_IAM \
        --no-confirm-changeset \
        --no-fail-on-empty-changeset \
        --resolve-s3 \
        --parameter-overrides $params

    print_success "Stack deployed"
}

# Get Cognito client secret (not available via CloudFormation output)
get_cognito_client_secret() {
    local user_pool_id="$1"
    local client_id="$2"
    aws cognito-idp describe-user-pool-client \
        --user-pool-id "$user_pool_id" \
        --client-id "$client_id" \
        --region "$AWS_REGION" \
        --query 'UserPoolClient.ClientSecret' \
        --output text 2>/dev/null || echo ""
}

# Get all stack outputs needed for frontend and stache-tools
get_frontend_config() {
    USER_POOL_ID=$(get_stack_output "$STACK_NAME" "UserPoolId")
    USER_POOL_CLIENT_ID=$(get_stack_output "$STACK_NAME" "UserPoolClientId")
    COGNITO_DOMAIN=$(get_stack_output "$STACK_NAME" "UserPoolDomain")
    API_URL=$(get_stack_output "$STACK_NAME" "ApiUrl")
    FRONTEND_BUCKET=$(get_stack_output "$STACK_NAME" "FrontendBucketName")
    CLOUDFRONT_ID=$(get_stack_output "$STACK_NAME" "CloudFrontDistributionId")
    FRONTEND_URL=$(get_stack_output "$STACK_NAME" "FrontendUrl")

    # stache-tools outputs
    STACHE_TOOLS_CLIENT_ID=$(get_stack_output "$STACK_NAME" "StacheToolsClientId")
    STACHE_TOOLS_TOKEN_URL=$(get_stack_output "$STACK_NAME" "StacheToolsTokenUrl")
    STACHE_TOOLS_SCOPES=$(get_stack_output "$STACK_NAME" "StacheToolsScopes")
    API_FUNCTION_NAME=$(get_stack_output "$STACK_NAME" "ApiFunctionName")

    # Get client secret from Cognito (not available via CloudFormation)
    if [[ -n "$USER_POOL_ID" ]] && [[ -n "$STACHE_TOOLS_CLIENT_ID" ]]; then
        STACHE_TOOLS_CLIENT_SECRET=$(get_cognito_client_secret "$USER_POOL_ID" "$STACHE_TOOLS_CLIENT_ID")
    fi

    # Get CloudFront domain name for custom domain CNAME setup
    if [[ -n "$CLOUDFRONT_ID" ]]; then
        CLOUDFRONT_DOMAIN=$(aws cloudfront get-distribution \
            --id "$CLOUDFRONT_ID" \
            --query 'Distribution.DomainName' \
            --output text 2>/dev/null || echo "")
    fi
}

# Deploy frontend to S3 and invalidate CloudFront
deploy_frontend() {
    local frontend_dir="$1"

    print_header "Deploying frontend to S3"

    # Generate runtime config.json for pre-built packages using jq for safe JSON escaping
    # This allows npm packages to work with any deployment
    jq -n \
        --arg auth "cognito" \
        --arg pool_id "$USER_POOL_ID" \
        --arg client_id "$USER_POOL_CLIENT_ID" \
        --arg domain "$COGNITO_DOMAIN" \
        --arg api_url "$API_URL" \
        '{
          AUTH_PROVIDER: $auth,
          COGNITO_USER_POOL_ID: $pool_id,
          COGNITO_CLIENT_ID: $client_id,
          COGNITO_DOMAIN: $domain,
          API_URL: $api_url
        }' > "$frontend_dir/config.json"
    print_success "Generated runtime config.json"

    # Sync with cache headers
    aws s3 sync "$frontend_dir" "s3://$FRONTEND_BUCKET/" \
        --delete \
        --cache-control "max-age=31536000,public" \
        --exclude "index.html" \
        --exclude "*.json"

    # Upload index.html with no-cache
    aws s3 cp "$frontend_dir/index.html" "s3://$FRONTEND_BUCKET/index.html" \
        --cache-control "no-cache,no-store,must-revalidate"

    # Upload config.json with no-cache (runtime configuration)
    aws s3 cp "$frontend_dir/config.json" "s3://$FRONTEND_BUCKET/config.json" \
        --cache-control "no-cache,no-store,must-revalidate"

    # Upload any other JSON files with no-cache
    find "$frontend_dir" -name "*.json" ! -name "config.json" -exec aws s3 cp {} "s3://$FRONTEND_BUCKET/" \
        --cache-control "no-cache,no-store,must-revalidate" \;

    print_success "Frontend deployed to S3"

    print_header "Invalidating CloudFront cache"
    aws cloudfront create-invalidation \
        --distribution-id "$CLOUDFRONT_ID" \
        --paths "/*" \
        --output text > /dev/null

    print_success "CloudFront cache invalidated"
}

# Generate .env file for local development
generate_local_env() {
    local output_file="$1"
    local role_arn=$(get_stack_output "$STACK_NAME" "ApiFunctionRoleArn")
    local index_arn=$(get_stack_output "$STACK_NAME" "S3VectorsIndexArn")

    cat > "$output_file" << EOF
# Stache Local Development Environment
# Generated from stack: $STACK_NAME
# Region: $AWS_REGION
# Generated: $(date -Iseconds)

# =============================================================================
# AWS CREDENTIALS
# =============================================================================
# Option 1: Assume the Lambda's IAM role (has all required permissions)
#   aws sts assume-role --role-arn "$role_arn" --role-session-name local-dev
#
# Option 2: Use your own IAM user/role with equivalent permissions
#   Required: s3vectors:*, dynamodb:* on stache tables, bedrock:InvokeModel
# =============================================================================

# AWS Provider Configuration
VECTORDB_PROVIDER=s3vectors
NAMESPACE_PROVIDER=dynamodb
LLM_PROVIDER=bedrock
EMBEDDING_PROVIDER=bedrock
ENABLE_DOCUMENT_INDEX=true

# AWS Region
AWS_REGION=$AWS_REGION

# S3 Vectors Index
S3VECTORS_INDEX_ARN=$index_arn

# DynamoDB Tables
DYNAMODB_TABLE_NAME=${RESOURCE_PREFIX}-namespaces
DYNAMODB_DOCUMENT_INDEX_TABLE=${RESOURCE_PREFIX}-documents

# Lambda IAM Role (for assuming)
STACHE_LAMBDA_ROLE_ARN=$role_arn

# =============================================================================
# STACHE-TOOLS / MCP CONFIGURATION
# =============================================================================

# API URL (if using HTTP transport)
STACHE_API_URL=$API_URL

# Lambda Function (if using Lambda transport - recommended)
STACHE_LAMBDA_FUNCTION=$API_FUNCTION_NAME

# Cognito OAuth (for HTTP transport)
STACHE_COGNITO_CLIENT_ID=$STACHE_TOOLS_CLIENT_ID
STACHE_COGNITO_CLIENT_SECRET=$STACHE_TOOLS_CLIENT_SECRET
STACHE_COGNITO_TOKEN_URL=$STACHE_TOOLS_TOKEN_URL
STACHE_COGNITO_SCOPE=$STACHE_TOOLS_SCOPES
EOF

    print_success "Local environment file written to: $output_file"
    echo ""
    echo "Usage:"
    echo "  source $output_file                    # Load into shell"
    echo "  # Or use python-dotenv in your code"
    echo ""
    echo "To assume the Lambda role for local dev:"
    echo "  eval \$(aws sts assume-role --role-arn \"$role_arn\" \\"
    echo "    --role-session-name local-dev --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \\"
    echo "    --output text | awk '{print \"export AWS_ACCESS_KEY_ID=\"\$1\" AWS_SECRET_ACCESS_KEY=\"\$2\" AWS_SESSION_TOKEN=\"\$3}')"
}

# Print deployment summary
print_deploy_summary() {
    print_header "Deployment Complete"

    echo -e "${GREEN}Your App:${NC} $FRONTEND_URL"
    echo ""

    # Show custom domain setup instructions if domain is configured
    if [[ -n "${DOMAIN:-}" ]] && [[ "$DOMAIN" != "None" ]] && [[ -n "${CLOUDFRONT_DOMAIN:-}" ]]; then
        echo -e "${YELLOW}Custom Domain Setup:${NC}"
        echo "  Add this CNAME record to your DNS:"
        echo ""
        echo "    Type:  CNAME"
        echo "    Name:  $DOMAIN"
        echo "    Value: $CLOUDFRONT_DOMAIN"
        echo ""
    fi

    echo "Stack Details:"
    echo "  Prefix:         $RESOURCE_PREFIX"
    echo "  Stack Name:     $STACK_NAME"
    echo "  Region:         $AWS_REGION"
    echo "  API Gateway:    $API_URL"
    echo "  CloudFront ID:  $CLOUDFRONT_ID"
    if [[ -n "${CLOUDFRONT_DOMAIN:-}" ]]; then
        echo "  CloudFront:     $CLOUDFRONT_DOMAIN"
    fi
    echo "  S3 Bucket:      $FRONTEND_BUCKET"
    echo "  User Pool ID:   $USER_POOL_ID"

    # stache-tools configuration
    if [[ -n "${API_FUNCTION_NAME:-}" ]]; then
        echo ""
        print_header "stache-tools Configuration"

        echo -e "${GREEN}Option 1: Lambda Transport (Recommended)${NC}"
        echo "  Uses AWS credentials directly - no OAuth setup needed."
        echo ""
        echo "  Environment variables:"
        echo "    export STACHE_LAMBDA_FUNCTION=$API_FUNCTION_NAME"
        echo "    export AWS_REGION=$AWS_REGION"
        echo ""
        echo "  Or for Claude Desktop MCP (~/.config/claude/claude_desktop_config.json):"
        echo '    {'
        echo '      "mcpServers": {'
        echo '        "stache": {'
        echo '          "command": "stache-mcp",'
        echo '          "env": {'
        echo "            \"STACHE_LAMBDA_FUNCTION\": \"$API_FUNCTION_NAME\","
        echo "            \"AWS_REGION\": \"$AWS_REGION\""
        echo '          }'
        echo '        }'
        echo '      }'
        echo '    }'
        echo ""

        if [[ -n "${STACHE_TOOLS_CLIENT_ID:-}" ]] && [[ -n "${STACHE_TOOLS_CLIENT_SECRET:-}" ]]; then
            echo -e "${YELLOW}Option 2: HTTP Transport (OAuth)${NC}"
            echo "  Uses API Gateway with OAuth authentication."
            echo ""
            echo "  Environment variables:"
            echo "    export STACHE_API_URL=$API_URL"
            echo "    export STACHE_COGNITO_CLIENT_ID=$STACHE_TOOLS_CLIENT_ID"
            echo "    export STACHE_COGNITO_CLIENT_SECRET=$STACHE_TOOLS_CLIENT_SECRET"
            echo "    export STACHE_COGNITO_TOKEN_URL=$STACHE_TOOLS_TOKEN_URL"
            echo "    export STACHE_COGNITO_SCOPE=\"$STACHE_TOOLS_SCOPES\""
            echo ""
        fi

        echo "  Install stache-tools:"
        echo "    pip install stache-tools          # HTTP transport only"
        echo "    pip install stache-tools[lambda]  # Lambda transport support"
    fi
}
