#!/bin/bash
set -e

# Check certificate status for a domain
# Usage: ./scripts/check-certificate.sh <domain>
#
# Examples:
#   ./scripts/check-certificate.sh stache.example.com

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common functions
source "$SCRIPT_DIR/lib/common.sh"

DOMAIN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            echo "Usage: $0 <domain>"
            echo ""
            echo "Check the validation status of an ACM certificate for a domain."
            echo ""
            echo "Examples:"
            echo "  $0 stache.example.com"
            exit 0
            ;;
        -*)
            print_error "Unknown option: $1"
            echo "Usage: $0 <domain>"
            exit 1
            ;;
        *)
            DOMAIN="$1"
            shift
            ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    print_error "Domain is required"
    echo "Usage: $0 <domain>"
    exit 1
fi

print_header "Checking certificate status"

# Check AWS credentials
check_aws_credentials || exit 1

echo "Looking for certificate for domain: $DOMAIN"
echo ""

# Find certificate by domain name
CERT_ARN=$(aws acm list-certificates \
    --region "$AWS_REGION" \
    --query "CertificateSummaryList[?DomainName=='$DOMAIN'].CertificateArn | [0]" \
    --output text 2>/dev/null || echo "")

if [[ -z "$CERT_ARN" ]] || [[ "$CERT_ARN" == "None" ]]; then
    print_warning "No certificate found for domain: $DOMAIN"
    echo ""
    echo "To create a certificate, run:"
    echo "  ./scripts/setup-custom-domain.sh $DOMAIN"
    exit 1
fi

# Get certificate details
CERT_INFO=$(aws acm describe-certificate \
    --certificate-arn "$CERT_ARN" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null)

CERT_STATUS=$(echo "$CERT_INFO" | jq -r '.Certificate.Status')
CERT_CREATED=$(echo "$CERT_INFO" | jq -r '.Certificate.CreatedAt')

echo "Domain:  $DOMAIN"
echo "ARN:     $CERT_ARN"
echo "Created: $CERT_CREATED"
echo ""

case "$CERT_STATUS" in
    ISSUED)
        print_success "Status: ISSUED (validated)"
        echo ""
        echo "Certificate is ready! You can deploy with:"
        echo "  ./scripts/deploy.sh --domain $DOMAIN"
        ;;
    PENDING_VALIDATION)
        print_warning "Status: PENDING_VALIDATION"
        echo ""
        echo "DNS validation required. Add this CNAME record:"
        echo ""

        VALIDATION=$(echo "$CERT_INFO" | jq -r '.Certificate.DomainValidationOptions[0].ResourceRecord')
        CNAME_NAME=$(echo "$VALIDATION" | jq -r '.Name')
        CNAME_VALUE=$(echo "$VALIDATION" | jq -r '.Value')

        echo "  Type:  CNAME"
        echo "  Name:  $CNAME_NAME"
        echo "  Value: $CNAME_VALUE"
        echo ""
        echo "After adding the DNS record, validation usually takes 5-30 minutes."
        ;;
    EXPIRED)
        print_error "Status: EXPIRED"
        echo ""
        echo "Certificate has expired. Request a new one with:"
        echo "  ./scripts/setup-custom-domain.sh $DOMAIN"
        ;;
    FAILED)
        print_error "Status: FAILED"
        echo ""
        echo "Certificate validation failed. Check the AWS Console for details:"
        echo "https://console.aws.amazon.com/acm/home?region=$AWS_REGION#/certificates"
        ;;
    *)
        echo "Status: $CERT_STATUS"
        ;;
esac
