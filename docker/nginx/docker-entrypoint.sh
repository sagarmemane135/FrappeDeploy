#!/bin/sh
set -e

mkdir -p /etc/nginx/templates

if [ "$ENABLE_SSL" = "true" ]; then
    echo "[Nginx Entrypoint] SSL termination enabled. Activating HTTPS template..."
    cp /etc/nginx/templates-available/default-ssl.conf.template /etc/nginx/templates/default-ssl.conf.template
else
    echo "[Nginx Entrypoint] SSL disabled or terminated upstream. Activating HTTP template..."
    cp /etc/nginx/templates-available/default.conf.template /etc/nginx/templates/default.conf.template
fi

exec /docker-entrypoint.sh "$@"
