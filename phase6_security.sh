#!/usr/bin/env bash
# =============================================================================
# phase6_security.sh — Post-Patch Security Hardening
# Run as: root
#
# Steps:
#   F. Create fips.ora under new DB home ldap/admin
#   G. Disable extproc by renaming the binary
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase6_security.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

log "=== PHASE 6: Security Hardening ==="
log "New DB Home: ${NEW_DB_HOME}"

# ── Step F: Create fips.ora ───────────────────────────────────────────────────
log "Step F: Configuring FIPS 140 — creating fips.ora..."

LDAP_ADMIN_DIR="${NEW_DB_HOME}/ldap/admin"
FIPS_FILE="${LDAP_ADMIN_DIR}/fips.ora"

if [[ ! -d "${LDAP_ADMIN_DIR}" ]]; then
  log "  Creating missing directory: ${LDAP_ADMIN_DIR}"
  mkdir -p "${LDAP_ADMIN_DIR}"
  chown oracle:oinstall "${LDAP_ADMIN_DIR}"
  chmod 755 "${LDAP_ADMIN_DIR}"
fi

log "  Writing ${FIPS_FILE}..."
cat > "${FIPS_FILE}" << 'EOF'
SSLFIPS_140=TRUE
EOF

chown oracle:oinstall "${FIPS_FILE}"
chmod 640 "${FIPS_FILE}"
log "  fips.ora created with permissions 640 oracle:oinstall"
cat "${FIPS_FILE}"

# ── Step G: Disable extproc ───────────────────────────────────────────────────
log "Step G: Disabling extproc binary..."

EXTPROC_PATH="${NEW_DB_HOME}/bin/extproc"

if [[ -f "${EXTPROC_PATH}" ]]; then
  mv "${EXTPROC_PATH}" "${EXTPROC_PATH}.orig"
  log "  Renamed: ${EXTPROC_PATH} → ${EXTPROC_PATH}.orig"
elif [[ -f "${EXTPROC_PATH}.orig" ]]; then
  log "  Notice: extproc already disabled (${EXTPROC_PATH}.orig exists)."
else
  log "  WARNING: extproc not found at ${EXTPROC_PATH} — skipping."
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log "Verification:"
log "  fips.ora  : $(ls -l ${FIPS_FILE} 2>/dev/null || echo 'NOT FOUND')"
log "  extproc   : $(ls ${EXTPROC_PATH} 2>/dev/null && echo 'ACTIVE (unexpected)' || echo 'Disabled OK')"
log "  extproc.orig: $(ls ${EXTPROC_PATH}.orig 2>/dev/null && echo 'Present OK' || echo 'NOT FOUND')"

log "=== PHASE 6 COMPLETE ==="
