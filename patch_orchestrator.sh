#!/usr/bin/env bash
# =============================================================================
# patch_orchestrator.sh — Master Oracle OOP Patch Orchestrator
# Run as: root
#
# USAGE:
#   ./patch_orchestrator.sh [--phase <1-5>] [--from-phase <n>] [--dry-run]
#
# OPTIONS:
#   --phase <n>      Run only phase n (1-5)
#   --from-phase <n> Run from phase n to end
#   --dry-run        Print what would be done without executing
#   --cleanup        Also run phase 5 cleanup (off by default — run manually)
#
# PHASES:
#   1  phase1_grid_prep.sh   Build and patch new Grid home  (online)
#   2  phase2_db_prep.sh     Build and patch new DB home    (online)
#   3  phase3_switch.sh      Home switch + datapatch        (OUTAGE)
#   4  phase4_post_install.sh Post-patch validation          (online)
#   5  phase5_cleanup.sh     Deinstall old homes            (manual)
# =============================================================================
set -euo pipefail

# Set umask so all directories/files created by root, grid, and oracle
# inherit group-write permission — required for shared NFS staging area
# where both grid and oracle users need to read/write patch directories.
umask 0002

# ── Must run as root ──────────────────────────────────────────────────────────
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: patch_orchestrator.sh must be run as root."
  exit 1
fi

# ── Defaults ──────────────────────────────────────────────────────────────────
START_PHASE=1
END_PHASE=4    # Phase 5 (cleanup) is opt-in only
DRY_RUN=false
SINGLE_PHASE=""

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)       SINGLE_PHASE="$2"; START_PHASE="$2"; END_PHASE="$2"; shift 2 ;;
    --from-phase)  START_PHASE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --cleanup)     END_PHASE=5; shift ;;
    --help|-h)
      sed -n '3,25p' "$0"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── Load configuration ────────────────────────────────────────────────────────
# SCRIPTS_DIR is always the directory containing this orchestrator script
# regardless of what patch.conf says — this allows running from any location
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPTS_DIR}/patch.conf"

if [[ ! -f "${CONF_FILE}" ]]; then
  echo "ERROR: Configuration file not found: ${CONF_FILE}"
  exit 1
fi
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_DIR}/master_patch.log") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

