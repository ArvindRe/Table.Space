# Oracle Data Pump Scripts

A space for capturing Oracle database migration approaches — the complexity encountered in real-world large-scale data movements, and the solutions built to address them. Rooted in production experience running 400 concurrent Data Pump export jobs over 72 hours against 400 TB+ Exadata databases, this repository documents both the operational scripts and the architectural decisions, trade-offs, and lessons that shaped them.

---

## Further Reading

| Document | Description |
|----------|-------------|
| [Advanced Use Cases](Advanced_Use_Cases.md) | Full metadata exports, SQL Plan Baseline migration, DDL extraction to SQL file, QA/DEV object sync after production refresh |
| [Large-Scale Parallel Runs — Architecture & Article](Parallel_datapump_runner/Large_Scale_Parallel_Runs.md) | Deep-dive on running 400 export jobs over 72 hours against 400 TB+ Exadata databases — architecture, LOB handling, constraints, and recommendations |
| [Parallel Runner — Usage](Parallel_datapump_runner/README.md) | How to use `run_exports_parallel.sh` and `run_imports_parallel.sh` |
| [Parallel Runner — Learnings](Parallel_datapump_runner/learnings.md) | Operational lessons: single-quote escaping, LOB identification SQL, ROWID-split parfile patterns, SecureFile import transforms |
| [Resource Utilisation — PGA & TEMP](resource_utilization/README.md) | Scripts for monitoring PGA memory and TEMP tablespace under parallel export load — live snapshot, AWR trend, 80% threshold detection, interactive drilldown |

---

## Overview

| Script | Purpose |
|--------|---------|
| `datapump_workflow.sh` | **End-to-end interactive wrapper** — runs all steps below in order with prompts to Proceed, Skip, or Exit |
| `datapump.sh` | Interactive script to generate expdp/impdp parfiles for a ticket |
| `get_datapump_logfile.sh` | Resolves the full OS path of an export log from a parfile |
| `get_dumpfiles.sh` | Extracts dumpfile paths from an expdp log |
| `list_dumpfiles.sh` | Lists dumpfiles with sizes and timestamps (`ls -lh`) |
| `archive_logfile.sh` | Copies a log file to a protected local archive and applies `chattr +i` |
| `remove_dumpfiles_15d.sh` | Deletes dumpfiles older than 15 days |
| `schedule_cleanup_cron_16d.sh` | Schedules `remove_dumpfiles_15d.sh` via cron, 16 days after export |
| `resource_limit/get_resource_limit.sh` | Checks process/session utilisation and flags high-usage instances |
| `resource_limit/get_pq_diag.sh` | ORA-12805 parallel query diagnostics |
| `db_size/get_db_size.sh` | Reports database total size |

> **Recommended:** Use `datapump_workflow.sh` to run the end-to-end process interactively — it handles steps 1–6 in order, prompts to Proceed, Skip, or Exit at each step, handles password prompts securely, and auto-logs every job to `rj_dba.datapump_log`. Steps 7 (archive) and 8 (cron cleanup) are currently run manually using the individual scripts. See **Running the Full Workflow** with `datapump_workflow.sh` for a demo.

> The Parts below document each script individually for cases where you need to run steps manually or out of order.

---

## Prerequisites — Password Helper (`get_pw.sh`)

Several scripts (`get_host.sh`, `datapump_longops.sh`, `datapump_workflow.sh`) retrieve database passwords by calling:

```bash
/export/home/oracle/bin/get_pw.sh <DB_NAME> <username>
```

This script must be present on every host where the Datapump scripts run. **It is not included in the scripts deployment — you must create it yourself** to match your environment's credential storage.

### What it must do

Accept two positional arguments (`DB_NAME`, `username`) and print the plaintext password to stdout, then exit 0. Any non-zero exit causes the calling script to abort.

### Customisation options

| Environment | Recommended implementation |
|-------------|----------------------------|
| **CyberArk / AIM** | Call `AIMGetCredential.exe` or the `clipasswordsdk` CLI and print `Password=` field |
| **HashiCorp Vault** | `vault kv get -field=password secret/oracle/<DB_NAME>/<username>` |
| **CyberArk Central Credential Provider (CCP)** | HTTP REST call via `curl` to the CCP endpoint, parse the `Content` field |
| **Oracle Wallet / mkstore** | `mkstore -wrl /path/to/wallet -viewEntry oracle.security.client.password1` |
| **Flat credential file (simple/dev)** | Lookup from a protected file readable only by the `oracle` OS user |
| **Interactive fallback** | Prompt with `read -s -rp "Password: " pw && echo "$pw"` (not suitable for cron) |

