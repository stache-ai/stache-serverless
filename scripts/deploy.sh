#!/bin/bash
set -e

# Deploy Stache to AWS
# Usage: ./scripts/deploy.sh [options]
#
# Options:
#   --prefix <prefix>           Resource prefix (default: stache, allows multiple deployments)
#   --domain <domain>           Custom domain - certificate looked up by domain name
#   --certificate-arn <arn>     ACM certificate ARN (optional, auto-detected from domain)
#   --skip-frontend             Skip frontend build and deployment
#   --skip-backend              Skip SAM build and deploy (frontend only)
#   --skip-layer                Skip Lambda layer build (use existing)
#   -s, --sam-only              Just run sam deploy (skip layer, sam build, frontend)
#   --from-source [path]        Build from local source instead of PyPI (default: ../stache)
#   --local-env [file]          Output .env file for local development (skips deploy)
#   -h, --help                  Show this help message
#
# Environment variables:
#   RESOURCE_PREFIX             Same as --prefix
#   STACHE_FROM_SOURCE          Set to path to build from source (or "true" for default path)

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
FROM_SOURCE=""
LOCAL_ENV_FILE=""

# Check environment variable for source builds
if [[ -n "$STACHE_FROM_SOURCE" ]]; then
    if [[ "$STACHE_FROM_SOURCE" == "true" ]]; then
        FROM_SOURCE="../stache"
    else
        FROM_SOURCE="$STACHE_FROM_SOURCE"
    fi
fi

show_help() {
    head -19 "$0" | tail -15
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

# Handle custom domain
if [[ -n "$DOMAIN" ]]; then
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
                mangum \
                -t "$PROJECT_DIR/layer/python" --quiet
        else
            # Install from PyPI
            pip install \
                stache-ai \
                stache-ai-bedrock \
                stache-ai-s3vectors \
                stache-ai-dynamodb \
                mangum \
                -t "$PROJECT_DIR/layer/python" --quiet
        fi

        # Clean up to reduce size (keep stache_ai*.dist-info for entry points)
        find "$PROJECT_DIR/layer/python" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
        find "$PROJECT_DIR/layer/python" -type d -name "*.dist-info" ! -name "stache_ai*.dist-info" -exec rm -rf {} + 2>/dev/null || true
        find "$PROJECT_DIR/layer/python" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true

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
    fi

    # Deploy
    deploy_sam_stack
else
    print_warning "Skipping backend deployment"
fi

# Get outputs for frontend
print_header "Getting stack outputs"
get_frontend_config

# Build and deploy frontend
if [[ "$SKIP_FRONTEND" == false ]]; then
    # Determine frontend source
    FRONTEND_SOURCE="${FROM_SOURCE:-../stache}"

    # Resolve to absolute path before cd
    FRONTEND_DIR="$(cd "$FRONTEND_SOURCE/frontend" 2>/dev/null && pwd)"
    if [[ -z "$FRONTEND_DIR" ]] || [[ ! -d "$FRONTEND_DIR" ]]; then
        print_error "Frontend not found at $FRONTEND_SOURCE/frontend"
        exit 1
    fi

    print_header "Building frontend"
    cd "$FRONTEND_DIR"

    # Set environment variables for build
    export VITE_AUTH_PROVIDER="cognito"
    export VITE_COGNITO_USER_POOL_ID="$USER_POOL_ID"
    export VITE_COGNITO_CLIENT_ID="$USER_POOL_CLIENT_ID"
    export VITE_COGNITO_DOMAIN="$COGNITO_DOMAIN"
    export VITE_API_URL="$API_URL"

    npm ci --silent
    npm run build

    print_success "Frontend built"

    deploy_frontend "$FRONTEND_DIR/dist"
else
    print_warning "Skipping frontend deployment"
fi

# Summary
print_deploy_summary
