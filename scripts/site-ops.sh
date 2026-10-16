#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Frappe Multi-Tenant Site Operations Automation
# ==============================================================================

SITES_DIR="/home/frappe/frappe-bench/sites"

usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [arguments]

Commands:
  create <site-name> [--db-name <name>] [--admin-password <pass>] [--install-app <app>]
      Provision a new tenant site in the bench and initialize database.

  migrate <site-name>
      Run safe database schema synchronization, patches, and cache clearing.

  backup <site-name> [--with-files]
      Generate immediate database and files backup for the tenant.

  restore <site-name> <db-backup.sql.gz> [--files <files.tar>] [--private-files <pfiles.tar>]
      Restore site database and assets from existing backup archive.

  maintenance <site-name> <on|off>
      Toggle maintenance mode on a specific tenant.

  drop <site-name>
      Permanently drop a tenant site and remove its database.

  list
      List all existing tenant sites in the current bench.

EOF
    exit 1
}

COMMAND="${1:-}"
shift || usage

case "$COMMAND" in
    create)
        SITE_NAME="${1:?Site name is required}"
        shift
        DB_NAME=""
        ADMIN_PASSWORD=""
        INSTALL_APPS=()

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --db-name) DB_NAME="$2"; shift 2 ;;
                --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
                --install-app) INSTALL_APPS+=("$2"); shift 2 ;;
                *) echo "Unknown option: $1"; exit 1 ;;
            esac
        done

        echo ">>> Creating new site: $SITE_NAME..."
        CMD_ARGS=(new-site "$SITE_NAME")

        if [ -n "$DB_NAME" ]; then
            CMD_ARGS+=(--db-name "$DB_NAME")
        fi
        if [ -n "$ADMIN_PASSWORD" ]; then
            CMD_ARGS+=(--admin-password "$ADMIN_PASSWORD")
        else
            CMD_ARGS+=(--admin-password "admin")
        fi

        # Pass MariaDB root password from environment if set
        if [ -n "${DB_ROOT_PASSWORD:-}" ]; then
            CMD_ARGS+=(--mariadb-root-password "$DB_ROOT_PASSWORD")
        fi

        bench "${CMD_ARGS[@]}"

        for app in "${INSTALL_APPS[@]}"; do
            echo ">>> Installing app: $app onto $SITE_NAME..."
            bench --site "$SITE_NAME" install-app "$app"
        done

        echo ">>> Site $SITE_NAME provisioned successfully."
        ;;

    migrate)
        SITE_NAME="${1:?Site name is required}"
        echo ">>> Executing safe migration for $SITE_NAME..."
        bench --site "$SITE_NAME" set-maintenance-mode on || true
        bench --site "$SITE_NAME" backup
        bench --site "$SITE_NAME" migrate
        bench --site "$SITE_NAME" clear-cache
        bench --site "$SITE_NAME" set-maintenance-mode off
        echo ">>> Migration completed for $SITE_NAME."
        ;;

    backup)
        SITE_NAME="${1:?Site name is required}"
        shift
        WITH_FILES=0
        if [[ "${1:-}" == "--with-files" ]]; then
            WITH_FILES=1
        fi

        echo ">>> Backing up site: $SITE_NAME..."
        if [ "$WITH_FILES" -eq 1 ]; then
            bench --site "$SITE_NAME" backup --with-files
        else
            bench --site "$SITE_NAME" backup
        fi
        echo ">>> Backup completed. Files saved to: $SITES_DIR/$SITE_NAME/private/backups/"
        ;;

    restore)
        SITE_NAME="${1:?Site name is required}"
        DB_FILE="${2:?Path to database .sql.gz backup is required}"
        shift 2

        RESTORE_ARGS=(--site "$SITE_NAME" restore "$DB_FILE")

        if [ -n "${DB_ROOT_PASSWORD:-}" ]; then
            RESTORE_ARGS+=(--mariadb-root-password "$DB_ROOT_PASSWORD")
        fi

        while [[ $# -gt 0 ]]; do
            case "$1" in
                --files) RESTORE_ARGS+=(--with-public-files "$2"); shift 2 ;;
                --private-files) RESTORE_ARGS+=(--with-private-files "$2"); shift 2 ;;
                *) echo "Unknown option: $1"; exit 1 ;;
            esac
        done

        echo ">>> Restoring site $SITE_NAME from $DB_FILE..."
        bench "${RESTORE_ARGS[@]}"
        bench --site "$SITE_NAME" migrate
        echo ">>> Restore completed successfully."
        ;;

    maintenance)
        SITE_NAME="${1:?Site name is required}"
        STATE="${2:?Specify on or off}"
        echo ">>> Setting maintenance mode to $STATE for $SITE_NAME..."
        bench --site "$SITE_NAME" set-maintenance-mode "$STATE"
        ;;

    drop)
        SITE_NAME="${1:?Site name is required}"
        echo ">>> WARNING: Dropping site $SITE_NAME and its database!"
        read -p "Are you sure? Type '$SITE_NAME' to confirm: " -r CONFIRM
        if [ "$CONFIRM" != "$SITE_NAME" ]; then
            echo "Aborted."
            exit 1
        fi

        DROP_ARGS=(drop-site "$SITE_NAME" --force)
        if [ -n "${DB_ROOT_PASSWORD:-}" ]; then
            DROP_ARGS+=(--root-password "$DB_ROOT_PASSWORD")
        fi

        bench "${DROP_ARGS[@]}"
        echo ">>> Site $SITE_NAME dropped."
        ;;

    list)
        echo ">>> Configured tenant sites in $SITES_DIR:"
        find "$SITES_DIR" -maxdepth 2 -name "site_config.json" -exec dirname {} + | xargs -n 1 basename
        ;;

    *)
        usage
        ;;
esac