### Minimal template

```bash
#!/bin/bash
# /export/home/oracle/bin/get_pw.sh
# Retrieve Oracle password from your PAM/credential store.
# Usage: get_pw.sh <DB_NAME> <username>

DB_NAME="${1:?DB_NAME required}"
USERNAME="${2:?username required}"

# --- CUSTOMISE THIS BLOCK ---
# Replace the example below with a call to your PAM tool.
# Must print the password to stdout and exit 0 on success.

# Example: CyberArk AIM
# /opt/CARKaim/sdk/clipasswordsdk GetPassword \
#   -p AppDescs.AppID=OracleScripts \
#   -p Query="Safe=OracleSafe;Object=${DB_NAME}_${USERNAME}" \
#   -o Password

# Example: HashiCorp Vault
# vault kv get -field=password "secret/oracle/${DB_NAME}/${USERNAME}"

echo "ERROR: get_pw.sh is not configured. Edit /export/home/oracle/bin/get_pw.sh." >&2
exit 1
# --- END CUSTOMISE ---
```

> **Security:** The script must be owned by `oracle`, mode `700`, and must **never** write passwords to disk, shell history, or logs. The scripts that call it pass the output directly into sqlplus via a process substitution — the password is never stored in a variable that could appear in `ps` output.

---

## Part 1: Generating Parfiles

### Step 1 — Run `datapump.sh`

This script prompts you for job details and creates a ticket folder containing:
- `expdp_<TICKET>.par` — export parfile, run on the **source** database
- `expdp_<TICKET>_BKP.par` — backup export parfile, run on the **target** database to preserve existing objects before import
- `impdp_<TICKET>.par` — import parfile, run on the **target** database

```bash
./datapump.sh
```

### Step 2 — Select a Job Type

The script supports 8 job types:

| # | Job Type | Key Parameters |
|---|----------|----------------|
| 1 | Table | `tables` |
| 2 | Schema | `schemas` |
| 3 | Full Database | `full=Y` |
| 4 | Tablespace | `tablespaces` (or TTS mode) |
| 5 | Query-Filtered Table | `tables` + `query` |
| 6 | Metadata-Only | `content=METADATA_ONLY` |
| 7 | Network Link (DB-to-DB, no dumpfile) | `network_link` — **No dumpfiles created!** |
| 8 | Partitioned Table | `compression=DATA_ONLY` (expdp) + `data_options=TRUST_EXISTING_TABLE_PARTITIONS` (impdp) |

### Step 3 — Example: Schema Export

```
[oracle@db-server-01 scripts]$ ./datapump.sh
Enter Ticket Name (example: RJF000123456):
RITM1000665
Enter Oracle DIRECTORY name:
DATA_PUMP_DIR1
Enter PARALLEL degree (example: 8):
8
Select job type:
1) Table
2) Schema
3) Full Database
4) Tablespace
5) Query-Filtered Table
6) Metadata-Only
7) Network Link (DB-to-DB, no dumpfile)
8) Partitioned Table
Enter choice [1-8]: 2
Enter schemas (comma-separated):
REVENUE_OWNER
Enter remap_schema (optional):
REVENUE_OWNER:CL_NRW:REVENUE_OWNER_CL_VAL
Enter remap_tablespace (optional):
REVENUE_DATA:REVENUE_REP_DATA:REVENUE_DATA_REVERSE:REVENUE_REP_DATA
Enter PARALLEL degree for impdp (recommended: 32):
32
```

**Output:**
```
✔ Folder created       : RITM1000665/
✔ EXPDP parfile        : expdp_RITM1000665.par
✔ EXPDP BKP parfile    : expdp_RITM1000665_BKP.par
✔ IMPDP parfile        : impdp_RITM1000665.par
```

---

### Step 4 — Run expdp / impdp

```bash
# Step 4a: Export from SOURCE database
expdp aregukumar/$$$$$$$$@sourcdb parfile=RITM1096665/expdp_RITM1096665.par

# Step 4b: Backup existing objects on TARGET database (run before import)
expdp aregukumar/$$$$$$$$@targetpdb parfile=RITM1096665/expdp_RITM1096665_BKP.par

# Step 4c: Import into TARGET database
impdp aregukumar/$$$$$$$$@targetpdb parfile=RITM1096665/impdp_RITM1096665.par
```

