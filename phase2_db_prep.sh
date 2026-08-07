#!/usr/bin/env bash
# =============================================================================
# phase2_db_prep.sh — Build and patch new Database home
# Run as: oracle user (invoked via sudo -u oracle from orchestrator)
# =============================================================================
set -euo pipefail

# Inherit group-write for shared NFS staging area
umask 0002

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase2_db_prep.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== PHASE 2: Database Home Preparation ==="
log "New DB Home   : ${NEW_DB_HOME}"
log "Patch Location: ${PATCH_LOC}"

# ── 1. Verify prerequisites ──────────────────────────────────────────────────
log "Checking required zip files..."
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
log "All required files present."

# ── 2. Extract base DB software ──────────────────────────────────────────────
log "Extracting base Oracle DB 19.3 software into ${NEW_DB_HOME}..."
cd "${NEW_DB_HOME}"
unzip -q -o "${BASE_SW_DIR}/${DB_BASE_ZIP}" -d .
log "Base DB extraction complete."

# ── 3. Update OPatch ─────────────────────────────────────────────────────────
log "Updating OPatch in new DB home..."
rm -rf "${NEW_DB_HOME}/OPatch"
unzip -q -o "${PATCH_LOC}/${OPATCH_ZIP}" -d "${NEW_DB_HOME}/"
OPATCH_VER=$("${NEW_DB_HOME}/OPatch/opatch" version 2>/dev/null | grep "OPatch Version" | awk '{print $NF}')
log "OPatch version: ${OPATCH_VER}"

# ── 4. Extract standalone DB RU patch ────────────────────────────────────────
log "Extracting standalone DB patch ${DB_RU_STANDALONE_PATCH}..."
# Verify write permission on PATCH_LOC before attempting extraction
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
log "Standalone DB patch extracted."

# ── 5. Verify patch directories ──────────────────────────────────────────────
log "Verifying patch directories..."
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
log "All patch directories verified."

# ── 6. Prepare response file for new DB home ─────────────────────────────────
log "Preparing DB response file for new home..."
if [[ ! -f "${DB_RSP}" ]]; then
  log "ERROR: DB response file not found: ${DB_RSP}"
  exit 1
fi

# Create working copy in /tmp (writable by all users, unlike LOG_DIR)
DB_RSP_TMP="/tmp/db_install_$(date +%Y%m%d%H%M%S)_$$.rsp"
cp "${DB_RSP}" "${DB_RSP_TMP}"
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_DB_HOME}|" "${DB_RSP_TMP}"
log "Response file copy: ${DB_RSP_TMP}"
log "ORACLE_HOME set to: $(grep '^ORACLE_HOME=' ${DB_RSP_TMP})"

# ── 7. Run runInstaller with -applyRU ────────────────────────────────────────
log "Running runInstaller INSTALL_DB_SWONLY with RU ${DB_APPLY_RU_PATCH}..."
log "  -applyRU    : ${DB_APPLY_RU_PATH}"
log "  -applyOneOffs: ${DB_ONEOFF_PATHS_FULL}"
log "  -responseFile: ${DB_RSP_TMP}"

"${NEW_DB_HOME}/runInstaller" \
  -silent \
  -ignorePrereqFailure \
  -waitforcompletion \
  -applyRU "${DB_APPLY_RU_PATH}" \
  -applyOneOffs "${DB_ONEOFF_PATHS_FULL}" \
  -responseFile "${DB_RSP_TMP}" \
  ORACLE_HOME="${NEW_DB_HOME}"

log "runInstaller completed."

# ── 7. Stage AutoUpgrade JAR ─────────────────────────────────────────────────
if [[ -f "${AUTOUPGRADE_JAR}" ]]; then
  log "Staging AutoUpgrade JAR..."
  cp "${AUTOUPGRADE_JAR}" "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar"
  AU_VER=$("${NEW_DB_HOME}/jdk/bin/java" -jar "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar" -version 2>/dev/null | head -1)
  log "AutoUpgrade version: ${AU_VER}"
else
  log "WARNING: autoupgrade.jar not found at ${AUTOUPGRADE_JAR} — skipping stage."
fi

# ── 8. AutoUpgrade analyze (pre-check, online, no changes) ───────────────────
log "Running AutoUpgrade analyze (read-only pre-check)..."
"${NEW_DB_HOME}/jdk/bin/java" \
  -jar "${NEW_DB_HOME}/rdbms/admin/autoupgrade.jar" \
  -config "${AUTOUPGRADE_CFG}" \
  -mode analyze \
  -noconsole

log "AutoUpgrade analyze complete — review ${LOG_DIR} for any FAILED checks."

log "=== PHASE 2 COMPLETE ==="
