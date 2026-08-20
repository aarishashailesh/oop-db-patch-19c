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

log "=== PHASE 3: Grid and Database Home Switch ==="
log "Old Grid Home: ${OLD_GRID_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"
log "New DB Home  : ${NEW_DB_HOME}"

NODE_NAME=$(/usr/bin/hostname -s)
log "Node: ${NODE_NAME}"

# ── Step 0: Stop database and listener (OUTAGE BEGINS) ───────────────────────
# Listener must be stopped as grid via srvctl — NOT as oracle via lsnrctl.
# Running lsnrctl stop as oracle fails with TNS-01190 on GI installations
# because the listener is a CRS-managed resource owned by the grid user.
log "Step 0: Stopping database and listener (OUTAGE START)..."
rungrid "
  export ORACLE_HOME=${OLD_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  echo 'Stopping database ${DB_NAME}...'
  \${ORACLE_HOME}/bin/srvctl stop database -d ${DB_NAME}
  echo 'Stopping listener...'
  \${ORACLE_HOME}/bin/srvctl stop listener -l LISTENER
  echo 'Verifying listener stopped:'
  \${ORACLE_HOME}/bin/srvctl status listener
"
# Verify database pmon is gone
if pgrep -f "ora_pmon_${DB_NAME}" > /dev/null 2>&1; then
  die "ora_pmon_${DB_NAME} still running after shutdown — aborting."
fi
log "  Database and listener confirmed stopped."

# ── Step 1: Create switchGridHome response file ───────────────────────────────
# CRITICAL: switchGridHome requires a response file with correct ASM group names.
# Passing groups as CLI parameters causes [INS-41885] even when values are
# correct — the installer reads groups from OCR internally and conflicts with
# CLI values. Response file is the only reliable method.
#
# The group names (GI_OSDBA_GROUP etc.) are defined in patch.conf.
# IMPORTANT: This environment uses 'asmbba' not the standard 'asmdba'.
# Always verify from original grid_install.rsp before patching:
#   grep -i "osdba\|osasm\|osoper" /u01/rsp/grid_install.rsp
log "Step 1: Creating switchGridHome response file..."
SWITCH_RSP="/tmp/switch_grid_$(date +%Y%m%d%H%M%S)_$$.rsp"
trap 'rm -f "${SWITCH_RSP}"' EXIT

cp "${GRID_RSP}" "${SWITCH_RSP}"
sed -i "s|^oracle.install.asm.OSDBA=.*|oracle.install.asm.OSDBA=${GI_OSDBA_GROUP}|g" \
  "${SWITCH_RSP}"
sed -i "s|^oracle.install.asm.OSOPER=.*|oracle.install.asm.OSOPER=${GI_OSOPER_GROUP}|g" \
  "${SWITCH_RSP}"
sed -i "s|^oracle.install.asm.OSASM=.*|oracle.install.asm.OSASM=${GI_OSASM_GROUP}|g" \
  "${SWITCH_RSP}"
sed -i "s|^oracle.install.option=.*|oracle.install.option=CRS_SWONLY|g" \
  "${SWITCH_RSP}"

log "  switchGridHome response file: ${SWITCH_RSP}"
grep -E "^oracle.install.asm\.|^oracle.install.option" "${SWITCH_RSP}" | \
  grep -v "^#" | while IFS= read -r line; do log "  ${line}"; done

# ── Step 2: gridSetup.sh -switchGridHome (as grid) ───────────────────────────
log "Step 2: gridSetup.sh -switchGridHome (as ${GRID_USER})..."
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/gridSetup.sh \
    -silent \
    -switchGridHome \
    -responseFile ${SWITCH_RSP}
"
log "gridSetup.sh -switchGridHome complete."

# Verify inventory shows new home with CRS=true
INVENTORY_XML="/u01/app/oraInventory/ContentsXML/inventory.xml"
if grep -q "${NEW_GRID_HOME}.*CRS=\"true\"" "${INVENTORY_XML}" 2>/dev/null; then
  log "  Inventory confirmed: new GI home has CRS=true"
else
  log "  WARNING: New GI home does not show CRS=true in inventory.xml — verify manually."
  grep -E "19\.(3[012])" "${INVENTORY_XML}" 2>/dev/null | \
    while IFS= read -r line; do log "  ${line}"; done
fi

# ── Step 3: Verify root.sh script paths BEFORE running root.sh ───────────────
# CRITICAL: gridSetup.sh -applyRU (phase1) generates root.sh, rootmacro.sh,
# and rootconfig.sh with whatever ORACLE_HOME was in the response file at that
# time. If CRS_SWONLY + new home path were not set correctly in phase1, these
# scripts will reference the OLD home and root.sh will fail with CLSRSC-901
# (destination home same as configured home) or run entirely from the old home.
# Always verify and fix BEFORE running root.sh.
log "Step 3: Verifying root.sh script paths (CRITICAL pre-check)..."
ROOT_SCRIPTS=(
  "${NEW_GRID_HOME}/root.sh"
  "${NEW_GRID_HOME}/install/utl/rootmacro.sh"
  "${NEW_GRID_HOME}/crs/config/rootconfig.sh"
)
for script in "${ROOT_SCRIPTS[@]}"; do
  if [[ ! -f "${script}" ]]; then
    log "  WARNING: Script not found: ${script}"
    continue
  fi
  OLD_COUNT=$(grep -c "${OLD_GRID_HOME}" "${script}" 2>/dev/null || true)
  if (( OLD_COUNT > 0 )); then
    log "  FIXING: ${OLD_COUNT} old home reference(s) in $(basename ${script})"
    sed -i "s|${OLD_GRID_HOME}|${NEW_GRID_HOME}|g" "${script}"
    REMAINING=$(grep -c "${OLD_GRID_HOME}" "${script}" 2>/dev/null || true)
    if (( REMAINING > 0 )); then
      die "${REMAINING} old home reference(s) remain in ${script} after fix — aborting."
    fi
    log "  FIXED: $(basename ${script})"
  else
    log "  OK: $(basename ${script})"
  fi
done
log "  All root scripts verified — safe to run root.sh."

# ── Step 4: root.sh from new Grid home (as root) ─────────────────────────────
log "Step 4: Running root.sh from new Grid home (3-10 min expected)..."
"${NEW_GRID_HOME}/root.sh" || die "root.sh failed — review: ${GRID_BASE}/crsdata/$(hostname -s)/crsconfig/rootcrs_*.log"
log "root.sh complete."

# ── Step 5: Verify CRS is online on new home ─────────────────────────────────
log "Step 5: Verifying CRS is online on new home..."
sleep 15
MAX_WAIT=180; ELAPSED=0
while (( ELAPSED < MAX_WAIT )); do
  if "${NEW_GRID_HOME}/bin/crsctl" check crs 2>/dev/null | \
      grep -q "CRS-4537: Cluster Ready Services is online"; then
    log "  CRS is online."
    break
  fi
  sleep 10; (( ELAPSED += 10 ))
  log "  Waiting for CRS... ${ELAPSED}s"
done
(( ELAPSED >= MAX_WAIT )) && die "CRS did not come online within ${MAX_WAIT}s after root.sh"

log "CRS release patch level:"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch

log "CRS resource status:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t

log "CRS init resources:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t -init

# ── Step 6: Update grid user profiles ────────────────────────────────────────
log "Step 6: Updating grid user profiles..."
GRID_HOME_DIR=$(eval echo ~${GRID_USER})
for profile in "${GRID_HOME_DIR}/.bash_profile" "${GRID_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    sed -i "s|${OLD_GRID_HOME}|${NEW_GRID_HOME}|g" "${profile}"
    log "  Updated: ${profile}"
  fi
done

# ── Step 7: AutoUpgrade deploy (as oracle) ────────────────────────────────────
# NOTE: runInstaller -switchOracleHome and its root.sh are NOT needed when
# using AutoUpgrade -mode deploy. AutoUpgrade handles the DB home switch
# internally. This is confirmed by Oracle documentation and the workplace
# reference document — deploy goes directly to AutoUpgrade without any
# runInstaller -switchOracleHome step.
log "Step 7: AutoUpgrade deploy — DB home switch + datapatch..."
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
  export ORACLE_BASE=${ORACLE_BASE}
  export ADR_BASE=${ORACLE_BASE}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/jdk/bin/java \
    -jar \${ORACLE_HOME}/rdbms/admin/autoupgrade.jar \
    -config ${AUTOUPGRADE_CFG} \
    -mode deploy \
    -noconsole
"

# Wait for AutoUpgrade deploy to complete
log "  Waiting for AutoUpgrade deploy to complete (up to 60 min)..."
DEPLOY_STATUS_LOG="${ORACLE_BASE}/admin/upg_logs/cfgtoollogs/upgrade/auto/status/status.log"
MAX_WAIT=3600; ELAPSED=0; SLEEP_INTERVAL=30
while (( ELAPSED < MAX_WAIT )); do
  if [[ -f "${DEPLOY_STATUS_LOG}" ]]; then
    if grep -q "Status.*SUCCESS" "${DEPLOY_STATUS_LOG}" 2>/dev/null; then
      log "  AutoUpgrade deploy completed successfully."
      grep -E "Status|Version Before|Version After|Duration" \
        "${DEPLOY_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      break
    elif grep -q "Status.*ERROR\|Status.*FAILED" "${DEPLOY_STATUS_LOG}" 2>/dev/null; then
      log "ERROR: AutoUpgrade deploy failed."
      cat "${DEPLOY_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      die "AutoUpgrade deploy failed — review: ${ORACLE_BASE}/admin/upg_logs/"
    fi
  fi
  sleep ${SLEEP_INTERVAL}; (( ELAPSED += SLEEP_INTERVAL ))
  log "  Deploy in progress... ${ELAPSED}s elapsed"
done
(( ELAPSED >= MAX_WAIT )) && die "AutoUpgrade deploy timed out after ${MAX_WAIT}s"

log "AutoUpgrade deploy complete."

# ── Step 8: Update oracle user profiles ───────────────────────────────────────
log "Step 8: Updating oracle user profiles..."
ORACLE_HOME_DIR=$(eval echo ~${ORACLE_USER})
for profile in "${ORACLE_HOME_DIR}/.bash_profile" "${ORACLE_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    sed -i "s|${OLD_DB_HOME}|${NEW_DB_HOME}|g" "${profile}"
    log "  Updated: ${profile}"
  fi
done

# Ensure ADR_BASE is in oracle profile (prevents kfod ADR errors on next run)
ORACLE_HOME_DIR=$(eval echo ~${ORACLE_USER})
if ! grep -q "ADR_BASE" "${ORACLE_HOME_DIR}/.bash_profile" 2>/dev/null; then
  echo "export ADR_BASE=${ORACLE_BASE}" >> "${ORACLE_HOME_DIR}/.bash_profile"
  log "  Added ADR_BASE to ${ORACLE_HOME_DIR}/.bash_profile"
fi

log "=== PHASE 3 COMPLETE ==="
log ""
log "Verify with:"
log "  ${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
log "  ${NEW_GRID_HOME}/bin/crsctl stat res -t"
log "  sqlplus / as sysdba <<< \"SELECT patch_id,status FROM dba_registry_sqlpatch;\""
