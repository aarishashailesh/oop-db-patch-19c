# Oracle 19c OOP Patch Automation Framework
## Single Node CRS (lnx98.home.aarisha.com) — 19.31 → 19.32

---

## Log Review Summary — Successful Full Run (2026-08-14)

| Phase | Start | End | Duration | Result |
|---|---|---|---|---|
| 1 — Grid Home Prep | 14:27:51 | 14:45:41 | ~18 min | ✅ COMPLETE |
| 2 — DB Home Prep | 14:45:41 | 15:11:11 | ~25 min | ✅ COMPLETE |
| 3 — Home Switch | 15:11:11 | 16:23:45 | ~72 min | ✅ COMPLETE |
| 4 — Post Install | 16:23:45 | 16:25:33 | ~2 min | ✅ COMPLETE |
| 5 — Cleanup | 16:39:37 | 16:40:12 | ~1 min | ✅ COMPLETE |
| 6 — Security | 16:44:16 | 16:44:16 | <1 min | ✅ COMPLETE |
| 7 — AIDE | 16:56:38 | 16:58:08 | ~2 min | ✅ COMPLETE |

**Total patch cycle: ~2.5 hours**

### Key Findings from Log Review

**Phase 1 — All 5 patches applied successfully:**
- Base Grid 19.3 extracted (2 min)
- OPatch 12.2.0.1.52 installed
- RU combo 39618711 extracted
- gridSetup.sh CRS_SWONLY applied: 39526364, 39107825, 39107855, 39472050, 39503034 — all OK
- Binary integrity: oracle=421MB, lsnrctl=185KB, zero-byte count=5 (expected)

**Phase 2 — All 4 patches applied successfully:**
- Base DB 19.3 extracted (2 min)
- OPatch 12.2.0.1.52 installed
- runInstaller applied: 39472050 (RU), 39526364, 39222882 (OJVM), 39657094 (DataPump) — all OK
- AutoUpgrade analyze: 1 CDB + 2 PDBs, 0 failures

**Phase 3 — Grid switch and AutoUpgrade deploy completed:**
- DB_DDL_ALERT_TRG disabled in CDB$ROOT and PDB1 ✅
- Pre-patch connectivity: SYSDBA OK, tnsping proddb OK (10ms), tnsping SCAN OK (10ms)
- gridSetup.sh -switchGridHome completed
- root.sh (Grid) and root.sh (DB) both executed
- AutoUpgrade deploy: 1 job finished, 0 failed
- Post-patch connectivity: tnsping SCAN OK (10ms) ✅
- DB_DDL_ALERT_TRG re-enabled ✅
- grid and oracle bash_profiles updated ✅

**Phase 4 — All validations passed:**
- chopt disable olap/rat/partitioning completed (gcc warning is cosmetic — KVM guest has no compiler, but chopt succeeds via make fallback)
- utlrp: OBJECTS WITH ERRORS = 0, ERRORS DURING RECOMPILATION = 0 ✅
- XOQ_VALIDATE and APS_VALIDATE: both completed successfully ✅
- v$option: Partitioning=FALSE, OLAP=FALSE, Real Application Testing=FALSE ✅
- dba_registry: APS=OPTION OFF, XOQ=OPTION OFF ✅
- All 15 components: VALID or OPTION OFF ✅
- Grid: 19.32.0.0.0 [39107825 39107855 39472050 39503034 39526364] ✅
- Database running from: /u01/app/oracle/product/19.0.0/dbhome_1932 ✅
- CDB: READ WRITE, PDB1: READ WRITE, PDB$SEED: READ ONLY ✅

**Phase 4 — datapatch shows WITH ERRORS — KNOWN ISSUE:**
Patches 39657094, 39472050, 39222882 show `WITH ERRORS (PREV PATCH)`.
This is expected from the previous patch cycle run. These are superseded
entries from a prior failed/partial run. The current successful run shows
SUCCESS rows above them. Verify with:
```sql
SELECT patch_id, status, description
FROM dba_registry_sqlpatch
ORDER BY action_time DESC;
-- The most recent rows (top) must show SUCCESS
```

