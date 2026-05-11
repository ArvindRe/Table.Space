# Datapump Scripts — Directory Briefing

**Location:** `/export/home/oracle/arvind/` on `orce01ldb1pd`
**Owner:** Arvind Regukumar
**Purpose:** End-to-end Oracle Data Pump orchestration — parfile generation, job monitoring, log archiving, dumpfile cleanup, and ZFS replication management.

---

## Script Inventory

### Core Data Pump Scripts

| Script | Role |
|--------|------|
| `datapump.sh` | Interactive parfile generator. Prompts for ticket name, Oracle DIRECTORY, parallelism, and job type (1-8). Produces `expdp_<TICKET>.par` (source export), `expdp_<TICKET>_BKP.par` (target backup export), and `impdp_<TICKET>.par` (target import) inside a per-ticket folder. |
| `get_datapump_logfile.sh` | Resolves the full OS path of an expdp log by querying the Oracle DIRECTORY object for a given database. Input: `<DB_NAME> <parfile>`. Output: full NFS path to the log file. |

### Log Archiving

| Script | Role |
|--------|------|
| `archive_logfile.sh` | Copies an expdp/impdp log to a local archive directory (`/export/home/oracle/arvind/log_archive/` by default) and applies `chattr +i` (immutable). Requires `oracle` to have `sudo NOPASSWD` access to `/usr/bin/chattr`. Does not work on NFS — archive dir must be local. |

### Dumpfile Inspection

| Script | Role |
|--------|------|
| `get_dumpfiles.sh` | Parses an expdp log file (or scans a directory of logs) and prints the full paths of all dumpfiles created. |
| `list_dumpfiles.sh` | Calls `get_dumpfiles.sh` and runs `ls -loch` on each dumpfile to show size and timestamps. |

### Cleanup

| Script | Role |
|--------|------|
| `remove_dumpfiles_15d.sh` | Deletes dumpfiles (identified via expdp log) that are older than 15 days. Supports `DRY_RUN=1` for preview mode and `LOGFILE=` to redirect output. |
| `schedule_cleanup_cron_16d.sh` | Installs a self-removing one-shot cron entry that fires 16 days after the export. On success, the cron job deletes itself from crontab. Idempotent — safe to re-run for the same log file. |

### Job Monitoring

| Script | Role |
|--------|------|
| `datapump_longops.sh` | Frontend wrapper. Accepts `EXP`/`IMP` and `<DB_NAME>`. Calls `run_datapump_longops.sh` to query `GV$SESSION_LONGOPS` and `GV$SESSION` for a running expdp/impdp job — shows percent complete and estimated time remaining. |
| `run_datapump_longops.sh` | Backend SQL runner invoked by `datapump_longops.sh`. Contains the actual SQLPlus here-doc querying `GV$SESSION_LONGOPS`. |

### Host & PDB Discovery

| Script | Role |
|--------|------|
| `get_host.sh` | Resolves the hostname and CDB instance name for a given PDB or CDB alias. Calls `run_get_db_host.sh`. Queries `v$instance` and `v$session` (intentionally single-instance scoped). |
| `run_get_db_host.sh` | Backend SQL runner invoked by `get_host.sh`. Contains the SQLPlus here-doc querying `v$instance` and `v$session`. |
| `fetch_pdbs_dynamic.sh` | SSHs to a remote Oracle database server, copies `list_pdbs.sh` to `/tmp/` on the target, and executes it to list all CDBs and their PDBs with open mode and restricted status. |
| `list_pdbs.sh` | Standalone script deployed on target hosts by `fetch_pdbs_dynamic.sh`. Discovers all running CDB PMON processes, sets `ORACLE_SID` for each, and runs `SHOW PDBS` via SQLPlus. |

### ZFS Replication

| Script | Role |
|--------|------|
| `ZFS_sync.sh` | Triggers an on-demand ZFS replication send/update from the Denver (DEN) ZFS appliance to the ZFS site via the ZFS REST API. Polls every 5 minutes (up to 20 iterations) until the state returns to `idle`. Run in background and tail the log. |
| `ZFS_SYNC_status.sh` | Queries the ZFS REST API and prints the current replication state (`sending` or `idle`) without triggering a new sync. |

---

## Script Relationships

```
datapump.sh
  └─ produces: expdp_<TICKET>.par, expdp_<TICKET>_BKP.par, impdp_<TICKET>.par

get_datapump_logfile.sh
  └─ resolves NFS log path → input for get_dumpfiles / list_dumpfiles / cleanup scripts

get_dumpfiles.sh  ←──  list_dumpfiles.sh  (calls get_dumpfiles.sh internally)

remove_dumpfiles_15d.sh  ←──  schedule_cleanup_cron_16d.sh  (invokes via cron)

get_host.sh  →  run_get_db_host.sh  (SQL backend)
datapump_longops.sh  →  run_datapump_longops.sh  (SQL backend)
fetch_pdbs_dynamic.sh  →  list_pdbs.sh  (copied to /tmp/ on remote host via SSH)

ZFS_sync.sh  (trigger)
ZFS_FUNC_status.sh  (query only)
```

---

## Job Types Supported by `datapump.sh`

| # | Type | Key Parameters |
|---|------|----------------|
| 1 | Table | `tables` |
| 2 | Schema | `schemas` |
| 3 | Full Database | `full=Y` |
| 4 | Tablespace | `tablespaces` |
| 5 | Query-Filtered Table | `tables` + `query` |
| 6 | Metadata-Only | `content=METADATA_ONLY` |
| 7 | Network Link | `network_link` |
| 8 | Partitioned Table | `compression=DATA_ONLY` (exp) + `data_options=TRUST_EXISTING_TABLE_PARTITIONS` (imp) |

---

## Notes for AI Agents

- All scripts use `#!/usr/bin/env bash` (or `#!/bin/bash` for older ones copied to remote hosts).
- `chattr +i` is local-filesystem only — never use it against NFS paths.
- `gv$` views are used for RAC-aware queries (`datapump_longops.sh`); `-a` is intentional in `get_host.sh` (single-instance identification).
- ZFS scripts contain a hardcoded Basic Auth header — treat as a secret if reading or modifying.
- The `_BKP` parfile exports existing objects from the **target** database before import, for rollback purposes.
- `schedule_cleanup_cron_16d.sh` uses GNU `date` with `%` address delimiters — not portable to BSD `sed`.
