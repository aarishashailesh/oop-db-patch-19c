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
  runoracle_p4 "
    export ORACLE_HOME=${home}
    export ORACLE_SID=${sid}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @${info}
  " > "${out}" 2>&1 || rc=$?
  if (( rc == 0 )) && grep -q '^CDB=YES' "${out}"; then
    grep '^NOTRW=' "${out}" | while IFS= read -r l; do log "  WARNING: PDB ${l#NOTRW=} is not READ WRITE, trigger left unchanged there"; done
    logd=$(mktemp -d /tmp/ddl_trg_logs_XXXXXX); chmod 777 "${logd}"
    log "  CDB: ${action} in CDB\$ROOT and all open PDBs (catcon.pl, PDB\$SEED excluded)"
    runoracle_p4 "
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
    runoracle_p4 "
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

# Partitioning must NOT be disabled in a CDB (non-CDB only), so detect it first.
cat > /tmp/phase4_iscdb.sql << 'SQLEOF'
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT cdb FROM v$database;
EXIT;
SQLEOF
IS_CDB=$(runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_iscdb.sql 2>/dev/null | tr -d '[:space:]' || true)
log "  CDB: ${IS_CDB:-unknown}"
if [[ "${IS_CDB}" == "YES" ]]; then
  CHOPT_PART="echo 'CDB: skipping chopt disable partitioning (non-CDB only)'"
  log "  Options to disable: olap, rat (partitioning skipped: this is a CDB)"
else
  CHOPT_PART="echo 'Disabling Partitioning...'; ./chopt disable partitioning"
  log "  Options to disable: olap, rat (Real Application Testing), partitioning"
fi

su - "${ORACLE_USER}" -c "unset LD_LIBRARY_PATH
  export ORACLE_HOME=${NEW_DB_HOME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  cd \${ORACLE_HOME}/bin

  echo 'Disabling OLAP...'
  ./chopt disable olap

  echo 'Disabling Real Application Testing (rat)...'
  ./chopt disable rat

  ${CHOPT_PART}
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

# ── Step D: OLAP registry validation (all containers) and utlrp ──────────────
# After "chopt disable olap" the OLAP components (APS, XOQ) must be re-validated so
# DBA_REGISTRY shows OPTION OFF. In a CDB this has to happen in CDB$ROOT, PDB$SEED
# and every PDB; if only the root is validated, the PDBs keep showing VALID and the
# next AutoUpgrade run fails with "Database option APS/XOQ mismatch" violations.
log "Step D: Validating OLAP components (XOQ_VALIDATE, APS_VALIDATE)..."
if [[ "${IS_CDB}" == "YES" ]]; then
  printf 'exec sys.xoq_validate\nexec sys.aps_validate\n' > /tmp/phase4_olap_catcon.sql
  chmod 644 /tmp/phase4_olap_catcon.sql
  OLAP_LOGDIR=$(mktemp -d /tmp/phase4_olap_logs_XXXXXX); chmod 777 "${OLAP_LOGDIR}"
  log "  CDB: running in CDB\$ROOT, PDB\$SEED and all open PDBs with catcon.pl (logs: ${OLAP_LOGDIR})"
  runoracle_p4 "
    export ORACLE_HOME=${NEW_DB_HOME}
    export ORACLE_SID=${DB_INSTANCE}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/perl/bin/perl \${ORACLE_HOME}/rdbms/admin/catcon.pl -d /tmp -l ${OLAP_LOGDIR} -b phase4_olap phase4_olap_catcon.sql
  " || log "  WARNING: catcon.pl returned non-zero. Review ${OLAP_LOGDIR} and run XOQ_VALIDATE / APS_VALIDATE in each container by hand."
  log "  Closed PDBs are skipped by catcon: open them and re-run if any PDB is not READ WRITE."
else
  cat > /tmp/phase4_olap_validate.sql << 'SQLEOF'
SET SERVEROUTPUT ON
EXEC SYS.XOQ_VALIDATE
EXEC SYS.APS_VALIDATE
EXIT;
SQLEOF
  runsql "${DB_INSTANCE}" "${NEW_DB_HOME}" /tmp/phase4_olap_validate.sql
fi

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

PROMPT === Pending plug-in violations (CDB only; expected: no rows) ===
SELECT name, message FROM pdb_plug_in_violations WHERE status <> 'RESOLVED' AND message LIKE 'Database option%';

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
