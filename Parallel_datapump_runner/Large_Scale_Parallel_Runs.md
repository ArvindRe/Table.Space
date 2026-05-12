# Running 400 Oracle Data Pump Jobs Over 72 Hours — Architecture, Tooling, and Hard-Won Lessons

## The Problem

Production Oracle databases hold the ground truth. QA and DEV environments need a representative slice of that data to run meaningful tests, reproduce bugs, and validate migrations — but refreshing them is rarely simple. The data is large, the jobs are many, and production availability windows are narrow.

In this engagement the requirement was specific:

- **400 distinct export jobs** targeting selected schemas and tables across multiple production databases, **each exceeding 400 TB**, running on **Oracle Exadata**
- **~300 TB** of data to be extracted and loaded into lower environments (QA/DEV), also Exadata-hosted, as part of a quarterly refresh cycle
- A **hard 72-hour execution window** — roughly three overnight runs, non-negotiable
- **Minimal human intervention** — the team monitors progress but cannot babysit every job

Running 400 jobs manually, one at a time, was obviously off the table. Running all 400 simultaneously was equally impractical — it would saturate I/O, exhaust the streams pool, and destabilize production. The answer was a **controlled parallel pipeline**: a configurable worker pool that keeps a fixed number of Data Pump sessions running at all times, automatically picking up the next job the moment one finishes.

---

## Operating Constraints

Two hard constraints shaped every architectural decision and ruled out approaches that would otherwise seem attractive at first glance.

### Storage Crunch

The production source databases each exceed 400 TB. The QA and DEV Exadata environments — their cell storage and ZFS appliances combined — do not have capacity to hold a full clone. This is the fundamental reason a **subset approach** was required: QA/DEV can accommodate ~300 TB of selected, high-value data, not a 400 TB+ replica.

Any strategy premised on copying first and filtering later was ruled out by this constraint:

- **Full PDB or database clones**: a physical clone of a 400 TB+ Exadata database requires 400 TB+ on the target before a single unwanted row is removed. QA/DEV does not have that headroom.
- **Snapshot standby + selective delete**: the full dataset lands on target cell storage already near capacity, and then you attempt to delete 100+ TB of unwanted rows — an operation that is slow, generates redo, and is risky to interrupt mid-way.

Data Pump is the only Oracle-native logical tool that applies the row filter (`query=`) **at the source** during export. Only the wanted ~300 TB ever leaves the production environment, which is the only model that works within the QA/DEV storage budget.

### Time Crunch

Seventy-two hours is not a generous window for 300 TB of logical data movement. Every hour of idle time in the pipeline is unrecoverable. This is what motivated the worker pool design: the moment any job finishes, the next one launches. There is no gap between jobs and no human in the critical path.

---

## Why Other Approaches Were Ruled Out

### Transportable Tablespaces

Transportable Tablespaces (TTS) is a physical copy mechanism — it bypasses row-by-row serialization and is typically orders of magnitude faster than a logical export for large tables. RMAN-based TTS makes the READ ONLY requirement manageable. However, two independent problems rule it out here:

**Problem 1 — Number of tablespaces.** The 400 export jobs span many schemas and tablespaces. Coordinating TTS across that many tablespace sets — setting them all READ ONLY, verifying self-containment, managing the transport, then setting them READ WRITE again — is operationally complex enough to be its own multi-day project, before any data reaches the target.

**Problem 2 — Post-transport row deletion.** TTS delivers entire tablespace datafiles to the target. To achieve the subset, you would then need to delete the unwanted rows from every table in every transported tablespace, one table at a time. At 400 TB+ of source data, the unwanted rows could total 100+ TB. Deleting that volume generates enormous redo on the target and takes longer than the logical export would have. TTS gets the data there faster but leaves you with a worse version of the deletion problem.

### Standby-Based Extraction

Running exports from a physical standby to offload the primary is theoretically attractive. Two independent problems ruled it out here.

**Problem 1 — DB link overhead.** The standby is accessible only as an auxiliary over a database link. Data Pump routed through a DB link (`network_link` parameter) serializes all row traffic through the link layer — there is no Smart Scan offload, no parallel direct read, just row-by-row network transfer. For TB-scale data this is significantly slower than exporting directly from the primary.

