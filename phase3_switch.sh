#!/usr/bin/env bash
# =============================================================================
# phase3_switch.sh — Grid and Database Home Switch (CRS_CONFIG)
# Run as: root
# Uses su - to switch to grid/oracle users (no sudoers required)
# =============================================================================
set -euo pipefail
umask 0022

CONF_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch.conf"
source "${CONF_FILE}"

mkdir -p "${LOG_DIR}"
exec >> "${LOG_DIR}/phase3_switch.log" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
die()  { log "CRITICAL ERROR: $*"; exit 1; }
rungrid()   { su - "${GRID_USER}"   -c "$1"; }
runoracle() { su - "${ORACLE_USER}" -c "$1"; }

log "=== PHASE 3: Grid and Database Home Switch (CRS_CONFIG) ==="
log "Old Grid Home: ${OLD_GRID_HOME}"
log "New Grid Home: ${NEW_GRID_HOME}"
log "Old DB Home  : ${OLD_DB_HOME}"
log "New DB Home  : ${NEW_DB_HOME}"

NODE_NAME=$(/usr/bin/hostname -s)
log "Node: ${NODE_NAME}"

# ── Helper: disable/enable DB_DDL_ALERT_TRG in CDB and all open PDBs ─────────
manage_ddl_trigger() {
  local action="$1"   # DISABLE or ENABLE
  local sql_action
  [[ "${action}" == "DISABLE" ]] && sql_action="DISABLE" || sql_action="ENABLE"

  log "  Trigger action: ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ${sql_action}"

  cat > /tmp/phase3_trigger_${action,,}.sql << SQLEOF
SET PAGESIZE 100 LINESIZE 120 FEEDBACK ON

-- Act on CDB\$ROOT
ALTER SESSION SET CONTAINER = CDB\$ROOT;
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_triggers
  WHERE trigger_name = 'DB_DDL_ALERT_TRG' AND owner = 'SYS';
  IF v_count > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ${sql_action}';
    DBMS_OUTPUT.PUT_LINE('CDB\$ROOT: DB_DDL_ALERT_TRG ${sql_action}D');
  ELSE
    DBMS_OUTPUT.PUT_LINE('CDB\$ROOT: DB_DDL_ALERT_TRG not found - skipped');
  END IF;
END;
/

-- Act on all open PDBs
DECLARE
  CURSOR c_pdbs IS
    SELECT name FROM v\$pdbs
    WHERE  open_mode = 'READ WRITE'
    AND    name != 'PDB\$SEED';
  v_count NUMBER;
BEGIN
  FOR pdb IN c_pdbs LOOP
    EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || pdb.name;
    SELECT COUNT(*) INTO v_count FROM dba_triggers
    WHERE trigger_name = 'DB_DDL_ALERT_TRG' AND owner = 'SYS';
    IF v_count > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ${sql_action}';
      DBMS_OUTPUT.PUT_LINE(pdb.name || ': DB_DDL_ALERT_TRG ${sql_action}D');
    ELSE
      DBMS_OUTPUT.PUT_LINE(pdb.name || ': DB_DDL_ALERT_TRG not found - skipped');
    END IF;
  END LOOP;
END;
/

-- Verify final status across all containers
SELECT con_id, owner, trigger_name, status
FROM   cdb_triggers
WHERE  trigger_name = 'DB_DDL_ALERT_TRG'
ORDER  BY con_id;

EXIT;
SQLEOF

  su - "${ORACLE_USER}" -c "
    export ORACLE_HOME=${OLD_DB_HOME}
    export ORACLE_SID=${DB_NAME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @/tmp/phase3_trigger_${action,,}.sql
  "
  rm -f /tmp/phase3_trigger_${action,,}.sql
  log "  Trigger ${sql_action} complete."
}

# ── Step 0: Disable DB_DDL_ALERT_TRG before outage ───────────────────────────
log "Step 0: Disabling DB_DDL_ALERT_TRG in CDB and all open PDBs..."
manage_ddl_trigger "DISABLE"

# ── Step 1: gridSetup.sh -switchGridHome (as grid) ───────────────────────────
log "Step 1: gridSetup.sh -switchGridHome (as ${GRID_USER})..."
rungrid "
  export ORACLE_HOME=${NEW_GRID_HOME}
  export CV_ASSUME_DISTID=${CV_ASSUME_DISTID}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/gridSetup.sh \
    -silent \
    -switchGridHome \
    oracle.install.crs.config.clusterNodes=${NODE_NAME}
"
log "gridSetup.sh -switchGridHome complete."

# ── Step 2: root.sh from new Grid home (as root) ─────────────────────────────
log "Step 2: Running root.sh from new Grid home..."
"${NEW_GRID_HOME}/root.sh"
log "Grid home root.sh complete."

# ── Step 2b: root.sh from new DB home (as root) ───────────────────────────────
# Required after runInstaller INSTALL_DB_SWONLY in Phase 2.
# Must run AFTER Grid home root.sh so the new Grid stack is active.
log "Step 2b: Running root.sh from new DB home..."
"${NEW_DB_HOME}/root.sh"
log "DB home root.sh complete."

# ── Step 3: Verify Grid ───────────────────────────────────────────────────────
log "Step 3: Verifying Grid resources (waiting 30s for stack to stabilise)..."
sleep 30

log "CRS release patch level:"
"${NEW_GRID_HOME}/bin/crsctl" query crs releasepatch

log "CRS resource status:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t

log "CRS init resources:"
"${NEW_GRID_HOME}/bin/crsctl" stat res -t -init

# ── Step 4: Update grid user profiles ────────────────────────────────────────
log "Step 4: Updating grid user profiles..."
GRID_HOME_DIR=$(eval echo ~${GRID_USER})
for profile in "${GRID_HOME_DIR}/.bash_profile" "${GRID_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    sed -i "s|${OLD_GRID_HOME}|${NEW_GRID_HOME}|g" "${profile}"
    log "  Updated: ${profile}"
  fi
done

# ── Step 4b: Update root user profiles ───────────────────────────────────────
# root may have ORACLE_HOME pointing to the Grid home for crsctl/srvctl access.
# Update the same way as grid user profiles.
log "Step 4b: Updating root user profiles..."
ROOT_HOME_DIR=$(eval echo ~root)
for profile in "${ROOT_HOME_DIR}/.bash_profile" "${ROOT_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    if grep -q "${OLD_GRID_HOME}" "${profile}"; then
      sed -i "s|${OLD_GRID_HOME}|${NEW_GRID_HOME}|g" "${profile}"
      log "  Updated: ${profile}"
    else
      log "  Skipped: ${profile} (no reference to ${OLD_GRID_HOME})"
    fi
  fi
done

# ── Step 5: AutoUpgrade deploy (as oracle) ────────────────────────────────────
log "Step 5: AutoUpgrade deploy — DB home switch + datapatch..."
log "  Config   : ${AUTOUPGRADE_CFG}"
log "  New Home : ${NEW_DB_HOME}"

# Auto-detect DB name if not set in patch.conf
if [[ -z "${DB_NAME}" ]]; then
  DB_NAME=$(runoracle "
    export ORACLE_HOME=${NEW_GRID_HOME}
    export PATH=\${ORACLE_HOME}/bin:\${PATH}
    \${ORACLE_HOME}/bin/srvctl list database 2>/dev/null | head -1
  " || true)
  [[ -z "${DB_NAME}" ]] && die "Could not detect database name via srvctl."
  log "  Auto-detected database: ${DB_NAME}"
fi
log "  Database: ${DB_NAME}"

runoracle "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${DB_NAME}
  export PATH=\${ORACLE_HOME}/bin:/usr/local/bin:/usr/bin:/bin
  \${ORACLE_HOME}/jdk/bin/java \
    -jar \${ORACLE_HOME}/rdbms/admin/autoupgrade.jar \
    -config ${AUTOUPGRADE_CFG} \
    -mode deploy \
    -noconsole
"
log "AutoUpgrade deploy complete."

# ── Step 5b: Re-enable DB_DDL_ALERT_TRG after outage ─────────────────────────
log "Step 5b: Re-enabling DB_DDL_ALERT_TRG in CDB and all open PDBs..."
# Use new DB home now that AutoUpgrade has switched the database
cat > /tmp/phase3_trigger_enable.sql << 'SQLEOF'
SET PAGESIZE 100 LINESIZE 120 FEEDBACK ON SERVEROUTPUT ON

-- Re-enable in CDB$ROOT
ALTER SESSION SET CONTAINER = CDB$ROOT;
DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM dba_triggers
  WHERE trigger_name = 'DB_DDL_ALERT_TRG' AND owner = 'SYS';
  IF v_count > 0 THEN
    EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ENABLE';
    DBMS_OUTPUT.PUT_LINE('CDB$ROOT: DB_DDL_ALERT_TRG ENABLED');
  ELSE
    DBMS_OUTPUT.PUT_LINE('CDB$ROOT: DB_DDL_ALERT_TRG not found - skipped');
  END IF;
END;
/

-- Re-enable in all open PDBs
DECLARE
  CURSOR c_pdbs IS
    SELECT name FROM v$pdbs
    WHERE  open_mode = 'READ WRITE'
    AND    name != 'PDB$SEED';
  v_count NUMBER;
BEGIN
  FOR pdb IN c_pdbs LOOP
    EXECUTE IMMEDIATE 'ALTER SESSION SET CONTAINER = ' || pdb.name;
    SELECT COUNT(*) INTO v_count FROM dba_triggers
    WHERE trigger_name = 'DB_DDL_ALERT_TRG' AND owner = 'SYS';
    IF v_count > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TRIGGER SYS.DB_DDL_ALERT_TRG ENABLE';
      DBMS_OUTPUT.PUT_LINE(pdb.name || ': DB_DDL_ALERT_TRG ENABLED');
    ELSE
      DBMS_OUTPUT.PUT_LINE(pdb.name || ': DB_DDL_ALERT_TRG not found - skipped');
    END IF;
  END LOOP;
END;
/

-- Verify final status
SELECT con_id, owner, trigger_name, status
FROM   cdb_triggers
WHERE  trigger_name = 'DB_DDL_ALERT_TRG'
ORDER  BY con_id;

EXIT;
SQLEOF

su - "${ORACLE_USER}" -c "
  export ORACLE_HOME=${NEW_DB_HOME}
  export ORACLE_SID=${DB_NAME}
  export PATH=\${ORACLE_HOME}/bin:\${PATH}
  \${ORACLE_HOME}/bin/sqlplus -s / as sysdba @/tmp/phase3_trigger_enable.sql
"
rm -f /tmp/phase3_trigger_enable.sql
log "DB_DDL_ALERT_TRG re-enabled."

# ── Step 6: Update oracle user profiles ───────────────────────────────────────
log "Step 6: Updating oracle user profiles..."
ORACLE_HOME_DIR=$(eval echo ~${ORACLE_USER})
for profile in "${ORACLE_HOME_DIR}/.bash_profile" "${ORACLE_HOME_DIR}/.bashrc"; do
  if [[ -f "${profile}" ]]; then
    if grep -q "${OLD_DB_HOME}" "${profile}"; then
      sed -i "s|${OLD_DB_HOME}|${NEW_DB_HOME}|g" "${profile}"
      log "  Updated: ${profile}"
    else
      log "  Skipped: ${profile} (no reference to ${OLD_DB_HOME})"
    fi
  fi
done

log "=== PHASE 3 COMPLETE ==="
log ""
log "Verify with:"
log "  ${NEW_GRID_HOME}/bin/crsctl query crs releasepatch"
log "  ${NEW_GRID_HOME}/bin/crsctl stat res -t"
log "  sqlplus / as sysdba <<< \"SELECT patch_id,status FROM dba_registry_sqlpatch;\""
