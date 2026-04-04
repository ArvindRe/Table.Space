# Oracle Data Pump — Scripts Usage Guide

**Location:** `/export/home/oracle/arvind/` on `orce01ldb1pd`

> **Work In Progress:** These scripts are currently hosted in a personal directory on `orce01ldb1pd`. Once finalised and tested, the intent is to move them to a **shared NFS location** (e.g. `/nfs/shared/scripts/datapump/`) so they are accessible from all Oracle database servers without needing to copy or maintain separate copies per server.

---

## Overview

This page describes the end-to-end workflow for running Oracle Data Pump export/import jobs and cleaning up dumpfiles afterwards using a suite of shell scripts.

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

### Step 3 — Example: Partitioned Table Job

```
[oracle@orce01ldb1pd arvind]$ ./datapump.sh
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

It backs up your crontab and prints the cron entry for you to add manually:

```
[oracle@orce01ldb1pd arvind]$ ./schedule_cleanup_cron_16d.sh
Enter the full path of the export log file (e.g. /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428164.log): /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
WARN: '/nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log' not found on this host. Make sure the path is correct before the cron fires.
Enter time of day to run (HH:MM, 24h). Default = 02:44: 02:44
✔  Crontab backed up to: /export/home/oracle/arvind/crontab_backup_20260327_024600.txt

Add the following entry to your crontab  (run: crontab -e):

44 02 12 04 * /export/home/oracle/arvind/remove_dumpfiles_15d.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log > /export/home/oracle/arvind/remove_dumpfiles_expdp_RITM10874428.log 2>&1 && crontab -l | grep -v expdp_RITM10874428.log | crontab -

- Fires once on  : 2026-04-12 at 02:44
- Cleanup script : /export/home/oracle/arvind/remove_dumpfiles_15d.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM10874428.log
- Output log     : /export/home/oracle/arvind/remove_dumpfiles_expdp_RITM10874428.log

Note: The cron entry self-removes after a successful run (exit code 0).
```

**Key behaviours:**
- **Never modifies crontab** — backs up the current crontab to a timestamped file, then prints the entry for you to add manually with `crontab -e`
- Fires once on the computed date, 16 days from when you run the scheduler
- On successful completion (exit 0), the cron entry **removes itself** from crontab automatically via `grep -v`
- The cleanup run is logged to `/export/home/oracle/arvind/remove_dumpfiles_<logfile>.log`

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

`datapump_workflow.sh` is an interactive wrapper that runs steps 1–6 in order. At each step it asks whether to **[P]roceed**, **[S]kip**, or **[E]xit**. For `expdp`/`impdp` steps it offers **[R]un now** (prompts for password securely), **[M]ark as done** (if you already ran it manually), **[S]kip**, or **[E]xit**.

> **Note:** Steps 7 (archive logs) and 8 (cron cleanup entry) are currently not included in the wrapper — run them manually using `archive_logfile.sh` and `schedule_cleanup_cron_16d.sh` as described in Parts 3 and 8.

After every export or import job completes, the wrapper automatically writes a row to `rj_dba.datapump_log` on the respective database. The table is created automatically on first use if it does not exist.

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

### Sample Session

```
[oracle@orce01ldb1pd arvind]$ ./datapump_workflow.sh

  Oracle Data Pump — End-to-End Workflow Runner

Each step can be [P]roceeded, [S]kipped, or [E]xited.

  Ticket name (e.g. RJF000123456): RITM1096665
  Source DB name: CERCRDI
  Target DB name: CERPCQA1
  DB username (e.g. aregukumar): aregukumar
  Archive directory [/export/home/oracle/arvind/log_archive]:

  Ticket    : RITM1096665
  Source DB : CERCRDI
  Target DB : CERPCQA1
  DB User   : aregukumar
  Archive   : /export/home/oracle/arvind/log_archive

