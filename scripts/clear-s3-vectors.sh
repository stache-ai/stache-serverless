#!/bin/bash
# Clear all vectors from S3 Vectors indexes
# Usage: AWS_PROFILE=jtpenny-ragbrain ./clear-s3-vectors.sh [--dry-run]

set -e

# Get AWS account ID dynamically
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}
PREFIX=${RESOURCE_PREFIX:-stache}

BUCKET="${PREFIX}-vectors-${ACCOUNT_ID}"
INDEXES=("documents" "summaries" "insights")
DRY_RUN=false

if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE ==="
fi

echo "Account: $ACCOUNT_ID"
echo "Bucket: $BUCKET"

for INDEX in "${INDEXES[@]}"; do
    INDEX_ARN="arn:aws:s3vectors:${REGION}:${ACCOUNT_ID}:bucket/${BUCKET}/index/${INDEX}"

    echo ""
    echo "=== Index: $INDEX ==="

    # List all vectors (loop for pagination)
    NEXT_TOKEN=""
    ALL_KEYS=()

    while true; do
        if [[ -z "$NEXT_TOKEN" ]]; then
            RESPONSE=$(aws s3vectors list-vectors --index-arn "$INDEX_ARN" --max-results 1000 2>/dev/null || echo '{"vectors":[]}')
        else
            RESPONSE=$(aws s3vectors list-vectors --index-arn "$INDEX_ARN" --max-results 1000 --starting-token "$NEXT_TOKEN" 2>/dev/null || echo '{"vectors":[]}')
        fi

        # Extract keys from this page
        KEYS=$(echo "$RESPONSE" | jq -r '.vectors[].key')
        for KEY in $KEYS; do
            ALL_KEYS+=("$KEY")
        done

        # Check for next page
        NEXT_TOKEN=$(echo "$RESPONSE" | jq -r '.nextToken // empty')
        if [[ -z "$NEXT_TOKEN" ]]; then
            break
        fi
    done

    COUNT=${#ALL_KEYS[@]}
    echo "Found $COUNT vectors"

    if [[ "$COUNT" == "0" ]]; then
        echo "Nothing to delete"
        continue
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "Would delete $COUNT vectors (dry run)"
        continue
    fi

    # Delete in batches (API might have limits)
    BATCH_SIZE=100
    for ((i=0; i<COUNT; i+=BATCH_SIZE)); do
        BATCH=("${ALL_KEYS[@]:i:BATCH_SIZE}")
        echo "  Deleting batch of ${#BATCH[@]} vectors..."
        aws s3vectors delete-vectors \
            --index-arn "$INDEX_ARN" \
            --keys "${BATCH[@]}" \
            2>/dev/null || echo "    Failed to delete batch"
    done

    echo "Deleted $COUNT vectors from $INDEX"
done

echo ""
echo "=== Done ==="
