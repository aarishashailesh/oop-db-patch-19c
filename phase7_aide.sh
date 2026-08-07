#!/usr/bin/env bash
# =============================================================================
# phase7_aide.sh — Post-Patch AIDE Integrity Database Reset
# Run as: root
#
# After patching, Oracle home binaries have changed. The AIDE reference
# database must be regenerated so future integrity checks have a correct baseline.
#
# Two scenarios:
#   First run  : aide --init  → creates initial aide.db.new.gz
#   After patch: aide --update → compares against existing aide.db.gz,
#                                produces new aide.db.new.gz
# In both cases the new database is promoted to aide.db.gz as the master.
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
chmod 664 "${LOG_DIR}/phase7_aide.log" 2>/dev/null || true
exec >> "${LOG_DIR}/phase7_aide.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

log "=== PHASE 7: AIDE Integrity Database Reset ==="

# ── Verify AIDE is installed ──────────────────────────────────────────────────
if ! command -v aide &>/dev/null; then
  log "WARNING: aide command not found — skipping AIDE reset."
  log "Install with: dnf install -y aide"
  log "=== PHASE 7 SKIPPED (AIDE not installed) ==="
  exit 0
fi

AIDE_NEW_DB="/var/lib/aide/aide.db.new.gz"
AIDE_MASTER_DB="/var/lib/aide/aide.db.gz"
AIDE_TIMEOUT=3600
INTERVAL=30

# ── Determine whether to init or update ───────────────────────────────────────
if [[ -s "${AIDE_MASTER_DB}" ]]; then
  AIDE_CMD="--update"
  log "Mode: UPDATE — existing master database found at ${AIDE_MASTER_DB}"
  log "  Master DB size: $(stat -c%s ${AIDE_MASTER_DB}) bytes"
else
  AIDE_CMD="--init"
  log "Mode: INIT — no master database found, performing first-time initialization"
  log "  This creates the initial AIDE baseline from the current filesystem."
fi

# ── Run AIDE in background ────────────────────────────────────────────────────
log "Running: aide ${AIDE_CMD} (30-60 min expected)..."
# Only remove previous new.gz if master exists — if first-time init,
# preserve any existing aide.db.new.gz in case it was manually created
if [[ -s "${AIDE_MASTER_DB}" ]]; then
  rm -f "${AIDE_NEW_DB}"
  log "  Removed previous ${AIDE_NEW_DB} for clean update."
fi
aide "${AIDE_CMD}" &
AIDE_PID=$!
log "AIDE PID: ${AIDE_PID}"

# ── Wait for completion ────────────────────────────────────────────────────────
ELAPSED=0
while true; do
  if ! kill -0 "${AIDE_PID}" 2>/dev/null; then
    # Process has ended — check exit and output
    if [[ -s "${AIDE_NEW_DB}" ]]; then
      FILE_SIZE=$(stat -c%s "${AIDE_NEW_DB}")
      log "AIDE ${AIDE_CMD} complete. Output: ${AIDE_NEW_DB} (${FILE_SIZE} bytes)"
      break
    else
      # aide --update exits non-zero when differences found (normal after patching)
      # but still produces the output file. If file is missing, it's a real error.
      die "AIDE process ended but ${AIDE_NEW_DB} is empty or missing. " \
          "Check /var/log/aide/aide.log for details."
    fi
  fi
  ELAPSED=$(( ELAPSED + INTERVAL ))
  if (( ELAPSED >= AIDE_TIMEOUT )); then
    kill "${AIDE_PID}" 2>/dev/null || true
    die "AIDE timed out after ${AIDE_TIMEOUT}s."
  fi
  log "  AIDE running... ${ELAPSED}s elapsed"
  sleep "${INTERVAL}"
done

# ── Promote new database to master ────────────────────────────────────────────
log "Promoting new AIDE database to master reference..."
cp -f "${AIDE_NEW_DB}" "${AIDE_MASTER_DB}"
chmod 600 "${AIDE_MASTER_DB}"
MASTER_SIZE=$(stat -c%s "${AIDE_MASTER_DB}")
log "Master AIDE database: ${AIDE_MASTER_DB} (${MASTER_SIZE} bytes)"
log "Future aide --check runs will use this as the new baseline."

log "=== PHASE 7 COMPLETE ==="
