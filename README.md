# Enterprise Frappe Deployment Framework

An architect-grade, production-ready deployment framework for **Frappe & ERPNext**, optimized for **Single-VM / Edge (Docker Compose)** and **High-Scale Clusters (Kubernetes)**.

Built on the **"Stateless Application, Stateful Sites" (Strategy B: Shared Persistent Volume)** model, this framework guarantees zero schema race conditions, predictable resource isolation, pluggable SSL/TLS, dynamic multi-tenancy, and high-throughput static/private file delivery.

---

## 1. Architectural Topology

```
                                  [ INTERNET ]
                                       │
                                       ▼
                     [ Ingress Controller / Nginx Proxy ]
               (Pluggable SSL/TLS, Wildcard Routing, Gzip, Buffers)
                                       │
        ┌──────────────────────────────┼──────────────────────────────┐
        │                              │                              │
        ▼                              ▼                              ▼
  Static & Assets              WebSocket Upgrades              HTTP Application
  (/assets, /files)            (/socket.io/*)                  (/, /api/*, /app/*)
  [Direct from Volume]         [Socket.IO Service :9000]       [Gunicorn WSGI :8000]
                                       │                              │
                                       │ Redis Pub/Sub                │ pymysql (Per-Request)
                                       ▼                              ▼
         ┌──────────────────────[ Redis Queue ]────────┐       [ MariaDB / Postgres ]
         │                       (noeviction)          │       (Cluster / Read-Replicas)
         ▼                                             ▼              ▲
   [ RQ Worker - Default ]                    [ Scheduler (1 replica) ]│
   (short, default queues)                    (Enqueues scheduled_jobs)│
         │                                             │              │
         └─────────────────────────────────────────────┴──────────────┘
                                       │
                               [ Redis Cache ]
                              (allkeys-lru RAM)
```

### Component Responsibility Matrix

| Component | Technology | Scaling Strategy | Critical Parameters |
| :--- | :--- | :--- | :--- |
| **Web Server** | Gunicorn (WSGI) | Horizontal (`replicas ≥ 2`, HPA) | `--preload`, `workers = (2*CPU)+1`, max-requests recycling |
| **Worker Default** | Python RQ | Horizontal (`replicas ≥ 2`, HPA) | Consumes `short,default` queues |
| **Worker Long** | Python RQ | Fixed / Low Scale (`replicas: 1-2`) | Consumes `long` queue; `terminationGracePeriod: 1800s` |
| **Scheduler** | Python Loop | **Strict Singleton (`replicas: 1`)** | Deployment `strategy: Recreate` (Avoid duplicate job dispatch) |
| **Socket.IO** | Node.js | Independent Scale | Listens `:9000`, consumes Redis Pub/Sub channel `events` |
| **Redis Cache** | Redis 7 | Standalone / Sentinel | `allkeys-lru` eviction policy, no persistence (`save ""`) |
| **Redis Queue** | Redis 7 | Standalone / Sentinel / StatefulSet | **`noeviction`** eviction policy, AOF + RDB persistent storage |
| **Proxy / Ingress**| Nginx | Front-line | Serves `/assets/` and `/files/`, executes `X-Accel-Redirect` |

---

## 2. Directory Structure

