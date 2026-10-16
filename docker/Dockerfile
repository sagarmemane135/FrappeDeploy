# check=skip=SecretsUsedInArgOrEnv
# Global build arguments (available in all FROM instructions)
ARG PYTHON_VERSION=3.11
ARG NODE_VERSION=18
ARG DEBIAN_RELEASE=bookworm

# ==============================================================================
# STAGE 0: Application Source Fetcher (Clones from Git via apps.json or build args)
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE} AS app-source-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/frappe/frappe-bench

# Build arguments for dynamic app fetching & private repo authentication
ARG APPS_JSON=""
ARG APPS_JSON_BASE64=""
ARG GITHUB_TOKEN=""
ARG GIT_TOKEN=""

# Copy cloner automation & apps specification (no host apps required)
COPY docker/fetch_apps.py /opt/fetch_apps.py
COPY apps.json* /opt/apps.json

# Fetch all applications into /home/frappe/frappe-bench/apps (using SSH agent or Tokens)
RUN --mount=type=ssh,required=false \
    --mount=type=secret,id=git_token,required=false \
    --mount=type=secret,id=github_token,required=false \
    APPS_JSON="${APPS_JSON}" \
    APPS_JSON_BASE64="${APPS_JSON_BASE64}" \
    GITHUB_TOKEN="${GITHUB_TOKEN}" \
    GIT_TOKEN="${GIT_TOKEN}" \
    python3 /opt/fetch_apps.py


# ==============================================================================
# STAGE 1: Frontend Asset Builder
# ==============================================================================
FROM node:${NODE_VERSION}-${DEBIAN_RELEASE}-slim AS asset-builder

# Install minimal build tools needed for node-gyp / native modules
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3 \
    make \
    g++ \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/frappe/frappe-bench

# Install Yarn package manager
RUN npm install -g yarn --force

# Copy application source code and sites metadata from app-source-builder
COPY --from=app-source-builder /home/frappe/frappe-bench/apps /home/frappe/frappe-bench/apps
COPY --from=app-source-builder /home/frappe/frappe-bench/sites /home/frappe/frappe-bench/sites

# Ensure sites/apps.txt and sites/assets exist
RUN mkdir -p /home/frappe/frappe-bench/sites/assets && \
    if [ ! -f /home/frappe/frappe-bench/sites/apps.txt ]; then \
        (test -d apps/frappe && echo frappe || true; ls -1 apps | grep -v '^frappe$') > /home/frappe/frappe-bench/sites/apps.txt; \
    fi

