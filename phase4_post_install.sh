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
#   F. Enable SYS.DB_DDL_ALERT_TRG again (disabled in phase 3)
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

runoracle_p4() { su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH; $1"; }

runsql() {
  # runsql <instance_sid> <oracle_home> <sql_file>
  local sid="$1" home="$2" sqlfile="$3"
  su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${sqlfile}
  "
}


# ── SYS.DB_DDL_ALERT_TRG: disabled before the outage (phase 3), enabled after patching (phase 4)
# Works for a non-CDB, or a CDB (root plus every READ WRITE PDB). Containers where the
# trigger does not exist are skipped. Returns non-zero if sqlplus fails.
ddl_trigger() {   # usage: ddl_trigger DISABLE|ENABLE <oracle_home> <oracle_sid>
  local action="$1" home="$2" sid="$3" rc=0
  local sqlf out
  sqlf=$(mktemp /tmp/ddl_trg_XXXXXX.sql)
  out=$(mktemp /tmp/ddl_trg_XXXXXX.out)
  cat > "${sqlf}" << 'SQLEOF'
SET SERVEROUTPUT ON SIZE UNLIMITED FEEDBACK OFF PAGESIZE 0 LINESIZE 200
WHENEVER SQLERROR EXIT FAILURE
DECLARE
  TYPE t_names IS TABLE OF VARCHAR2(128);
  v_names   t_names := t_names();
  v_skipped t_names := t_names();
  v_cdb     VARCHAR2(3);
  PROCEDURE do_trg(p_label IN VARCHAR2) IS
    v_cnt PLS_INTEGER;
  BEGIN
    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM dba_triggers WHERE owner = ''SYS'' AND trigger_name = ''DB_DDL_ALERT_TRG''' INTO v_cnt;
    IF v_cnt = 0 THEN
      DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || p_label || ': trigger not present, skipped');
    ELSE
      EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG __ACTION__';
      DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG ' || p_label || ': __ACTION__ done');
    END IF;
  END do_trg;
BEGIN
  EXECUTE IMMEDIATE 'SELECT cdb FROM v$database' INTO v_cdb;
  do_trg(CASE WHEN v_cdb = 'YES' THEN 'CDB$ROOT' ELSE 'non-CDB' END);
  IF v_cdb = 'YES' THEN
    EXECUTE IMMEDIATE q'[SELECT name FROM v$pdbs WHERE name <> 'PDB$SEED' AND open_mode = 'READ WRITE' ORDER BY con_id]'
      BULK COLLECT INTO v_names;
    EXECUTE IMMEDIATE q'[SELECT name FROM v$pdbs WHERE name <> 'PDB$SEED' AND open_mode <> 'READ WRITE' ORDER BY con_id]'
      BULK COLLECT INTO v_skipped;
    FOR i IN 1 .. v_names.COUNT LOOP
      EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || DBMS_ASSERT.ENQUOTE_NAME(v_names(i), FALSE);
      do_trg(v_names(i));
    END LOOP;
    EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = CDB$ROOT';
    FOR i IN 1 .. v_skipped.COUNT LOOP
      DBMS_OUTPUT.PUT_LINE('DB_DDL_ALERT_TRG WARNING: PDB ' || v_skipped(i) || ' is not READ WRITE, skipped');
    END LOOP;
  END IF;
END;
/
EXIT
SQLEOF
  sed -i "s/__ACTION__/${action}/g" "${sqlf}"
  chmod 644 "${sqlf}"
  runoracle_p4 "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${sqlf}
  " > "${out}" 2>&1 || rc=$?
  while IFS= read -r l; do log "  ${l}"; done < "${out}"
  rm -f "${sqlf}" "${out}"
  return "${rc}"
}

log "=== PHASE 4: Post-Installation Tasks ==="

# -- Phase gate: Require phases 1 2 3 to have completed ------
require_phase_complete 1 2 3
log "New DB Home: ${NEW_DB_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"

# ── Detect DB name and instance SID ──────────────────────────────────────────
[[ -z "${DB_NAME}" ]] && die "DB_NAME not set in patch.conf"

DB_INSTANCE=$(su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH
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

su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH
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
su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH
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

# ── Step F: Enable SYS.DB_DDL_ALERT_TRG again (disabled in phase 3) ───────────
log "Step F: Enabling SYS.DB_DDL_ALERT_TRG (non-CDB, or CDB root and open PDBs)..."
ddl_trigger ENABLE "${NEW_DB_HOME}" "${DB_INSTANCE}" \
  || die "Could not enable SYS.DB_DDL_ALERT_TRG. Run: alter trigger SYS.DB_DDL_ALERT_TRG enable;  in the root and each PDB, then re-run phase 4."

# ── Step G: Verify Grid patch level ────────────────────────────────────────────
log "Step G: Verifying Grid patch level and resource status..."
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch
"${NEW_GRID_HOME}/bin/crsctl" status resource -t

# ── Cleanup temp SQL files ─────────────────────────────────────────────────────
rm -f /tmp/phase4_pre_invalids.sql /tmp/phase4_validate.sql /tmp/phase4_voption.sql

mark_phase_complete 4
log "=== PHASE 4 COMPLETE ==="
log ""
log "Review validation report: ${LOG_DIR}/phase4_validation.log"
log "  v\$option  : Partitioning, OLAP, RAT must show FALSE"
log "  dba_registry: APS, XOQ must show OPTION OFF"
log "  datapatch : no rows with status != SUCCESS"
