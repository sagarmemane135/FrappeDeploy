#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Frappe Container Initialization & Pre-Flight Checks
# ==============================================================================

SITES_DIR="/home/frappe/frappe-bench/sites"
TEMPLATE_DIR="/home/frappe/frappe-bench/sites_template"

# 1. Sync immutable image assets into shared stateful sites directory (Strategy B)
if [ -d "$TEMPLATE_DIR" ]; then
    mkdir -p "$SITES_DIR/assets"

    # Synchronize compiled assets from image to shared volume
    if [ -d "$TEMPLATE_DIR/assets" ]; then
        cp -rf "$TEMPLATE_DIR/assets/." "$SITES_DIR/assets/" 2>/dev/null || true
    fi

    # Synchronize apps.txt with newly added image apps
    if [ -f "$TEMPLATE_DIR/apps.txt" ]; then
        if [ ! -f "$SITES_DIR/apps.txt" ]; then
            echo "[Entrypoint] Initializing $SITES_DIR/apps.txt from template..."
            cp "$TEMPLATE_DIR/apps.txt" "$SITES_DIR/apps.txt"
        else
            while IFS= read -r app || [ -n "$app" ]; do
                [ -z "$app" ] && continue
                if ! grep -Fxq "$app" "$SITES_DIR/apps.txt"; then
                    echo "[Entrypoint] Registering newly installed app '$app' into $SITES_DIR/apps.txt"
                    echo "$app" >> "$SITES_DIR/apps.txt"
                fi
            done < "$TEMPLATE_DIR/apps.txt"
        fi
    fi
fi

# 2. Wait for Relational Database (MariaDB or PostgreSQL)
if [ "${WAIT_FOR_DB:-1}" = "1" ] && [ -n "${FRAPPE_DB_HOST:-}" ]; then
    DB_PORT="${FRAPPE_DB_PORT:-3306}"
    echo "[Entrypoint] Verifying database connectivity at $FRAPPE_DB_HOST:$DB_PORT..."
    if command -v wait-for-it >/dev/null 2>&1; then
        wait-for-it "$FRAPPE_DB_HOST:$DB_PORT" -t "${WAIT_FOR_DB_TIMEOUT:-60}" -- echo "[Entrypoint] Database is ready."
    fi
fi

# 3. Wait for Redis Cache
if [ "${WAIT_FOR_REDIS:-1}" = "1" ] && [ -n "${FRAPPE_REDIS_CACHE:-}" ]; then
    # Parse redis host and port from URL (e.g., redis://redis-cache:6379 or redis://:password@host:port)
    REDIS_CACHE_HOST=$(echo "$FRAPPE_REDIS_CACHE" | awk -F'[/:]' '{print $4}')
    REDIS_CACHE_PORT=$(echo "$FRAPPE_REDIS_CACHE" | awk -F'[/:]' '{print $5}')
    REDIS_CACHE_PORT="${REDIS_CACHE_PORT:-6379}"

    if [ -n "$REDIS_CACHE_HOST" ] && command -v wait-for-it >/dev/null 2>&1; then
        echo "[Entrypoint] Verifying Redis Cache at $REDIS_CACHE_HOST:$REDIS_CACHE_PORT..."
        wait-for-it "$REDIS_CACHE_HOST:$REDIS_CACHE_PORT" -t 30 -- echo "[Entrypoint] Redis Cache is ready."
    fi
fi

# 4. Wait for Redis Queue
if [ "${WAIT_FOR_REDIS:-1}" = "1" ] && [ -n "${FRAPPE_REDIS_QUEUE:-}" ]; then
    REDIS_QUEUE_HOST=$(echo "$FRAPPE_REDIS_QUEUE" | awk -F'[/:]' '{print $4}')
    REDIS_QUEUE_PORT=$(echo "$FRAPPE_REDIS_QUEUE" | awk -F'[/:]' '{print $5}')
    REDIS_QUEUE_PORT="${REDIS_QUEUE_PORT:-6379}"

    if [ -n "$REDIS_QUEUE_HOST" ] && command -v wait-for-it >/dev/null 2>&1; then
        echo "[Entrypoint] Verifying Redis Queue at $REDIS_QUEUE_HOST:$REDIS_QUEUE_PORT..."
        wait-for-it "$REDIS_QUEUE_HOST:$REDIS_QUEUE_PORT" -t 30 -- echo "[Entrypoint] Redis Queue is ready."
    fi
fi

# 5. Handover process execution
echo "[Entrypoint] Starting application process: $*"
exec "$@"
