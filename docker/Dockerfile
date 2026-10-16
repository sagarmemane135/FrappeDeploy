# ==============================================================================
# STAGE 1: Frontend Asset Builder
# ==============================================================================
FROM node:18-bullseye-slim AS asset-builder

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

# Copy application source directories
COPY apps /home/frappe/frappe-bench/apps

# Install Node dependencies across all apps that have package.json
RUN for app_dir in apps/*; do \
        if [ -f "$app_dir/package.json" ]; then \
            echo "Installing node dependencies for $app_dir..." && \
            (cd "$app_dir" && yarn install --frozen-lockfile --ignore-engines --network-timeout 300000); \
        fi \
    done

# Compile production frontend bundles
RUN cd apps/frappe && yarn build --production


# ==============================================================================
# STAGE 2: Python Backend Environment Builder
# ==============================================================================
FROM python:3.11-slim-bullseye AS backend-builder

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

COPY apps /home/frappe/frappe-bench/apps

# Upgrade packaging tools
RUN pip install --no-cache-dir --upgrade pip wheel setuptools

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
FROM python:3.11-slim-bullseye AS runtime

# System runtime dependencies (libraries only, no compilers)
RUN apt-get update && apt-get install -y --no-install-recommends \
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

# Install Node.js runtime strictly for Frappe Socket.IO service
RUN curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Security: Non-root frappe user with deterministic UID/GID 1000
RUN groupadd -g 1000 frappe && \
    useradd -u 1000 -g 1000 -m -s /bin/bash frappe

USER frappe
WORKDIR /home/frappe/frappe-bench

# Copy Python virtual environment from Stage 2
COPY --chown=frappe:frappe --from=backend-builder /home/frappe/frappe-bench/env /home/frappe/frappe-bench/env

# Copy app source code
COPY --chown=frappe:frappe apps /home/frappe/frappe-bench/apps

# Pre-populate compiled static assets in an immutable container directory
# The entrypoint will mirror these to shared storage if needed
RUN mkdir -p /home/frappe/frappe-bench/sites/assets \
             /home/frappe/frappe-bench/sites_template \
             /home/frappe/frappe-bench/logs

COPY --chown=frappe:frappe --from=asset-builder /home/frappe/frappe-bench/apps/frappe/frappe/public /home/frappe/frappe-bench/sites_template/assets/frappe

# Generate baseline apps.txt from installed apps
RUN ls -1 /home/frappe/frappe-bench/apps > /home/frappe/frappe-bench/sites_template/apps.txt

# Environment variables
ENV PATH="/home/frappe/frappe-bench/env/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    FRAPPE_STREAM_LOGGING=1 \
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
             /usr/local/bin/backup-s3.sh
USER frappe

EXPOSE 8000 9000

ENTRYPOINT ["entrypoint.sh"]
CMD ["gunicorn", "-b", "0.0.0.0:8000", "--workers", "4", "--threads", "2", "--timeout", "120", "frappe.app:application", "--preload"]
