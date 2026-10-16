#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Offsite Backup Synchronization to S3-Compatible Object Storage
# ==============================================================================

SITES_DIR="${SITES_DIR:-/home/frappe/frappe-bench/sites}"
S3_BUCKET="${S3_BUCKET:?Environment variable S3_BUCKET must be specified}"
S3_PREFIX="${S3_PREFIX:-frappe-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

echo ">>> Starting backup synchronization to s3://${S3_BUCKET}/${S3_PREFIX}..."

# Verify aws cli or rclone presence
if command -v aws >/dev/null 2>&1; then
    SYNC_TOOL="aws"
elif command -v rclone >/dev/null 2>&1; then
    SYNC_TOOL="rclone"
else
    echo "ERROR: Neither 'aws' cli nor 'rclone' found in PATH. Install one of them."
    exit 1
fi

# Locate all backup archives across all tenant sites
find "$SITES_DIR" -type d -path "*/private/backups" | while read -r BACKUP_DIR; do
    SITE_NAME=$(echo "$BACKUP_DIR" | awk -F'/' '{print $(NF-2)}')
    echo ">>> Syncing backups for site: $SITE_NAME..."

    if [ "$SYNC_TOOL" = "aws" ]; then
        aws s3 sync "$BACKUP_DIR" "s3://${S3_BUCKET}/${S3_PREFIX}/${SITE_NAME}/" \
            --exclude "*" \
            --include "*.sql.gz" \
            --include "*.tar" \
            --include "*.tgz" \
            --include "*.json"
    else
        rclone sync "$BACKUP_DIR" "s3:${S3_BUCKET}/${S3_PREFIX}/${SITE_NAME}/"
    fi
done

# Local pruning of older archives to conserve RWX persistent volume capacity
echo ">>> Pruning local backup files older than $RETENTION_DAYS days..."
find "$SITES_DIR" -type f -path "*/private/backups/*" -mtime +"$RETENTION_DAYS" -exec rm -f {} +

echo ">>> Offsite backup synchronization completed successfully."
