#!/usr/bin/env bash
# =============================================================================
# phase5_cleanup.sh - Remove old Grid and DB homes
# Run as: root
# WARNING: Only run after phase4 validation is complete and confirmed.
# Wait at least 24 hours post-patching before running cleanup.
#
# Method: detach each old home from the Oracle inventory with
#   <new home>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<old home>
# (run as the owner of that home), then remove the old directories.
# deinstall is NOT used. If a detach fails, nothing is deleted.
# =============================================================================
set -euo pipefail

# Inherit group-write for shared NFS staging area
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase5_cleanup.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

# -- Inventory helpers --------------------------------------------------------
INV_LOC=$(awk -F= '/^inventory_loc/{print $2}' /etc/oraInst.loc 2>/dev/null | tr -d ' ' || true)
INV_LOC="${INV_LOC:-/u01/app/oraInventory}"
INV_XML="${INV_LOC}/ContentsXML/inventory.xml"

# True if the home path is registered in the inventory and not marked REMOVED.
home_in_inventory() {
  grep -F "LOC=\"${1%/}\"" "${INV_XML}" 2>/dev/null | grep -qv 'REMOVED="T"'
}

# detach_home <os_user> <runInstaller path> <old home>
# Runs as the home owner with a clean environment (the login .bashrc exports
# a Grid ORACLE_HOME / ORACLE_SID / LD_LIBRARY_PATH that must not leak in).
detach_home() {
  local user="$1" oui="$2" old="${3%/}"
  if ! home_in_inventory "${old}"; then
    log "  ${old} is not registered in the inventory (already detached) - skipped."
    return 0
  fi
  [[ -x "${oui}" ]] || { log "ERROR: ${oui} not found or not executable."; return 1; }
  log "  ${oui} -silent -detachHome ORACLE_HOME=${old}  (as ${user})"
  su - "${user}" -c "unset ORACLE_HOME ORACLE_SID LD_LIBRARY_PATH; export CV_ASSUME_DISTID=${CV_ASSUME_DISTID:-OEL7.8}; ${oui} -silent -detachHome ORACLE_HOME=${old}" \
    || { log "ERROR: detachHome returned non-zero for ${old}."; return 1; }
  if home_in_inventory "${old}"; then
    log "ERROR: ${old} is still registered in ${INV_XML} after detachHome."
    return 1
  fi
  log "  Detached from inventory: ${old}"
}

# safe_rm <directory>: refuses anything that is too broad or contains a new home.
safe_rm() {
  local d="${1%/}"
  case "${d}" in ""|"/"|"/u01"|"/u01/app") log "ERROR: refusing to remove '${d}'."; return 1 ;; esac
  case "${NEW_GRID_HOME%/}/" in "${d}/"*) log "ERROR: ${d} contains the new Grid home - not removing."; return 1 ;; esac
  case "${NEW_DB_HOME%/}/"   in "${d}/"*) log "ERROR: ${d} contains the new DB home - not removing.";   return 1 ;; esac
  if [[ -d "${d}" ]]; then
    local du; du=$(du -sh "${d}" 2>/dev/null | awk '{print $1}')
    log "Removing ${d} (${du})..."
    rm -rf "${d}"
  fi
}

log "=== PHASE 5: Old Home Cleanup ==="

# -- Phase gate: Require phases 1 2 3 4 to have completed ------
require_phase_complete 1 2 3 4
log "Old Grid Home: ${OLD_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"
log "Inventory    : ${INV_XML}"

# Safety check - confirm new homes are active
log "Confirming new Grid home is active..."
ACTIVE_GI=$("${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch 2>/dev/null | grep -i "${NEW_PATCH_LEVEL}" || echo "")
if [[ -z "${ACTIVE_GI}" ]]; then
  die "New Grid home ${NEW_GRID_HOME} does not appear to be the active home. Aborting cleanup."
fi
log "New Grid home confirmed active."

# Safety check - confirm database running from new home
DB_HOME_ACTIVE=$("${NEW_GRID_HOME}/bin/crsctl" stat res ora.${DB_NAME}.db -p 2>/dev/null | grep "ORACLE_HOME=${NEW_DB_HOME}" || echo "")
if [[ -z "${DB_HOME_ACTIVE}" ]]; then
  log "WARNING: Database resource does not show new DB home. Proceeding with caution."
fi

# -- Detach old homes from the inventory (nothing is deleted yet) -------------
log "Step 1: Detaching old DB home from the inventory..."
detach_home "${ORACLE_USER}" "${NEW_DB_HOME}/oui/bin/runInstaller" "${OLD_DB_HOME}" \
  || die "Could not detach ${OLD_DB_HOME}. Nothing was deleted. Fix and re-run phase 5."

log "Step 2: Detaching old Grid home from the inventory..."
detach_home "${GRID_USER}" "${NEW_GRID_HOME}/oui/bin/runInstaller" "${OLD_GRID_HOME}" \
  || die "Could not detach ${OLD_GRID_HOME}. Nothing was deleted. Fix and re-run phase 5."

# -- Remove residual directories ---------------------------------------------
log "Step 3: Removing old Grid version directory..."
safe_rm "$(dirname "${OLD_GRID_HOME}")" || die "Old Grid directory was not removed."

log "Step 4: Removing old DB home directory..."
safe_rm "${OLD_DB_HOME}" || die "Old DB home directory was not removed."

# -- Remove swap file if still present ---------------------------------------
if swapon --show | grep -q "/swapfile"; then
  log "Removing temporary swap file..."
  swapoff /swapfile
  rm -f /swapfile
  sed -i '/swapfile/d' /etc/fstab
  log "Swap file removed."
fi

# -- Final verification -------------------------------------------------------
log "Final verification..."
[[ ! -d "${OLD_GRID_HOME}" ]] && log "Old Grid home removed: OK" || log "WARNING: ${OLD_GRID_HOME} still exists."
[[ ! -d "${OLD_DB_HOME}" ]]   && log "Old DB home removed: OK"   || log "WARNING: ${OLD_DB_HOME} still exists."
[[ -d "${NEW_GRID_HOME}" ]]   && log "New Grid home exists: OK"  || log "ERROR: ${NEW_GRID_HOME} missing!"
[[ -d "${NEW_DB_HOME}" ]]     && log "New DB home exists: OK"    || log "ERROR: ${NEW_DB_HOME} missing!"
home_in_inventory "${OLD_GRID_HOME}" && log "WARNING: old Grid home is still registered in the inventory." || log "Old Grid home not registered in inventory: OK"
home_in_inventory "${OLD_DB_HOME}"   && log "WARNING: old DB home is still registered in the inventory."   || log "Old DB home not registered in inventory: OK"

log "Active homes in the inventory (REMOVED homes hidden):"
{ grep -i "HOME NAME" "${INV_XML}" 2>/dev/null | grep -v 'REMOVED="T"' || true; } \
  | while IFS= read -r l; do log "  ${l}"; done

mark_phase_complete 5
log "=== PHASE 5 COMPLETE ==="