STEP 1: Generate parfiles  (datapump.sh)
  ▶ Run datapump.sh to create parfiles for RITM1096665?
  [P]roceed [S]kip [E]xit — P

  Enter Oracle DIRECTORY name:
  DATA_PUMP_DIR1
  Enter PARALLEL degree (example: 8):
  8
  Select job type:
  1) Table
  2) Schema
  ...
  Enter choice [1-8]: 2
  Enter schemas (comma-separated):
  REVENUE_OWNER

  ✔ Folder created       : RITM1096665/
  ✔ EXPDP parfile        : expdp_RITM1096665.par
  ✔ EXPDP BKP parfile    : expdp_RITM1096665_BKP.par
  ✔ IMPDP parfile        : impdp_RITM1096665.par
  ✔ datapump.sh completed.

STEP 2: Run SOURCE export  (expdp)
  Parfile: /export/home/oracle/arvind/RITM1096665/expdp_RITM1096665.par
  Command: [expdp] CERCRDI aregukumar parfile=RITM1096665/expdp_RITM1096665.par
  [P]roceed [S]kip [M]ark as done [E]xit — P
  Password for aregukumar@CERCRDI:
  Export: Release 19.0.0.0 — Production on Fri Mar 27 08:15:02 2026
  ...
  ✔ expdp completed successfully.
  Writing job entry to rj_dba.datapump_log on CERCRDI ...
  ✔ Logged to rj_dba.datapump_log (EXP / SUCCESS)

STEP 3: Resolve SOURCE export log path  (get_datapump_logfile.sh)
  ▶ Query Oracle DIRECTORY to find full NFS log path for CERCRDI?
  [P]roceed [S]kip [E]xit — P

  FULL_LOG_PATH = /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665.log
  ✔ Source log resolved: /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665.log

STEP 4: Inspect source dumpfiles  (list_dumpfiles.sh)
  ▶ Run list_dumpfiles.sh on: /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665.log?
  [P]roceed [S]kip [E]xit — S
  ⚠  Skipping.

  -rw-r-----  1 oracle asmadmin  514kp  19G Mar 27 05:20 /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665_01.dmp
  -rw-r-----  1 oracle asmadmin  115G   Mar 27 05:20 /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665_02.dmp

STEP 5: Run TARGET backup export  (expdp BKP)
  Parfile: /export/home/oracle/arvind/RITM1096665/expdp_RITM1096665_BKP.par
  Command: expdp aregukumar/[PASSWORD]@CERPCQA1 parfile=RITM1096665/expdp_RITM1096665_BKP.par
  [P]roceed [M]ark as done [S]kip [E]xit — M
  Password for aregukumar@CERPCQA1:
  ✔ expdp completed successfully.
  Writing job entry to rj_dba.datapump_log on CERPCQA1 ...
  ✔ Logged to rj_dba.datapump_log (EXP_BKP / SUCCESS)

STEP 6: Run TARGET import  (impdp)
  Parfile: /export/home/oracle/arvind/RITM1096665/impdp_RITM1096665.par
  Command: impdp aregukumar/[PASSWORD]@CERPCQA1 parfile=RITM1096665/impdp_RITM1096665.par
  [P]roceed [M]ark as done [S]kip [E]xit — M
  Password for aregukumar@CERPCQA1:
  ✔ impdp completed successfully.
  Writing job entry to rj_dba.datapump_log on CERPCQA1 ...
  ✔ Logged to rj_dba.datapump_log (IMP / SUCCESS)

  Workflow complete for RITM1096665.
```

> **After the workflow completes**, run steps 7 and 8 manually:

```bash
# Step 7 — Archive logs
./archive_logfile.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665.log
./archive_logfile.sh /nfs/xs/repl/ZST-to-STG/expdp_RITM1096665_BKP.log
./archive_logfile.sh /nfs/xs/repl/ZST-to-STG/impdp_RITM1096665.log

