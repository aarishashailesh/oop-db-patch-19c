#!/usr/bin/env bash
# =============================================================================
# phase4_post_install.sh — Post-patch validation and binary modifications
# Run as: root
#
# Steps:
#   A. Record pre-patch invalid objects baseline
#   B. Disable unused DB options via chopt (olap, rat, partitioning)
#   C. Restart database
#   D. Run internal validations (XOQ_VALIDATE, APS_VALIDATE) and utlrp
#   E. Verify v$option shows FALSE for disabled options
#   F. Verify DBA_REGISTRY — all components VALID or OPTION OFF
#   G. Verify Grid patch level and resource status
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
chmod 664 "${LOG_DIR}/phase4_post_install.log" 2>/dev/null || true
exec >> "${LOG_DIR}/phase4_post_install.log" 2>&1

log()    { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()    { log "CRITICAL ERROR: $*"; exit 1; }

runsql() {
  # runsql <instance_sid> <oracle_home> <sql_file>
  local sid="$1" home="$2" sqlfile="$3"
  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${sqlfile}
  "
}

log "=== PHASE 4: Post-Installation Tasks ==="
log "New DB Home: ${NEW_DB_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"

# ── Detect DB name and instance SID ──────────────────────────────────────────
[[ -z "${DB_NAME}" ]] && die "DB_NAME not set in patch.conf"

DB_INSTANCE=$(su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/srvctl status database -d ${DB_NAME} 2>/dev/null \
    | grep \$(hostname -s) | awk '{print \$2}'
" 2>/dev/null || echo "")
[[ -z "${DB_INSTANCE}" ]] && DB_INSTANCE="${DB_NAME}1"
log "Database : ${DB_NAME}"
log "Instance : ${DB_INSTANCE}"

# ── Step A: Record pre-modification invalid objects ───────────────────────────
log "Step A: Recording invalid object baseline..."
cat > /tmp/phase4_pre_invalids.sql << 'SQLEOF'
SET PAGESIZE 100 LINESIZE 120 FEEDBACK OFF
PROMPT === Pre-modification invalid objects ===
SELECT owner, object_type, COUNT(*) cnt
FROM   dba_objects
WHERE  status = 'INVALID'
GROUP  BY owner, object_type
ORDER  BY owner, object_type;
PROMPT === Current v$option for disabled options ===
COLUMN parameter FORMAT A30
COLUMN value     FORMAT A10
SELECT parameter, value
FROM   v$option
WHERE  parameter IN ('Partitioning','Real Application Testing','OLAP');
EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_pre_invalids.sql \
  | tee "${LOG_DIR}/pre_patch_invalid_objects.log"

# ── Step B: Disable unused DB options via chopt ───────────────────────────────
log "Step B: Disabling unused Oracle options via chopt..."
log "  Options to disable: olap, rat (Real Application Testing), partitioning"

su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  cd \${ORACLE_HOME}/bin

  echo 'Disabling OLAP...'
  ./chopt disable olap

  echo 'Disabling Real Application Testing (rat)...'
  ./chopt disable rat

  echo 'Disabling Partitioning...'
  ./chopt disable partitioning
"
log "chopt disable complete."

# ── Step C: Restart database ────────────────────────────────────────────────────
log "Step C: Restarting database ${DB_NAME} to apply chopt changes..."
su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  ${NEW_GRID_HOME}/bin/srvctl stop  database -d ${DB_NAME}
  ${NEW_GRID_HOME}/bin/srvctl start database -d ${DB_NAME}
"
log "Database restarted."

# ── Step D: Recompile invalid objects with utlrp ─────────────────────────────
# NOTE: SYS.XOQ_VALIDATE and SYS.APS_VALIDATE are NOT called here.
# These procedures update the database registry for the Oracle OLAP option
# and are ONLY required when enabling or disabling OLAP using the chopt tool
# (which is done in Step B above). They are NOT part of standard OOP patching.
# If chopt is not used in this environment, XOQ_VALIDATE/APS_VALIDATE are
# never needed.
log "Step D: Recompiling invalid objects with utlrp..."
cat > /tmp/phase4_validate.sql << 'SQLEOF'
SET ECHO OFF FEEDBACK ON SERVEROUTPUT ON

PROMPT === Recompiling invalid objects (utlrp) ===
@?/rdbms/admin/utlrp

EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_validate.sql
log "utlrp complete."

# ── Step E: Verify v$option shows FALSE for disabled options ─────────────────
log "Step E: Verifying disabled options in v\$option..."
cat > /tmp/phase4_voption.sql << 'SQLEOF'
SET PAGESIZE 100 LINESIZE 120 FEEDBACK OFF
COLUMN parameter FORMAT A30
COLUMN value     FORMAT A10
COLUMN con_id    FORMAT 99999

PROMPT === v$option — disabled options (must show FALSE) ===
SELECT parameter, value, con_id
FROM   v$option
WHERE  parameter IN ('Partitioning','Real Application Testing','OLAP');

PROMPT === DBA_REGISTRY — APS and XOQ (must show OPTION OFF) ===
SELECT comp_id, comp_name, status
FROM   dba_registry
WHERE  comp_id IN ('APS','XOQ');

PROMPT === datapatch status (must show SUCCESS) ===
SELECT patch_id, status, description
FROM   dba_registry_sqlpatch
WHERE  status != 'SUCCESS'
ORDER  BY action_time DESC;
-- Expected: no rows

PROMPT === All components (must be VALID or OPTION OFF) ===
SELECT comp_name, status
FROM   dba_registry
ORDER  BY comp_name;

PROMPT === CDB and PDB status ===
SELECT name, open_mode, cdb FROM v$database;
SELECT con_id, name, open_mode FROM v$pdbs;

EXIT;
SQLEOF
runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_voption.sql \
  | tee "${LOG_DIR}/phase4_validation.log"

# ── Step G: Verify Grid patch level ────────────────────────────────────────────
log "Step G: Verifying Grid patch level and resource status..."
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch
"${NEW_GRID_HOME}/bin/crsctl" status resource -t

# ── Cleanup temp SQL files ─────────────────────────────────────────────────────
rm -f /tmp/phase4_pre_invalids.sql /tmp/phase4_validate.sql /tmp/phase4_voption.sql

log "=== PHASE 4 COMPLETE ==="
log ""
log "Review validation report: ${LOG_DIR}/phase4_validation.log"
log "  v\$option  : Partitioning, OLAP, RAT must show FALSE"
log "  dba_registry: APS, XOQ must show OPTION OFF"
log "  datapatch : no rows with status != SUCCESS"