```
deploy/
├── README.md                          # This architecture guide & runbook
├── docker/                            # Immutable container packaging
│   ├── Dockerfile                     # Multi-stage production container (Node + Python)
│   ├── Dockerfile.nginx               # Nginx reverse proxy with dynamic template engine
│   ├── entrypoint.sh                  # Container startup script, pre-flight checks, signal handling
│   └── nginx/
│       ├── nginx.conf                 # Master Nginx configuration (buffers, gzip, worker limits)
│       └── templates/
│           ├── default.conf.template  # HTTP / Upstream-terminated SSL virtual host
│           └── default-ssl.conf.template # Direct HTTPS termination virtual host
├── compose/                           # Docker Compose orchestration
│   ├── .env.example                   # Baseline environment configurations
│   ├── docker-compose.yml             # Full-stack production compose
│   └── docker-compose.mariadb.yml     # Standalone MariaDB 10.6 tuned overlay
├── k8s/                               # Kubernetes cloud-native manifests (Kustomize)
│   ├── base/
│   │   ├── kustomization.yaml         # Base manifest assembler
│   │   ├── configmap.yaml             # Global bench common_site_config.json
│   │   ├── secrets.env.example        # Secret template (DB passwords, encryption keys)
│   │   ├── storage/
│   │   │   └── pvc-sites.yaml         # Strategy B: ReadWriteMany shared volume
│   │   ├── redis/
│   │   │   ├── redis-cache.yaml       # Deployment with LRU cache configuration
│   │   │   └── redis-queue.yaml       # StatefulSet with persistent disk & noeviction
│   │   ├── web/
│   │   │   ├── deployment.yaml        # Gunicorn deployment with probes and preStop hook
│   │   │   ├── service.yaml           # ClusterIP service
│   │   │   └── hpa.yaml               # Horizontal Pod Autoscaler
│   │   ├── workers/
│   │   │   ├── worker-default.yaml    # Short & default queues deployment
│   │   │   └── worker-long.yaml       # Long queue with 1800s termination grace period
│   │   ├── scheduler/
│   │   │   └── deployment.yaml        # Singleton deployment with Recreate strategy
│   │   ├── socketio/
│   │   │   ├── deployment.yaml        # Node.js real-time service
│   │   │   └── service.yaml           # ClusterIP service
│   │   ├── ingress/
│   │   │   └── ingress.yaml           # Pluggable TLS ingress with multi-tenant routing
│   │   └── jobs/
│   │       ├── job-migrate.yaml       # Safe rollout migration Job
│   │       └── job-backup.yaml        # Automated daily backup CronJob
│   └── overlays/
│       ├── production/                # High-availability production overlay
│       └── staging/                   # Cost-optimized staging overlay
└── scripts/                           # Operations & Maintenance Automation
    ├── site-ops.sh                    # Multi-tenant site lifecycle CLI (create/migrate/backup/restore)
    ├── health-check.sh                # End-to-end multi-component diagnostic script
    └── backup-s3.sh                   # S3-compatible offsite backup synchronization & retention
```

---

## 3. Storage Mount Strategy (Strategy B: Shared Persistent Volume)

Frappe separates application code from site runtime data:
- **Immutable Container Image**: Contains Python virtual environment (`/home/frappe/frappe-bench/env`) and application code (`/home/frappe/frappe-bench/apps`).
- **Shared Persistent Volume (RWX)**: Mounted at `/home/frappe/frappe-bench/sites`.

```
/home/frappe/frappe-bench/sites/ [Shared RWX Volume Mount]
├── apps.txt                 # Initialized by container entrypoint on boot
├── common_site_config.json  # Injected via ConfigMap / Compose mount
├── assets/                  # Pre-compiled static assets (mirrored on container startup)
└── <tenant.domain.com>/     # Tenant Site Directory
    ├── site_config.json     # DB credentials, encryption keys (Secret)
    ├── public/files/        # Public uploaded attachments (served directly by Nginx)
    ├── private/files/       # Invoices, HR docs (served via X-Accel-Redirect)
    └── private/backups/     # Scheduled .sql.gz database dumps
```

### Storage Best Practices
1. **Kubernetes StorageClass**: Use a `ReadWriteMany` (RWX) storage provisioner such as **AWS EFS CSI**, **Azure Files NFS**, **CephFS**, or **NFS Provisioner**.
2. **Asset Synchronization**: The container entrypoint automatically detects whether new assets exist in the image template (`sites_template/assets`) and mirrors them into the shared volume on startup without overwriting tenant data.

---

## 4. Multi-Tenancy & Pluggable TLS/SSL Architecture

Frappe natively identifies tenants using the incoming HTTP `Host` header. This framework eliminates hardcoded certificate assumptions in favor of modular TLS patterns.

### Pluggable TLS Strategies

#### Pattern 1: Edge / Cloud Load Balancer SSL Termination
- Used when running behind **AWS Application Load Balancer (ACM)**, **Cloudflare**, **Google Cloud HTTPS Load Balancer**, or an enterprise reverse proxy.
- Ingress/Nginx receives cleartext HTTP with `X-Forwarded-Proto: https`.
- Frappe respects the proto header via `USE_PROXY=1` in `frappe/app.py`.
- **Manifest setup**: Omit `spec.tls` in `ingress.yaml` or use `default.conf.template` in Nginx.

#### Pattern 2: Bring-Your-Own-Certificate (Enterprise PKI / Wildcard Secret)
- Used when you possess corporate certificates (e.g., `*.erp.company.com`).
- Store the certificate in Kubernetes:
  ```bash
  kubectl create secret tls frappe-tls-cert \
    --cert=/path/to/fullchain.pem \
    --key=/path/to/privkey.pem \
    -n erp-production
  ```
- **Manifest setup**: Reference `secretName: frappe-tls-cert` in `k8s/base/ingress/ingress.yaml`.