> **Note:** The BKP export (`expdp_<TICKET>_BKP.par`) should always be run on the **target** database before importing, to capture any existing data that would be overwritten or replaced. This allows rollback if the import needs to be reversed.

> **Partitioned Table note:** Indexes, constraints, triggers, and grants are excluded from impdp and must be re-created manually. The impdp parfile contains a `POST-IMPORT STEPS` comment block with the exact DDL steps, including rebuilding indexes with parallelism and enabling constraints with `NOVALIDATE`.

---

## Part 2: Resolving the Export Log Path

After export, use `get_datapump_logfile.sh` to resolve the full OS path of the log file from the parfile. This is needed when the Oracle `DIRECTORY` object abstracts the real NFS path.

### Usage

```bash
./get_datapump_logfile.sh <DB_NAME> <parfile>
```

### Example

```bash
./get_datapump_logfile.sh EDMQ00QA ./RITM10904787/expdp_RITM10904787.par
```

**Output:**
```
Parfile values detected.
  DIRECTORY : data_pump_dir2
  LOGFILE   : expdp_RITM10904787.log

Querying Oracle directory path from database 'EDMQ00QA' ...

  Database      : EDMQ00QA
  Directory Obj : data_pump_dir2
  OS Path       : /nfs/xs/repl/ZST-to-DEN
  Log File      : expdp_RITM10904787.log

  FULL_LOG_PATH : /nfs/xs/repl/ZST-to-DEN/expdp_RITM10904787.log
```

Copy the **FULL_LOG_PATH** — this is used as the input for all cleanup scripts.

---

## Part 3: Archiving Log Files (Immutable Protection)

Once export and import are complete, archive both log files to a **local protected directory** using `archive_logfile.sh`. The script copies the log and applies `chattr +i` (immutable) so the file cannot be deleted or modified, even by root.

> **Important:** `chattr +i` only works on **local filesystems**. It will not work on NFS (where the dumpfiles/logs are written during the job). The archive directory must be a local path on the Oracle server.

### Prerequisites

The `oracle` user needs a `sudoers` entry for `chattr`:

```
oracle ALL=(root) NOPASSWD: /usr/bin/chattr
```

### Usage

```bash
./archive_logfile.sh <logfile_path>
```

Optionally override the archive directory:

```bash
ARCHIVE_DIR=/custom/archive/path ./archive_logfile.sh <logfile_path>
```

Default archive location: `/export/home/oracle/arvind/log_archive/`

### Example — Archive both logs after a job

```bash
# Archive the export log
./archive_logfile.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log

# Archive the import log
./archive_logfile.sh /nfs/xs/repl/ZST-to-STG/impdp_RITM10874428.log
```

**Output:**
```
Copied: /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
  --> /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
Protected: chattr +i applied to /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
✔ Archive complete: /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log (immutable)
```

### Viewing archived logs

```bash
ls -lh /export/home/oracle/arvind/log_archive/
```

Confirm immutable flag is set (look for `i` in the flags column):
```
lsattr /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
----i--------e-- /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
```

### Removing an archived log (if ever needed)

```bash
sudo chattr -i -- /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
rm -f -- /export/home/oracle/arvind/log_archive/expdp_RITM10874428.log
```

---

## Part 4: Inspecting Dumpfiles

Use these two scripts to verify what dumpfiles were created before scheduling cleanup.

### `get_dumpfiles.sh` — List dumpfile paths

Parses the expdp log and prints the paths of all dumpfiles created.

```bash
./get_dumpfiles.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
```

**Output:**
```
/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_01.dmp
/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_02.dmp
/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_03.dmp
/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_04.dmp
```

You can also point it at a **directory** to scan multiple log files at once:

```bash
./get_dumpfiles.sh /nfs/xs/repl/ZST-to-STG/
```

### `list_dumpfiles.sh` — Lists with file size and timestamp

```bash
./list_dumpfiles.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
```

**Output:**
```
-rw-r-----  1 oracle asmadmin  6.3G Feb  4 02:06 /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_01.dmp
-rw-r-----  1 oracle asmadmin  136G Feb  4 02:04 /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_02.dmp
-rw-r-----  1 oracle asmadmin  0.8G Feb  4 02:06 /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_03.dmp
-rw-r-----  1 oracle asmadmin       Feb  4 02:06 /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_04.dmp
```