# Step 8 — Generate cron cleanup entry
./schedule_cleanup_cron_16d.sh
```

---

### Behavioural notes

| Scenario | What to do |
|----------|-----------|
| Already ran expdp manually | Choose **[M]ark as done** at step 2 — wrapper moves on without re-running |
| Re-running after existing target data | Choose **[S]kip** at step 3 — wrapper prompts you to type the path directly |
| Log path already known | Choose **[S]kip** at step 3 — wrapper prompts you to type the path directly |
| Need to exit mid-workflow | Choose **[E]xit** at any prompt — no partial cron entries are left behind |

---

### Notes

- All scripts must be located in the same directory (e.g. `/export/home/oracle/arvind/`) and called from there, or invoked via their full path.
- **ZFS — Planned NFS migration:** Once these scripts are production-ready, they will be moved to a shared NFS path accessible from all servers. At that point, the hardcoded `/export/home/oracle/arvind/` path references in `schedule_cleanup_cron_16d.sh` and `archive_logfile.sh` will need to be updated to reflect the new shared location.
- For **Network Link** jobs (type 7), no dumpfiles are created — skip Parts 4 and 5.
- For **Partitioned Table** jobs (type 8), review and execute the `POST-IMPORT STEPS` comment block inside the generated `impdp_<TICKET>.par` before closing the ticket.
- The `archive_logfile.sh` script requires the oracle user to have `sudo` access to `/usr/bin/chattr`. Without it, the file is still copied but will not be immutable.
- `chattr +i` cannot be applied to files on NFS mounts. Always use a local directory for `ARCHIVE_DIR`.

---

## Other Useful Scripts

These scripts support common tasks before, during, and after a Data Pump job.

### `get_host.sh` — Find where a database is running

Resolves the hostname and CDB instance name for a given database (PDB or CDB alias). Useful when you need to know which physical server the database is on before running an export.

**Usage:**
```bash
cd resource_limit/
./get_host.sh <DB_NAME>
```

**Example:**
```
[oracle@orce01ldb1pd arvind]$ ./get_host.sh lightpopqa

INSTANCE:
INSTANCE_NAME
----------------
cxg90qal

BACKGROUND_MACHINES:
MACHINE
--------------------
exp10lbdb1.rjf.com
[oracle@orce01ldb1pd arvind]$
```

> Use this to confirm the target host before using `fetch_pdbs_dynamic.sh` or scheduling any DB-side operations.

---

### `resource_limit/get_resource_limit.sh` — Check process / session utilisation

Queries `GV$RESOURCE_LIMIT` across all RAC instances for a given database and reports current and maximum utilisation of processes, sessions, and transactions. Automatically detects any instance where **current or historical-max** utilisation exceeds **75%** of the limit, highlights it in red, and prompts to investigate.

If you choose **[I]nvestigate**, it pipes the flagged instance IDs to `run_get_resource_drilldown.sh`, which runs 7 root-cause queries: session status breakdown, non-idle wait events, top programs, machine/module/user breakdown, stale inactive sessions, JDBC Thin Client leak check, and blocking sessions.

> **Important:** Connect via a **CDB service** for accurate results. `GV$RESOURCE_LIMIT` is CDB-level, but `GV$SESSION`/`GV$PROCESS` are PDB-scoped — connecting via a PDB service will produce mismatched counts.

**Usage:**
```bash
cd resource_limit/
./get_resource_limit.sh <DB_NAME>
```

**Example:**
```
[oracle@orce01ldb1pd arvind]$ ./get_resource_limit.sh cxl4scdsqa

=== Resource Limits Report ===

INST RESOURCE     CURRENT  MAX  LIMIT  CTRS  NO31
   1 processes        295  312   800   315   399
   2 processes        186  287   800   256   345
   3 processes         61  790   800    49  1006
   4 processes         82  740   800    75   955

*** HIGH utilisation detected ***
Inst 3 — processes:990 max (over 43)
Inst 4 — processes:990 max (over 75)

