# Oracle 19c OOP Patch Automation Framework
## Single Node CRS, separate OS users (`grid` owns Grid Infrastructure, `oracle` owns the database)

Version 3 of the two-user framework (base: github.com/aarishashailesh/oop-db-patch-19c).
For hosts where `grid` and `oracle` are the same account, use the single-owner build instead.

---

## Environment this version targets

| Item | Value |
|---|---|
| Grid Infrastructure owner | `grid` (`GRID_USER`) |
| Database owner | `oracle` (`ORACLE_USER`) |
| Primary group | `oinstall` (`INSTALL_GROUP`) |
| ASM groups (OSDBA / OSOPER / OSASM) | for example `asmdba` / `asmoper` / `asmadmin`; take the real values from your original Grid response file |
| Grid base (`GRID_BASE`) | for example `/u01/app/grid` |
| Database base (`ORACLE_BASE`) | for example `/u01/app/oracle` |

The orchestrator is started as **root**. Phase 1 runs as `grid` and Phase 2 as `oracle` (via `sudo -u`). Phases 3 to 7 run as root and switch to `grid` or `oracle` with `su -` where needed.

---

## Directory Layout

```
/u01/shared/software/patches/automation/   <- SCRIPTS_DIR (readable by grid and oracle, never under /root)
|-- patch.conf                             <- EDIT THIS FOR EACH PATCH CYCLE
|-- patch_orchestrator.sh                  <- Master orchestrator (run as root)
|-- phase1_grid_prep.sh                    <- Build + patch new Grid home      (grid)
|-- phase2_db_prep.sh                      <- Build + patch new DB home        (oracle)
|-- phase3_switch.sh                       <- Home switch + AutoUpgrade deploy (root, su - grid / oracle)
|-- phase4_post_install.sh                 <- Post-patch validation + utlrp    (root, su - oracle)
|-- phase5_cleanup.sh                      <- Detach + remove old homes        (manual)
|-- phase6_security.sh                     <- FIPS file + extproc disable      (manual)
|-- phase7_aide.sh                         <- AIDE baseline reset              (manual)
`-- README.md

/u01/shared/software/patches/1932/         <- PATCH_LOC (staging)
|-- logs/                                  <- LOG_DIR: phaseN_*.log and .phase_status/phaseN.done
|-- p6880880_190000_Linux-x86-64.zip       <- Latest OPatch
|-- p<RU_COMBO>_190000_Linux-x86-64.zip    <- RU combo (Phase 1 extracts it here)
|-- p<DB_STANDALONE>_*.zip                 <- Standalone DB patch (Phase 2 extracts it here)
|-- autoupgrade.jar
`-- orcl_auto_patch.cfg                    <- AutoUpgrade config

/u01/rsp/grid_install.rsp , db_install.rsp <- GRID_RSP / DB_RSP templates (never modified)
/u01/shared/software/db/base_releases/     <- BASE_SW_DIR: LINUX.X64_193000_grid_home.zip, LINUX.X64_193000_db_home.zip
```

Extracted patch directories appear under `PATCH_LOC` only after Phases 1 and 2 run.

---

## For Each New Patch Cycle

**Only edit `patch.conf`.**

### Patch identity (always update)
| Variable | Description |
|---|---|
| `NEW_PATCH_LEVEL` / `OLD_PATCH_LEVEL` | Labels used in logs |
| `RU_COMBO_PATCH` | Outer RU combo patch number |
| `GI_RU_PATCH` | GI RU bundle directory inside the combo (contains `bundle.xml`) |
| `GI_APPLY_RU_PATCH` | `gridSetup.sh -applyRU` sub-patch (OCW) |
| `GI_ONEOFF_PATCHES` | `gridSetup.sh -applyOneOffs`, comma-separated IDs |
| `DB_APPLY_RU_PATCH` | `runInstaller -applyRU` sub-patch (DB RU) |
| `DB_ONEOFF_PATCHES` | `runInstaller -applyOneOffs`, comma-separated IDs |
| `RU_COMBO_TOPLEVEL_PATCHES` | Patches at the top level of the combo (for example OJVM) |
| `DB_RU_STANDALONE_PATCH` / `DB_RU_STANDALONE_ZIP` | Standalone DB patch number and zip name |