---

## Part 5: Cleanup — Removing Dumpfiles

Dumpfiles should be removed **after 15 days** (once import is confirmed successful and there is no need to re-run). There are two ways to do this.

### Option A: Run cleanup manually

```bash
./remove_dumpfiles_15d.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
```

**Output:**
```
=== 2026-03-12 02:44:45 | Starting cleanup (>15 days old).  Dry-run: 0
Removing (older than 15d): /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_01.dmp
Removing (older than 15d): /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_02.dmp
Removing (older than 15d): /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_03.dmp
Removing (older than 15d): /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428_04.dmp
=== 2026-03-12 02:44:45 | Cleanup done.
```

#### Dry-run mode (preview without deleting):

```bash
DRY_RUN=1 ./remove_dumpfiles_15d.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
```

#### Custom log output location:

```bash
LOGFILE=/tmp/my_cleanup.log ./remove_dumpfiles_15d.sh /nfs/xs/repl/...
```

### Option B: Schedule cleanup automatically via cron (recommended)

Use `schedule_cleanup_cron_16d.sh` to install a **self-removing, one-shot cron job** that fires 16 days after the export date.

```bash
./schedule_cleanup_cron_16d.sh
```

The script will prompt for:
1. **Full path to the export log file** — e.g. `/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log`
   (Use `get_datapump_logfile.sh` to resolve this if unknown)
2. **Time of day to run** — defaults to the current time (HH:MM, 24h)

```
[oracle@db-server-01 scripts]$ ./schedule_cleanup_cron_16d.sh
Enter the full path of the export log file: /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
Enter time of day to run (HH:MM, 24h). Default = 02:44: 02:44
✔  Crontab backed up to: /export/home/oracle/arvind/crontab_backup_20260327_024600.txt

Add the following entry to your crontab  (run: crontab -e):

44 02 12 04 * /export/home/oracle/arvind/remove_dumpfiles_15d.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log > /export/home/oracle/arvind/remove_dumpfiles_expdp_RITM10874428.log 2>&1 && crontab -l | grep -v expdp_RITM10874428.log | crontab -

- Fires once on  : 2026-04-12 at 02:44
- Cleanup script : /export/home/oracle/arvind/remove_dumpfiles_15d.sh
- Output log     : /export/home/oracle/arvind/remove_dumpfiles_expdp_RITM10874428.log
```

**Key behaviours:**
- Never modifies crontab directly — backs up current crontab, prints the entry for you to add with `crontab -e`
- Fires once on the computed date, 16 days from when you run the scheduler
- On successful completion, the cron entry **removes itself** automatically

---

## End-to-End Workflow Summary

```
1. datapump.sh
   └─ Creates: RITM####/expdp_RITM####.par     (source export)
               RITM####/expdp_RITM####_BKP.par  (target backup export)
               RITM####/impdp_RITM####.par       (target import)

2. expdp aregukumar/$$$$$$$$@sourcedb parfile=RITM####/expdp_RITM####.par
   └─ Exports data from SOURCE, writes dumpfiles + log to Oracle DIRECTORY (NFS)

3. get_datapump_logfile.sh <DB> RITM####/expdp_RITM####.par
   └─ Resolves full log path: /nfs/.../expdp_RITM####.log

4. list_dumpfiles.sh /nfs/.../expdp_RITM####.log
   └─ Confirm source dumpfiles exist and look correct

5. expdp aregukumar/$$$$$$$$@targetpdb parfile=RITM####/expdp_RITM####_BKP.par
   └─ Backs up existing objects on TARGET before import

6. impdp aregukumar/$$$$$$$$@targetpdb parfile=RITM####/impdp_RITM####.par
   └─ Import into TARGET complete

— Run manually after steps 1–6 complete —————————————————

7. archive_logfile.sh /nfs/.../expdp_RITM####.log
   archive_logfile.sh /nfs/.../expdp_RITM####_BKP.log
   archive_logfile.sh /nfs/.../impdp_RITM####.log
   └─ Copies all logs to local archive; applies chattr +i (immutable)

8. schedule_cleanup_cron_16d.sh
   └─ Backs up crontab; prints a one-shot cron entry to add manually (crontab -e)
   └─ Cron entry self-removes after successful cleanup
```

---

## Running the Full Workflow with `datapump_workflow.sh`

