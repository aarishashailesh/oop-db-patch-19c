#!/usr/bin/env bash
# =============================================================================
# phase1_grid_prep.sh -- Build and patch new Grid Infrastructure home
# Run as: grid user (invoked via sudo -u grid from orchestrator)
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase1_grid_prep.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== PHASE 1: Grid Home Preparation ==="
log "New Grid Home : ${NEW_GRID_HOME}"
log "Patch Location: ${PATCH_LOC}"

# Phase gate: Phase 1 has no prerequisites (it is the first phase)

# -- 0. Idempotency check -----------------------------------------------------
# If the new GI home exists and opatch lspatches shows the target RU patch,
# Phase 1 is already complete -- skip it cleanly.
# Note: opatch lspatches works correctly after a successful run because Step 11
# runs UpdateLocalInventory. If a previous run died BEFORE Step 11, the home
# will exist but opatch will show base 19.3 -- in that case we exit with
# diagnostic information rather than re-running gridSetup.sh (which fails
# with [INS-32826] on an already-registered home).
if [[ -f "${NEW_GRID_HOME}/OPatch/opatch" ]]; then
  log "Step 0: New GI home already exists -- checking patch level..."
  EXISTING_PATCHES=$("${NEW_GRID_HOME}/OPatch/opatch" lspatches 2>/dev/null || true)
  if echo "${EXISTING_PATCHES}" | grep -q "${GI_APPLY_RU_PATCH}"; then
    log "Step 0: New GI home already patched at target level -- Phase 1 complete."
    log "  Found: $(echo "${EXISTING_PATCHES}" | grep "${GI_APPLY_RU_PATCH}")"
    log "=== PHASE 1 COMPLETE (already done -- skipped) ==="
    mark_phase_complete 1
    exit 0
  else
    log "Step 0: New GI home exists but OPatch inventory shows base 19.3."
    log "  A previous run likely failed after patching but before Step 11."
    log "  Check .patch_storage to determine actual state:"
    ls "${NEW_GRID_HOME}/.patch_storage/" 2>/dev/null | grep "^[0-9]" | \
      while IFS= read -r line; do log "    ${line}"; done
    log ""
    log "  If .patch_storage shows ${GI_APPLY_RU_PATCH}_* the binaries are patched."
    log "  Run as grid to fix the OPatch inventory then re-run the orchestrator:"
    log "    ${NEW_GRID_HOME}/OPatch/opatch util UpdateLocalInventory -oh ${NEW_GRID_HOME} -silent"
    log "  If .patch_storage does NOT show ${GI_APPLY_RU_PATCH}_* restore from snapshot."
    exit 1
  fi
fi
log "Step 0: New GI home does not exist yet -- proceeding with Phase 1."

# -- 1. Verify prerequisites --------------------------------------------------
log "Step 1: Checking required zip files..."
for f in \
  "${BASE_SW_DIR}/${GRID_BASE_ZIP}" \
  "${PATCH_LOC}/${OPATCH_ZIP}" \
  "${PATCH_LOC}/${RU_COMBO_ZIP}"; do
  if [[ ! -f "${f}" ]]; then
    log "ERROR: Required file not found: ${f}"
    exit 1
  fi
done
log "Step 1: All required files present."

# -- 2. Check disk space (need 15 GB free) ------------------------------------
log "Step 2: Checking disk space..."
SPACE_CHECK_DIR=$(dirname "${NEW_GRID_HOME}")
AVAIL_GB=$(df -BG "${SPACE_CHECK_DIR}" | awk 'NR==2 {gsub("G","",$4); print $4}')
if (( AVAIL_GB < 15 )); then
  log "ERROR: Insufficient disk space. Need 15 GB, found ${AVAIL_GB} GB on ${SPACE_CHECK_DIR}"
  exit 1
fi
log "Step 2: Disk space OK: ${AVAIL_GB} GB available on ${SPACE_CHECK_DIR}."

# -- 3. Extract base Grid software --------------------------------------------
log "Step 3: Extracting base Grid 19.3 software into ${NEW_GRID_HOME}..."
unzip -q -o "${BASE_SW_DIR}/${GRID_BASE_ZIP}" -d "${NEW_GRID_HOME}/"
log "Step 3: Base Grid extraction complete."

