#!/usr/bin/env bash
# =============================================================================
# phase4_post_install.sh — Post-patch validation and object recompilation
# Run as: root
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase4_post_install.log" 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die() { log "CRITICAL ERROR: $*"; exit 1; }

runsql() {
  # runsql <sid> <oracle_home> <sql_file>
  local sid="$1" home="$2" sqlfile="$3"
  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${sqlfile}
  "
}

log "=== PHASE 4: Post-Installation Tasks ==="

# ── Detect DB name and instance SID ──────────────────────────────────────────
[[ -z "${DB_NAME}" ]] && die "DB_NAME not set in patch.conf"

DB_INSTANCE=$(su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/srvctl status database -d ${DB_NAME} 2>/dev/null \
    | grep \$(hostname -s) | awk '{print \$2}'
" 2>/dev/null || echo "")
[[ -z "${DB_INSTANCE}" ]] && DB_INSTANCE="${DB_NAME}1"
log "Database  : ${DB_NAME}"
log "Instance  : ${DB_INSTANCE}"
log "New Home  : ${NEW_DB_HOME}"

# ── Step A: Record pre-patch invalid objects ───────────────────────────────────
log "Step A: Recording invalid object baseline..."
cat > /tmp/phase4_invalids.sql << 'SQLEOF'
SET PAGESIZE 200 LINESIZE 120 FEEDBACK OFF
SELECT owner, object_type, COUNT(*) cnt
FROM   dba_objects
WHERE  status = 'INVALID'
GROUP  BY owner, object_type
ORDER  BY owner, object_type;
EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_invalids.sql \
  > "${LOG_DIR}/pre_patch_invalid_objects.log" 2>&1 || true
log "Invalid objects baseline: ${LOG_DIR}/pre_patch_invalid_objects.log"

# ── Step B: Restart database ────────────────────────────────────────────────────
log "Step B: Restarting database ${DB_NAME}..."
su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  ${NEW_GRID_HOME}/bin/srvctl stop  database -d ${DB_NAME}
  ${NEW_GRID_HOME}/bin/srvctl start database -d ${DB_NAME}
"
log "Database restarted."

# ── Step C: Recompile invalid objects and validate ─────────────────────────────
log "Step C: Recompiling invalid objects..."
cat > /tmp/phase4_utlrp.sql << 'SQLEOF'
SET ECHO OFF FEEDBACK OFF SERVEROUTPUT ON
@?/rdbms/admin/utlrp
EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_utlrp.sql || true
log "utlrp complete."

# ── Step D: datapatch status validation ────────────────────────────────────────
log "Step D: Validating datapatch and component registry..."
cat > /tmp/phase4_validate.sql << 'SQLEOF'
SET PAGESIZE 100 LINESIZE 150 FEEDBACK OFF

PROMPT === datapatch status ===
SELECT patch_id, status, description
FROM   dba_registry_sqlpatch
ORDER  BY action_time DESC;

PROMPT === component registry ===
SELECT comp_name, version, status
FROM   dba_registry
ORDER  BY comp_name;

PROMPT === invalid objects post-patch ===
SELECT owner, object_type, COUNT(*) cnt
FROM   dba_objects
WHERE  status = 'INVALID'
GROUP  BY owner, object_type
ORDER  BY owner, object_type;

PROMPT === CDB and PDB status ===
SELECT name, open_mode, cdb FROM v$database;
SELECT con_id, name, open_mode FROM v$pdbs;

EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_validate.sql \
  | tee "${LOG_DIR}/phase4_validation.log"

# ── Step E: Verify Grid patch level ────────────────────────────────────────────
log "Step E: Verifying Grid patch level..."
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch
"${NEW_GRID_HOME}/bin/crsctl" status resource -t

# ── Cleanup temp SQL files ─────────────────────────────────────────────────────
rm -f /tmp/phase4_invalids.sql /tmp/phase4_utlrp.sql /tmp/phase4_validate.sql

log "=== PHASE 4 COMPLETE ==="
log ""
log "Review:"
log "  ${LOG_DIR}/phase4_validation.log"
log "  ${LOG_DIR}/pre_patch_invalid_objects.log"
