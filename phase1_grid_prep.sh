#!/usr/bin/env bash
# =============================================================================
# phase1_grid_prep.sh — Build and patch new Grid home
# Run as: grid user (invoked via sudo -u grid from orchestrator)
# =============================================================================
set -euo pipefail

# Inherit group-write for shared NFS staging area
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
# shellcheck source=patch.conf
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase1_grid_prep.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== PHASE 1: Grid Home Preparation ==="
log "New Grid Home : ${NEW_GRID_HOME}"
log "Patch Location: ${PATCH_LOC}"

# ── 1. Verify prerequisites ──────────────────────────────────────────────────
log "Checking required zip files..."
for f in \
  "${BASE_SW_DIR}/${GRID_BASE_ZIP}" \
  "${PATCH_LOC}/${OPATCH_ZIP}" \
  "${PATCH_LOC}/${RU_COMBO_ZIP}"; do
  if [[ ! -f "${f}" ]]; then
    log "ERROR: Required file not found: ${f}"
    exit 1
  fi
done
log "All required files present."

# ── 2. Check disk space (need 15 GB free) ────────────────────────────────────
SPACE_CHECK_DIR=$(dirname "${NEW_GRID_HOME}")
AVAIL_GB=$(df -BG "${SPACE_CHECK_DIR}" | awk 'NR==2 {gsub("G","",$4); print $4}')
if (( AVAIL_GB < 15 )); then
  log "ERROR: Insufficient disk space. Need 15 GB, found ${AVAIL_GB} GB on ${SPACE_CHECK_DIR}"
  exit 1
fi
log "Disk space OK: ${AVAIL_GB} GB available on ${SPACE_CHECK_DIR}."

# ── 3. Extract base Grid software ────────────────────────────────────────────
log "Extracting base Grid 19.3 software into ${NEW_GRID_HOME}..."
unzip -q -o "${BASE_SW_DIR}/${GRID_BASE_ZIP}" -d "${NEW_GRID_HOME}/"
log "Base Grid extraction complete."

# ── 4. Update OPatch ─────────────────────────────────────────────────────────
log "Updating OPatch in new Grid home..."
rm -rf "${NEW_GRID_HOME}/OPatch"
unzip -q -o "${PATCH_LOC}/${OPATCH_ZIP}" -d "${NEW_GRID_HOME}/"
OPATCH_VER=$("${NEW_GRID_HOME}/OPatch/opatch" version 2>/dev/null | grep "OPatch Version" | awk '{print $NF}')
log "OPatch version: ${OPATCH_VER}"

# ── 5. Extract RU Combo patch ────────────────────────────────────────────────
log "Extracting RU combo patch ${RU_COMBO_PATCH}..."
unzip -q -o "${PATCH_LOC}/${RU_COMBO_ZIP}" -d "${PATCH_LOC}/"
log "RU combo extraction complete."

# ── 6. Verify patch directories exist ────────────────────────────────────────
log "Verifying patch directory structure..."
for p in \
  "${GI_APPLY_RU_PATH}" \
  $(echo "${GI_ONEOFF_PATHS}" | tr ',' ' '); do
  if [[ ! -d "${p}" ]]; then
    log "ERROR: Patch directory not found: ${p}"
    exit 1
  fi
done
log "All patch directories verified."

# ── 7. Prepare response file for new Grid home ───────────────────────────────
log "Preparing Grid response file for new home..."
if [[ ! -f "${GRID_RSP}" ]]; then
  log "ERROR: Grid response file not found: ${GRID_RSP}"
  exit 1
fi

# Create working copy in /tmp (writable by all users)
GRID_RSP_TMP="/tmp/grid_install_$(date +%Y%m%d%H%M%S)_$$.rsp"
cp "${GRID_RSP}" "${GRID_RSP_TMP}"
sed -i "s|^ORACLE_HOME=.*|ORACLE_HOME=${NEW_GRID_HOME}|" "${GRID_RSP_TMP}"
log "Response file copy: ${GRID_RSP_TMP}"
log "ORACLE_HOME set to: $(grep '^ORACLE_HOME=' ${GRID_RSP_TMP})"

# ── 8. Run gridSetup.sh with CRS_SWONLY + -applyRU ──────────────────────────
log "Running gridSetup.sh CRS_SWONLY with RU ${GI_APPLY_RU_PATCH}..."
log "  -applyRU    : ${GI_APPLY_RU_PATH}"
log "  -applyOneOffs: ${GI_ONEOFF_PATHS}"
log "  -responseFile: ${GRID_RSP_TMP}"

"${NEW_GRID_HOME}/gridSetup.sh" \
  -silent \
  -ignorePrereqFailure \
  -waitforcompletion \
  -applyRU "${GI_APPLY_RU_PATH}" \
  -applyOneOffs "${GI_ONEOFF_PATHS}" \
  -responseFile "${GRID_RSP_TMP}" \
  oracle.install.option=CRS_SWONLY

log "gridSetup.sh completed."

# ── 8. Verify binary integrity ───────────────────────────────────────────────
log "Verifying new Grid home binary integrity..."
ZERO_COUNT=$(find "${NEW_GRID_HOME}/bin" -size 0 2>/dev/null | wc -l)
log "Zero-byte files in bin/: ${ZERO_COUNT}"
for critical in lsnrctl oracle; do
  FSIZE=$(stat -c%s "${NEW_GRID_HOME}/bin/${critical}" 2>/dev/null || echo 0)
  if (( FSIZE == 0 )); then
    log "ERROR: Critical binary ${critical} is zero bytes — gold image not properly installed."
    exit 1
  fi
  log "  ${critical}: $(numfmt --to=iec ${FSIZE})"
done

# ── 9. Verify patches in patch_storage ───────────────────────────────────────
log "Verifying patches in .patch_storage..."
for p in ${GI_APPLY_RU_PATCH} $(echo "${GI_ONEOFF_PATCHES}" | tr ',' ' '); do
  MATCH=$(ls "${NEW_GRID_HOME}/.patch_storage/" 2>/dev/null | grep "^${p}" | wc -l)
  if (( MATCH == 0 )); then
    log "WARNING: Patch ${p} not found in .patch_storage — verify manually."
  else
    log "  Patch ${p}: OK"
  fi
done

log "=== PHASE 1 COMPLETE ==="