### Home paths (explicit, never derived from the patch level)
`OLD_GRID_HOME`, `NEW_GRID_HOME`, `OLD_DB_HOME`, `NEW_DB_HOME`.

> **No trailing slash on any home path.** The orchestrator now stops with an error if one is found.
> Phases 1 and 3 run `sed s|OLD|NEW|` over helper scripts and profile files, and Phase 3 compares
> `NEW_GRID_HOME` with `crs_home` in `/etc/oracle/olr.loc`. A trailing `/` makes both miss.

### Users, groups, bases (set once per host)
```bash
GRID_USER="grid"
ORACLE_USER="oracle"
INSTALL_GROUP="oinstall"
GI_OSDBA_GROUP="asmdba"       # use the values in the ORIGINAL grid response file
GI_OSOPER_GROUP="asmoper"
GI_OSASM_GROUP="asmadmin"
GRID_BASE="/u01/app/grid"
ORACLE_BASE="/u01/app/oracle"
DB_NAME="proddb"              # CRS database name (srvctl config database); empty = auto-detect
```
Verify the groups with: `grep -i "osdba\|osoper\|osasm" /u01/rsp/grid_install.rsp`

### Response files
These are templates only. Each run works on a temporary copy.
- Phase 1 rewrites `ORACLE_HOME`, forces `oracle.install.option=CRS_SWONLY` and sets `clusterNodes`.
- Phase 2 rewrites only `ORACLE_HOME` in the DB response file.
- Phase 3 rewrites OSDBA / OSOPER / OSASM from `patch.conf`, forces `CRS_SWONLY`, keeps `clusterNodes` from the template (it must read `<short-host>:<short-host>-vip.<domain>`). The copy is handed to `grid` with mode 600 and passwords are never logged.

---

## Running the Orchestrator (as root)

### Validate configuration first
```bash
./patch_orchestrator.sh --phase 1 --dry-run
```
A dry run checks `patch.conf` values, trailing slashes, `PATCH_LOC` and that `grid` can read the scripts. It does not check that the patch zips exist.

### Phase by phase (recommended)
```bash
./patch_orchestrator.sh --phase 1    # Grid home prep (online)
./patch_orchestrator.sh --phase 2    # DB home prep + AutoUpgrade analyze (online)
./patch_orchestrator.sh --phase 3    # Switch (OUTAGE)
./patch_orchestrator.sh --phase 4    # Post-patch validation
```

### Hardened hosts: run every phase with `systemd-run`
Where logind kills the session (`KillUserProcesses=yes`, idle session stop after 600 s, `TMOUT=600`), `nohup` and `&` die with the login session. Start each phase as a transient systemd service instead. It is owned by PID 1, outside your session, so logout and idle timeouts cannot kill it. No phase script prompts for input, so no tty is needed. `--working-directory` is deliberately not used (it needs systemd 233 or newer, so it fails on OL7); the commands below use full paths.

Use one unit name per phase. Run as root:

| Phase | Start command |
|---|---|
| 1 Grid home prep | `systemd-run --unit=oppatch-p1 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 1` |
| 2 DB home prep | `systemd-run --unit=oppatch-p2 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 2` |
| 3 Switch (OUTAGE) | `systemd-run --unit=oppatch-p3 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 3` |
| 4 Post-patch validation | `systemd-run --unit=oppatch-p4 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 4` |
| 5 Cleanup | `systemd-run --unit=oppatch-p5 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 5` |
| 6 FIPS + extproc | `systemd-run --unit=oppatch-p6 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 6` |
| 7 AIDE reset | `systemd-run --unit=oppatch-p7 --remain-after-exit /u01/shared/software/patches/automation/patch_orchestrator.sh --phase 7` |