**Problem 2 — Active Data Guard read workload.** The standby was serving non-stop read-only queries from application and reporting users via Active Data Guard. Converting it to a snapshot standby — which would be required to apply any write operations or run Data Pump directly against it — would suspend redo apply and take the standby out of ADG read-only mode, cutting off those users for the duration of the 72-hour window. That was not acceptable.

The `CLUSTER=N` parfile parameter still limits parallelism to the local RAC instance and avoids cross-node coordination overhead, but the exports run against the primary, not the standby.

---

## The Architecture

### Overview

```
┌─────────────────────────────────────────────────┐
│  run_exports_parallel.sh  (or run_imports_*)     │
│  ├─ parse_args()       CLI flags → globals       │
│  ├─ validate_parfiles() preflight checks         │
│  ├─ prompt_password()  single password entry     │
│  └─ run_worker_pool()  worker pool engine        │
│       ├─ _launch_job() fork expdp/impdp          │
│       ├─ _reap_finished() collect exit codes     │
│       ├─ _poll_wait()   bash <4.3 fallback       │
│       └─ _record_result() update counters        │
│  print_summary()  elapsed time per parfile       │
└─────────────────────────────────────────────────┘
           sources dp_parallel_lib.sh (shared core)
```

### Three Files, Clean Separation

| File | Role |
|------|------|
| `dp_parallel_lib.sh` | Shared library — worker pool, argument parsing, password handling, summary. Sourced at runtime; never executed directly. |
| `run_exports_parallel.sh` | Thin driver for `expdp`. Sources the lib, calls `main()`. |
| `run_imports_parallel.sh` | Thin driver for `impdp`. Sources the lib, calls `main()`. |

The export and import runners are intentionally identical except for the tool name they pass to the worker pool. All logic lives in the library so fixes and improvements propagate to both in one change.

---

## How the Worker Pool Works

### The Core Loop

1. At startup the pool launches up to `-j` (default: 3) jobs simultaneously — one `expdp` or `impdp` process per parfile, each backgrounded and captured to its own `.out` log file.
2. The main loop calls `wait -n` (bash 4.3+), which blocks until **any single child exits**. The moment it returns, the reaper identifies which PID finished, records its exit code, and immediately launches the next queued parfile.
3. On bash older than 4.3, the pool falls back to polling with `kill -0` every 5 seconds — slightly less reactive but functionally equivalent.
4. The loop terminates when the running counter reaches zero and the queue is empty.

This design guarantees that all `-j` slots stay busy for the entire run. There is no idle time between jobs.

### Password Handling

The password is prompted once, stored in a bash variable (`_DP_PASS`), and passed directly to each `expdp`/`impdp` invocation. On `EXIT`, `INT`, or `TERM` the cleanup trap kills all children and explicitly unsets the variable. It is never written to disk.

> **Note:** The credential appears briefly in the process table (as `expdp user/pass@tns`). This matches the standard Oracle CLI invocation pattern. For higher security, an Oracle Wallet or external secret store eliminates this exposure entirely.

### Signal Safety

`trap cleanup_trap EXIT INT TERM` is set after the password is stored but before any jobs launch. A `Ctrl-C` or unexpected termination kills all background children cleanly, preventing orphaned Data Pump sessions from continuing to consume production I/O and generating partial dumpfiles.

### Summary Table

After every job completes, the pool prints a final table:

```
PARFILE                                  RC    START                END                  ELAPSED
expdp_SCHEMA_ORDERS.par                  0     2026-05-07 22:00:01  2026-05-07 22:43:17  00:43:16
expdp_SCHEMA_POSITIONS.par               0     2026-05-07 22:00:01  2026-05-08 00:11:40  02:11:39
expdp_SCHEMA_LOB_TABLE_0.par             0     2026-05-07 22:43:17  2026-05-08 01:05:02  02:21:45
...
Total: 400 | Succeeded: 397 | Failed: 3
```

This gives an immediate answer to "what failed?" without manually inspecting 400 log files.

---

## How to Use the Scripts

### Prerequisites

