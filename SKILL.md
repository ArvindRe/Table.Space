name: datapump-migration
description: >
  **MIGRATION SKILL** — End-to-end Oracle Data Pump migration orchestration.
  Use for: generating parfiles; running source exports and target backup exports;
  computing exports; monitoring live expdp/impdp jobs; and recommending post-datapump
  steps (log archiving, dumpfile cleanup scheduling, ZFS replication, post-import
  validations). Covers all 8 job types supported by datapump.sh.
  DO NOT USE FOR: general Oracle SQL help unrelated to Data Pump;
  ZFS hardware troubleshooting; unrelated shell scripting.
applies: "**/*.sh, **/*.par, **/RITM*/**, **/TASK*/**"

# Skill: Oracle Data Pump Migration Workflow

## Purpose

Guide a complete Oracle Data Pump migration from parfile generation through
post-import validation using the scripts in this repository. Each phase produces
specific artifacts; gate the next phase on those artifacts existing and being valid.

---

## Phase 0 — Pre-flight: Resolve Host and PDB

Before generating parfiles, confirm the source and target databases are reachable.

```bash
# Resolve host and CDB instance for the source PDB
./get_host.sh <SOURCE_DB>

# Resolve host and CDB instance for the target PDB
./get_host.sh <TARGET_DB>
```

**Decision point:**
- If either returns no rows or a connection error — stop and resolve TNS / network before continuing.
- Confirm the Oracle DIRECTORY object name exists on both source and target (needed for parfile generation).

---

## Phase 1 — Parfile Generation

Run `datapump.sh` interactively. It produces three parfiles inside a
`<TICKET>/` subdirectory.

```bash
./datapump.sh
```

**Prompts and expected inputs:**

| Prompt | Example |
|--------|---------|
| Ticket name | `RITM0012345` |
| Oracle DIRECTORY | `DATA_PUMP_DIR` |
| Parallelism degree | `8` |
| Job type (1–8) | `2` (Schema) |

**Job type reference:**

| # | Type | Key parfile parameters |
|---|------|----------------------|
| 1 | Table | `tables=` |
| 2 | Schema | `schemas=` |
| 3 | Full Database | `full=Y` |
| 4 | Tablespace | `tablespaces=` |
| 5 | Query-Filtered Table | `tables=` + `query=` |
| 6 | Metadata-Only | `content=METADATA_ONLY` |
| 7 | Network Link | `network_link=` (no dumpfile) |
| 8 | Partitioned Table | `compression=DATA_ONLY` (exp) + `data_options=TRUST_EXISTING_TABLE_PARTITIONS` (imp) |

**Outputs produced:**
- `<TICKET>/expdp_<TICKET>.par` — source export parfile
- `<TICKET>/expdp_<TICKET>_BKP.par` — target backup import parfile (pre-import snapshot)
- `<TICKET>/impdp_<TICKET>.par` — target import parfile

**Validation:** Confirm all three files exist before proceeding. For Network Link
jobs, no dumpfile is written — skip Phases 2b and 2c.

---

## Phase 2a — Source Export

Run `expdp` on the **source** database using the generated parfile:

```bash
expdp \"/  as sysdba\" parfile=<TICKET>/expdp_<TICKET>.par
```

While the job runs, monitor progress with Phase 4 (monitoring).

**After completion:** Resolve the full log path:

```bash
./get_datapump_logfile.sh <SOURCE_DB> <TICKET>/expdp_<TICKET>.par
```

Save the returned path — it is required for Phases 3, 5, and 6.

---

## Phase 2b — Target Backup Export (if target objects exist)

If the target schema/tables already exist and a rollback baseline is needed,
run the BKP export on the **target** database before importing:

```bash
expdp \"/  as sysdba\" parfile=<TICKET>/expdp_<TICKET>_BKP.par
```

Resolve the BKP log path:

```bash
./get_datapump_logfile.sh <TARGET_DB> <TICKET>/expdp_<TICKET>_BKP.par
```