**Phase 5 — Old homes removed cleanly:**
- /u01/app/19.0.0 (6.5GB) removed ✅
- /u01/app/oracle/product/19.0.0/dbhome_1 (7.0GB) removed ✅
- Deinstall tool WARNING is cosmetic — silent mode requires -paramfile which we skip; rm -rf handles actual removal ✅

**Phase 6 — Security hardening complete:**
- fips.ora: SSLFIPS_140=TRUE written, permissions 640 oracle:oinstall ✅
- extproc renamed to extproc.orig ✅

**Phase 7 — AIDE complete:**
- First attempt: AIDE not installed — skipped (AIDE was installed manually then re-run)
- Second run: aide --update in UPDATE mode (master db existed) ✅
- Result: "AIDE found NO differences" — confirms patched files already baselined ✅
- 168,549 entries, 1m 16s runtime
- NOTE: Install AIDE before patch cycle with: `dnf install -y aide`

---

## Directory Layout

```
/u01/patching/automation/          ← Scripts directory (accessible by root, grid, oracle)
├── patch.conf                     ← EDIT THIS FOR EACH PATCH CYCLE
├── patch_orchestrator.sh          ← Master orchestrator (run as root)
├── phase1_grid_prep.sh            ← Build + patch new Grid home   (online)
├── phase2_db_prep.sh              ← Build + patch new DB home     (online)
├── phase3_switch.sh               ← Home switch + AutoUpgrade     (OUTAGE)
├── phase4_post_install.sh         ← Post-patch validation + utlrp (online)
├── phase5_cleanup.sh              ← Deinstall old homes           (manual)
├── phase6_security.sh             ← FIPS 140 + extproc disable    (manual)
├── phase7_aide.sh                 ← AIDE integrity DB reset       (manual)
└── README.md                      ← This file

/u01/patching/patches/1932/        ← Patch staging (PATCH_LOC)
├── p6880880_190000_Linux-x86-64.zip     ← Latest OPatch
├── p39618711_190000_Linux-x86-64.zip    ← RU Combo zip
├── p39657094_1932000DBRU_Generic.zip    ← DataPump standalone patch
├── autoupgrade.jar                       ← Latest AutoUpgrade JAR
├── orcl_auto_patch.cfg                   ← AutoUpgrade config file
└── 39618711/                             ← Extracted by phase 1 automatically
    ├── 39222882/                         ← OJVM (top-level in combo)
    └── 39467003/                         ← GI RU bundle
        ├── 39107825/  39107855/
        ├── 39472050/  39503034/
        └── 39526364/

/u01/shared/software/db/base_releases/   ← BASE_SW_DIR (reused every cycle)
├── LINUX.X64_193000_grid_home.zip       ← Base Grid 19.3 software
└── LINUX.X64_193000_db_home.zip         ← Base DB 19.3 software

/u01/patching/logs/logs_1932/            ← LOG_DIR for this cycle
├── master_patch.log                     ← Orchestrator master log
├── phase1_grid_prep.log                 ← Phase 1 detail log
├── phase2_db_prep.log                   ← Phase 2 detail log
├── phase3_switch.log                    ← Phase 3 detail log (largest — ~67KB)
├── phase4_post_install.log              ← Phase 4 detail log
├── phase4_validation.log                ← v$option + registry validation output
├── phase5_cleanup.log                   ← Phase 5 detail log
├── phase6_security.log                  ← Phase 6 detail log
└── phase7_aide.log                      ← Phase 7 detail log

/u01/rsp/                                ← Response files (reused every cycle)
├── grid_install.rsp                     ← Grid response file (ORACLE_HOME updated per run)
└── db_install.rsp                       ← DB response file (ORACLE_HOME updated per run)
```

---

## Pre-Patch Checklist

Before running the orchestrator for a new patch cycle:

**1. Download patch files to PATCH_LOC:**
```bash
ls -lh /u01/patching/patches/1932/
# Must have:
#   p<OPATCH>_190000_Linux-x86-64.zip
#   p<RU_COMBO>_190000_Linux-x86-64.zip
#   p<DB_STANDALONE>_<version>_Generic.zip
#   autoupgrade.jar  (latest from MOS)
#   orcl_auto_patch.cfg
```

**2. Verify base software zips exist (reused every cycle):**
```bash
ls /u01/shared/software/db/base_releases/
# Must have:
#   LINUX.X64_193000_grid_home.zip
#   LINUX.X64_193000_db_home.zip
```

**3. Update patch.conf — the only file you edit each cycle:**
```bash
vi /u01/patching/automation/patch.conf
```

**4. Ensure AIDE is installed (required for Phase 7):**
```bash
rpm -q aide || dnf install -y aide
# If first-time AIDE init needed:
aide --init
cp -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
```

**5. Verify response files exist:**
```bash
ls -l /u01/rsp/grid_install.rsp /u01/rsp/db_install.rsp
```

**6. Take a Proxmox snapshot of lnx98 before patching:**
```bash
# From lnx173 Proxmox host — snapshot the VM at 19.31 baseline
```

---

## Updating patch.conf for Each Patch Cycle

`patch.conf` is the **only** file you edit between cycles. All paths, patch numbers, and derived variables are controlled from this single file.

### Variables to update every cycle:

```bash
# Patch level labels (for log messages)
NEW_PATCH_LEVEL="19.33"          # ← new target
OLD_PATCH_LEVEL="19.32"          # ← current running

# RU Combo — outer zip patch number
RU_COMBO_PATCH="<new_number>"

# GI RU bundle directory inside the combo (contains bundle.xml)
GI_RU_PATCH="<new_number>"

# gridSetup.sh -applyRU: OCW sub-patch inside GI_RU_PATCH
GI_APPLY_RU_PATCH="<new_number>"

# gridSetup.sh -applyOneOffs: comma-separated IDs inside GI_RU_PATCH bundle
GI_ONEOFF_PATCHES="<id1>,<id2>,<id3>,<id4>"

# runInstaller -applyRU: DB RU sub-patch inside GI_RU_PATCH
DB_APPLY_RU_PATCH="<new_number>"

# runInstaller -applyOneOffs: comma-separated IDs inside GI_RU_PATCH bundle
DB_ONEOFF_PATCHES="<id1>,<id2>"

# Top-level RU combo patches (e.g. OJVM — lives at combo_root/<id>/ not in bundle)
RU_COMBO_TOPLEVEL_PATCHES="<ojvm_id>"

# Standalone DB patches outside the combo (e.g. DataPump)
DB_RU_STANDALONE_PATCH="<new_number>"
DB_RU_STANDALONE_ZIP="p<new_number>_<version>_Generic.zip"

# Home paths — explicit full paths (Grid and DB use different naming conventions)
OLD_GRID_HOME="/u01/app/19.32.0.0/grid"     # ← currently active
NEW_GRID_HOME="/u01/app/19.33.0.0/grid"     # ← new home to build

OLD_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1932"   # ← currently active
NEW_DB_HOME="/u01/app/oracle/product/19.0.0/dbhome_1933"   # ← new home to build
```

### How to identify patch layout from the RU combo:
```bash
# After downloading, check what's inside the combo zip:
unzip -l p<RU_COMBO>.zip | grep -E "^[0-9]+.*/$" | head -20
# Top-level dirs = RU_COMBO_TOPLEVEL_PATCHES (e.g. OJVM)
# Bundle dir (contains bundle.xml) = GI_RU_PATCH
# Sub-dirs inside bundle = GI_ONEOFF_PATCHES / DB_ONEOFF_PATCHES / GI_APPLY_RU_PATCH
```

---

## Running the Orchestrator