# -- 4. Update OPatch ---------------------------------------------------------
log "Step 4: Updating OPatch in new Grid home..."
rm -rf "${NEW_GRID_HOME}/OPatch"
unzip -q -o "${PATCH_LOC}/${OPATCH_ZIP}" -d "${NEW_GRID_HOME}/"
OPATCH_VER=$("${NEW_GRID_HOME}/OPatch/opatch" version 2>/dev/null \
  | grep "OPatch Version" | awk '{print $NF}')
log "Step 4: OPatch version: ${OPATCH_VER}"

# -- 5. Extract RU Combo patch ------------------------------------------------
log "Step 5: Extracting RU combo patch ${RU_COMBO_PATCH}..."
unzip -q -o "${PATCH_LOC}/${RU_COMBO_ZIP}" -d "${PATCH_LOC}/"
log "Step 5: RU combo extraction complete."

# -- 6. Verify patch directories exist ----------------------------------------
log "Step 6: Verifying patch directory structure..."
for p in \
  "${GI_APPLY_RU_PATH}" \
  $(echo "${GI_ONEOFF_PATHS}" | tr ',' ' '); do
  if [[ ! -d "${p}" ]]; then
    log "ERROR: Patch directory not found: ${p}"
    exit 1
  fi
done
log "Step 6: All patch directories verified."

# -- 7. Prepare response file for new Grid home -------------------------------
log "Step 7: Preparing Grid response file for new home..."
if [[ ! -f "${GRID_RSP}" ]]; then
  log "ERROR: Grid response file not found: ${GRID_RSP}"
  exit 1
fi

GRID_RSP_TMP="/tmp/grid_install_$(date +%Y%m%d%H%M%S)_$$.rsp"
cp "${GRID_RSP}" "${GRID_RSP_TMP}"
trap 'rm -f "${GRID_RSP_TMP}"' EXIT

# CRITICAL: Set ORACLE_HOME to new home -- this determines the paths stamped
# into root.sh, rootmacro.sh, and rootconfig.sh. Using the old home here
# causes all three scripts to reference the old home making root.sh fail
# after switchGridHome and requiring manual sed fixes.
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_GRID_HOME}|" "${GRID_RSP_TMP}"

# Set CRS_SWONLY in the response file (belt-and-suspenders alongside CLI arg)
sed -i "s|^oracle.install.option=.*|oracle.install.option=CRS_SWONLY|" "${GRID_RSP_TMP}"

# Set clusterNodes (required per gridsetup.rsp Section D for CRS_SWONLY)
LOCAL_NODE=$(/usr/bin/hostname -s)
sed -i "s|^oracle.install.crs.config.clusterNodes=.*|oracle.install.crs.config.clusterNodes=${LOCAL_NODE}|" \
  "${GRID_RSP_TMP}"

log "Step 7: Response file ready: ${GRID_RSP_TMP}"
log "Step 7: Critical values (passwords excluded from log):"
# Exclude Password lines to avoid printing ASM/monitor credentials in the log
grep -E "^oracle.install.option|^ORACLE_HOME|^oracle.install.asm\.OS|^oracle.install.crs.config.clusterNodes" \
  "${GRID_RSP_TMP}" | grep -v "^#" | while IFS= read -r line; do log "  ${line}"; done

# -- 8. Run gridSetup.sh with CRS_SWONLY + -applyRU --------------------------
log "Step 8: Running gridSetup.sh CRS_SWONLY with RU ${GI_APPLY_RU_PATCH}..."
log "  -applyRU     : ${GI_APPLY_RU_PATH}"
log "  -applyOneOffs: ${GI_ONEOFF_PATHS}"
log "  -responseFile: ${GRID_RSP_TMP}"

