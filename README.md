# Oracle 19c OOP Patch Automation Framework
## Single Node CRS — lnx98.home.aarisha.com

---

## Directory Layout

```
/opt/oracle/patches/automation/
├── patch.conf              ← EDIT THIS FOR EACH PATCH CYCLE
├── patch_orchestrator.sh   ← Master orchestrator (run as root)
├── phase1_grid_prep.sh     ← Build + patch new Grid home
├── phase2_db_prep.sh       ← Build + patch new DB home
├── phase3_switch.sh        ← Home switch + datapatch (OUTAGE)
├── phase4_post_install.sh  ← Post-patch validation + utlrp
├── phase5_cleanup.sh       ← Deinstall old homes (manual)
└── README.md               ← This file

/opt/oracle/patches/
├── patch.conf              (symlink or copy from automation/)
├── logs/                   ← All script logs written here
├── base_releases/          ← Grid and DB base 19.3 zips
├── p6880880_*.zip          ← Latest OPatch
├── p<RU_COMBO>_*.zip       ← RU Combo zip
├── p<DB_STANDALONE>_*.zip  ← DataPump or standalone DB patch
├── autoupgrade.jar         ← Latest AutoUpgrade JAR
├── gridsetup.rsp           ← Grid response file
├── db_install.rsp          ← DB response file
└── orcl_auto_patch.cfg     ← AutoUpgrade config
```

---

## For Each New Patch Cycle

**Only edit `patch.conf`** — update these variables:

### Patch Identity (always update):
| Variable | Example | Description |
|---|---|---|
| `NEW_PATCH_LEVEL` | `19.32` | Target patch level (for logs) |
| `OLD_PATCH_LEVEL` | `19.31` | Current running level (for logs) |
| `RU_COMBO_PATCH` | `39618711` | Outer RU combo patch number |
| `GI_RU_PATCH` | `39467003` | GI RU bundle dir (inside combo) |
| `GI_APPLY_RU_PATCH` | `39526364` | gridSetup.sh -applyRU sub-patch |
| `GI_ONEOFF_PATCHES` | `39107825,39107855,...` | Grid -applyOneOffs (comma-sep IDs) |
| `DB_APPLY_RU_PATCH` | `39472050` | runInstaller -applyRU sub-patch |
| `DB_ONEOFF_PATCHES` | `39526364,39222882` | DB -applyOneOffs (comma-sep IDs) |
| `DB_RU_STANDALONE_PATCH` | `39657094` | Standalone DB patch number |
| `DB_RU_STANDALONE_ZIP` | `p39657094_*.zip` | Standalone DB patch zip filename |

### Home Paths (update for each cycle — Grid and DB are independent):
| Variable | lnx98 Example | Description |
|---|---|---|
| `OLD_GRID_HOME` | `/u01/app/19.0.0/grid` | Current active Grid home |
| `NEW_GRID_HOME` | `/u01/app/19.32.0.0/grid` | New patched Grid home to build |
| `OLD_DB_HOME` | `/u01/app/oracle/product/19.0.0/dbhome_1` | Current active DB home |
| `NEW_DB_HOME` | `/u01/app/oracle/product/19.0.0/dbhome_1932` | New patched DB home to build |

> **Note:** Grid and DB home paths use different naming conventions and
> are set explicitly. They are NOT derived from patch level numbers
> because the DB home suffix (e.g. `dbhome_1`, `dbhome_1931`, `dbhome_1932`)
> follows no predictable pattern across environments.

### Response Files:
The scripts use your existing response files from `/u01/rsp/`.
A timestamped working copy is made per run with `ORACLE_HOME` updated
to the new home path — the originals are never modified.

| Variable | Default | Description |
|---|---|---|
| `GRID_RSP` | `/u01/rsp/grid_install.rsp` | Existing Grid response file |
| `DB_RSP` | `/u01/rsp/db_install.rsp` | Existing DB response file |

---

## Running the Orchestrator

### Full patch run (Phases 1-4, no cleanup):
```bash
# Stage patches first, then:
chmod +x /opt/oracle/patches/automation/*.sh

nohup /opt/oracle/patches/automation/patch_orchestrator.sh \
  > /dev/null 2>&1 &

tail -f /opt/oracle/patches/logs/master_patch.log
```

### Run a single phase:
```bash
./patch_orchestrator.sh --phase 1    # Grid home prep only
./patch_orchestrator.sh --phase 3    # Switch only (outage)
```

### Resume from a phase (e.g. after fixing phase 2 failure):
```bash
./patch_orchestrator.sh --from-phase 2
```

### Dry run (shows what would happen, no execution):
```bash
./patch_orchestrator.sh --dry-run
```

### Run cleanup after validation (Phase 5):
```bash
./patch_orchestrator.sh --phase 5    # Interactive — requires typing 'YES'
```

---

## Phase Summary

| Phase | Script | User | Window | Description |
|---|---|---|---|---|
| 1 | phase1_grid_prep.sh | grid | Online | Extract, OPatch, gridSetup.sh CRS_SWONLY |
| 2 | phase2_db_prep.sh | oracle | Online | Extract, OPatch, runInstaller, AutoUpgrade analyze |
| 3 | phase3_switch.sh | root | **OUTAGE** | roothas.sh switch, DB home switch, datapatch |
| 4 | phase4_post_install.sh | root | Online | utlrp, chopt, registry validation |
| 5 | phase5_cleanup.sh | root | Online | Deinstall old homes (manual opt-in) |

---

## Key Design Principles

1. **No hardcoded values** — all version-specific paths derive from `patch.conf`
2. **Idempotent where possible** — re-running a phase after failure is safe
3. **Fail fast** — `set -euo pipefail` in every script; any error stops immediately
4. **Timestamped logging** — every step logged with timestamp to phase-specific log
5. **Pre-flight checks** — each phase verifies required files before doing anything
6. **Auto-detect DB name** — `srvctl list database` used; override in patch.conf if needed
7. **Phase 5 is opt-in** — cleanup requires explicit `--cleanup` flag AND typing 'YES'

---

## Known Issues and Notes

- `gridSetup.sh -switchGridHome` does NOT work on Oracle Restart (HAS).
  This framework uses `roothas.sh -prepatch/-postpatch` instead.
- `srvctl modify database -o` must be run with ORACLE_HOME set to the OLD home.
  This is handled automatically by phase3_switch.sh.
- `opatch lspatches` on new homes returns error 28/135 before the home switch.
  Use `.patch_storage/` directory listing for pre-switch patch verification.
- Phase 3 includes a 30-second interactive pause before the outage step.
  In fully automated (non-interactive) deployments, remove the `read` command.