[I]nvestigate flagged instances  [E]xit — I
```

---

### `resource_limit/get_pq_diag.sh` — ORA-12805 Parallel Query Diagnostics

When a Data Pump job fails with **ORA-12805** ("parallel query server died unexpectedly"), this script diagnoses resource contention. It runs 7 queries:

1. Process / session headroom (`GV$RESOURCE_LIMIT`)
2. Parallel server parameters (`parallel_max_servers`, `parallel_threads_per_cpu`, etc.)
3. Current PQ slave pool usage (`GV$PX_PROCESS`)
4. Active query coordinators with slave counts
5. PQ slave wait events
6. Non-PQ top consumers competing for process slots
7. Stale inactive sessions eating process slots

Optionally scope to specific instances by passing a comma-separated list.

**Usage:**
```bash
cd resource_limit/
./get_pq_diag.sh <DB_NAME> [inst_id,inst_id,...]
```

**Examples:**
```bash
./get_pq_diag.sh cxl4scdsqa            # all instances
./get_pq_diag.sh cxl4scdsqa 2,4        # instances 2 and 4 only
```

---

### `db_size/get_db_size.sh` — Report database size

Queries the database and reports its total size. Useful for estimating dumpfile space requirements before running an export.

**Usage:**
```bash
cd db_size/
./get_db_size.sh <DB_NAME>
```

---

### `datapump_longops.sh` — Monitor a running Data Pump job

Queries `GV$SESSION_LONGOPS` to show the progress of a currently running expdp or impdp job. Provides the percent complete and estimated time remaining.

**Usage:**
```bash
./datapump_longops.sh <EXP|IMP> <DB_NAME>
```

**Parameters:**
- `EXP` — monitor an export job
- `IMP` — monitor an import job

**Example:**
```
[oracle@orce01ldb1pd arvind]$ ./datapump_longops.sh EXP lightpopqa

HOSTNAME           SID  OPNAME              TARGET                    DONE_PCT  TIME_REMAINING_SEC  START_TIME
---------          ---  ------              ------                    --------  ------------------  ----------
AREGUKUMAR   1813  STG_EXPORT_TABLE_01                         66        8256  2026/02/04 02:00:56
[oracle@orce01ldb1pd arvind]$
```

> Run this in a separate terminal while an expdp/impdp is in progress to track how far along the job is.

---

### `fetch_pdbs_dynamic.sh` — Lists all PDBs on a host

SSHs to a remote Oracle database server and lists all CDBs running on it along with their PDBs, open modes, and restricted status.

**Usage:**
```bash
./fetch_pdbs_dynamic.sh <HOSTNAME>
```

**Example:**
```
[oracle@orce01ldb1pd arvind]$ ./fetch_pdbs_dynamic.sh squa80ldb1qa
Finding all container databases on the Linux server...
List of container databases:
cxgq00qa1  cxgq02qa1  cxgq03qa1

Collecting PDBs for each CDB...
PDBs in CDB cxgq00qa1:
  1  PDBREED    READ ONLY   NO
  3  DBDBQA     READ WRITE  NO
  4  IQIQPILQA  READ WRITE  NO
  5  DXGQLMXQA  READ WRITE  NO

PDBs in CDB cxgq02qa1:
  1  PDBREED    READ ONLY   NO
  3  SOMETRICA  READ WRITE  NO
  4  ZUZINTQA   READ WRITE  NO
...
```

> Internally copies `list_pdbs.sh` to `/tmp/` on the remote host and executes it via SSH.

---

### `ZFS_sync.sh` — Trigger a ZFS replication sync (DEN → STG)

Triggers an on-demand ZFS replication send/update from the Denver (DEN) ZFS appliance to the STG site via the ZFS REST API. Polls the sync state every 5 minutes (up to 20 iterations) and exits when the state returns to `idle`.

> **Security note:** The script contains a hardcoded Basic Auth header for the ZFS REST API. If the ZFS appliance password changes, update the `authorization` header in both `ZFS_sync.sh` and `ZFS_SYNC_status.sh`.

**Usage (run in background and tail the log):**
```
[oracle@orce01ldb1pd arvind]$ ./ZFS_sync.sh > ZFS_sync.log &
[1] 161569
[oracle@orce01ldb1pd arvind]$ tail -f ZFS_sync.log
Start ZFS sync
Zfs sync still running
Zfs sync completed
[oracle@orce01ldb1pd arvind]$
```

- Polls every **300 seconds** (5 minutes), up to **100 minutes** total.
- Exits with code `0` on completion regardless of whether idle state was reached within the loop.

---

### `ZFS_SYNC_status.sh` — Check current ZFS replication state

Queries the ZFS REST API and prints the current state of the replication action without triggering a new sync. Useful for checking whether a sync is still in progress.

**Usage:**
```bash
./ZFS_FUNC_status.sh
```

**Output (sync in progress):**
```
sending
```

**Output (sync complete / idle):**
```
idle
```

> Run this at any time to check whether the ZFS sync initiated by `ZFS_sync.sh` has finished before proceeding with import jobs that depend on the replicated data.
