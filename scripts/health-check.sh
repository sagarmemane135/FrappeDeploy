#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Comprehensive Multi-Component Frappe Bench Health Check
# ==============================================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

STATUS=0

log_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    STATUS=1
}

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

echo "=================================================="
echo " Frappe Environment Health Diagnostic"
echo "=================================================="

# Auto-detect test tenant site or use HEALTHCHECK_SITE env var
SITES_PATH="${SITES_PATH:-/home/frappe/frappe-bench/sites}"
DETECTED_SITE=$(find "$SITES_PATH" -maxdepth 2 -name "site_config.json" -exec dirname {} + 2>/dev/null | head -n 1 | xargs -n 1 basename 2>/dev/null || true)
TEST_SITE="${HEALTHCHECK_SITE:-${DETECTED_SITE:-sis.local}}"

log_info "Targeting site: $TEST_SITE for connectivity checks..."

# 1. Database Connectivity
log_info "Testing Relational Database Connection..."
if python3 -c "import frappe; frappe.init('$TEST_SITE'); frappe.connect(); print('DB connection verified.'); frappe.destroy()" 2>/dev/null; then
    log_ok "Database connected successfully and queries execute properly."
else
    log_fail "Database connection failed! Verify DB_HOST, credentials, and network."
fi

# 2. Redis Cache Verification
log_info "Testing Redis Cache..."
if python3 -c "import frappe; frappe.init('$TEST_SITE'); frappe.cache.set_value('_health_test', 1); assert frappe.cache.get_value('_health_test') == 1; print('Cache read/write verified.')" 2>/dev/null; then
    log_ok "Redis Cache read/write operation succeeded."
else
    log_fail "Redis Cache connection or read/write failed!"
fi

# 3. Redis Queue Verification
log_info "Testing Redis Queue..."
if python3 -c "from frappe.utils.background_jobs import get_redis_conn; r = get_redis_conn(); r.ping(); print('Queue connection verified.')" 2>/dev/null; then
    log_ok "Redis Queue responds to PING."
else
    log_fail "Redis Queue connection failed!"
fi

# 4. Storage Space Check (Strategy B Volume)
log_info "Checking Sites Volume Mount Storage..."
SITES_PATH="${SITES_PATH:-/home/frappe/frappe-bench/sites}"
if [ -d "$SITES_PATH" ]; then
    DISK_USAGE=$(df -h "$SITES_PATH" | awk 'NR==2 {print $5}')
    AVAILABLE=$(df -h "$SITES_PATH" | awk 'NR==2 {print $4}')
    log_ok "Sites volume accessible at $SITES_PATH ($DISK_USAGE used, $AVAILABLE free)."
else
    log_fail "Sites storage directory $SITES_PATH not found!"
fi

# 5. Application Web Ping (HTTP)
log_info "Testing Local Web WSGI Ping..."
HTTP_PORT="${WEBSERVER_PORT:-8000}"
if curl -s -f "http://localhost:${HTTP_PORT}/api/method/frappe.ping" -H "Host: $TEST_SITE" | grep -q "pong"; then
    log_ok "Web server responded with 'pong' on port ${HTTP_PORT}."
else
    log_fail "Web server failed to return pong on port ${HTTP_PORT}!"
fi

echo "=================================================="
if [ "$STATUS" -eq 0 ]; then
    echo -e "${GREEN}ALL COMPONENTS OPERATING AT MAXIMUM HEALTH${NC}"
else
    echo -e "${RED}ONE OR MORE COMPONENTS REPORTED ISSUES${NC}"
fi
echo "=================================================="

exit "$STATUS"
