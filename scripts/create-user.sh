#!/bin/bash
set -e

# Create a Cognito user for Stache
# Usage: ./scripts/create-user.sh [--prefix <prefix>] <email> [password]
# If password is not provided, a random one will be generated
#
# Environment variables:
#   RESOURCE_PREFIX             Resource prefix (default: stache)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
EMAIL=""
PASSWORD=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            set_prefix "$2"
            shift 2
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--prefix <prefix>] <email> [password]"
            exit 1
            ;;
        *)
            if [ -z "$EMAIL" ]; then
                EMAIL="$1"
            else
                PASSWORD="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$EMAIL" ]; then
    echo "Usage: $0 [--prefix <prefix>] <email> [password]"
    echo "Example: $0 user@example.com"
    echo "Example: $0 --prefix myapp user@example.com MyP@ssw0rd!"
    exit 1
fi

# Generate password if not provided
if [ -z "$PASSWORD" ]; then
    # Generate a random password that meets Cognito requirements
    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)
    PASSWORD="${PASSWORD}Aa1!"  # Ensure it meets complexity requirements
    GENERATED=true
else
    GENERATED=false
fi

print_header "Creating Cognito user"

# Check AWS credentials
check_aws_credentials || exit 1

# Get User Pool ID from stack
USER_POOL_ID=$(get_stack_output "$STACK_NAME" "UserPoolId")

if [ -z "$USER_POOL_ID" ] || [ "$USER_POOL_ID" = "None" ]; then
    print_error "Could not find User Pool ID. Is the stack deployed?"
    exit 1
fi

print_success "Found User Pool: $USER_POOL_ID"

# Create user
echo "Creating user: $EMAIL"

aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
    --message-action SUPPRESS \
    --region "$AWS_REGION" \
    --output text > /dev/null

print_success "User created"

# Set password
echo "Setting password..."

aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username "$EMAIL" \
    --password "$PASSWORD" \
    --region "$AWS_REGION"

print_success "Password set"

# Get frontend URL
FRONTEND_URL=$(get_stack_output "$STACK_NAME" "FrontendUrl")

# Output
print_header "User Created Successfully"

echo "Email:    $EMAIL"
if [ "$GENERATED" = true ]; then
    echo "Password: $PASSWORD"
    echo ""
    echo -e "${YELLOW}Note: Save this password - it won't be shown again!${NC}"
else
    echo "Password: (as provided)"
fi
echo ""

if [ -n "$FRONTEND_URL" ] && [ "$FRONTEND_URL" != "None" ]; then
    echo "Login at: $FRONTEND_URL"
fi
