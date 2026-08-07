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
chmod 664 "${LOG_DIR}/phase6_security.log" 2>/dev/null || true
exec >> "${LOG_DIR}/phase6_security.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

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
printf 'SSLFIPS_140=TRUE\n' > "${FIPS_FILE}"
chown oracle:oinstall "${FIPS_FILE}"
chmod 640 "${FIPS_FILE}"

log "  fips.ora created:"
ls -l "${FIPS_FILE}"
cat "${FIPS_FILE}"

# ── Step G: Disable extproc ───────────────────────────────────────────────────
log "Step G: Disabling extproc binary..."

EXTPROC_PATH="${NEW_DB_HOME}/bin/extproc"

if [[ -f "${EXTPROC_PATH}" ]]; then
  mv "${EXTPROC_PATH}" "${EXTPROC_PATH}.orig"
  log "  Renamed: extproc → extproc.orig"
  ls -l "${EXTPROC_PATH}.orig"
elif [[ -f "${EXTPROC_PATH}.orig" ]]; then
  log "  Notice: extproc already disabled (extproc.orig exists)."
else
  log "  WARNING: extproc not found at ${EXTPROC_PATH} — skipping."
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log "Verification:"
[[ -f "${FIPS_FILE}" ]]         && log "  fips.ora  : OK ($(stat -c%a ${FIPS_FILE}))" \
                                 || log "  fips.ora  : MISSING"
[[ ! -f "${EXTPROC_PATH}" ]]    && log "  extproc   : Disabled OK" \
                                 || log "  extproc   : ACTIVE (unexpected)"
[[ -f "${EXTPROC_PATH}.orig" ]] && log "  extproc.orig: Present" \
                                 || log "  extproc.orig: Not found"

log "=== PHASE 6 COMPLETE ==="
