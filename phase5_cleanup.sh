#!/usr/bin/env bash
# =============================================================================
# phase5_cleanup.sh — Deinstall old Grid and DB homes
# Run as: root
# WARNING: Only run after phase4 validation is complete and confirmed.
# Wait at least 24 hours post-patching before running cleanup.
# =============================================================================
set -euo pipefail

# Inherit group-write for shared NFS staging area
umask 0002

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase5_cleanup.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

log "=== PHASE 5: Old Home Cleanup ==="
log "Old Grid Home: ${OLD_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"

# Safety check — confirm new homes are active
log "Confirming new Grid home is active..."
ACTIVE_GI=$("${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null | grep -i "${NEW_PATCH_LEVEL}" || echo "")
if [[ -z "${ACTIVE_GI}" ]]; then
  die "New Grid home ${NEW_GRID_HOME} does not appear to be the active home. Aborting cleanup."
fi
log "New Grid home confirmed active."

# Safety check — confirm database running from new home
DB_HOME_ACTIVE=$("${NEW_GRID_HOME}/bin/crsctl" stat res ora.proddb.db -p 2>/dev/null | grep "ORACLE_HOME=${NEW_DB_HOME}" || echo "")
if [[ -z "${DB_HOME_ACTIVE}" ]]; then
  log "WARNING: Database resource does not show new DB home. Proceeding with caution."
fi

# ── Fix permissions on old Grid home for deinstall ────────────────────────────
log "Resetting permissions on old Grid home for deinstall..."
chmod -R 775 "${OLD_GRID_HOME}/"
chown -R "${GRID_USER}:${INSTALL_GROUP}" "${OLD_GRID_HOME}/"

# ── Deinstall old Grid home ────────────────────────────────────────────────────
log "Running deinstall dry-run for old Grid home..."
sudo -u "${GRID_USER}" -i bash -c "
  export CV_ASSUME_DISTID=OEL7.8
  export ORACLE_HOME=${OLD_GRID_HOME}
  export PATH=\$ORACLE_HOME/bin:\$PATH
  \$ORACLE_HOME/deinstall/deinstall -checkonly -silent 2>&1
" || log "WARNING: deinstall -checkonly returned non-zero."

log "Deinstalling old Grid home ${OLD_GRID_HOME}..."
sudo -u "${GRID_USER}" -i bash -c "
  export CV_ASSUME_DISTID=OEL7.8
  export ORACLE_HOME=${OLD_GRID_HOME}
  export PATH=\$ORACLE_HOME/bin:\$PATH
  echo 'y' | \$ORACLE_HOME/deinstall/deinstall -silent 2>&1
" || log "WARNING: Grid home deinstall returned non-zero — verify manually."

# ── Deinstall old DB home ──────────────────────────────────────────────────────
log "Deinstalling old DB home ${OLD_DB_HOME}..."
sudo -u "${ORACLE_USER}" -i bash -c "
  export ORACLE_HOME=${OLD_DB_HOME}
  export PATH=\$ORACLE_HOME/bin:\$PATH
  echo 'y' | \$ORACLE_HOME/deinstall/deinstall -silent 2>&1
" || log "WARNING: DB home deinstall returned non-zero — verify manually."

# ── Remove residual directories ────────────────────────────────────────────────
log "Removing old Grid version directory..."
OLD_GRID_VER_DIR=$(dirname "${OLD_GRID_HOME}")
if [[ -d "${OLD_GRID_VER_DIR}" ]]; then
  DU=$(du -sh "${OLD_GRID_VER_DIR}" 2>/dev/null | awk '{print $1}')
  log "Removing ${OLD_GRID_VER_DIR} (${DU})..."
  rm -rf "${OLD_GRID_VER_DIR}"
fi

log "Removing old DB home directory..."
if [[ -d "${OLD_DB_HOME}" ]]; then
  DU=$(du -sh "${OLD_DB_HOME}" 2>/dev/null | awk '{print $1}')
  log "Removing ${OLD_DB_HOME} (${DU})..."
  rm -rf "${OLD_DB_HOME}"
fi

# ── Remove swap file if still present ─────────────────────────────────────────
if swapon --show | grep -q "/swapfile"; then
  log "Removing temporary swap file..."
  swapoff /swapfile
  rm -f /swapfile
  sed -i '/swapfile/d' /etc/fstab
  log "Swap file removed."
fi

# ── Final verification ─────────────────────────────────────────────────────────
log "Final verification..."
[[ ! -d "${OLD_GRID_HOME}" ]] && log "Old Grid home removed: OK" || log "WARNING: ${OLD_GRID_HOME} still exists."
[[ ! -d "${OLD_DB_HOME}" ]]   && log "Old DB home removed: OK"   || log "WARNING: ${OLD_DB_HOME} still exists."
[[ -d "${NEW_GRID_HOME}" ]]   && log "New Grid home exists: OK"  || log "ERROR: ${NEW_GRID_HOME} missing!"
[[ -d "${NEW_DB_HOME}" ]]     && log "New DB home exists: OK"    || log "ERROR: ${NEW_DB_HOME} missing!"

cat /u01/app/oraInventory/ContentsXML/inventory.xml | grep -i "HOME NAME\|LOC="

log "=== PHASE 5 COMPLETE ==="
