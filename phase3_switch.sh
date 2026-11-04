#!/usr/bin/env bash
# =============================================================================
# phase3_switch.sh — Grid and Database Home Switch (CRS_CONFIG)
# Run as: root
# Uses su - to switch to grid/oracle users (no sudoers required)
#
# Step 0a disables SYS.DB_DDL_ALERT_TRG (db/cdb/pdb) before the outage and
# AutoUpgrade; phase4 enables it again after patching.
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase3_switch.log" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "CRITICAL ERROR: $*"; exit 1; }
rungrid()   { su - "${GRID_USER}"   -c "unset LD_LIBRARY_PATH; $1"; }
runoracle() { su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH; $1"; }

# ── SYS.DB_DDL_ALERT_TRG: disabled before the outage (phase 3), enabled after patching (phase 4)
# Works for a non-CDB, or a CDB (root plus every READ WRITE PDB). Containers where the
# trigger does not exist are skipped. Returns non-zero if sqlplus fails.
ddl_trigger() {   # usage: ddl_trigger DISABLE|ENABLE <oracle_home> <oracle_sid>
  local action="$1" home="$2" sid="$3" rc=0 tag
  tag=$(mktemp -u XXXXXX)
  local info="/tmp/ddl_trg_${tag}_info.sql" body="/tmp/ddl_trg_${tag}_body.sql" one="/tmp/ddl_trg_${tag}_one.sql"
  local out logd
  out=$(mktemp /tmp/ddl_trg_XXXXXX.out)
  # Statement run in every container (non-CDB: once). Containers without the trigger are skipped.
  cat > "${body}" << 'SQLEOF'
SET SERVEROUTPUT ON
DECLARE
  v_cnt PLS_INTEGER;
BEGIN
  SELECT COUNT(*) INTO v_cnt FROM dba_triggers WHERE owner = 'SYS' AND trigger_name = 'DB_DDL_ALERT_TRG';
  IF v_cnt = 0 THEN
    DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || SYS_CONTEXT('USERENV','CON_NAME') || ': trigger not present, skipped');
  ELSE
    EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG __ACTION__';
    DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || SYS_CONTEXT('USERENV','CON_NAME') || ': __ACTION__ done');
  END IF;
END;
/
SQLEOF
  sed -i "s/__ACTION__/${action}/g" "${body}"
  # Is it a CDB, and are any PDBs not open READ WRITE (catcon only reaches open containers)?
  cat > "${info}" << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT 'CDB=' || cdb FROM v$database;
