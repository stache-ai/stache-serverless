#!/bin/bash
set -e

# Create a Cognito user for Stache
# Usage: ./scripts/create-user.sh [--prefix <prefix>] [--no-email] <email> [password]
#
# By default, Cognito emails the user a temporary password.
# Use --no-email to suppress the email and display the password instead.
#
# Environment variables:
#   RESOURCE_PREFIX             Resource prefix (default: stache)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
EMAIL=""
PASSWORD=""
SUPPRESS_EMAIL=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            set_prefix "$2"
            shift 2
            ;;
        --no-email)
            SUPPRESS_EMAIL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--prefix <prefix>] [--no-email] <email> [password]"
            echo ""
            echo "Create a Cognito user. By default, Cognito emails the temporary password."
            echo ""
            echo "Options:"
            echo "  --prefix <prefix>  Resource prefix (default: stache)"
            echo "  --no-email         Suppress email and display password instead"
            echo ""
            echo "Examples:"
            echo "  $0 user@example.com              # Emails temp password to user"
            echo "  $0 --no-email user@example.com   # Shows password in output"
            echo "  $0 user@example.com MyP@ssw0rd!  # Uses provided password (no email)"
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--prefix <prefix>] [--no-email] <email> [password]"
            exit 1
            ;;
        *)
            if [ -z "$EMAIL" ]; then
                EMAIL="$1"
            else
                PASSWORD="$1"
                SUPPRESS_EMAIL=true  # If password provided, don't email
            fi
            shift
            ;;
    esac
done

if [ -z "$EMAIL" ]; then
    echo "Usage: $0 [--prefix <prefix>] [--no-email] <email> [password]"
    echo "Example: $0 user@example.com              # Emails temp password"
    echo "Example: $0 --no-email user@example.com   # Shows password in output"
    exit 1
fi

# Generate password only if suppressing email (otherwise Cognito generates it)
if [ "$SUPPRESS_EMAIL" = true ] && [ -z "$PASSWORD" ]; then
    # Generate a random password that meets Cognito requirements
    PASSWORD=$(openssl rand -base64 12 | tr -d '/+=' | head -c 12)
    PASSWORD="${PASSWORD}Aa1!"  # Ensure it meets complexity requirements
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

if [ "$SUPPRESS_EMAIL" = true ]; then
    # Suppress email - we'll set password manually
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
        --message-action SUPPRESS \
        --region "$AWS_REGION" \
        --output text > /dev/null

    print_success "User created"

    # Set password permanently (no forced change)
    echo "Setting password..."
    aws cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --password "$PASSWORD" \
        --permanent \
        --region "$AWS_REGION"

    print_success "Password set"
else
    # Let Cognito email the temporary password
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$EMAIL" \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
        --region "$AWS_REGION" \
        --output text > /dev/null

    print_success "User created - temporary password emailed to $EMAIL"
fi

# Get frontend URL
FRONTEND_URL=$(get_stack_output "$STACK_NAME" "FrontendUrl")

# Output
print_header "User Created Successfully"

echo "Email:    $EMAIL"
if [ "$SUPPRESS_EMAIL" = true ]; then
    echo "Password: $PASSWORD"
    echo ""
    echo -e "${YELLOW}Note: Save this password - it won't be shown again!${NC}"
else
    echo ""
    echo "A temporary password has been emailed to the user."
    echo "They will be prompted to change it on first login."
fi
echo ""

if [ -n "$FRONTEND_URL" ] && [ "$FRONTEND_URL" != "None" ]; then
    echo "Login at: $FRONTEND_URL"
fi
