#!/usr/bin/env bash
# =============================================================================
# phase2_db_prep.sh -- Build and patch new Database home
# Run as: oracle user (invoked via sudo -u oracle from orchestrator)
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase2_db_prep.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== PHASE 2: Database Home Preparation ==="
log "New DB Home   : ${NEW_DB_HOME}"
log "Patch Location: ${PATCH_LOC}"

# -- 1. Verify prerequisites --------------------------------------------------
log "Step 1: Checking required zip files..."
for f in \
  "${BASE_SW_DIR}/${DB_BASE_ZIP}" \
  "${PATCH_LOC}/${OPATCH_ZIP}" \
  "${PATCH_LOC}/${RU_COMBO_ZIP}" \
  "${PATCH_LOC}/${DB_RU_STANDALONE_ZIP}"; do
  if [[ ! -f "${f}" ]]; then
    log "ERROR: Required file not found: ${f}"
    exit 1
  fi
done
log "Step 1: All required files present."

# -- 2. Extract base DB software ----------------------------------------------
log "Step 2: Extracting base Oracle DB 19.3 software into ${NEW_DB_HOME}..."
cd "${NEW_DB_HOME}"
unzip -q -o "${BASE_SW_DIR}/${DB_BASE_ZIP}" -d .
log "Step 2: Base DB extraction complete."

# -- 3. Update OPatch ---------------------------------------------------------
log "Step 3: Updating OPatch in new DB home..."
rm -rf "${NEW_DB_HOME}/OPatch"
unzip -q -o "${PATCH_LOC}/${OPATCH_ZIP}" -d "${NEW_DB_HOME}/"
OPATCH_VER=$("${NEW_DB_HOME}/OPatch/opatch" version 2>/dev/null | grep "OPatch Version" | awk '{print $NF}')
log "Step 3: OPatch version: ${OPATCH_VER}"

# -- 4. Extract standalone DB RU patch ----------------------------------------
log "Step 4: Extracting standalone DB patch ${DB_RU_STANDALONE_PATCH}..."
if [[ ! -w "${PATCH_LOC}" ]]; then
  log "ERROR: No write permission on ${PATCH_LOC} for user $(whoami)."
  log "Fix with: chmod g+w ${PATCH_LOC}"
  exit 1
fi
unzip -q -o "${PATCH_LOC}/${DB_RU_STANDALONE_ZIP}" -d "${PATCH_LOC}/"
if [[ ! -d "${PATCH_LOC}/${DB_RU_STANDALONE_PATCH}" ]]; then
  log "ERROR: Standalone patch dir ${PATCH_LOC}/${DB_RU_STANDALONE_PATCH} not found after extraction."
  exit 1
fi
log "Step 4: Standalone DB patch extracted."

# -- 5. Verify patch directories ----------------------------------------------
log "Step 5: Verifying patch directories..."
for p in \
  "${DB_APPLY_RU_PATH}" \
  $(echo "${DB_ONEOFF_PATHS_FULL}" | tr ',' ' '); do
  if [[ ! -d "${p}" ]]; then
    log "ERROR: Patch directory not found: ${p}"
    log "  Check patch.conf:"
    log "    DB_ONEOFF_PATCHES (inside bundle)      : ${DB_ONEOFF_PATCHES}"
    log "    RU_COMBO_TOPLEVEL_PATCHES (top-level)  : ${RU_COMBO_TOPLEVEL_PATCHES}"
    log "    DB_RU_STANDALONE_PATCH (standalone)    : ${DB_RU_STANDALONE_PATCH}"
    log "  Available in bundle dir ${GI_RU_BUNDLE_DIR}:"
    ls "${GI_RU_BUNDLE_DIR}/" 2>/dev/null | sed 's/^/    /'
    log "  Available in RU combo dir ${RU_PATCH_DIR}:"
    ls "${RU_PATCH_DIR}/" 2>/dev/null | grep "^[0-9]" | sed 's/^/    /'
    exit 1
  fi
done
log "Step 5: All patch directories verified."

# -- 6. Prepare response file for new DB home ---------------------------------
log "Step 6: Preparing DB response file for new home..."
if [[ ! -f "${DB_RSP}" ]]; then
  log "ERROR: DB response file not found: ${DB_RSP}"
  exit 1
fi

DB_RSP_TMP="/tmp/db_install_$(date +%Y%m%d%H%M%S)_$$.rsp"
cp "${DB_RSP}" "${DB_RSP_TMP}"
trap 'rm -f "${DB_RSP_TMP}"' EXIT
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_DB_HOME}|" "${DB_RSP_TMP}"
log "Step 6: Response file copy: ${DB_RSP_TMP}"
log "Step 6: ORACLE_HOME set to: $(grep '^ORACLE_HOME=' ${DB_RSP_TMP})"

# -- 7. Run runInstaller with -applyRU ----------------------------------------
log "Step 7: Running runInstaller INSTALL_DB_SWONLY with RU ${DB_APPLY_RU_PATCH}..."
log "  -applyRU     : ${DB_APPLY_RU_PATH}"
log "  -applyOneOffs: ${DB_ONEOFF_PATHS_FULL}"
log "  -responseFile: ${DB_RSP_TMP}"

