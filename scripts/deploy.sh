#!/bin/bash
set -e

# Deploy Stache to AWS
# Usage: ./scripts/deploy.sh [options]
#
# Options:
#   --prefix <prefix>           Resource prefix (default: stache, allows multiple deployments)
#   --domain <domain>           Custom domain - certificate looked up by domain name
#   --certificate-arn <arn>     ACM certificate ARN (optional, auto-detected from domain)
#   --cognito-domain <domain>   Custom Cognito hosted-UI domain (e.g. auth.example.com),
#                               created ALONGSIDE the prefix domain (both coexist). The JWT issuer
#                               is unchanged, so the API/authorizers are unaffected. Cert is
#                               auto-looked-up by name unless --cognito-certificate-arn is given.
#                               Provisions CloudFront (~15-20 min); the deploy prints the CNAME.
#   --cognito-certificate-arn <arn>  ACM cert (MUST be us-east-1) for --cognito-domain (optional,
#                               auto-detected from the domain name).
#   --use-cognito-domain        Build the FRONTEND against the custom Cognito domain instead of the
#                               prefix domain. Decoupled from creation: only pass this AFTER the
#                               custom domain is live (CloudFront provisioned + CNAME resolving),
#                               or hosted-UI logins will break.
#   --frontend-hosting <mode>   cloudfront (default) | external. external = no S3 bucket/CloudFront;
#                               the app is hosted elsewhere (e.g. Cloudflare Pages) at
#                               https://<--domain> (required). The deploy prints the env vars the
#                               external host needs instead of uploading the frontend. Sticky.
#   --additional-frontend-origin <https://host>  Extra origin for Cognito callbacks + API CORS
#                               (e.g. a preview host like https://my-app.pages.dev). "none"
#                               clears it. Sticky.
#   --confirm-frontend-teardown Required to switch an existing stack cloudfront -> external. Empties
#                               the frontend bucket so CloudFormation can delete it, and the
#                               CloudFront distribution is deleted. Repoint DNS FIRST.
#   --frontend-env [file]       Print (or write to file) the public env an external frontend host
#                               needs (honors --use-cognito-domain); no deploy.
#   --skip-frontend             Skip frontend build and deployment
#   --skip-backend              Skip SAM build and deploy (frontend only)
#   --skip-layer                Skip Lambda layer build (use existing)
#   -s, --sam-only              Just run sam deploy (skip layer, sam build, frontend)
#   -l, --layer-only            Rebuild layer and deploy (skip sam build, frontend)
#   --from-source [path]        Build from local source instead of PyPI (default: ../stache)
#   --embedding-model <model>   Bedrock embedding model id (default: cohere.embed-english-v3)
#                               Use cohere.embed-v4:0 to select Embed v4.
#   --enable-admin-password-auth   Enable ALLOW_ADMIN_USER_PASSWORD_AUTH on the web user
#                               pool client, so the e2e harness can sign test users in
#                               programmatically (via AdminInitiateAuth, IAM-gated).
#   --disable-admin-password-auth  Turn that flow back off.
#   --local-env [file]          Output .env file for local development (skips deploy)
#   -h, --help                  Show this help message
#
# Environment variables:
#   RESOURCE_PREFIX             Same as --prefix
#   STACHE_FROM_SOURCE          Set to path to build from source (or "true" for default path)
#   STACHE_BEDROCK_EMBEDDING_MODEL  Same as --embedding-model
#   STACHE_LLM_PROVIDER         LLM provider name to resolve at runtime (default: bedrock)
#   STACHE_EMBEDDING_PROVIDER   Embedding provider name to resolve at runtime (default: bedrock)
#   STACHE_VECTORDB_PROVIDER    Vector DB provider name (default: s3vectors)
#   STACHE_NAMESPACE_PROVIDER   Namespace registry provider name (default: dynamodb)
#   STACHE_DOCUMENT_INDEX_PROVIDER  Document index provider name (default: dynamodb)
#   STACHE_INGEST_JOBSTORE_PROVIDER Ingestion job store provider name (default: dynamodb)
#   STACHE_INGEST_BLOB_PROVIDER Original-blob store provider name (default: s3)
#   STACHE_ENABLE_ADMIN_PASSWORD_AUTH  "true"/"false", same as the flags above
#   STACHE_FRONTEND_HOSTING     Same as --frontend-hosting
#   STACHE_ADDITIONAL_FRONTEND_ORIGIN  Same as --additional-frontend-origin
#   STACHE_ALLOW_PYPI_WITH_EXTENSION  Set to 1 to allow a PyPI layer build even
#                               though an extension stack is deployed (normally
#                               refused -- see below)
#
# AN EXTENSION STACK MEANS --from-source.
#   This layer installs stache-ai, from PyPI unless --from-source says otherwise.
#   An extension stack's layer ships providers built against the LOCAL stache-ai,
#   which can import seams the published release does not have yet. If they do,
#   nothing errors: the import fails, provider discovery skips the provider, and
#   the functions come up healthy on the built-in providers with the extension
#   silently not running. So when an extension stack exists this build refuses to
#   use PyPI. Override with STACHE_ALLOW_PYPI_WITH_EXTENSION=1 once the published
#   version genuinely matches.
#
# STACK PARAMETERS ARE STICKY.
#   sam deploy resolves any parameter it is NOT given to the TEMPLATE DEFAULT, not
#   to the stack's current value, so omitting a flag on a redeploy would otherwise
#   silently revert it. The settings above (all seven provider names, the embedding
#   model, admin password auth, frontend hosting mode, additional frontend origin)
#   are therefore re-read from the deployed stack and
#   re-sent when you do not pass them. Passing a flag / env var still wins.
#
#   This matters most for the provider names: an extension layer registers its own
#   provider implementations under its own names, and CloudFormation rewrites the
#   whole Lambda environment on every deploy -- so without stickiness a routine
#   redeploy would quietly put every function back on the built-in providers.
#
# CHANGING THE EMBEDDING MODEL IS A RE-INDEX, NOT A CONFIG TWEAK.
#   Embed v3 and Embed v4 produce vectors in different embedding spaces. Pointing
#   a POPULATED vector index at a new embedding model does not migrate anything:
#   the stored vectors stay as they were, and querying v3 vectors with a v4 query
#   embedding returns meaningless results (no error, just silently bad matches).
#   Only change this on a fresh deployment, or as part of a deliberate re-index in
#   which every document is re-embedded with the new model.
#   Keep the output dimension at 1024 either way -- it must match the Dimension the
#   S3 Vectors indexes were created with, and changing that replaces the indexes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Script-specific config
SKIP_FRONTEND=false
SKIP_BACKEND=false
SKIP_LAYER=false
SAM_ONLY=false
DOMAIN=""
CERT_ARN=""
COGNITO_CUSTOM_DOMAIN=""
COGNITO_CERT_ARN=""
USE_COGNITO_DOMAIN=false
FROM_SOURCE=""
LOCAL_ENV_FILE=""
FRONTEND_ENV_FILE=""
CONFIRM_FRONTEND_TEARDOWN=false

