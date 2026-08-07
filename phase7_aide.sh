#!/usr/bin/env bash
# =============================================================================
# phase7_aide.sh — Post-Patch AIDE Integrity Database Reset
# Run as: root
#
# After patching, the Oracle home binaries have changed. The AIDE reference
# database must be regenerated so future integrity checks have a correct baseline.
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase7_aide.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

log "=== PHASE 7: AIDE Integrity Database Reset ==="

# ── Verify AIDE is installed ──────────────────────────────────────────────────
if ! command -v aide &>/dev/null; then
  log "WARNING: aide command not found — skipping AIDE reset."
  log "Install AIDE with: dnf install -y aide"
  log "=== PHASE 7 SKIPPED (AIDE not installed) ==="
  exit 0
fi

AIDE_NEW_DB="/var/lib/aide/aide.db.new.gz"
AIDE_MASTER_DB="/var/lib/aide/aide.db.gz"
AIDE_TIMEOUT=3600  # 1 hour max wait

# ── Run AIDE update in background ─────────────────────────────────────────────
log "Running aide --update in background (this may take 30-60 minutes)..."
rm -f "${AIDE_NEW_DB}"
aide --update &
AIDE_PID=$!
log "AIDE PID: ${AIDE_PID}"

# ── Wait for completion ────────────────────────────────────────────────────────
ELAPSED=0
INTERVAL=30
while true; do
  if ! kill -0 "${AIDE_PID}" 2>/dev/null; then
    # Process ended — check if output file was produced
    if [[ -s "${AIDE_NEW_DB}" ]]; then
      FILE_SIZE=$(stat -c%s "${AIDE_NEW_DB}")
      log "AIDE update complete. Output: ${AIDE_NEW_DB} (${FILE_SIZE} bytes)"
      break
    else
      log "WARNING: AIDE process ended but ${AIDE_NEW_DB} is empty or missing."
      die "AIDE update failed — check /var/log/aide/aide.log for details."
    fi
  fi

  ELAPSED=$(( ELAPSED + INTERVAL ))
  if (( ELAPSED >= AIDE_TIMEOUT )); then
    kill "${AIDE_PID}" 2>/dev/null || true
    die "AIDE update timed out after ${AIDE_TIMEOUT}s."
  fi

  log "  AIDE running... elapsed ${ELAPSED}s"
  sleep "${INTERVAL}"
done

# ── Promote new database to master ────────────────────────────────────────────
log "Promoting new AIDE database to master reference..."
cp -f "${AIDE_NEW_DB}" "${AIDE_MASTER_DB}"
log "  ${AIDE_NEW_DB} → ${AIDE_MASTER_DB}"

# ── Verify ────────────────────────────────────────────────────────────────────
MASTER_SIZE=$(stat -c%s "${AIDE_MASTER_DB}")
log "Master AIDE database updated: ${AIDE_MASTER_DB} (${MASTER_SIZE} bytes)"
log "Future aide --check runs will use this as the new baseline."

log "=== PHASE 7 COMPLETE ==="