# ROOT CAUSE FIX: runInstaller exits non-zero when optional prerequisite warnings
# are present (e.g. [INS-13014] "Target environment does not meet some optional
# requirements"). With set -euo pipefail this silently kills the script right
# after runInstaller, skipping Steps 8 and 9 (AutoUpgrade JAR and analyze).
# Fix: capture the exit code explicitly and check the installer log for the
# "Successfully Setup Software" string to distinguish warnings from failures.
"${NEW_DB_HOME}/runInstaller" \
  -silent \
  -ignorePrereqFailure \
  -waitforcompletion \
  -applyRU "${DB_APPLY_RU_PATH}" \
  -applyOneOffs "${DB_ONEOFF_PATHS_FULL}" \
  -responseFile "${DB_RSP_TMP}" \
  ORACLE_HOME="${NEW_DB_HOME}" || {
    RI_RC=$?
    RI_LOG=$(ls -t /u01/app/oraInventory/logs/InstallActions*/installActions*.log \
      2>/dev/null | head -1 || true)
    if grep -q "Successfully Setup Software" "${RI_LOG}" 2>/dev/null; then
      log "  Step 7: runInstaller completed with warnings (exit code ${RI_RC}) — continuing."
      log "  [INS-13014] optional prerequisite warnings are expected and harmless."
      log "  Install log: ${RI_LOG}"
    else
      log "ERROR: Step 7: runInstaller FAILED with exit code ${RI_RC}."
      log "  Install log: ${RI_LOG:-not found}"
      log "  Review log for details before retrying."
      exit 1
    fi
  }

log "Step 7: runInstaller completed successfully."

# -- 8. Stage AutoUpgrade JAR -------------------------------------------------
# Hard failure -- AutoUpgrade is required for the deploy phase (phase3).
# Download from MOS Doc ID 2485457.1 and place at ${AUTOUPGRADE_JAR}.
log "Step 8: Staging AutoUpgrade JAR..."
if [[ ! -f "${AUTOUPGRADE_JAR}" ]]; then
  log "ERROR: autoupgrade.jar not found at ${AUTOUPGRADE_JAR}"
  log "  Download from: https://support.oracle.com (Doc ID 2485457.1)"
  log "  Place at: ${AUTOUPGRADE_JAR}"
  exit 1
fi
cp "${AUTOUPGRADE_JAR}" "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar"
AU_VER=$("${NEW_DB_HOME}/jdk/bin/java" \
  -jar "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar" \
  -version 2>/dev/null | grep "build.version" || true)
log "Step 8: AutoUpgrade JAR staged. Version: ${AU_VER}"

# -- 9. AutoUpgrade analyze (pre-check, online, no changes) -------------------
log "Step 9: Running AutoUpgrade analyze (read-only pre-check)..."

# ADR_BASE must be set -- AutoUpgrade calls kfod from the source home to check
# FRA free space. Without ADR_BASE, kfod fails with:
#   Error 49802 initializing ADR / could not initialize the diag context
# which causes COM-115 / DISK_SPACE_FOR_RECOVERY_AREA check failure.
export ADR_BASE="${ORACLE_BASE:-/u01/app/oracle}"

# Verify diag directory is owned by oracle
if [[ -d "${ADR_BASE}/diag" ]]; then
  DIAG_OWNER=$(stat -c '%U' "${ADR_BASE}/diag")
  if [[ "${DIAG_OWNER}" != "${ORACLE_USER}" ]]; then
    log "WARNING: ${ADR_BASE}/diag is owned by '${DIAG_OWNER}' not '${ORACLE_USER}'"
    log "  kfod ADR init will fail -- run as root: chown -R oracle:oinstall ${ADR_BASE}/diag"
  fi
fi

# Remove unrecognized parameter global.timezone_upg if present in the config
# (not a valid AutoUpgrade parameter -- causes harmless but noisy warnings)
if grep -q "timezone_upg" "${AUTOUPGRADE_CFG}" 2>/dev/null; then
  log "  Removing unrecognized 'global.timezone_upg' from AutoUpgrade config..."
  sed -i '/timezone_upg/d' "${AUTOUPGRADE_CFG}"
fi

"${NEW_DB_HOME}/jdk/bin/java" \
  -jar "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar" \
  -config "${AUTOUPGRADE_CFG}" \
  -mode analyze \
  -noconsole

# Wait for analyze jobs to complete and validate status log
log "Step 9: Waiting for AutoUpgrade analyze to complete..."
ANALYZE_STATUS_LOG="${ADR_BASE}/admin/upg_logs/cfgtoollogs/upgrade/auto/status/status.log"
MAX_WAIT=600
ELAPSED=0
SLEEP_INTERVAL=30

while (( ELAPSED < MAX_WAIT )); do
  if [[ -f "${ANALYZE_STATUS_LOG}" ]]; then
    if grep -q "Status.*SUCCESS" "${ANALYZE_STATUS_LOG}" 2>/dev/null; then
      log "Step 9: AutoUpgrade analyze completed successfully."
      grep -E "Status|Version Before|Version After|Stage Name|Duration" \
        "${ANALYZE_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      break
    elif grep -q "Status.*ERROR\|Status.*FAILED" "${ANALYZE_STATUS_LOG}" 2>/dev/null; then
      log "ERROR: Step 9: AutoUpgrade analyze FAILED -- do NOT proceed to phase3."
      cat "${ANALYZE_STATUS_LOG}" | while IFS= read -r line; do log "  ${line}"; done
      log "  Review: ${ADR_BASE}/admin/upg_logs/*/autoupgrade_*_user.log"
      exit 1
    fi
  fi
  sleep ${SLEEP_INTERVAL}
  (( ELAPSED += SLEEP_INTERVAL ))
  log "  Waiting for analyze... ${ELAPSED}s elapsed"
done

if (( ELAPSED >= MAX_WAIT )); then
  log "ERROR: Step 9: AutoUpgrade analyze timed out after ${MAX_WAIT}s."
  exit 1
fi

log "Step 9: AutoUpgrade analyze complete."
log "  Status log: ${ANALYZE_STATUS_LOG}"

log "=== PHASE 2 COMPLETE ==="