Shortcut for the current shell, so each phase is `oppatch 1`, `oppatch 2`, and so on (adjust the path if `SCRIPTS_DIR` differs):
```bash
oppatch() {   # usage: oppatch <phase> [extra orchestrator args, e.g. --dry-run]
  local n="$1"; shift
  systemctl stop "oppatch-p${n}" 2>/dev/null || true         # clear a finished unit of the same name
  systemctl reset-failed "oppatch-p${n}" 2>/dev/null || true
  systemd-run --unit="oppatch-p${n}" --remain-after-exit \
    /u01/shared/software/patches/automation/patch_orchestrator.sh --phase "${n}" "$@"
}
oppatchstat() {   # usage: oppatchstat <phase>
  systemctl show "oppatch-p$1" -p ActiveState -p SubState -p Result -p ExecMainStatus
}
```

Watch a phase (all safe to repeat after a reconnect):
```bash
tail -n 50 /u01/shared/software/patches/1932/logs/master_patch.log
systemctl status oppatch-p1 --no-pager
systemctl show oppatch-p1 -p ActiveState -p Result -p ExecMainStatus
# finished OK: ActiveState=active (exited) Result=success ExecMainStatus=0
# failed:      Result=exit-code and a non-zero ExecMainStatus; read the phase log in LOG_DIR
journalctl -u oppatch-p1 --no-pager | tail -n 50
systemctl stop oppatch-p1          # clear the unit when you are done
```
Notes:
- The orchestrator already writes `master_patch.log` and a log per phase; the journal is a backup.
- Do not sit in a foreground `tail -f` or `sleep` for more than 10 minutes. `TMOUT` logs you out (the phase keeps running).
- Start the next phase only after `Result=success`. The `.phase_status` markers enforce the order anyway.
- Keep Phase 3 (the outage) as its own unit so you decide when it starts. `--from-phase 1` with no `--phase` runs 1 to 4 in one unit.
- `enable-linger` is not needed. It is for `systemd-run --user`, not for system units.
- Never pass a password with `--setenv`; it would appear in `systemctl show`.

### Practicing `systemd-run` on the home lab
The lab has none of the office hardening, so recreate it, then compare `nohup` with `systemd-run`:
```bash
# as root on the lab host
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nKillUserProcesses=yes\nStopIdleSessionSec=600\n' > /etc/systemd/logind.conf.d/99-lab-hardening.conf
printf 'readonly TMOUT=600\nexport TMOUT\n' > /etc/profile.d/99-lab-tmout.sh
systemctl restart systemd-logind        # or reboot; then log in again so TMOUT applies
```
`StopIdleSessionSec` needs systemd 252 or newer and is ignored on older releases. `KillUserProcesses=yes` plus `TMOUT=600` is enough to reproduce the behavior.

In a fresh login:
```bash
nohup sleep 1500 > /dev/null 2>&1 &                    # dies when the session ends
systemd-run --unit=survivor --remain-after-exit sleep 1500
# wait for the idle logout at 10 minutes, log in again as root, then:
pgrep -a sleep ; systemctl status survivor --no-pager  # nohup sleep gone, survivor still running
systemctl stop survivor
```
Then run `oppatch 1 --dry-run` and a real Phase 1 on the lab, reconnecting midway. Remove the lab hardening afterwards: delete the two files above and restart `systemd-logind`.

### Other options
```bash
./patch_orchestrator.sh --from-phase 2     # resume after fixing a failure
./patch_orchestrator.sh --cleanup          # also run phase 5
./patch_orchestrator.sh --full             # phases 1-7
./patch_orchestrator.sh --reset-status     # clear markers after a snapshot restore
```

---

## Phase Summary

