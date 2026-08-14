#!/usr/bin/env bash
# =============================================================================
# phase3_switch.sh — Grid and Database Home Switch (CRS_CONFIG)
# Run as: root
# Uses su - to switch to grid/oracle users (no sudoers required)
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase3_switch.log" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "CRITICAL ERROR: $*"; exit 1; }
rungrid()   { su - "${GRID_USER}"   -c "$1"; }
runoracle() { su - "${ORACLE_USER}" -c "$1"; }

log "=== PHASE 3: Grid and Database Home Switch (CRS_CONFIG) ==="
log "Old Grid Home: ${OLD_GRID_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"
log "New DB Home  : ${NEW_DB_HOME}"

NODE_NAME=$(/usr/bin/hostname -s)
log "Node: ${NODE_NAME}"

# ── Step 1: gridSetup.sh -switchGridHome (as grid) ───────────────────────────
log "Step 1: gridSetup.sh -switchGridHome (as ${GRID_USER})..."
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/gridSetup.sh \
    -silent \
    -switchGridHome \
    oracle.install.crs.config.clusterNodes=${NODE_NAME}
"
log "gridSetup.sh -switchGridHome complete."

# ── Step 2: root.sh from new Grid home (as root) ─────────────────────────────
log "Step 2: Running root.sh from new Grid home..."
"${NEW_GRID_HOME}/root.sh"
log "Grid home root.sh complete."

# ── Step 2b: root.sh from new DB home (as root) ───────────────────────────────
# Required after runInstaller INSTALL_DB_SWONLY in Phase 2.
# Must run AFTER Grid home root.sh so the new Grid stack is active.
log "Step 2b: Running root.sh from new DB home..."
"${NEW_DB_HOME}/root.sh"
log "DB home root.sh complete."

# ── Step 3: Verify Grid ───────────────────────────────────────────────────────
log "Step 3: Verifying Grid resources (waiting 30s for stack to stabilise)..."
sleep 30

log "CRS release patch level:"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch

log "CRS resource status:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t

log "CRS init resources:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t -init

# ── Step 4: Update grid user profiles ────────────────────────────────────────
log "Step 4: Updating grid user profiles..."
GRID_HOME_DIR=$(eval echo ~${GRID_USER})
for profile in "${GRID_HOME_DIR}/.bash_profile" "${GRID_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    sed -i "s|${OLD_GRID_HOME}|${NEW_GRID_HOME}|g" "${profile}"
    log "  Updated: ${profile}"
  fi
done

# ── Step 5: AutoUpgrade deploy (as oracle) ────────────────────────────────────
log "Step 5: AutoUpgrade deploy — DB home switch + datapatch..."
log "  Config   : ${AUTOUPGRADE_CFG}"
log "  New Home : ${NEW_DB_HOME}"

# Auto-detect DB name if not set in patch.conf
if [[ -z "${DB_NAME}" ]]; then
  DB_NAME=$(runoracle "
    export ORACLE_HOME=${NEW_GRID_HOME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/srvctl list database 2>/dev/null | head -1
  " || true)
  [[ -z "${DB_NAME}" ]] && die "Could not detect database name via srvctl."
  log "  Auto-detected database: ${DB_NAME}"
fi
log "  Database: ${DB_NAME}"

runoracle "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${DB_NAME}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/jdk/bin/java \
    -jar \${ORACLE_HOME}/rdbms/admin/autoupgrade.jar \
    -config ${AUTOUPGRADE_CFG} \
    -mode deploy \
    -noconsole
"
log "AutoUpgrade deploy complete."

# ── Step 6: Update oracle user profiles ───────────────────────────────────────
log "Step 6: Updating oracle user profiles..."
ORACLE_HOME_DIR=$(eval echo ~${ORACLE_USER})
for profile in "${ORACLE_HOME_DIR}/.bash_profile" "${ORACLE_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    sed -i "s|${OLD_DB_HOME}|${NEW_DB_HOME}|g" "${profile}"
    log "  Updated: ${profile}"
  fi
done

log "=== PHASE 3 COMPLETE ==="
log ""
log "Verify with:"
log "  ${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
log "  ${NEW_GRID_HOME}/bin/crsctl stat res -t"
log "  sqlplus / as sysdba <<< \"SELECT patch_id,status FROM dba_registry_sqlpatch;\""