**Decision point:** If the BKP export fails (e.g., objects don't exist yet),
this step is safe to skip — the BKP parfile is purely a rollback safeguard.

---

## Phase 2c — Import

Run `impdp` on the **target** database:

```bash
impdp \"/  as sysdba\" parfile=<TICKET>/impdp_<TICKET>.par
```

Monitor progress with Phase 4 (monitoring).

**Special case — Partitioned Table (job type 8):** After import completes,
follow the post-import steps printed by `datapump.sh`:
1. Rebuild unusable indexes.
2. Re-enable disabled constraints.
3. Reset parallelism on indexes/tables to 1.

**After completion:** Resolve the import log path:

```bash
./get_datapump_logfile.sh <TARGET_DB> <TICKET>/impdp_<TICKET>.par
```

---

## Phase 4 — Monitor Running Jobs

Use this at any time during Phases 2a, 2b, or 2c to check progress:

```bash
# Monitor export
./datapump_longops.sh EXP <DB_NAME>

# Monitor import
./datapump_longops.sh IMP <DB_NAME>
```

**Output columns:**
- `DONE_PCT` — Percentage complete (0–100)
- `TIME_REMAINING_SEC` — Estimated seconds remaining
- `OPNAME` — Job name (confirm it matches the ticket)

**Tip:** Run in a loop for continuous monitoring:

```bash
watch -n 30 './datapump_longops.sh EXP <DB_NAME>'
```

---

## Phase 5 — Post-Datapump: Log Archiving

Archive both the export and import logs immediately after each job completes.
The archive applies `chattr +i` (immutable) — the archive directory must be
on a **local** filesystem, not NFS.

```bash
# Archive source export log
./archive_logfile.sh <FULL_PATH_TO_EXPDP_LOG>

# Archive target BKP export log (if run)
./archive_logfile.sh <FULL_PATH_TO_EXPDP_BKP_LOG>

# Archive import log
./archive_logfile.sh <FULL_PATH_TO_IMPDP_LOG>
```

Default archive location: `/export/home/oracle/arvind/log_archive/`

Override with: `ARCHIVE_DIR=/custom/path ./archive_logfile.sh <log>`

**Prerequisite:** Oracle user must have:
```
oracle ALL=(root) NOPASSWD: /usr/bin/chattr
```

---

## Phase 6 — Post-Datapump: Dumpfile Inspection

Verify the dumpfiles created by the export:

```bash
# List dumpfile paths only
./get_dumpfiles.sh <FULL_PATH_TO_EXPDP_LOG>

# List with sizes and timestamps
./list_dumpfiles.sh <FULL_PATH_TO_EXPDP_LOG>
```

Confirm:
- All expected dumpfiles are present.
- File sizes are non-zero.
- Timestamps match the export window.

---

## Phase 7 — Post-Datapump: Schedule Dumpfile Cleanup

Schedule automatic deletion of source dumpfiles 16 days after export using a
self-removing cron entry:

```bash
./schedule_cleanup_cron_16d.sh
```

**Prompts:**
- Full path to the export log file (from Phase 2a)
- Cleanup time-of-day (HH:MM, 24-hour)

The script prints a cron line to stdout — add it manually via `crontab -e`.

**To preview what will be deleted without deleting (dry run):**
```bash
DRY_RUN=1 ./remove_dumpfiles_15d.sh <FULL_PATH_TO_EXPDP_LOG>
```

---

## Phase 8 — Post-Datapump: ZFS Replication (if applicable)

If the dumpfiles reside on a ZFS-replicated NFS share (DEN → STG), trigger
an on-demand sync after export:

```bash
# Check current replication state first
./ZFS_SYNC_status.sh

# Trigger sync (run in background and tail log)
nohup ./ZFS_sync.sh > /tmp/zfs_sync_$(date +%Y%m%d_%H%M%S).log 2>&1 &
tail -f /tmp/zfs_sync_*.log
```

`ZFS_sync.sh` polls every 5 minutes (up to 20 iterations) until state returns
to `idle`. Do not trigger a second sync while one is in `sending` state.

---

## Phase 9 — Post-Datapump: Validation Checklist

After import completes, recommend these validations:

### Object Count Comparison

```sql
-- On source
SELECT object_type, COUNT(*) FROM dba_objects
WHERE owner = '<SCHEMA>' GROUP BY object_type ORDER BY 1;

-- On target — compare counts
```

### Invalid Objects

```sql
SELECT object_name, object_type, status FROM dba_objects
WHERE owner = '<SCHEMA>' AND status != 'VALID'
ORDER BY object_type, object_name;
```

### Row Count Spot Check (for critical tables)

```sql
SELECT COUNT(*) FROM <SCHEMA>.<TABLE>;
```

### Compile Invalid Objects (if any)

```sql
EXEC dbms_utility.compile_schema(schema => '<SCHEMA>', compile_all => FALSE);
```

### Partitioned Table Jobs (job type 8) — Additional Checks

1. Rebuild unusable indexes: `ALTER INDEX <idx> REBUILD;`
2. Re-enable constraints: `ALTER TABLE <t> ENABLE CONSTRAINT <c>;`
3. Reset degree: `ALTER TABLE <t> PARALLEL 1;`

---

## Quick Reference: Script → Phase Mapping

| Script | Phase |
|--------|-------|
| `get_host.sh` | 0 — Pre-flight |
| `datapump.sh` | 1 — Parfile generation |
| `get_datapump_logfile.sh` | 2a, 2b, 2c — Resolve log paths |
| `datapump_longops.sh` | 4 — Job monitoring |
| `archive_logfile.sh` | 5 — Log archiving |
| `get_dumpfiles.sh` / `list_dumpfiles.sh` | 6 — Dumpfile inspection |
| `schedule_cleanup_cron_16d.sh` / `remove_dumpfiles_15d.sh` | 7 — Cleanup scheduling |
| `ZFS_sync.sh` / `ZFS_SYNC_status.sh` | 8 — ZFS replication |

---

## Key Constraints and Gotchas

- `chattr +i` (`archive_logfile.sh`) **does not work on NFS** — archive dir must be local.
- `gv$` views are used in `datapump_longops.sh` for RAC-aware monitoring; `v$` is intentional in `get_host.sh`.
- `schedule_cleanup_cron_16d.sh` uses GNU `sed` — not portable to BSD sed.
- ZFS scripts contain a hardcoded Basic Auth header — do not log or expose the ZFS script contents.
- For Network Link jobs (type 7), no dumpfiles are written — skip Phases 6, 7, and 8.
- The `_BKP` parfile targets the **target** database (rollback snapshot), not the source.