#### Pattern 3: Automated ACME / cert-manager (Let's Encrypt / Vault)
- If `cert-manager` is installed in the cluster, simply uncomment the annotation in `k8s/base/ingress/ingress.yaml`:
  ```yaml
  cert-manager.io/cluster-issuer: "letsencrypt-production"
  ```

---

## 5. High-Performance File Delivery (`X-Accel-Redirect`)

Serving private attachments through Python worker processes saturates Gunicorn concurrency.

This framework leverages **Nginx `X-Accel-Redirect`**:
1. Client requests private file: `GET /private/files/invoice-992.pdf`.
2. Nginx passes request to Gunicorn (`frappe_web`) with header `X-Use-X-Accel-Redirect: v1`.
3. Frappe checks session and DocType permissions in Python (`frappe/utils/response.py`).
4. If authorized, Frappe returns an empty HTTP response with header:
   ```http
   X-Accel-Redirect: /protected/private/files/invoice-992.pdf
   ```
5. Nginx intercepts this header and directly streams the file from disk via kernel `sendfile`, freeing the Python worker in milliseconds.

---

## 6. Building Container Images

The architecture is **100% self-contained**: it does **not** assume any application repositories exist locally on your machine. All code is fetched and compiled dynamically during the build stage using `apps.json` or build arguments.

Furthermore, **Python and Node.js versions are fully parameterized** via build arguments.

### Build Arguments Reference

| Argument | Default | Description |
| :--- | :--- | :--- |
| `PYTHON_VERSION` | `3.11` | Python base version (e.g. `3.10`, `3.11`, `3.12`) |
| `NODE_VERSION` | `18` | Node.js base version for asset compiler & Socket.IO (e.g. `18`, `20`) |
| `APPS_JSON_BASE64` | `""` | Base64-encoded JSON string of apps (Recommended: avoids all quote escaping) |
| `APPS_JSON` | `""` | Raw JSON string of apps to clone and build |
| `GITHUB_TOKEN` / `GIT_TOKEN` | `""` | Personal Access Token for private HTTPS git repositories |

---

### A. Building with Public Repositories (apps.json)
By default, Docker reads `apps.json`:
```bash
docker build -t frappe-app:latest -f docker/Dockerfile .
```

To customize Python or Node versions:
```bash
docker build \
  --build-arg PYTHON_VERSION=3.11 \
  --build-arg NODE_VERSION=20 \
  -t frappe-app:latest \
  -f docker/Dockerfile .
```

---

### B. Building with Private Git Repositories

#### Option 1: Using BuildKit SSH Agent Forwarding (Recommended for SSH URLs: `git@github.com:...`)
Your local SSH key is forwarded in memory to authenticate during git clone without ever being saved into the Docker image:
```bash
# Linux / macOS:
DOCKER_BUILDKIT=1 docker build --ssh default -t frappe-app:latest -f docker/Dockerfile .

# Windows PowerShell:
$env:DOCKER_BUILDKIT=1
docker build --ssh default -t frappe-app:latest -f docker/Dockerfile .
```

#### Option 2: Using GitHub Personal Access Token (for HTTPS URLs: `https://github.com/...`)
```bash
# Via BuildKit Secret (most secure, avoids leaking in history):
docker build --secret id=git_token,src=token.txt -t frappe-app:latest -f docker/Dockerfile .

# Or via Build Argument:
docker build --build-arg GITHUB_TOKEN="ghp_yourTokenHere" -t frappe-app:latest -f docker/Dockerfile .
```

---

### C. Overriding Apps List via Base64 (Recommended: Zero Quote Escaping)

Passing JSON strings directly into Docker build args often fails due to shell quote escaping rules (`"`, `'`, `\`). **Base64** solves this completely.

#### In Windows PowerShell:
```powershell
# Method 1: Encode directly from apps.json file
$APPS_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes("apps.json"))

# Method 2: Or encode from an inline string
$json = '[{"url":"https://github.com/frappe/frappe","branch":"version-15"},{"url":"git@github.com:my-org/my-custom-app.git","branch":"main"}]'
$APPS_BASE64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))

# Build with Base64 and SSH forwarding (for private repos):
docker build `
  --build-arg APPS_JSON_BASE64=$APPS_BASE64 `
  --ssh default `
  -t frappe-app:latest `
  -f docker/Dockerfile .
```

#### In Linux / macOS / CI/CD (Bash):
```bash
# Method 1: Encode directly from apps.json file
APPS_BASE64=$(base64 -w 0 apps.json)

# Method 2: Or encode from an inline string
APPS_BASE64=$(echo -n '[{"url":"https://github.com/frappe/frappe","branch":"version-15"},{"url":"git@github.com:my-org/my-custom-app.git","branch":"main"}]' | base64 -w 0)

