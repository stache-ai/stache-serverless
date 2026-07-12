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

# Does the main stack ($STACK_NAME) exist? Cached: the sticky-parameter
# resolution below asks once per parameter and there is no point re-describing
# the stack each time.
_MAIN_STACK_EXISTS_CHECKED=""
_MAIN_STACK_EXISTS_RESULT=1

main_stack_exists() {
    if [[ -z "$_MAIN_STACK_EXISTS_CHECKED" ]]; then
        _MAIN_STACK_EXISTS_CHECKED=1
        if stack_exists "$STACK_NAME"; then
            _MAIN_STACK_EXISTS_RESULT=0
        else
            _MAIN_STACK_EXISTS_RESULT=1
        fi
    fi
    return "$_MAIN_STACK_EXISTS_RESULT"
}

# Resolve a STICKY stack parameter, writing the resolved value to stdout (empty
# if nothing resolves, meaning: pass nothing and let the template default win).
#
# Why this exists: `sam deploy` resolves every parameter it is NOT explicitly
# given to the TEMPLATE DEFAULT -- NOT to the value currently deployed on the
# stack. So a routine redeploy that merely omits a flag silently reverts that
# parameter to its default, and CloudFormation then applies that as a real
# change (it has already cost us a silently deleted DynamoDB GSI in a sibling
# stack). For the parameters below the failure is worse than a crash: reverting
# BedrockEmbeddingModel from cohere.embed-v4:0 to the v3 default against an index
# populated with v4 vectors returns meaningless search results with no error,
# because the two models embed into different vector spaces.
#
# Precedence:
#   1. operator intent -- env var / CLI flag, if provided
#   2. the value currently deployed on the stack
#   3. the template default (fresh stack, or parameter not yet on the stack)
resolve_sticky_param() {
    local param_key="$1"
    local override="${2:-}"

    if [[ -n "$override" ]]; then
        echo "$override"
        return 0
    fi

    # No stack yet: nothing to preserve, let the template default apply.
    main_stack_exists || return 0

    # Declare and assign separately so the assignment's exit status is not
    # masked by `local`'s own success.
    local deployed
    deployed=$(get_stack_parameter "$STACK_NAME" "$param_key")

    # Empty/None also covers a parameter that the deployed stack predates.
    if [[ -n "$deployed" ]] && [[ "$deployed" != "None" ]]; then
        echo "$deployed"
    fi
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

# Refuse a PyPI layer build underneath a deployed extension stack.
#
# This layer is what installs stache-ai, and by default it installs it from
# PyPI. An extension stack ships its own layer of providers on top of this one,
# and those providers are built against the LOCAL stache-ai -- they import seams
# that the published release may not have yet. Install this layer from PyPI
# under an extension layer built against a newer local stache-ai and the result
# is a deployment that is broken but LOOKS FINE:
#
#   the extension's provider imports a seam the published stache-ai lacks
#     -> ImportError
#     -> provider discovery skips it (deliberately: a provider with an
#        uninstalled optional dependency must not break the ones next to it)
#     -> the provider is simply absent from the registry
#     -> the functions come up healthy, on the built-in providers, and every
#        extension the layer was carrying is silently not running
#
# That shipped once. Nothing errored; only an end-to-end test caught it. So:
# when an extension stack exists, this build must come from source.
#
# STACHE_ALLOW_PYPI_WITH_EXTENSION=1 overrides, for the day the published
# version genuinely matches the seams the extension packages were built against.
#
# Args: $1 = FROM_SOURCE (empty when building from PyPI)
require_source_build_with_extension() {
    local from_source="$1"

    [[ -n "$from_source" ]] && return 0

    if [[ "${STACHE_ALLOW_PYPI_WITH_EXTENSION:-}" == "1" ]]; then
        print_warning "STACHE_ALLOW_PYPI_WITH_EXTENSION=1: building this layer from PyPI"
        echo "  even though an extension stack is deployed. The published stache-ai must" >&2
        echo "  actually provide every seam the extension layer's packages import, or the" >&2
        echo "  extension's providers will fail to import and be silently skipped." >&2
        return 0
    fi

    local extension_stack="${RESOURCE_PREFIX}-enterprise"
    stack_exists "$extension_stack" || return 0

    print_error "Refusing to build this layer from PyPI: an extension stack is deployed."
    echo "  Stack '$extension_stack' exists, so the core functions run with its" >&2
    echo "  extension layer attached. That layer's providers are built against the" >&2
    echo "  LOCAL stache-ai and may import seams the PUBLISHED stache-ai does not have" >&2
    echo "  yet." >&2
    echo "" >&2
    echo "  If they do, nothing errors. The import fails, provider discovery skips the" >&2
    echo "  provider, it vanishes from the registry, and the functions come up healthy" >&2
    echo "  on the built-in providers -- with every extension the layer was carrying" >&2
    echo "  silently not running. This has happened. Only an e2e test found it." >&2
    echo "" >&2
    echo "  Build the layer from local source instead:" >&2
    echo "      $0 --from-source" >&2
    echo "" >&2
    echo "  Once the published stache-ai genuinely matches the seams the extension" >&2
    echo "  packages import, you can allow the PyPI build explicitly:" >&2
    echo "      STACHE_ALLOW_PYPI_WITH_EXTENSION=1 $0" >&2
    return 1
}

# Build SAM parameter string
# Writes the parameter string to stdout; all human-facing output goes to stderr
# because callers capture stdout via $(...).
# Returns non-zero if the enterprise stack exists but only exposes a layer that
# cannot safely be attached to the core functions (see below).
build_sam_params() {
    # ResourcePrefix names nearly every resource in the stack, and for the ones
    # with a physical name (DynamoDB TableName, the S3 Vectors bucket) a changed
    # name is a REPLACEMENT, not a rename: CloudFormation builds new, empty
    # resources and abandons the old ones. So a deploy that quietly picks a
    # different prefix than the one already deployed silently strands the data.
    #
    # The stack name is fixed, so there is exactly one core stack per account and
    # a prefix change on it is never what anyone meant -- it is a forgotten
    # --prefix. Refuse rather than guess. (Unlike the sticky params below we do
    # NOT silently adopt the deployed value: the operator asked for a specific
    # prefix, and quietly ignoring that is its own surprise.)
    local deployed_prefix
    deployed_prefix=$(get_stack_parameter "$STACK_NAME" "ResourcePrefix" 2>/dev/null) || true
    if [[ -n "$deployed_prefix" && "$deployed_prefix" != "None" \
          && "$deployed_prefix" != "$RESOURCE_PREFIX" ]]; then
        print_error "Refusing to deploy: resource prefix mismatch." >&2
        echo "  Stack '$STACK_NAME' is deployed with ResourcePrefix=$deployed_prefix" >&2
        echo "  but this run resolved ResourcePrefix=$RESOURCE_PREFIX." >&2
        echo "" >&2
        echo "  Deploying would RENAME the stack's resources. For anything with a" >&2
        echo "  physical name (the DynamoDB tables, the S3 Vectors bucket) a rename" >&2
        echo "  is a REPLACEMENT: CloudFormation would create new, empty resources" >&2
        echo "  and abandon the ones holding your data." >&2
        echo "" >&2
        echo "  You almost certainly just omitted --prefix. Re-run with:" >&2
        echo "      $0 --prefix $deployed_prefix <other args>" >&2
        return 1
    fi

    local params="ResourcePrefix=$RESOURCE_PREFIX"

    if [[ -n "${DOMAIN:-}" ]] && [[ "$DOMAIN" != "None" ]]; then
        params="$params AppDomain=$DOMAIN"
    fi
    if [[ -n "${CERT_ARN:-}" ]] && [[ "$CERT_ARN" != "None" ]]; then
        params="$params CertificateArn=$CERT_ARN"
    fi

    # Provider names and the embedding model are parameterized rather than
    # hardcoded in the template: CloudFormation rewrites the whole Lambda
    # environment on every deploy, so anything applied out-of-band is otherwise
    # silently reverted to the template default.
    #
    # These are STICKY: the env var wins if set, otherwise we re-send whatever is
    # already deployed on the stack, so a plain `./scripts/deploy.sh` with no env
    # vars cannot quietly reset them. See resolve_sticky_param for the full why.
    # (AppDomain/CertificateArn above are already made sticky by
    # get_existing_domain_config, which seeds DOMAIN/CERT_ARN from the stack.)
    local llm_provider embedding_provider embedding_model admin_password_auth
    local vectordb_provider namespace_provider document_index_provider
    local ingest_jobstore_provider ingest_blob_provider

    llm_provider=$(resolve_sticky_param "LlmProvider" "${STACHE_LLM_PROVIDER:-}")
    if [[ -n "$llm_provider" ]]; then
        params="$params LlmProvider=$llm_provider"
        print_success "LLM provider: $llm_provider" >&2
    fi

    embedding_provider=$(resolve_sticky_param "EmbeddingProvider" "${STACHE_EMBEDDING_PROVIDER:-}")
    if [[ -n "$embedding_provider" ]]; then
        params="$params EmbeddingProvider=$embedding_provider"
        print_success "Embedding provider: $embedding_provider" >&2
    fi

    # The storage-side provider names. Same story as the two above: an extension
    # layer may register its own implementations under different names, and those
    # names have to survive a plain redeploy of this stack.
    vectordb_provider=$(resolve_sticky_param "VectorDbProvider" "${STACHE_VECTORDB_PROVIDER:-}")
    if [[ -n "$vectordb_provider" ]]; then
        params="$params VectorDbProvider=$vectordb_provider"
        print_success "Vector DB provider: $vectordb_provider" >&2
    fi

    namespace_provider=$(resolve_sticky_param "NamespaceProvider" "${STACHE_NAMESPACE_PROVIDER:-}")
    if [[ -n "$namespace_provider" ]]; then
        params="$params NamespaceProvider=$namespace_provider"
        print_success "Namespace provider: $namespace_provider" >&2
    fi

    document_index_provider=$(resolve_sticky_param "DocumentIndexProvider" "${STACHE_DOCUMENT_INDEX_PROVIDER:-}")
    if [[ -n "$document_index_provider" ]]; then
        params="$params DocumentIndexProvider=$document_index_provider"
        print_success "Document index provider: $document_index_provider" >&2
    fi

    ingest_jobstore_provider=$(resolve_sticky_param "IngestJobstoreProvider" "${STACHE_INGEST_JOBSTORE_PROVIDER:-}")
    if [[ -n "$ingest_jobstore_provider" ]]; then
        params="$params IngestJobstoreProvider=$ingest_jobstore_provider"
        print_success "Ingest job store provider: $ingest_jobstore_provider" >&2
    fi

    ingest_blob_provider=$(resolve_sticky_param "IngestBlobProvider" "${STACHE_INGEST_BLOB_PROVIDER:-}")
    if [[ -n "$ingest_blob_provider" ]]; then
        params="$params IngestBlobProvider=$ingest_blob_provider"
        print_success "Ingest blob provider: $ingest_blob_provider" >&2
    fi

    embedding_model=$(resolve_sticky_param "BedrockEmbeddingModel" "${STACHE_BEDROCK_EMBEDDING_MODEL:-}")
    if [[ -n "$embedding_model" ]]; then
        params="$params BedrockEmbeddingModel=$embedding_model"
        print_success "Bedrock embedding model: $embedding_model" >&2
    fi

    # Admin-only password auth flow on the web user pool client (e2e harness).
    # Sticky too: once an operator has turned it on (or off), a redeploy that
    # does not mention it must not flip it back.
    admin_password_auth=$(resolve_sticky_param "EnableAdminPasswordAuth" "${STACHE_ENABLE_ADMIN_PASSWORD_AUTH:-}")
    if [[ -n "$admin_password_auth" ]]; then
        params="$params EnableAdminPasswordAuth=$admin_password_auth"
        print_success "Admin password auth flow: $admin_password_auth" >&2
    fi

    # Check for an enterprise stack and attach its extension layer if present.
    #
    # We consume EnterpriseSlimLayerArn -- the layer deduplicated against the
    # core layer (~2 MB). We must NOT consume EnterpriseLayerArn: that is the
    # enterprise stack's self-contained "fat" layer (~112 MB), built for the
    # enterprise stack's OWN functions, which already re-bundles everything the
    # core layer ships. Lambda caps function code plus all layers at 250 MB
    # unzipped and the core layer alone is ~124 MB, so attaching the fat layer
    # to a core function blows the limit and the deploy fails with:
    #   Function code combined with layers exceeds the maximum allowed size
    #   of 262144000 bytes.
    # There is deliberately no fallback to the fat layer.
    local enterprise_stack="${RESOURCE_PREFIX}-enterprise"
    local slim_layer_arn
    slim_layer_arn=$(get_stack_output "$enterprise_stack" "EnterpriseSlimLayerArn")

    if [[ -n "$slim_layer_arn" ]] && [[ "$slim_layer_arn" != "None" ]]; then
        params="$params EnterpriseLayerArn=$slim_layer_arn"
        print_success "Found enterprise slim layer: $slim_layer_arn" >&2
    elif ! stack_exists "$enterprise_stack" && main_stack_exists; then
        # No enterprise stack under this prefix -- but the main stack may still
        # have a layer attached (e.g. it was published by a stack deployed under a
        # DIFFERENT prefix, which this lookup cannot see). Do not let that silently
        # detach the layer: without EnterpriseLayerArn the template reverts it to
        # "", HasEnterpriseLayer goes false, and every function loses the extension
        # layer -- stranding LlmProvider/EmbeddingProvider on a provider name that
        # nothing implements. Keep whatever is deployed.
        local deployed_layer_arn
        deployed_layer_arn=$(resolve_sticky_param "EnterpriseLayerArn")
        if [[ -n "$deployed_layer_arn" ]]; then
            params="$params EnterpriseLayerArn=$deployed_layer_arn"
            print_warning "No '$enterprise_stack' stack; keeping the layer already on the stack:" >&2
            echo "    $deployed_layer_arn" >&2
        fi
    elif stack_exists "$enterprise_stack"; then
        # The enterprise stack is deployed but predates the slim layer. Fail
        # loudly rather than silently attaching a layer that cannot fit.
        local fat_layer_arn
        fat_layer_arn=$(get_stack_output "$enterprise_stack" "EnterpriseLayerArn")
        if [[ -n "$fat_layer_arn" ]] && [[ "$fat_layer_arn" != "None" ]]; then
            print_error "Enterprise stack '$enterprise_stack' exposes no EnterpriseSlimLayerArn output." >&2
            echo "  It only exposes the self-contained EnterpriseLayerArn:" >&2
            echo "    $fat_layer_arn" >&2
            echo "  That layer is for the enterprise stack's own functions. Attaching it to a" >&2
            echo "  core function exceeds Lambda's 250MB code+layers limit and the deploy fails." >&2
            echo "  Redeploy the enterprise stack so it publishes EnterpriseSlimLayerArn." >&2
            return 1
        fi
        print_warning "Enterprise stack '$enterprise_stack' exists but exposes no layer output" >&2
    fi

    echo "$params"
}

# Deploy SAM stack
deploy_sam_stack() {
    # Declare and assign separately: `local params=$(...)` would mask a non-zero
    # exit status from build_sam_params behind `local`'s own success.
    local params
    params=$(build_sam_params) || return 1

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
    local ingest_queue_url=$(get_stack_output "$STACK_NAME" "IngestQueueUrl")
    local originals_bucket=$(get_stack_output "$STACK_NAME" "OriginalsBucket")
    local ingest_jobs_table=$(get_stack_output "$STACK_NAME" "IngestJobsTable")

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
# INGESTION PHASE 2 - AWS ASYNC TIER
# =============================================================================
# Defaults to the in-process sync tier; set these to enable the async tier.
INGEST_QUEUE_PROVIDER=sqs
INGEST_JOBSTORE_PROVIDER=dynamodb
INGEST_BLOB_PROVIDER=s3
INGEST_QUEUE_SQS_URL=$ingest_queue_url
INGEST_JOBSTORE_DYNAMODB_TABLE=$ingest_jobs_table
INGEST_BLOB_S3_BUCKET=$originals_bucket
# Phase 3 - presigned upload intake (hand out presigned PUT URLs)
INGEST_INTAKE_PROVIDER=s3presign

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