# Check environment variable for source builds
if [[ -n "$STACHE_FROM_SOURCE" ]]; then
    if [[ "$STACHE_FROM_SOURCE" == "true" ]]; then
        FROM_SOURCE="../stache"
    else
        FROM_SOURCE="$STACHE_FROM_SOURCE"
    fi
fi

# Print the header comment block (everything from the title down to the first
# blank line), with the leading "# " stripped. Beats hardcoded line offsets,
# which silently truncate the help text whenever the header grows.
show_help() {
    sed -n '4,/^$/p' "$0" | sed 's/^#\( \|$\)//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            set_prefix "$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --certificate-arn)
            CERT_ARN="$2"
            shift 2
            ;;
        --cognito-domain)
            COGNITO_CUSTOM_DOMAIN="$2"
            shift 2
            ;;
        --cognito-certificate-arn)
            COGNITO_CERT_ARN="$2"
            shift 2
            ;;
        --use-cognito-domain)
            USE_COGNITO_DOMAIN=true
            shift
            ;;
        --frontend-hosting)
            # Exported so build_sam_params (lib/common.sh) forwards it as the
            # FrontendHosting stack parameter.
            export STACHE_FRONTEND_HOSTING="$2"
            shift 2
            ;;
        --additional-frontend-origin)
            if [[ "$2" != "none" && ! "$2" =~ ^https://[a-z0-9.-]+$ ]]; then
                print_error "--additional-frontend-origin must be https://host (no path/slash) or none"
                exit 1
            fi
            export STACHE_ADDITIONAL_FRONTEND_ORIGIN="$2"
            shift 2
            ;;
        --confirm-frontend-teardown)
            CONFIRM_FRONTEND_TEARDOWN=true
            shift
            ;;
        --frontend-env)
            if [[ -n "$2" ]] && [[ ! "$2" =~ ^- ]]; then
                FRONTEND_ENV_FILE="$2"
                shift 2
            else
                FRONTEND_ENV_FILE="-"
                shift
            fi
            ;;
        --skip-frontend)
            SKIP_FRONTEND=true
            shift
            ;;
        --skip-backend)
            SKIP_BACKEND=true
            shift
            ;;
        --skip-layer)
            SKIP_LAYER=true
            shift
            ;;
        --sam-only|-s)
            SAM_ONLY=true
            SKIP_LAYER=true
            SKIP_FRONTEND=true
            shift
            ;;
        --layer-only|-l)
            SAM_ONLY=true
            SKIP_FRONTEND=true
            shift
            ;;
        --from-source)
            # Check if next arg is a path or another flag
            if [[ -n "$2" ]] && [[ ! "$2" =~ ^- ]]; then
                FROM_SOURCE="$2"
                shift 2
            else
                FROM_SOURCE="../stache"
                shift
            fi
            ;;
        --embedding-model)
            # Exported so build_sam_params (lib/common.sh) forwards it as the
            # BedrockEmbeddingModel stack parameter.
            export STACHE_BEDROCK_EMBEDDING_MODEL="$2"
            shift 2
            ;;
        --enable-admin-password-auth)
            # Exported so build_sam_params (lib/common.sh) forwards it as the
            # EnableAdminPasswordAuth stack parameter.
            export STACHE_ENABLE_ADMIN_PASSWORD_AUTH="true"
            shift
            ;;
        --disable-admin-password-auth)
            export STACHE_ENABLE_ADMIN_PASSWORD_AUTH="false"
            shift
            ;;
        --local-env)
            # Check if next arg is a file path or another flag
            if [[ -n "$2" ]] && [[ ! "$2" =~ ^- ]]; then
                LOCAL_ENV_FILE="$2"
                shift 2
            else
                LOCAL_ENV_FILE=".env"
                shift
            fi
            ;;
        -h|--help)
            show_help
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            ;;
    esac