| Phase | Script | Runs as | Window | Description |
|---|---|---|---|---|
| 1 | phase1_grid_prep.sh | grid | Online | Extract base Grid, OPatch, RU combo; `gridSetup.sh -applyRU/-applyOneOffs` (CRS_SWONLY); exit code 6 accepted |
| 2 | phase2_db_prep.sh | oracle | Online | Extract base DB, OPatch, standalone patch; `runInstaller -applyRU/-applyOneOffs`; AutoUpgrade analyze; exit code 6 accepted; resumes at Step 8 if the home exists |
| 3 | phase3_switch.sh | root, then `su - grid` / `su - oracle` | **OUTAGE** | Step 0a disables `SYS.DB_DDL_ALERT_TRG`; stop listener; `gridSetup.sh -switchGridHome` (exit code 6 accepted); `root.sh`; AutoUpgrade deploy; profile updates; CRS/oratab check |
| 4 | phase4_post_install.sh | root, then `su - oracle` | Online | `utlrp`, registry validation, Step F enables `SYS.DB_DDL_ALERT_TRG` |
| 5 | phase5_cleanup.sh | root | Manual | `runInstaller -detachHome` for the old DB home (as oracle) and old Grid home (as grid), then remove the old directories |
| 6 | phase6_security.sh | root | Manual | FIPS file, disable `extproc` |
| 7 | phase7_aide.sh | root | Manual | Reset AIDE baseline (must run last) |

Phase order is enforced by markers in `.phase_status`.

---

## What changed in this version

1. **Exit code 6.** `gridSetup.sh` and `runInstaller` exit with 6 when the install succeeded with optional prerequisite warnings (`INS-13014`). Phase 1 (`-applyRU`), Phase 2 (`runInstaller`) and Phase 3 (`-switchGridHome`) capture the code explicitly and continue on 0 and 6. Any other code stops the phase (Phase 1 additionally checks the installer logs for success before giving up).
2. **Phase 3 `INS-10105 ... (Permission denied)`.** The temporary response file was created by root with the template's mode (often 600) and read by `gridSetup.sh` as `grid`. It is now `chown grid:oinstall` and `chmod 600`, and password lines are filtered from the log.
3. **Listener stop** tolerates a listener that is already down (safe to re-run Phase 3).
4. **`SYS.DB_DDL_ALERT_TRG`.** Disabled in Phase 3 Step 0a, enabled in Phase 4 Step F (details below).
5. **Phase 5 uses `runInstaller -detachHome`** instead of `deinstall` (details below). The hardcoded `ora.proddb.db` is replaced by `ora.${DB_NAME}.db`.
6. **Trailing slash check** on the four home variables in the orchestrator.
7. **`systemd-run`** instructions for every phase, without `--working-directory`.
8. **Phase 3 Step 9** verifies the CRS database home, `/etc/oratab` and `olr.loc` (read-only, warnings only).
9. Every `su -` call starts with `unset LD_LIBRARY_PATH` so a profile that exports a Grid library path cannot leak into the installers.

## SYS.DB_DDL_ALERT_TRG

- **Phase 3, Step 0a** (before the listener is stopped and before AutoUpgrade): `alter trigger SYS.DB_DDL_ALERT_TRG disable` in a non-CDB, or in the CDB root and every READ WRITE PDB. The database must be open. If the trigger cannot be disabled, Phase 3 stops before anything is shut down. It runs as `oracle` from the old DB home.
- **Phase 4, Step F:** the same with `enable`, from the new DB home. If it fails, Phase 4 stops (no success marker), so Phase 5 cannot run until the trigger is enabled.
- Containers without the trigger are skipped. PDBs that are not READ WRITE are listed in the log as warnings.

Manual check or fix:
```sql
select owner, trigger_name, status from dba_triggers where trigger_name = 'DB_DDL_ALERT_TRG';
alter trigger SYS.DB_DDL_ALERT_TRG enable;     -- in the root and in each PDB (alter session set container = <pdb>)
```

## Phase 5 cleanup: detachHome, not deinstall