`datapump_workflow.sh` is an interactive wrapper that runs steps 1–6 in order. At each step it asks whether to **[P]roceed**, **[S]kip**, or **[E]xit**. For `expdp`/`impdp` steps it offers **[R]un now**, **[M]ark as done**, **[S]kip**, or **[E]xit**.

> Steps 7 (archive logs) and 8 (cron cleanup entry) are not included in the wrapper — run them manually.

After every export or import job completes, the wrapper automatically writes a row to `rj_dba.datapump_log` on the respective database.

| Column | Contents |
|--------|---------|
| `OPERATION` | `EXP`, `EXP_BKP`, or `IMP` |
| `RITM` | RITM ticket name |
| `DBNAME` | DB username used to run the job |
| `TARGET` | Database the job ran against |
| `PARFILE` | Contents of the parfile (comments stripped) |
| `LOGFILE` | Full path to the Data Pump log file |
| `DUMPFILE` | First dumpfile name from the parfile |
| `JOB_NAME` | Data Pump Job name from the parfile |
| `PARALLEL_DEGREE` | Parallel degree from the parfile |
| `HOSTNAME` | Server the workflow ran on |
| `START_TIME` | Timestamp when the job started |
| `END_TIME` | Timestamp when the job ended |
| `STATUS` | `SUCCESS` or `FAILED` |

```bash
./datapump_workflow.sh
```

| Scenario | What to do |
|----------|-----------|
| Already ran expdp manually | Choose **[M]ark as done** at step 2 |
| Log path already known | Choose **[S]kip** at step 3 — wrapper prompts you to type the path directly |
| Need to exit mid-workflow | Choose **[E]xit** at any prompt |

---

## Other Useful Scripts

### `get_host.sh` — Find where a database is running

```bash
./get_host.sh <DB_NAME>
```

### `resource_limit/get_resource_limit.sh` — Check process / session utilisation

Queries `GV$RESOURCE_LIMIT` across all RAC instances, highlights any instance exceeding 75% utilisation, and optionally drills into root-cause queries (session status, wait events, blocking sessions, JDBC leak check).

```bash
cd resource_limit/
./get_resource_limit.sh <DB_NAME>
```

> Connect via a **CDB service** for accurate results — `GV$RESOURCE_LIMIT` is CDB-level.

### `resource_limit/get_pq_diag.sh` — ORA-12805 Parallel Query Diagnostics

Diagnoses resource contention when a Data Pump job fails with ORA-12805. Runs 7 queries covering process headroom, PQ slave pool usage, slave wait events, and stale sessions.

```bash
./get_pq_diag.sh <DB_NAME> [inst_id,inst_id,...]
```

### `db_size/get_db_size.sh` — Report database size

```bash
./get_db_size.sh <DB_NAME>
```

### `datapump_longops.sh` — Monitor a running Data Pump job

Queries `GV$SESSION_LONGOPS` to show percent complete and estimated time remaining for a running expdp or impdp job.

```bash
./datapump_longops.sh <EXP|IMP> <DB_NAME>
```

### `fetch_pdbs_dynamic.sh` — List all PDBs on a host

SSHs to a remote Oracle server and lists all CDBs and their PDBs with open mode and restricted status.

```bash
./fetch_pdbs_dynamic.sh <HOSTNAME>
```

### `ZFS_sync.sh` — Trigger ZFS replication (DEN → STG)

Triggers an on-demand ZFS replication via the ZFS REST API. Polls every 5 minutes until the state returns to `idle`. Run in background and tail the log.

```bash
./ZFS_sync.sh > ZFS_sync.log &
tail -f ZFS_sync.log
```

### `ZFS_SYNC_status.sh` — Check current ZFS replication state

```bash
./ZFS_SYNC_status.sh
# Output: sending  (or)  idle
```

---

## Notes

- All scripts must be located in the same directory (e.g. `/export/home/oracle/arvind/`) and called from there, or invoked via their full path.
- `chattr +i` cannot be applied to files on NFS mounts. Always use a local directory for `ARCHIVE_DIR`.
- For **Network Link** jobs (type 7), no dumpfiles are created — skip Parts 4 and 5.
- For **Partitioned Table** jobs (type 8), review and execute the `POST-IMPORT STEPS` comment block inside the generated `impdp_<TICKET>.par` before closing the ticket.
- ZFS scripts contain a hardcoded Basic Auth header — update both `ZFS_sync.sh` and `ZFS_SYNC_status.sh` if the ZFS appliance password changes.