# Build:
docker build \
  --build-arg APPS_JSON_BASE64="$APPS_BASE64" \
  --ssh default \
  -t frappe-app:latest \
  -f docker/Dockerfile .
```

---

### D. Building the Nginx Reverse Proxy Image
Execute from the `docker` directory (lightweight, ~15 seconds build):
```bash
cd docker
docker build -t frappe-nginx:latest -f Dockerfile.nginx .
cd ..
```

---

## 7. Deployment Guides

### A. Single-Server Deployment (Docker Compose)

1. **Configure Environment**:
   ```bash
   cd deploy/compose
   cp .env.example .env
   # Edit .env with your database passwords and domains
   ```

2. **Start the Stack**:
   - If using a **managed cloud database (AWS RDS, GCP CloudSQL)**:
     ```bash
     docker compose up -d
     ```
   - If using a **local containerized MariaDB**:
     ```bash
     docker compose -f docker-compose.yml -f docker-compose.mariadb.yml up -d
     ```

3. **Verify Health**:
   ```bash
   docker compose exec web health-check.sh
   # Or from host:
   ./scripts/health-check.sh
   ```

---

### B. Clustered Deployment (Kubernetes via Kustomize)

1. **Create Namespace & Secrets**:
   ```bash
   kubectl create namespace erp-production
   kubectl create secret generic frappe-secrets \
     --from-env-file=deploy/k8s/base/secrets.env.example \
     -n erp-production
   ```

2. **Deploy Storage, Redis, Web, and Workers**:
   ```bash
   kubectl apply -k deploy/k8s/overlays/production
   ```

3. **Verify Pod Status**:
   ```bash
   kubectl get pods -n erp-production -o wide
   ```

---

## 8. Operational Playbook & CLI Automation

The framework includes `deploy/scripts/site-ops.sh` to manage multi-tenant lifecycles cleanly.

### Provisioning a New Tenant Site
```bash
# Docker Compose:
docker compose exec web site-ops.sh create customer1.erp.example.com --install-app erpnext --install-app hrms

# Kubernetes:
kubectl exec -it deployment/frappe-web -n erp-production -- site-ops.sh create customer1.erp.example.com --install-app erpnext
```

### Safe Zero-Downtime Migration Pipeline
Never execute migrations directly on live pods without coordination. Use the automated pipeline:
```bash
# Via Script:
site-ops.sh migrate customer1.erp.example.com

# Via Kubernetes Job:
kubectl create -f deploy/k8s/base/jobs/job-migrate.yaml -n erp-production
```
The migration sequence executes:
1. `set-maintenance-mode on` (Halts scheduler and serves 503 to active users)
2. `ready-for-migration` (Drains running background worker jobs)
3. `backup` (Creates a pre-migration rollback snapshot)
4. `migrate` (Applies schema patches and DocType updates)
5. `clear-cache` (Purges Redis cache)
6. `set-maintenance-mode off` (Restores live traffic)

### Backups & Offsite S3 Synchronization
```bash
# 1. Take local backup
site-ops.sh backup customer1.erp.example.com --with-files

# 2. Sync archives to S3 / MinIO and prune local backups older than 30 days
export S3_BUCKET="my-company-erp-backups"
./deploy/scripts/backup-s3.sh
```

---

## 9. Sizing & Production Tuning Matrix

| Layer | Parameter | Recommended Value | Reason |
| :--- | :--- | :--- | :--- |
| **Gunicorn** | `--workers` | `(2 * CPU) + 1` | Squeezes maximum throughput under Python GIL |
| **Gunicorn** | `--max-requests` | `1000` | Recycles worker processes to eliminate Python memory creep |
| **Gunicorn** | `--max-requests-jitter` | `100` | Staggers process recycling to avoid thundering herds |
| **Gunicorn** | `--preload` | Enabled | Utilizes Frappe's `gc.freeze()` for Copy-on-Write memory sharing |
| **MariaDB** | `max_connections` | `500 - 1000` | Prevents connection starvation during worker spikes |
| **MariaDB** | `innodb_buffer_pool_size` | `70-80%` of RAM | Keeps database indexes and working set in memory |
| **Redis Queue** | `maxmemory-policy` | `noeviction` | Prevents losing queued background jobs |
| **Redis Cache** | `maxmemory-policy` | `allkeys-lru` | Safely drops old cache keys when RAM fills up |
| **Worker Long** | `terminationGracePeriod` | `1800s` | Guarantees long-running reports finish without SIGKILL |
| **Logging** | `FRAPPE_STREAM_LOGGING` | `1` | Forwards all logs to stdout/stderr for container collectors |