- bash 4.3+ (check with `bash --version`)
- `expdp` / `impdp` on `$PATH`
- An Oracle DIRECTORY object created and accessible to the exporting user
- All parfiles pre-generated (use `datapump.sh` from the parent toolkit)

### Step 1 — Create Oracle Directory Objects

```sql
CREATE OR REPLACE DIRECTORY "DATA_PUMP_DIR4" AS '/nfs/datapump/export/';
GRANT READ, WRITE ON DIRECTORY "DATA_PUMP_DIR4" TO system;
```

### Step 2 — Dry-Run to Verify Parfiles

Before touching production, validate that every parfile path resolves and the commands look correct:

```bash
./run_exports_parallel.sh -u SYSTEM -d PRODDB -n /ticket/parfiles/expdp_*.par
```

Output shows `[DRY-RUN] expdp SYSTEM/******@PRODDB parfile=...` for each file, with no actual execution.

### Step 3 — Run Exports

```bash
# 400 parfiles, 5 concurrent sessions, logs in /tmp/exp_logs
./run_exports_parallel.sh \
    -u SYSTEM \
    -d PRODDB \
    -j 5 \
    -o /tmp/exp_logs \
    /ticket/parfiles/expdp_*.par
```

The concurrency value (`-j`) is the primary tuning knob. Start at 3–5 on production and monitor I/O wait, streams pool usage, and redo log generation rate before increasing.

### Step 4 — Run Imports

```bash
./run_imports_parallel.sh \
    -u SYSTEM \
    -d QADB \
    -j 4 \
    -o /tmp/imp_logs \
    /ticket/parfiles/impdp_*.par
```

---

## Parfile Standards That Made This Work

The `learnings.md` file captures lessons learned during the actual 72-hour run. The most impactful ones:

### Export Consistency: `flashback_scn`

When 400 export jobs run over 72 hours, each job without a flashback point reads data as of its own start time. The first job and the last job are 72 hours apart. In a live 430 TB production database, that gap means referential integrity is broken in the QA/DEV dataset — a parent row exported at hour 0 may have a child row that was modified at hour 60 and reflects a state that never coexisted with the parent's exported state. The QA/DEV data is internally inconsistent before the first import even runs.

The fix is to capture a single SCN at the start of the export window and embed it in every parfile:

```sql
-- Run once before starting the parallel runner; record the output
SELECT current_scn FROM v$database;
```

```
# Add to every parfile
flashback_scn=<SCN captured above>
```

All 400 jobs now read from the same consistent snapshot regardless of when they execute within the 72-hour window. The QA/DEV dataset reflects a single coherent point in time.

#### The ORA-01555 Risk

On a 430 TB active production database, `flashback_scn` introduces a serious undo risk. A job that starts at hour 70 of the window needs undo data going all the way back to the original flashback SCN — 70 hours of undo retention. If undo segments have been reused in that time, the export fails with ORA-01555 (snapshot too old). At scale and over a 72-hour window, this is not a theoretical concern — it is a real failure mode.

**Mitigation 1 — Increase `UNDO_RETENTION` temporarily:**

```sql
-- Before the export window opens
ALTER SYSTEM SET undo_retention = 259200;  -- 72 hours in seconds

-- Restore after the window closes
ALTER SYSTEM SET undo_retention = <original_value>;
```

This extends how long Oracle preserves undo before reusing segments. It does not guarantee retention — Oracle can still overwrite undo if the tablespace is under pressure.

**Mitigation 2 — Guaranteed undo retention:**

```sql
ALTER TABLESPACE undotbs1 RETENTION GUARANTEE;

-- Revert after the export window
ALTER TABLESPACE undotbs1 RETENTION NOGUARANTEE;
```

Guaranteed retention prevents undo from being overwritten regardless of tablespace pressure. The trade-off is significant: if the undo tablespace fills up, DML on the production database fails. Only use this if the undo tablespace is sized comfortably beyond 72 hours of peak production undo generation. Monitor undo space continuously during the export window.

The two mitigations are complementary — raise `UNDO_RETENTION` to signal intent and size the retention window, then add `GUARANTEE` only if undo tablespace headroom supports it.