Each old home is detached from the inventory by its own owner, using the `runInstaller` of the new home:
```bash
# as oracle
<NEW_DB_HOME>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<OLD_DB_HOME>
# as grid
<NEW_GRID_HOME>/oui/bin/runInstaller -silent -detachHome ORACLE_HOME=<OLD_GRID_HOME>
```
The environment is cleaned first (`unset ORACLE_HOME ORACLE_SID LD_LIBRARY_PATH`). Only after both detaches succeed are the old directories removed, and `rm -rf` refuses `/`, `/u01`, `/u01/app` and any directory that contains a new home. A home that is already detached or marked `REMOVED="T"` is skipped, so Phase 5 can be re-run. If a detach fails, nothing is deleted.

Phase 5 does not prompt. It is only run with `--phase 5`, `--cleanup` or `--full`, and requires Phases 1 to 4 to be complete. Wait at least 24 hours after patching.

Check by hand: `grep -i "HOME NAME" /u01/app/oraInventory/ContentsXML/inventory.xml`
If an earlier cleanup deleted the directories but left the homes registered, run the two `-detachHome` commands above from the new homes.

## Known Issues and Notes

- **Not Data Guard aware.** The scripts patch the host they run on. Use the Data Guard framework for a primary and standby pair.
- `gridSetup.sh -switchGridHome` cannot be re-run once CRS is already running from the new home (`INS-45102`). Phase 3 detects that case and skips to the AutoUpgrade deploy step.
- `srvctl modify database -o` must run with `ORACLE_HOME` set to the old home. Phase 3 handles this.
- `opatch lspatches` on a new home can return errors before the switch. Use the `.patch_storage` listing for pre-switch checks.
- Do not shut the database down before Phase 3 Step 7. AutoUpgrade deploy needs it running to connect to the source home.
- `chopt` options apply to non-CDB databases only. Skip them for CDBs.
- `CV_ASSUME_DISTID=OEL7.8` is exported from `patch.conf`. Without it, `gridSetup.sh` and `runInstaller` can fail with `INS-08101` or a `NullPointerException`.
- A stale `PDB_PLUG_IN_VIOLATIONS` row can block the AutoUpgrade analyze step. Closing and reopening the PDB refreshes it.

## Troubleshooting quick reference

| Symptom | Likely cause | Action |
|---|---|---|
| `INS-10105 ... (Permission denied)` in Phase 3 | Temp response file owned by root | Use this `phase3_switch.sh` |
| `.bashrc` still shows the old Grid home after Phase 3 | Trailing `/` on `OLD_GRID_HOME` | Remove the slash in `patch.conf`, fix the profile by hand |
| Orchestrator: "has a trailing slash" | Home path ends with `/` | Remove it in `patch.conf` |
| `bash: unset: ... not a valid identifier` in Phase 5 | Old `deinstall` block with a broken `unset` continuation | Use this Phase 5, detach the homes by hand if the inventory still lists them |
| `INS-41885` on `switchGridHome` | Group values wrong or passed on the command line | Set `GI_OS*_GROUP` to match the original Grid response file |
| `CLSRSC-901` in `root.sh` | Old home path left in `root.sh` or `rootmacro.sh` | Phase 3 Step 3 corrects it, re-run the phase |
| Exit code 6 from `gridSetup.sh` / `runInstaller` | Optional prerequisite warnings | Accepted by Phases 1, 2 and 3 |
| Phase 3 stops at Step 0a | Database not open, or trigger could not be altered | Open the database, re-run Phase 3 (nothing was stopped yet) |
| Phase 4 stops at Step F | Trigger could not be enabled | Enable it by hand in the root and each PDB, re-run Phase 4 |
| `TNS-01190` from `lsnrctl stop` | Listener is CRS-managed | Use `srvctl stop listener` as `grid` |
| `kfod` Error 49802 in AutoUpgrade analyze | ADR directory owned by wrong user | `chown -R oracle:oinstall $ORACLE_BASE/diag` |
| "Phase N has not completed" | Missing success marker | Run earlier phases, or `--reset-status` after a snapshot restore |