# gridSetup.sh exits non-zero for optional prerequisite warnings (e.g. INS-13014)
# even when all patches are applied successfully. With set -euo pipefail this
# kills the script before Steps 9-11 run. Fix: capture exit code and check
# the installer log for actual success/failure.
"${NEW_GRID_HOME}/gridSetup.sh" \
  -silent \
  -ignorePrereqFailure \
  -waitforcompletion \
  -applyRU "${GI_APPLY_RU_PATH}" \
  -applyOneOffs "${GI_ONEOFF_PATHS}" \
  -responseFile "${GRID_RSP_TMP}" \
  oracle.install.option=CRS_SWONLY || {
    GS_RC=$?
    GS_LOG=$(ls -t /u01/app/oraInventory/logs/GridSetupActions*/installerPatchActions*.log \
      2>/dev/null | head -1 || true)
    GS_MAIN=$(ls -t /u01/app/oraInventory/logs/GridSetupActions*/installActions*.log \
      2>/dev/null | head -1 || true)
    if grep -qE "Successfully applied the patch|Successfully Setup Software" \
        "${GS_LOG}" 2>/dev/null || \
       grep -q "Successfully Setup Software" "${GS_MAIN}" 2>/dev/null; then
      log "  Step 8: gridSetup.sh exited with code ${GS_RC} -- patches applied successfully."
      log "  Optional prerequisite warnings are expected and harmless."
      log "  Patch log: ${GS_LOG:-not found}"
    else
      log "ERROR: Step 8: gridSetup.sh FAILED with exit code ${GS_RC}."
      log "  Patch log : ${GS_LOG:-not found}"
      log "  Install log: ${GS_MAIN:-not found}"
      exit 1
    fi
  }

log "Step 8: gridSetup.sh completed."

# -- 9. Verify binary integrity -----------------------------------------------
log "Step 9: Verifying new Grid home binary integrity..."
ZERO_COUNT=$(find "${NEW_GRID_HOME}/bin" -size 0 2>/dev/null | wc -l)
log "  Zero-byte files in bin/: ${ZERO_COUNT}"
for critical in lsnrctl oracle; do
  FSIZE=$(stat -c%s "${NEW_GRID_HOME}/bin/${critical}" 2>/dev/null || echo 0)
  if (( FSIZE == 0 )); then
    log "ERROR: Critical binary ${critical} is zero bytes -- extraction failed."
    exit 1
  fi
  # Use ls -lh for human-readable size (no numfmt dependency, no stdin hang)
  FSIZE_HR=$(ls -lh "${NEW_GRID_HOME}/bin/${critical}" 2>/dev/null | awk '{print $5}')
  log "  ${critical}: ${FSIZE_HR}"
done
log "Step 9: Binary integrity OK."

# -- 10. Verify root.sh script paths ------------------------------------------
log "Step 10: Verifying root.sh script paths in new Grid home..."
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
      log "  ERROR: ${REMAINING} old home reference(s) remain in ${script}"
      exit 1
    fi
    log "  FIXED: $(basename ${script})"
  else
    log "  OK: $(basename ${script})"
  fi
done
log "Step 10: Root script verification complete."

# -- 11. Verify and update OPatch inventory -----------------------------------
# After gridSetup.sh -applyRU the OPatch inventory may still show base 19.3
# if the installer exited before completing inventory registration. Fix with
# UpdateLocalInventory which refreshes from .patch_storage.
log "Step 11: Verifying OPatch patch inventory..."
OPATCH_OUT=$("${NEW_GRID_HOME}/OPatch/opatch" lspatches 2>/dev/null || true)

if echo "${OPATCH_OUT}" | grep -q "${GI_APPLY_RU_PATCH}"; then
  log "Step 11: OPatch inventory correct -- target patches confirmed."
  echo "${OPATCH_OUT}" | while IFS= read -r line; do log "  ${line}"; done
else
  log "Step 11: OPatch shows base 19.3 -- updating inventory from .patch_storage..."
  "${NEW_GRID_HOME}/OPatch/opatch" util UpdateLocalInventory \
    -oh "${NEW_GRID_HOME}" -silent 2>&1 | \
    while IFS= read -r line; do log "  ${line}"; done

  OPATCH_OUT2=$("${NEW_GRID_HOME}/OPatch/opatch" lspatches 2>/dev/null || true)
  if echo "${OPATCH_OUT2}" | grep -q "${GI_APPLY_RU_PATCH}"; then
    log "Step 11: OPatch inventory updated successfully."
    echo "${OPATCH_OUT2}" | while IFS= read -r line; do log "  ${line}"; done
  else
    log "  WARNING: Inventory still shows base 19.3 after UpdateLocalInventory."
    log "  Patches are confirmed in .patch_storage -- proceeding."
    log "  Inventory will self-correct after switchGridHome and root.sh."
  fi
fi

log "=== PHASE 1 COMPLETE ==="
log "Next: orchestrator will run ${NEW_GRID_HOME}/root.sh as root."
mark_phase_complete 1