### Standard Export Parameters

```
metrics=Y
logtime=ALL
compression=ALL
compression_algorithm=MEDIUM
exclude=STATISTICS
cluster=N
parallel=32
flashback_scn=<SCN>
```

- `FLASHBACK_SCN` — ensures all 400 jobs export from the same consistent snapshot. Capture the SCN once before the runner starts.
- `EXCLUDE=STATISTICS` — prevents importing stale optimizer statistics. Regenerate them fresh on the target after load.
- `CLUSTER=N` — restricts Data Pump to the local RAC instance, avoiding cross-node coordination overhead.
- `parallel=32` — high per-job parallelism to saturate Exadata's InfiniBand and cell I/O bandwidth within each export.
- `dumpfile=expdp_<NAME>_%U.dmp` — the `%U` wildcard creates numbered files, allowing Data Pump to write multiple dump files in parallel.

### Single Quotes in `query=` Parameters

When a parfile `query=` contains SQL with single quotes (e.g., `to_date()` calls), escape them with backslashes:

```
# Correct
query=SCHEMA.TABLE:"WHERE col >= to_date(\'01-MAY-25\',\'DD-MON-YY\')"

# Wrong — will fail at parse time
query=SCHEMA.TABLE:"WHERE col >= to_date('01-MAY-25','DD-MON-YY')"
```

The Data Pump parfile parser processes `\'` as a literal single quote before handing the SQL to Oracle.

---

## The LOB Problem — The Hardest Part

Large Object (LOB/CLOB) columns were the primary source of complexity. The root issue: **BasicFile LOBs do not support parallel access**. Data Pump assigns exactly one worker to a table containing a BasicFile LOB — no matter how high `parallel=` is set. For a table with 500 GB of LOB data, that means one worker, no parallelism, slow export. On Exadata, where every other workload benefits from Smart Scan and InfiniBand throughput, single-threaded LOB access is an especially painful bottleneck.

### Identifying LOB Storage Type

Always check before writing parfiles:

```sql
SELECT owner, table_name, column_name, segment_name, securefile
FROM   dba_lobs
WHERE  owner = '<SCHEMA>'
ORDER BY securefile, table_name;
```

| `SECUREFILE` | Type | Behavior |
|---|---|---|
| `NO` | BasicFile | Single-threaded. Must split manually. |
| `YES` | SecureFile | Supports native Data Pump parallelism. |

### Strategy for BasicFile LOBs: ROWID-Based Splitting

Split the table across N concurrent parfiles using `MOD` on the block number. No knowledge of table structure or primary key required:

```
# exp_lob_0.par
tables=SCHEMA.LOB_TABLE
query=SCHEMA.LOB_TABLE:"WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 0"
dumpfile=expdp_LOB_TABLE_0_%U.dmp

# exp_lob_1.par — change only the modulus remainder and filenames
query=SCHEMA.LOB_TABLE:"WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 1"
```

Feed all 4 parfiles to the parallel runner. Each handles a non-overlapping, exhaustive slice of the table. The modulus guarantees no row appears in more than one job.

### Importing LOB Tables — Convert to SecureFile

**Always convert BasicFile LOBs to SecureFile on import.** SecureFile supports full parallel access, making all subsequent queries and future exports dramatically faster:

```bash
# First dump — creates table with SecureFile storage
impdp ... dumpfile=expdp_LOB_TABLE_0_%U.dmp transform=lob_storage:securefile parallel=4

# Subsequent dumps — append (serial, one at a time)
impdp ... dumpfile=expdp_LOB_TABLE_1_%U.dmp table_exists_action=append parallel=4
impdp ... dumpfile=expdp_LOB_TABLE_2_%U.dmp table_exists_action=append parallel=4
impdp ... dumpfile=expdp_LOB_TABLE_3_%U.dmp table_exists_action=append parallel=4
```

The append imports run serial (not concurrent) to avoid index maintenance on every batch. Defer index creation until the final append completes.

### The Out-of-Row LOB Statistics Problem

Even SecureFile LOBs can be slow if Data Pump thinks the table is small. LOB data larger than 4000 bytes lives in a separate segment from the table — and `dba_tab_statistics` only reflects the table segment. A table with 1 TB of LOB data can appear to be 10 MB to Data Pump's size estimator, causing it to skip parallel query entirely.