# Populate static public assets from apps into sites/assets
RUN for app_dir in apps/*; do \
        app=$(basename "$app_dir"); \
        if [ -d "$app_dir/$app/public" ]; then \
            echo "Populating static public assets for $app..." && \
            mkdir -p "sites/assets/$app" && \
            cp -r "$app_dir/$app/public/"* "sites/assets/$app/" 2>/dev/null || true; \
        fi \
    done

# Install Node dependencies across all apps that have package.json
RUN for app_dir in apps/*; do \
        if [ -f "$app_dir/package.json" ]; then \
            echo "Installing node dependencies for $app_dir..." && \
            (cd "$app_dir" && yarn install --ignore-engines --network-timeout 300000); \
        fi \
    done

# Compile production frontend bundles
RUN cd apps/frappe && yarn build --production

# Sync any newly generated frontend files back into sites/assets
RUN for app_dir in apps/*; do \
        app=$(basename "$app_dir"); \
        if [ -d "$app_dir/$app/public" ]; then \
            mkdir -p "sites/assets/$app" && \
            cp -r "$app_dir/$app/public/"* "sites/assets/$app/" 2>/dev/null || true; \
        fi \
    done


# ==============================================================================
# STAGE 2: Python Backend Environment Builder
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE} AS backend-builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    build-essential \
    default-libmysqlclient-dev \
    libpq-dev \
    libffi-dev \
    libssl-dev \
    pkg-config \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /home/frappe/frappe-bench

# Setup virtual environment
RUN python3 -m venv /home/frappe/frappe-bench/env
ENV PATH="/home/frappe/frappe-bench/env/bin:$PATH"

# Copy application source code from app-source-builder (No local host apps required)
COPY --from=app-source-builder /home/frappe/frappe-bench/apps /home/frappe/frappe-bench/apps

# Upgrade packaging tools & install bench CLI
RUN pip install --no-cache-dir --upgrade pip wheel setuptools frappe-bench

# Install frappe core first
RUN pip install --no-cache-dir -e ./apps/frappe

# Install all other detected apps
RUN for app_dir in ./apps/*; do \
        if [ "$app_dir" != "./apps/frappe" ] && [ -d "$app_dir" ]; then \
            if [ -f "$app_dir/pyproject.toml" ] || [ -f "$app_dir/setup.py" ]; then \
                echo "Installing Python package: $app_dir..." && \
                pip install --no-cache-dir -e "$app_dir"; \
            fi \
        fi \
    done


# ==============================================================================
# STAGE 3: Minimal Production Runtime
# ==============================================================================
FROM python:${PYTHON_VERSION}-slim-${DEBIAN_RELEASE} AS runtime

ARG NODE_VERSION=18

# System runtime dependencies (libraries only, no compilers)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    mariadb-client \
    postgresql-client \
    libmariadb3 \
    libpq5 \
    curl \
    wait-for-it \
    wkhtmltopdf \
    libfontconfig1 \
    libxrender1 \
    libxext6 \
    fonts-liberation \
    ca-certificates \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js runtime strictly for Frappe Socket.IO service (dynamically matches NODE_VERSION)
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Security: Non-root frappe user with deterministic UID/GID 1000
RUN groupadd -g 1000 frappe && \
    useradd -u 1000 -g 1000 -m -s /bin/bash frappe

USER frappe
WORKDIR /home/frappe/frappe-bench

RUN git config --global --add safe.directory "*"

# Copy Python virtual environment from Stage 2
COPY --chown=frappe:frappe --from=backend-builder /home/frappe/frappe-bench/env /home/frappe/frappe-bench/env

# Copy app source code from Stage 0
COPY --chown=frappe:frappe --from=app-source-builder /home/frappe/frappe-bench/apps /home/frappe/frappe-bench/apps

# Copy Node.js dependencies for Frappe Socket.IO service from Stage 1
COPY --chown=frappe:frappe --from=asset-builder /home/frappe/frappe-bench/apps/frappe/node_modules /home/frappe/frappe-bench/apps/frappe/node_modules

# Pre-populate compiled static assets and sites metadata in an immutable container directory
# The entrypoint will mirror these to shared storage if needed
RUN mkdir -p /home/frappe/frappe-bench/sites/assets \
             /home/frappe/frappe-bench/sites_template/assets \
             /home/frappe/frappe-bench/logs

COPY --chown=frappe:frappe --from=asset-builder /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/sites_template/assets
COPY --chown=frappe:frappe --from=asset-builder /home/frappe/frappe-bench/sites/assets /home/frappe/frappe-bench/sites/assets
COPY --chown=frappe:frappe --from=app-source-builder /home/frappe/frappe-bench/sites/apps.txt /home/frappe/frappe-bench/sites_template/apps.txt
COPY --chown=frappe:frappe --from=app-source-builder /home/frappe/frappe-bench/sites/apps.txt /home/frappe/frappe-bench/sites/apps.txt

# Environment variables
ENV PATH="/home/frappe/frappe-bench/env/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    FRAPPE_STREAM_LOGGING=1 \
    GIT_PYTHON_REFRESH=quiet \
    SITES_PATH="/home/frappe/frappe-bench/sites"

# Entrypoint and operation automation scripts
COPY --chown=frappe:frappe docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chown=frappe:frappe scripts/site-ops.sh /usr/local/bin/site-ops.sh
COPY --chown=frappe:frappe scripts/health-check.sh /usr/local/bin/health-check.sh
COPY --chown=frappe:frappe scripts/backup-s3.sh /usr/local/bin/backup-s3.sh

USER root
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/site-ops.sh \
             /usr/local/bin/health-check.sh \
             /usr/local/bin/backup-s3.sh && \
    ln -sf /home/frappe/frappe-bench/env/bin/bench /usr/local/bin/bench
USER frappe

EXPOSE 8000 9000

ENTRYPOINT ["entrypoint.sh"]
CMD ["gunicorn", "-b", "0.0.0.0:8000", "--workers", "4", "--threads", "2", "--timeout", "120", "frappe.app:application", "--preload"]