SELECT 'NOTRW=' || name || ' (' || open_mode || ')' FROM v$pdbs WHERE name <> 'PDB$SEED' AND open_mode <> 'READ WRITE';
EXIT
SQLEOF
  { echo "WHENEVER SQLERROR EXIT FAILURE"; cat "${body}"; echo "EXIT"; } > "${one}"
  chmod 644 "${body}" "${info}" "${one}"
  runoracle "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${info}
  " > "${out}" 2>&1 || rc=$?
  if (( rc == 0 )) && grep -q '^CDB=YES' "${out}"; then
    grep '^NOTRW=' "${out}" | while IFS= read -r l; do log "  WARNING: PDB ${l#NOTRW=} is not READ WRITE, trigger left unchanged there"; done
    logd=$(mktemp -d /tmp/ddl_trg_logs_XXXXXX); chmod 777 "${logd}"
    log "  CDB: ${action} in CDB\$ROOT and all open PDBs (catcon.pl, PDB\$SEED excluded)"
    runoracle "
      export ORACLE_HOME=${home}
      export ORACLE_SID=${sid}
      export PATH=\${ORACLE_HOME}/bin:\${PATH}
      \${ORACLE_HOME}/perl/bin/perl \${ORACLE_HOME}/rdbms/admin/catcon.pl -d /tmp -l ${logd} -b ddl_trg -C 'PDB\$SEED' $(basename "${body}")
    " > "${out}" 2>&1 || rc=$?
    { grep -h 'DB_DDL_ALERT_TRG' "${logd}"/*.log 2>/dev/null || true; } | sort -u | while IFS= read -r l; do log "  ${l}"; done
    if grep -lE 'ORA-[0-9]+|SP2-[0-9]+' "${logd}"/*.log >/dev/null 2>&1; then
      log "  ERROR: errors in catcon logs:"
      { grep -hE 'ORA-[0-9]+|SP2-[0-9]+' "${logd}"/*.log || true; } | sort -u | while IFS= read -r l; do log "    ${l}"; done
      rc=1
    fi
    [[ -z "$(ls "${logd}"/*.log 2>/dev/null)" ]] && { log "  ERROR: catcon produced no logs (see output below)"; cat "${out}" | while IFS= read -r l; do log "    ${l}"; done; rc=1; }
    rm -rf "${logd}"
  elif (( rc == 0 )); then
    runoracle "
      export ORACLE_HOME=${home}
      export ORACLE_SID=${sid}
      export PATH=\${ORACLE_HOME}/bin:\${PATH}
      \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${one}
    " > "${out}" 2>&1 || rc=$?
    while IFS= read -r l; do log "  ${l}"; done < "${out}"
  else
    while IFS= read -r l; do log "  ${l}"; done < "${out}"
  fi
  rm -f "${info}" "${body}" "${one}" "${out}"
  return "${rc}"
}

log "=== PHASE 3: Grid and Database Home Switch ==="

# -- Phase gate: Require phases 1 2 to have completed ------
require_phase_complete 1 2
log "Old Grid Home: ${OLD_GRID_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"
log "New DB Home  : ${NEW_DB_HOME}"

NODE_NAME=$(/usr/bin/hostname -s)
log "Node: ${NODE_NAME}"

# -- GI switch idempotency check ----------------------------------------------
# Check if CRS is already running from the new GI home. This happens when
# Phase 3 is re-run after a partial failure where Steps 1-6 completed but
# Step 7 (AutoUpgrade deploy) failed. In that case gridSetup.sh -switchGridHome
# will fail with [INS-45102] "cannot move from active clusterware home".
# Detect this and skip directly to AutoUpgrade deploy.
GI_SWITCH_DONE=false
OCSSD_HOME=$(ls -la /proc/$(pgrep -f ocssd.bin 2>/dev/null | head -1)/exe \
  2>/dev/null | awk '{print $NF}' | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null || true)
if [[ "${OCSSD_HOME}" == "${NEW_GRID_HOME}" ]]; then
  log "GI switch already complete -- ocssd.bin running from new home."
  log "  Skipping Steps 0-6 (listener stop, switchGridHome, root.sh, CRS verify)."
  log "  Proceeding directly to Step 7 (AutoUpgrade deploy)."
  GI_SWITCH_DONE=true
fi

if [[ "${GI_SWITCH_DONE}" != "true" ]]; then

# ── Step 0a: Disable SYS.DB_DDL_ALERT_TRG before the outage and AutoUpgrade ────
# The database is still up from the old home here. Phase 4 enables the trigger again.
log "Step 0a: Disabling SYS.DB_DDL_ALERT_TRG (non-CDB, or CDB root and open PDBs)..."
TRG_DB="${DB_NAME}"
if [[ -z "${TRG_DB}" ]]; then
  TRG_DB=$(rungrid "export ORACLE_HOME=${OLD_GRID_HOME}; export PATH=\${ORACLE_HOME}/bin:\${PATH}; srvctl list database 2>/dev/null | head -1" || true)
fi
[[ -z "${TRG_DB}" ]] && die "Could not determine the database name to disable SYS.DB_DDL_ALERT_TRG."
TRG_SID=$(rungrid "export ORACLE_HOME=${OLD_GRID_HOME}; export PATH=\${ORACLE_HOME}/bin:\${PATH}; srvctl status database -d ${TRG_DB} 2>/dev/null | grep -i \$(hostname -s) | awk '{print \$2}' | head -1" 2>/dev/null || true)
TRG_SID="${TRG_SID:-${TRG_DB}}"
log "  Database: ${TRG_DB}   Instance: ${TRG_SID}   Home: ${OLD_DB_HOME}"
ddl_trigger DISABLE "${OLD_DB_HOME}" "${TRG_SID}" \
  || die "Could not disable SYS.DB_DDL_ALERT_TRG (is the database open?). Nothing has been stopped yet; fix and re-run phase 3."

# The listener must be stopped before switchGridHome.
# NOTE: Do NOT shut down the database here. AutoUpgrade deploy mode handles
# the database shutdown and restart internally as part of its deploy workflow.
# Shutting down the database before AutoUpgrade deploy causes:
#   "Unable to connect to database -- ORA-01034: ORACLE not available"
# because AutoUpgrade needs to connect to the source home database first.
#
# Listener must be stopped as grid via srvctl — NOT as oracle via lsnrctl.
# Running lsnrctl stop as oracle fails with TNS-01190 on GI installations
# because the listener is a CRS-managed resource owned by the grid user.
log "Step 0: Stopping listener (OUTAGE START)..."
rungrid "
  export ORACLE_HOME=${OLD_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  echo 'Stopping listener...'
  \${ORACLE_HOME}/bin/srvctl stop listener -l LISTENER || echo 'stop listener returned non-zero (already stopped?) -- continuing'
  echo 'Verifying listener stopped:'
  \${ORACLE_HOME}/bin/srvctl status listener
"
log "  Listener stopped. Database left running for AutoUpgrade deploy."

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
# The file is created by root but read by gridSetup.sh running as ${GRID_USER}.
# cp keeps the template's mode (often 600), which causes "(Permission denied)".
# It may contain passwords, so hand it to the Grid owner and keep it private.
chown "${GRID_USER}:${INSTALL_GROUP}" "${SWITCH_RSP}"
chmod 600 "${SWITCH_RSP}"
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
  grep -vi "^#\|password" | while IFS= read -r line; do log "  ${line}"; done

# ── Step 2: gridSetup.sh -switchGridHome (as grid) ───────────────────────────
log "Step 2: gridSetup.sh -switchGridHome (as ${GRID_USER})..."
# gridSetup.sh exit codes: 0 = success, 6 = success with optional prerequisite
# warnings, anything else = failure. Capture the code so set -e does not abort
# on 6 (same handling as phase1 and phase2).
set +e
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/gridSetup.sh \
    -silent \
    -switchGridHome \
    -responseFile ${SWITCH_RSP}
"
SG_RC=$?
set -e
case "${SG_RC}" in
  0) ;;
  6) log "  Step 2: gridSetup.sh finished with warnings (exit code 6) -- continuing." ;;
  *) log "ERROR: Step 2: gridSetup.sh -switchGridHome FAILED with exit code ${SG_RC}."
     log "  Check the newest log under /u01/app/oraInventory/logs/GridSetupActions*/"
     exit 1 ;;
esac
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

fi # end if [[ "${GI_SWITCH_DONE}" != "true" ]]

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
# Read log dir from orcl_auto_patch.cfg to avoid duplication with patch.conf
AUTOUPGRADE_LOG_DIR=$(grep "^global.autoupg_log_dir=" "${AUTOUPGRADE_CFG}" \
  2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
DEPLOY_STATUS_LOG="${AUTOUPGRADE_LOG_DIR}/cfgtoollogs/upgrade/auto/status/status.log"
log "  Deploy status log: ${DEPLOY_STATUS_LOG}"
MAX_WAIT=3600; ELAPSED=0; SLEEP_INTERVAL=30

# Check immediately first — deploy may have completed during Java execution
if [[ -f "${DEPLOY_STATUS_LOG}" ]] && \
   grep -q "Status.*SUCCESS" "${DEPLOY_STATUS_LOG}" 2>/dev/null; then
  log "  AutoUpgrade deploy already completed successfully."
  grep -E "Status|Version Before|Version After|Duration" \
    "${DEPLOY_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
  ELAPSED=${MAX_WAIT}  # skip the polling loop
fi
while (( ELAPSED < MAX_WAIT )); do
  if [[ -f "${DEPLOY_STATUS_LOG}" ]]; then
    if grep -q "Status.*SUCCESS" "${DEPLOY_STATUS_LOG}" 2>/dev/null; then
      log "  AutoUpgrade deploy completed successfully."
      grep -E "Status|Version Before|Version After|Duration" \
        "${DEPLOY_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      ELAPSED=${MAX_WAIT}
      break
    elif grep -q "Status.*ERROR\|Status.*FAILED" "${DEPLOY_STATUS_LOG}" 2>/dev/null; then
      log "ERROR: AutoUpgrade deploy failed."
      cat "${DEPLOY_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      die "AutoUpgrade deploy failed -- review: ${AUTOUPGRADE_LOG_DIR}/"
    fi
  fi
  sleep ${SLEEP_INTERVAL}; (( ELAPSED += SLEEP_INTERVAL ))
  log "  Deploy in progress... ${ELAPSED}s elapsed"
done
if (( ELAPSED < MAX_WAIT )); then
  die "AutoUpgrade deploy timed out after ${MAX_WAIT}s"
fi

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

# ── Step 9: Verify CRS registration, oratab and olr.loc ──────────────────────
# The CRS agent maintains /etc/oratab for CRS-managed databases and oraenv
# resolves +ASM from /etc/oracle/olr.loc, so nothing is edited here: just
# verify and warn. Fix manually only if a WARNING appears.
log "Step 9: Verifying CRS registration and /etc/oratab..."
CRS_DB_HOME=$(runoracle "
  ${NEW_GRID_HOME}/bin/srvctl config database -d ${DB_NAME} 2>/dev/null \
    | awk -F': ' '/^Oracle home/ {print \$2}'
" || true)
log "  CRS Oracle home for ${DB_NAME}: ${CRS_DB_HOME:-unknown}"
if [[ "${CRS_DB_HOME}" != "${NEW_DB_HOME}" ]]; then
  log "  WARNING: CRS does not show ${NEW_DB_HOME} as the home of ${DB_NAME}."
fi
log "  /etc/oratab entries:"
{ grep -v '^#' /etc/oratab 2>/dev/null | grep -v '^$' || true; } | while IFS= read -r line; do log "    ${line}"; done
if grep -v '^#' /etc/oratab 2>/dev/null | grep -qF "${OLD_DB_HOME}"; then
  log "  WARNING: /etc/oratab still references ${OLD_DB_HOME}."
fi
OLR_HOME=$(grep -i '^crs_home=' /etc/oracle/olr.loc 2>/dev/null | cut -d= -f2 || true)
log "  olr.loc crs_home: ${OLR_HOME:-unknown}"
if [[ -n "${OLR_HOME}" && "${OLR_HOME}" != "${NEW_GRID_HOME}" ]]; then
  log "  WARNING: olr.loc crs_home is not ${NEW_GRID_HOME}."
fi

mark_phase_complete 3
log "=== PHASE 3 COMPLETE ==="
log ""
log "Verify with:"
log "  ${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
log "  ${NEW_GRID_HOME}/bin/crsctl stat res -t"
log "  sqlplus / as sysdba <<< \"SELECT patch_id,status FROM dba_registry_sqlpatch;\""