Options (best to worst):

1. **Apply the 19.23.0 Data Pump Bundle Patch** — the correct fix. The bug is patched at this version.
2. **Use `estimate=blocks`** — forces accurate block-based size calculation. Requires 19.18.0+ with the DP bundle patch.
3. **Inflate statistics temporarily** — tell Data Pump the table is large by setting fake row/block counts via `dbms_stats.set_table_stats`. Effective, but invalidates cursors and requires careful cleanup after the export window.

---

## Streams Pool Sizing

Multiple concurrent Data Pump sessions all draw from the SGA streams pool (used by Advanced Queueing internally). Running 5 concurrent exports without adequate sizing causes sessions to wait or fail. Size it before the run:

```sql
ALTER SYSTEM SET streams_pool_size=2G SCOPE=MEMORY;
```

Tune upward if sessions stall on AQ-related waits in `v$session_wait`.

---

## Reassessing the Approach

### Data Pump Is the Right Tool Given These Constraints

With both source and target on Exadata, a hard storage ceiling on QA/DEV, row-level filtering required, and a 72-hour window, the alternatives close off one by one:

- **TTS** is ruled out by the number of tablespaces involved and the post-transport deletion problem — you'd spend more time deleting unwanted rows on the target than the logical export would have taken.
- **PDB / database clones** are ruled out by QA/DEV storage capacity — the target cannot absorb a full 400 TB+ copy.
- **Standby-based extraction** is slower than primary for this topology because the standby is accessible only via a DB link, and Data Pump through a DB link (`network_link`) loses Smart Scan offload and parallel direct read, falling back to row-by-row network transfer.

Data Pump against the primary, with row filters applied at source, compression to reduce NFS volume, and the parallel runner to keep all slots busy for the full 72 hours, is not just a reasonable approach — given the constraints, it is the correct one.

### Where There Is Still Room to Improve

These are the remaining gaps worth addressing, in priority order:

**Retry logic and checkpointing** are the two highest-priority additions to the runner. A transient failure at hour 60 of a 72-hour run currently requires manual re-intervention. With retry logic (`-r N`) and a checkpoint file (`-c`), failed jobs re-run automatically and an interrupted run resumes from where it stopped.

**Oracle Wallet** eliminates the interactive password prompt, enabling the runner to be launched from cron for fully unattended overnight execution. It also removes credentials from the process table entirely.

**Direct NFS (dNFS)** should be enabled on the Exadata database nodes for the dump file NFS mount. dNFS bypasses the OS NFS stack via a kernel-level path and typically doubles NFS write throughput — a meaningful gain across a 300 TB export with no code changes required.

**BasicFile LOB migration in production** is a one-time operation (`ALTER TABLE ... MOVE LOB ... STORE AS SECUREFILE`) that eliminates the ROWID-split workaround for all future refresh cycles and benefits all applications querying those tables.

---

## Recommendations for Further Improvement

### 1. Flashback SCN + Undo Retention Planning

Capture a single SCN before launching the runner and embed it in every parfile. Without this, a 72-hour, 400-job run produces an internally inconsistent QA/DEV dataset. Pair this with a temporary `UNDO_RETENTION` increase (to 259200 seconds for a 72-hour window) and evaluate guaranteed undo retention if the undo tablespace has sufficient headroom. Monitor undo space continuously during the window — a full undo tablespace with `RETENTION GUARANTEE` active will fail production DML.

### 3. Retry Logic for Failed Jobs ✓ Implemented

The runner re-queues failed parfiles up to N times before giving up, covering transient failures (network blips, ORA-12516 connection pool exhaustion, temporary lock contention). Use `-r N` to enable:

```bash
./run_imports_parallel.sh -u SYSTEM -d PRODDB -j 4 -r 2 /tmp/parfiles/imp_*.par
```

Failed jobs are re-appended to the internal queue; the worker pool picks them up automatically once a slot is free. Each parfile tracks its own retry count independently. A job that exhausts all attempts is recorded as FAILED in the final summary.

