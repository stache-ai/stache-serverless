#!/bin/bash
set -e

# Setup Custom Domain for Stache
# Usage: ./scripts/setup-custom-domain.sh <domain>
# Example: ./scripts/setup-custom-domain.sh stache.example.com
#
# This creates an ACM certificate for your domain and shows the DNS
# validation records you need to add.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

# Parse arguments
DOMAIN=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            set_prefix "$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--prefix <prefix>] <domain>"
            echo ""
            echo "Create an ACM certificate for a custom domain."
            echo ""
            echo "Options:"
            echo "  --prefix <prefix>  Resource prefix (default: stache)"
            echo ""
            echo "Examples:"
            echo "  $0 stache.example.com"
            echo "  $0 --prefix myapp stache.example.com"
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Usage: $0 [--prefix <prefix>] <domain>"
            exit 1
            ;;
        *)
            DOMAIN="$1"
            shift
            ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: $0 <domain>"
    echo "Example: $0 stache.example.com"
    exit 1
fi

print_header "Setting up custom domain: $DOMAIN"

# Check AWS credentials
check_aws_credentials || exit 1

# Check if certificate already exists for this domain
echo "Checking for existing certificate..."
EXISTING_CERT=$(aws acm list-certificates \
    --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -n "$EXISTING_CERT" ]] && [[ "$EXISTING_CERT" != "None" ]]; then
    print_warning "Certificate already exists for $DOMAIN"
    CERT_ARN="$EXISTING_CERT"

    # Check status
    CERT_STATUS=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region "$AWS_REGION" \
        --query 'Certificate.Status' \
        --output text)

    if [[ "$CERT_STATUS" == "ISSUED" ]]; then
        print_success "Certificate is already validated!"
        echo ""
        echo "You can deploy with:"
        echo "  ./scripts/deploy.sh --domain $DOMAIN"
        exit 0
    else
        echo "Certificate status: $CERT_STATUS"
        echo "Showing validation records..."
    fi
else
    # Request new certificate
    print_header "Requesting SSL certificate"
    echo "Requesting certificate for: $DOMAIN"

    CERT_ARN=$(aws acm request-certificate \
        --domain-name "$DOMAIN" \
        --validation-method DNS \
        --region "$AWS_REGION" \
        --tags Key=Name,Value="$DOMAIN" Key=Project,Value="$RESOURCE_PREFIX" \
        --query 'CertificateArn' \
        --output text)

    print_success "Certificate requested: $CERT_ARN"

    # Wait a moment for validation records to be available
    echo "Waiting for validation records..."
    sleep 5
fi

# Get validation records
print_header "DNS Validation Records"

# Poll for validation records (they may take a moment to appear)
MAX_ATTEMPTS=6
ATTEMPT=0
VALIDATION=""

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    VALIDATION=$(aws acm describe-certificate \
        --certificate-arn "$CERT_ARN" \
        --region "$AWS_REGION" \
        --query 'Certificate.DomainValidationOptions[0].ResourceRecord' \
        --output json 2>/dev/null || echo "null")

    if [[ "$VALIDATION" != "null" ]] && [[ -n "$VALIDATION" ]]; then
        break
    fi

    ATTEMPT=$((ATTEMPT + 1))
    if [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; then
        echo "Waiting for validation records... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
        sleep 5
    fi
done

if [[ "$VALIDATION" == "null" ]] || [[ -z "$VALIDATION" ]]; then
    print_error "Could not retrieve validation records"
    echo "Check the AWS Console:"
    echo "https://console.aws.amazon.com/acm/home?region=$AWS_REGION#/certificates"
    exit 1
fi

CNAME_NAME=$(echo "$VALIDATION" | jq -r '.Name')
CNAME_VALUE=$(echo "$VALIDATION" | jq -r '.Value')

echo ""
echo -e "${YELLOW}Add this CNAME record to your DNS:${NC}"
echo ""
echo "  Type:  CNAME"
echo "  Name:  $CNAME_NAME"
echo "  Value: $CNAME_VALUE"
echo ""

# Next steps
print_header "Next Steps"

echo "1. Add the DNS validation record above"
echo "2. Wait for certificate validation (usually 5-30 minutes)"
echo "3. Check status: ./scripts/check-certificate.sh $DOMAIN"
echo "4. Deploy: ./scripts/deploy.sh --domain $DOMAIN"
echo ""

print_header "Details"
echo "Certificate ARN: $CERT_ARN"
echo "Domain:          $DOMAIN"
echo "Region:          $AWS_REGION"
echo ""