done

print_header "Deploying Stache to AWS"

# Check AWS credentials
check_aws_credentials || exit 1

# Frontend hosting mode: sticky like the provider params (flag/env > deployed > default).
FRONTEND_HOSTING=$(resolve_sticky_param "FrontendHosting" "${STACHE_FRONTEND_HOSTING:-}")
FRONTEND_HOSTING="${FRONTEND_HOSTING:-cloudfront}"
case "$FRONTEND_HOSTING" in
    cloudfront|external) ;;
    *) print_error "--frontend-hosting must be cloudfront or external (got $FRONTEND_HOSTING)"; exit 1 ;;
esac
if [[ -n "${STACHE_ADDITIONAL_FRONTEND_ORIGIN:-}" && "$STACHE_ADDITIONAL_FRONTEND_ORIGIN" != "none" \
      && ! "$STACHE_ADDITIONAL_FRONTEND_ORIGIN" =~ ^https://[a-z0-9.-]+$ ]]; then
    print_error "STACHE_ADDITIONAL_FRONTEND_ORIGIN must be https://host (no path/slash) or none"
    exit 1
fi

# Handle --frontend-env (print the external-host env and exit; read-only)
if [[ -n "$FRONTEND_ENV_FILE" ]]; then
    if ! stack_exists "$STACK_NAME"; then
        print_error "Stack $STACK_NAME does not exist"
        exit 1
    fi
    get_frontend_config
    if [[ "$FRONTEND_ENV_FILE" == "-" ]]; then
        print_frontend_env
    else
        print_frontend_env "$FRONTEND_ENV_FILE"
    fi
    exit 0
fi

# Handle --local-env (generate config and exit)
if [[ -n "$LOCAL_ENV_FILE" ]]; then
    print_header "Generating local environment config"

    if ! stack_exists "$STACK_NAME"; then
        print_error "Stack $STACK_NAME does not exist"
        echo "Deploy first with: ./scripts/deploy.sh"
        exit 1
    fi

    get_frontend_config
    generate_local_env "$LOCAL_ENV_FILE"
    exit 0
fi

# Handle custom domain (external hosting needs no ACM cert for the app domain)
if [[ -n "$DOMAIN" && "$FRONTEND_HOSTING" == "cloudfront" ]]; then
    # Domain specified - look up certificate and verify it's validated
    if [[ -z "$CERT_ARN" ]]; then
        # No ARN provided, look it up by domain
        find_certificate_for_domain "$DOMAIN" || exit 1
    else
        # ARN provided directly, verify it's valid
        cert_status=$(get_certificate_status "$CERT_ARN")
        if [[ "$cert_status" != "ISSUED" ]]; then
            print_error "Certificate is not validated (status: $cert_status)"
            echo "Check status with: ./scripts/check-certificate.sh"
            exit 1
        fi
        print_success "Using provided certificate for: $DOMAIN"
    fi
fi

# Handle custom Cognito hosted-UI domain (independent of --domain). The cert for a
# Cognito custom domain is CloudFront-backed and MUST live in us-east-1 regardless
# of the pool's region; we look it up in $AWS_REGION (us-east-1 for this stack).
if [[ -n "$COGNITO_CUSTOM_DOMAIN" ]]; then
    if [[ -z "$COGNITO_CERT_ARN" ]]; then
        COGNITO_CERT_ARN=$(aws acm list-certificates --region "$AWS_REGION" \
            --query "CertificateSummaryList[?DomainName=='$COGNITO_CUSTOM_DOMAIN'].CertificateArn | [0]" \
            --output text 2>/dev/null || echo "")
        if [[ -z "$COGNITO_CERT_ARN" ]] || [[ "$COGNITO_CERT_ARN" == "None" ]]; then
            print_error "No ACM certificate found for Cognito domain: $COGNITO_CUSTOM_DOMAIN"
            echo "Request one first (us-east-1, DNS-validated):"
            echo "  aws acm request-certificate --region us-east-1 \\"
            echo "    --domain-name $COGNITO_CUSTOM_DOMAIN --validation-method DNS"
            exit 1
        fi
    fi
    cognito_cert_status=$(get_certificate_status "$COGNITO_CERT_ARN")
    if [[ "$cognito_cert_status" != "ISSUED" ]]; then
        print_error "Cognito domain certificate is not validated (status: $cognito_cert_status)"
        echo "It must be ISSUED before CloudFormation can attach the custom domain."
        exit 1
    fi
    print_success "Using certificate for Cognito domain: $COGNITO_CUSTOM_DOMAIN"
fi

# Check for stache repo if building from source
if [[ -n "$FROM_SOURCE" ]]; then
    if [[ ! -d "$FROM_SOURCE/packages" ]]; then
        print_error "Stache repo not found at $FROM_SOURCE"
        echo "Use --from-source <path> or set STACHE_FROM_SOURCE to point to stache repo"
        exit 1
    fi
    print_success "Building from source: $FROM_SOURCE"
else
    print_success "Installing from PyPI"
fi

# Backend deployment (layer, SAM build, SAM deploy)
if [[ "$SKIP_BACKEND" == false ]]; then
    # Build Lambda layer
    if [[ "$SKIP_LAYER" == false ]]; then
        # A PyPI build under a deployed extension stack is a silently broken
        # deployment -- see require_source_build_with_extension. Refuse before
        # anything is built or deployed.
        require_source_build_with_extension "$FROM_SOURCE" || exit 1

        print_header "Building Lambda layer"

        rm -rf "$PROJECT_DIR/layer"
        mkdir -p "$PROJECT_DIR/layer/python"

        if [[ -n "$FROM_SOURCE" ]]; then
            # Install from local source
            pip install \
                "$FROM_SOURCE/packages/stache-ai" \
                "$FROM_SOURCE/packages/stache-ai-bedrock" \
                "$FROM_SOURCE/packages/stache-ai-s3vectors" \
                "$FROM_SOURCE/packages/stache-ai-dynamodb" \
                "$FROM_SOURCE/packages/stache-ai-aws" \
                "$FROM_SOURCE/packages/stache-ai-documents" \
                mangum \
                -t "$PROJECT_DIR/layer/python" --quiet
        else
            # Install from PyPI
            pip install \
                stache-ai \
                stache-ai-bedrock \
                stache-ai-s3vectors \
                stache-ai-dynamodb \
                stache-ai-aws \
                stache-ai-documents \
                mangum \
                -t "$PROJECT_DIR/layer/python" --quiet
        fi

        # Clean up to reduce size (keep stache_ai*.dist-info for entry points)
        find "$PROJECT_DIR/layer/python" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
        find "$PROJECT_DIR/layer/python" -type d -name "*.dist-info" ! -name "stache_ai*.dist-info" -exec rm -rf {} + 2>/dev/null || true
        find "$PROJECT_DIR/layer/python" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
        # Drop the uvicorn dev-server stack — unused under Mangum/Lambda (nothing imports it),
        # and it double-counts (CodeUri copies the layer into each function package) against the
        # 250MB layer+code limit. Keep boto3/botocore: the layer's boto3 1.43.x provides s3vectors,
        # which the Lambda runtime's older boto3 lacks.
        for pkg in uvloop uvicorn httptools watchfiles websockets; do
            rm -rf "$PROJECT_DIR/layer/python/$pkg" 2>/dev/null || true
        done

        LAYER_SIZE=$(du -sh "$PROJECT_DIR/layer" | cut -f1)
        print_success "Lambda layer built ($LAYER_SIZE)"
    else
        print_warning "Skipping Lambda layer build"
    fi

    # Build SAM application (skip if --sam-only)
    if [[ "$SAM_ONLY" == false ]]; then
        print_header "Building SAM application"
        cd "$PROJECT_DIR"
        sam build
        print_success "SAM build complete"
    else
        print_warning "Skipping SAM build (--sam-only)"
        cd "$PROJECT_DIR"
    fi

    # Get existing domain config if updating
    if stack_exists "$STACK_NAME"; then
        print_warning "Updating existing stack"
        get_existing_domain_config
        get_existing_cognito_domain_config
    fi

    if [[ "$FRONTEND_HOSTING" == "external" ]]; then
        if [[ -z "$DOMAIN" || "$DOMAIN" == "None" ]]; then
            print_error "--frontend-hosting external requires --domain <app hostname> (e.g. app.example.com)"
            exit 1
        fi
        CONFIRM_FRONTEND_TEARDOWN="$CONFIRM_FRONTEND_TEARDOWN" confirm_frontend_teardown || exit 1
    fi

    # Deploy
    deploy_sam_stack
else
    print_warning "Skipping backend deployment"
fi

# Get outputs for frontend
print_header "Getting stack outputs"
get_frontend_config

# What the stack actually is now (a --skip-backend run may not match the flag).
# No output = a stack that predates FrontendHosting, i.e. cloudfront.
DEPLOYED_HOSTING=$(get_stack_output "$STACK_NAME" "FrontendHosting")
if [[ -z "$DEPLOYED_HOSTING" || "$DEPLOYED_HOSTING" == "None" ]]; then
    DEPLOYED_HOSTING="cloudfront"
fi

# Build and deploy frontend
if [[ "$SKIP_FRONTEND" == false && "$DEPLOYED_HOSTING" == "external" ]]; then
    print_warning "FrontendHosting=external: not building/uploading the frontend (deploy it on your static host)"
    print_frontend_env
elif [[ "$SKIP_FRONTEND" == false ]]; then
    # Find frontend source (priority order)
    FRONTEND_DIR=""

    if [[ -n "$FROM_SOURCE" ]]; then
        # Explicit --from-source takes priority
        FRONTEND_DIR="$(cd "$FROM_SOURCE/frontend" 2>/dev/null && pwd)"
    fi

    # Prefer the sibling stache repo (current source) over the vendored
    # submodule snapshot: the snapshot has drifted badly before (deployed
    # months-old UI missing whole pages without anyone noticing)
    if [[ -z "$FRONTEND_DIR" ]] && [[ -d "$PROJECT_DIR/../stache/frontend" ]]; then
        # Sibling directory
        FRONTEND_DIR="$(cd "$PROJECT_DIR/../stache/frontend" && pwd)"
    fi

    if [[ -z "$FRONTEND_DIR" ]] && [[ -d "$PROJECT_DIR/stache-frontend/frontend" ]]; then
        # Submodule snapshot (fallback only)
        FRONTEND_DIR="$(cd "$PROJECT_DIR/stache-frontend/frontend" && pwd)"
        print_warning "Using vendored frontend snapshot at $FRONTEND_DIR"
        print_warning "This copy may be stale - prefer --from-source or a sibling stache checkout"
    fi

    if [[ -z "$FRONTEND_DIR" ]]; then
        print_error "Frontend not found. Checked:"
        echo "  - $PROJECT_DIR/../stache/frontend (sibling dir)"
        echo "  - $PROJECT_DIR/stache-frontend/frontend (submodule)"
        echo "Use --from-source <path> to specify stache repo, or --skip-frontend"
        exit 1
    fi

    echo "Using frontend from: $FRONTEND_DIR"

    print_header "Building frontend"
    cd "$FRONTEND_DIR"

    # Set environment variables for build
    export VITE_AUTH_PROVIDER="cognito"
    export VITE_COGNITO_USER_POOL_ID="$USER_POOL_ID"
    export VITE_COGNITO_CLIENT_ID="$USER_POOL_CLIENT_ID"
    export VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN"
    export VITE_API_URL="$API_URL"
    # Empty on a core-only deployment; the frontend treats that as "no extension".
    export VITE_ENTERPRISE_API_URL="${ENTERPRISE_API_URL:-}"

    npm ci --silent
    npm run build

    print_success "Frontend built"

    deploy_frontend "$FRONTEND_DIR/dist"
else
    print_warning "Skipping frontend deployment"
fi

# Summary
print_deploy_summary