### 4. Checkpointing / Resume Capability ✓ Implemented

Every successful job is appended to a checkpoint file (`<tool>_parallel_<timestamp>.ckpt`) in the `logs/` directory. If the runner is killed mid-way (network drop, OS restart), resume the run with `-C <checkpoint_file>` — already-completed parfiles are skipped and the run continues from where it stopped:

```bash
# Resume an interrupted run (pass the same parfile glob as the original)
./run_imports_parallel.sh -u SYSTEM -d PRODDB -j 4 \
    -C logs/impdp_parallel_20260511_143000.ckpt \
    /tmp/parfiles/imp_*.par
```

Checkpoint format — one line appended per successful job:

```
/path/to/parfile|0|2026-05-11 14:30:00|2026-05-11 16:12:45
```

A custom checkpoint path can be specified with `-C`; otherwise the path is auto-generated alongside the log file. Both flags can be combined:

```bash
./run_imports_parallel.sh -u SYSTEM -d PRODDB -j 4 -r 2 \
    -C logs/impdp_parallel_20260511_143000.ckpt \
    /tmp/parfiles/imp_*.par
```

### 5. Enable Direct NFS (dNFS)

Configure the Exadata database nodes to use Oracle's Direct NFS client for the dump file NFS mount. dNFS bypasses the OS NFS stack with a kernel-level path, typically doubling write throughput. This is a configuration change with no script modifications required and a measurable impact across a 300 TB export.

### 6. Oracle Wallet Integration

Credentials passing through the process table is the clearest security gap in the current design. Oracle Wallet (`mkstore`, `orapki`) allows passwordless connections — `expdp /@PRODDB parfile=...` — with no credentials in the process table or shell history, and no interactive prompt at launch.

### 7. Rate Limiting During Business Hours

Concurrency (`-j`) is a coarse knob. Automatically reducing it during business hours — e.g., drop from 5 to 2 between 09:00 and 17:00 — keeps the pipeline running continuously across the 72-hour window without impacting production users during peak hours.

### 8. Per-Job Progress Notifications

A `curl` POST to a Slack webhook or `sendmail` on job failure would let the monitoring team know about problems without watching a terminal. Combined with `datapump_longops.sh` (which reads `GV$SESSION_LONGOPS`), a wrapper could post periodic progress updates during the run.

### 9. Parfile Generation Pipeline

For 400 jobs, parfile authoring is substantial prep work and a source of human error (especially single-quote escaping and LOB detection). An upstream script that reads a structured input file (schema, table, date filter, LOB type, target directory) and generates ready-to-run parfiles — including ROWID-split generation for BasicFile LOBs — would reduce setup time from hours to minutes.

### 10. Post-Import Statistics Refresh

`EXCLUDE=STATISTICS` is correct — Exadata-gathered statistics are not necessarily meaningful on the QA/DEV Exadata configuration. But this relies on someone running `DBMS_STATS.GATHER_DATABASE_STATS` after all imports complete. Appending an automatic stats-gather to the import runner's completion path closes this gap.

### 11. Structured JSON Output

The summary table is human-readable but not machine-readable. Emitting a parallel `summary.json` file would allow retry scripts, dashboards, and incident tickets to consume results without parsing formatted text.

---

## Summary

This toolset solved a concrete, large-scale data refresh problem under hard constraints: 400 TB+ Exadata source databases, QA/DEV Exadata environments without enough cell storage for full clones, row-level subsetting required, and a fixed 72-hour window. Those constraints collectively rule out the alternatives that appear attractive in the abstract — TTS is defeated by tablespace count and post-transport deletion complexity, PDB cloning is defeated by target storage, and standby-based extraction via DB link is slower than the primary for TB-scale data.

Data Pump applied against the primary with row filters at source, compression to reduce NFS volume, and the parallel runner to eliminate idle time between jobs is the correct model for this environment. The most technically interesting challenges were in Oracle internals rather than orchestration: BasicFile LOBs that resist parallelism, out-of-row LOB statistics that confuse the size estimator, and streams pool contention under concurrent load. The learnings documented in `learnings.md` represent real failures from the run — each a gotcha that will not bite a second time.