### Standard full patch run (Phases 1–4, no cleanup):
```bash
cd /u01/patching/automation/

nohup ./patch_orchestrator.sh --from-phase 1 \
  > /u01/patching/logs/logs_1932/full_patch_nohup.log 2>&1 &

echo "PID: $!"

# Monitor
tail -f /u01/patching/logs/logs_1932/master_patch.log
```

### Run a single phase:
```bash
./patch_orchestrator.sh --phase 1     # Grid home prep only
./patch_orchestrator.sh --phase 2     # DB home prep only
./patch_orchestrator.sh --phase 3     # Switch only (outage)
./patch_orchestrator.sh --phase 4     # Validation only
```

### Resume from a phase (after fixing a failure):
```bash
./patch_orchestrator.sh --from-phase 2    # Resume from phase 2
./patch_orchestrator.sh --from-phase 3    # Re-run switch + everything after
```

### Dry run (shows what would happen, no execution):
```bash
./patch_orchestrator.sh --phase 1 --dry-run
./patch_orchestrator.sh --from-phase 1 --dry-run
```

### Run cleanup (Phase 5) after validation — wait 24h first:
```bash
./patch_orchestrator.sh --phase 5
```

### Run security hardening (Phase 6):
```bash
./patch_orchestrator.sh --phase 6
```

### Run AIDE reset (Phase 7):
```bash
./patch_orchestrator.sh --phase 7
```

### Run full cycle including cleanup, security, and AIDE:
```bash
./patch_orchestrator.sh --from-phase 1 --full
```

---

## Phase Summary

| Phase | Script | Run As | Window | Description |
|---|---|---|---|---|
| 1 | phase1_grid_prep.sh | grid | **Online** | Extract base + OPatch, run gridSetup.sh CRS_SWONLY -applyRU |
| 2 | phase2_db_prep.sh | oracle | **Online** | Extract base + OPatch, run runInstaller, AutoUpgrade analyze |
| 3 | phase3_switch.sh | root | **OUTAGE** | Disable trigger, connectivity check, switchGridHome, root.sh×2, AutoUpgrade deploy, re-enable trigger |
| 4 | phase4_post_install.sh | root | **Online** | chopt disable, utlrp, XOQ/APS validate, v$option verify, Grid verify |
| 5 | phase5_cleanup.sh | root | Online | Deinstall old Grid and DB homes (`--cleanup` flag) |
| 6 | phase6_security.sh | root | Online | Create fips.ora, disable extproc |
| 7 | phase7_aide.sh | root | Online | aide --update or --init, promote to master db |

**Expected total runtime: 2–3 hours** (phases 1–4)

---

## Phase 3 Outage Scope

Phase 3 is the only phase with database downtime. The sequence is:

```
1. Disable SYS.DB_DDL_ALERT_TRG  (CDB$ROOT + all open PDBs)
2. Pre-patch connectivity check   (log baseline: SYSDBA, tnsping, PDBs)
3. gridSetup.sh -switchGridHome   (~5 min)
4. root.sh — new Grid home        (~5 min)
5. root.sh — new DB home          (~2 min)
6. Verify Grid resources online
7. AutoUpgrade -mode deploy       (~20-40 min — includes DB restart + datapatch)
8. Post-patch connectivity check  (verify: SYSDBA, tnsping SCAN, PDBs)
9. Re-enable SYS.DB_DDL_ALERT_TRG (CDB$ROOT + all open PDBs)
10. Update bash_profiles (grid, oracle, root)
```

**Typical outage window: ~35–50 minutes** (steps 3–7)

---

## Post-Patch Verification Commands

Run these after phase 4 completes to confirm success:

```bash
# Grid patch level
/u01/app/19.32.0.0/grid/bin/crsctl query crs releasepatch
# Expected: release patch string is [19.32.0.0.0]

# All resources online
/u01/app/19.32.0.0/grid/bin/crsctl status resource -t
# Expected: all ONLINE, ora.proddb.db shows HOME=.../dbhome_1932

# Database patch status
su - oracle -c "
  export ORACLE_HOME=/u01/app/oracle/product/19.0.0/dbhome_1932
  export ORACLE_SID=proddb
  export PATH=\$ORACLE_HOME/bin:\$PATH
  sqlplus -s / as sysdba << 'EOF'
  SELECT patch_id, status FROM dba_registry_sqlpatch ORDER BY action_time DESC;
  SELECT comp_name, status FROM dba_registry WHERE status NOT IN ('VALID','OPTION OFF');
  SELECT parameter, value FROM v\$option WHERE parameter IN ('Partitioning','OLAP','Real Application Testing');
  EXIT;
EOF
"
# Expected: most recent patches SUCCESS, no rows from second query, all FALSE from third
```

---

## Known Issues and Notes

### chopt gcc Warning (Phase 4)
```
/bin/sh: /usr/bin/gcc: No such file or directory
```
This is expected on KVM guests without a compiler installed. Oracle's `chopt` uses `make` with a fallback that succeeds even without gcc. Verify success by checking `v$option` shows FALSE — not by the chopt exit code.

### deinstall Silent Mode Warning (Phase 5)
```
In order to use silent option for deinstall tool, you must specify either
-checkonly or -paramfile <parameter file> option.
```
The deinstall tool's silent mode requires a paramfile generated by `-checkonly` first. The framework skips the formal deinstall and uses `rm -rf` directly, which is safe since the homes are no longer registered as active (CRS has already switched). Old home entries remain in inventory.xml — this is cosmetic and does not affect operation.

### datapatch WITH ERRORS (PREV PATCH) (Phase 4)
Rows showing `WITH ERRORS (PREV PATCH)` in `dba_registry_sqlpatch` are historical records from prior patch runs. They do not indicate a problem with the current cycle. Always check the **most recent** rows (ORDER BY action_time DESC) — those must show SUCCESS.

### AIDE Not Installed (Phase 7)
Phase 7 gracefully skips if AIDE is not installed and logs a warning. Install before the patch cycle:
```bash
dnf install -y aide
# First-time initialization (only once):
aide --init
cp -f /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
chmod 600 /var/lib/aide/aide.db.gz
```
Subsequent patch cycles use `aide --update` automatically.

### OUI Inventory After Cleanup
After Phase 5, the old homes remain listed in `inventory.xml` without `REMOVED="T"`. This is cosmetic. They can be manually detached with:
```bash
su - grid -c "
  /u01/app/19.32.0.0/grid/oui/bin/runInstaller \
    -silent -detachHome ORACLE_HOME=/u01/app/19.0.0/grid
"
```

### KVM Network Startup Timing (Phase 3 / Boot)
On KVM/QEMU VMs, `ora.net1.network` defaults to `START_TIMEOUT=0`. This causes cascade timing failures preventing auto-start of VIP → Listener → Database after reboot. The fix (applied during initial setup):
```bash
/u01/app/19.32.0.0/grid/bin/crsctl modify resource ora.net1.network \
  -attr "START_TIMEOUT=120" -unsupported
```

---

## Design Principles

1. **No hardcoded values** — all version-specific values in `patch.conf` only
2. **Self-referencing paths** — scripts find `patch.conf` relative to their own location
3. **umask 0022 throughout** — matches OS default; log files explicitly `chmod 664`
4. **PATCH_LOC permissions** — orchestrator sets `775 grid:oinstall` automatically
5. **Fail fast** — `set -euo pipefail` in every script; errors stop immediately
6. **Timestamped logging** — every step logged with timestamp; separate log per phase
7. **Temp SQL files** — SQL blocks written to `/tmp/*.sql` not heredocs inside bash -c
8. **Response files preserved** — originals never modified; timestamped working copy in /tmp
9. **Phase 5+ opt-in** — cleanup, security, AIDE are separate from the default phases 1–4
10. **DB_NAME explicit** — set in patch.conf; auto-detection via srvctl is unreliable pre-switch
