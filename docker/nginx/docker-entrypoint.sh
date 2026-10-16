#!/bin/sh
set -e

mkdir -p /etc/nginx/templates /etc/nginx/conf.d

# Ensure envsubst ONLY replaces our designated environment variables,
# leaving all Nginx variables ($host, $1, $http_upgrade, $remote_addr, $scheme, etc.) intact.
export NGINX_ENVSUBST_FILTER="UPSTREAM_WEB|UPSTREAM_SOCKETIO|HTTP_PORT|HTTPS_PORT|SERVER_NAME|CLIENT_MAX_BODY_SIZE|PROXY_READ_TIMEOUT|SSL_CERT_PATH|SSL_KEY_PATH"

if [ "$ENABLE_SSL" = "true" ]; then
    echo "[Nginx Entrypoint] SSL termination enabled. Activating HTTPS template..."
    cp /etc/nginx/templates-available/default-ssl.conf.template /etc/nginx/templates/default.conf.template
else
    echo "[Nginx Entrypoint] SSL disabled or terminated upstream. Activating HTTP template..."
    cp /etc/nginx/templates-available/default.conf.template /etc/nginx/templates/default.conf.template
fi

exec /docker-entrypoint.sh "$@"