run_phase() {
  local phase_num="$1"
  local script="$2"
  local description="$3"
  local run_as="${4:-root}"

  log "─────────────────────────────────────────────────────"
  log "PHASE ${phase_num}: ${description}"
  log "Script : ${SCRIPTS_DIR}/${script}"
  log "Run as : ${run_as}"
  log "─────────────────────────────────────────────────────"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log "[DRY-RUN] Would execute: ${SCRIPTS_DIR}/${script}"
    return 0
  fi

  if [[ ! -x "${SCRIPTS_DIR}/${script}" ]]; then
    die "Script not found or not executable: ${SCRIPTS_DIR}/${script}"
  fi

  local start_ts=$SECONDS

  if [[ "${run_as}" == "root" ]]; then
    PATCH_LOC="${PATCH_LOC}" bash "${SCRIPTS_DIR}/${script}"
  else
    sudo -u "${run_as}" \
      PATCH_LOC="${PATCH_LOC}" \
      bash "${SCRIPTS_DIR}/${script}"
  fi

  local exit_code=$?
  local elapsed=$(( SECONDS - start_ts ))

  if [[ ${exit_code} -ne 0 ]]; then
    die "Phase ${phase_num} FAILED with exit code ${exit_code} after ${elapsed}s."
  fi

  log "PHASE ${phase_num} COMPLETED in ${elapsed}s."
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
log "==========================================================="
log "ORACLE OOP PATCH ORCHESTRATOR"
log "==========================================================="
log "Patch level  : ${OLD_PATCH_LEVEL} → ${NEW_PATCH_LEVEL}"
log "New Grid Home: ${NEW_GRID_HOME}"
log "New DB Home  : ${NEW_DB_HOME}"
log "Patch staging: ${PATCH_LOC}"
log "Running phases: ${START_PHASE} to ${END_PHASE}"
log "Dry run      : ${DRY_RUN}"
log "==========================================================="

# Verify patch.conf has essential values
for var in NEW_PATCH_LEVEL OLD_PATCH_LEVEL RU_COMBO_PATCH GI_RU_PATCH \
           GI_APPLY_RU_PATCH GI_ONEOFF_PATCHES DB_APPLY_RU_PATCH; do
  [[ -z "${!var:-}" ]] && die "patch.conf variable '${var}' is not set."
done

# Verify PATCH_LOC exists and is accessible
[[ -d "${PATCH_LOC}" ]] || die "PATCH_LOC does not exist: ${PATCH_LOC}"

# Verify SCRIPTS_DIR is accessible by non-root users (grid/oracle run phase scripts)
if ! sudo -u "${GRID_USER}" test -r "${SCRIPTS_DIR}/phase1_grid_prep.sh" 2>/dev/null; then
  die "SCRIPTS_DIR '${SCRIPTS_DIR}' is not readable by user '${GRID_USER}'. " \
      "Do not use /root — move scripts to a shared path (e.g. /u01/shared/software/patches/automation)"
fi

# ── Pre-create log directory and log files with correct ownership ──────────────
# All phase scripts run as root/grid/oracle and must be able to append to log files.
# Pre-creating them with root:oinstall 664 ensures all users can write.
if [[ "${DRY_RUN}" != "true" ]]; then
  log "Pre-creating log directory and log files..."
  mkdir -p "${LOG_DIR}"
  chown root:"${INSTALL_GROUP}" "${LOG_DIR}"
  chmod 775 "${LOG_DIR}"
  for _logfile in \
    phase1_grid_prep.log \
    phase2_db_prep.log \
    phase3_switch.log \
    phase4_post_install.log \
    phase5_cleanup.log \
    master_patch.log; do
    _logpath="${LOG_DIR}/${_logfile}"
    touch "${_logpath}"
    chown root:"${INSTALL_GROUP}" "${_logpath}"
    chmod 664 "${_logpath}"
  done
  unset _logfile _logpath
  log "Log directory: ${LOG_DIR}"
fi

# ── Phase 1: Online — Build new Grid home ─────────────────────────────────────
if (( START_PHASE <= 1 && END_PHASE >= 1 )); then
  log ""
  log "PRE-PHASE 1: Creating Grid home directory structure..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p "${NEW_GRID_HOME}"
    chown -R "${GRID_USER}:${INSTALL_GROUP}" "$(dirname "${NEW_GRID_HOME}")"
    chmod -R 775 "${NEW_GRID_HOME}"
    # Create log directory and pre-create log files with correct ownership
    # so grid/oracle users can append to them via exec >> inside phase scripts
    mkdir -p "${LOG_DIR}"
    chmod 775 "${LOG_DIR}"
    chown root:"${INSTALL_GROUP}" "${LOG_DIR}"
    for logfile in phase1_grid_prep.log phase2_db_prep.log phase3_switch.log \
                   phase4_post_install.log phase5_cleanup.log; do
      touch "${LOG_DIR}/${logfile}"
      chown root:"${INSTALL_GROUP}" "${LOG_DIR}/${logfile}"
      chmod 664 "${LOG_DIR}/${logfile}"
    done
  fi
  run_phase 1 "phase1_grid_prep.sh" \
    "Build and patch new Grid home ${NEW_GRID_HOME}" \
    "${GRID_USER}"
fi

# ── Phase 2: Online — Build new DB home ───────────────────────────────────────
if (( START_PHASE <= 2 && END_PHASE >= 2 )); then
  log ""
  log "PRE-PHASE 2: Creating DB home directory structure..."
  if [[ "${DRY_RUN}" != "true" ]]; then
    mkdir -p "${NEW_DB_HOME}"
    chown -R "${ORACLE_USER}:${INSTALL_GROUP}" "${NEW_DB_HOME}"
    chmod -R 775 "${NEW_DB_HOME}"
  fi
  run_phase 2 "phase2_db_prep.sh" \
    "Build and patch new DB home ${NEW_DB_HOME}" \
    "${ORACLE_USER}"
fi

# ── Phase 3: OUTAGE — Switch homes ────────────────────────────────────────────
if (( START_PHASE <= 3 && END_PHASE >= 3 )); then
  log ""
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  log "PHASE 3 OUTAGE: Grid and Database home switch begins."
  log "Confirm maintenance window is in effect."
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  run_phase 3 "phase3_switch.sh" \
    "Grid home switch + DB home switch + AutoUpgrade deploy (OUTAGE)" \
    "root"
fi

# ── Phase 4: Online — Post-install validation ─────────────────────────────────
if (( START_PHASE <= 4 && END_PHASE >= 4 )); then
  run_phase 4 "phase4_post_install.sh" \
    "Post-patch validation, utlrp, chopt, component registry" \
    "root"
fi

# ── Phase 5: Cleanup — Optional, must be explicitly requested ─────────────────
if (( END_PHASE >= 5 )); then
  log ""
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  log "PHASE 5: Old home cleanup. This is IRREVERSIBLE."
  log "Only proceed if Phase 4 validation is fully confirmed."
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  run_phase 5 "phase5_cleanup.sh" \
    "Deinstall old homes ${OLD_GRID_HOME} and ${OLD_DB_HOME}" \
    "root"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "==========================================================="
log "ORACLE OOP PATCH ORCHESTRATION COMPLETE"
log "Patch level: ${OLD_PATCH_LEVEL} → ${NEW_PATCH_LEVEL}"
log "Logs       : ${LOG_DIR}/"
log "==========================================================="

log "Post-patch verification commands:"
log "  ${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
log "  ${NEW_GRID_HOME}/bin/crsctl status resource -t"
log "  sqlplus / as sysdba <<< \"SELECT patch_id,status FROM dba_registry_sqlpatch;\""
