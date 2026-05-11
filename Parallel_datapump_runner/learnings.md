# Parfile Learnings

## Query Parameter Formatting

### Single Quotes in `to_date()` Calls

When a `query=` parameter in a **parfile** contains `to_date()` or any SQL with single quotes, escape them with backslashes:

```
# Correct (parfile)
query=SCHEMA.TABLE:"WHERE col >= to_date(\'01-MAY-25\',\'DD-MON-YY\')"

# Incorrect — will fail
query=SCHEMA.TABLE:"WHERE col >= to_date('01-MAY-25','DD-MON-YY')"
```

The Data Pump parfile parser interprets `\'` as a literal single quote before passing the SQL to Oracle. This does **not** cause ORA-00911.

### Query Clause Structure

- The `query=` value must be prefixed with `SCHEMA.TABLE:` followed by the WHERE clause in double quotes.
- The `WHERE` keyword is included inside the quotes.

```
query=CCAL_TAXLOT_OWNER.COST_BSS:"WHERE col1 IN (...) AND col2 IN (...)"
```

### Full Load Tables

Tables exported as full loads simply omit the `query=` parameter entirely.

---

## Standard Export Parameters

```
metrics=Y
logtime=ALL
compression=ALL
compression_algorithm=MEDIUM
exclude=STATISTICS
cluster=N
parallel=32
```

- `EXCLUDE=STATISTICS` — regenerate stats on the target instead of importing stale ones.
- `CLUSTER=N` — disables RAC cross-instance parallelism; use when exporting from a standby.
- `parallel=32` — high parallelism for standby database exports.
- Dumpfile pattern uses `%U` for multi-file parallelism: `dumpfile=expdp_<NAME>_%U.dmp`

---

## Parfile Types

| Type | Key Parameter | Example |
|----|----|----|
| Table export | `tables=SCHEMA.TABLE` | `tables=CCAL_OWNER.EOD_POS` |
| Schema export | `schemas=SCHEMA` | `schemas=CIRD_OWNER` |

---

## Directory Objects

- Create the Oracle DIRECTORY before running exports:

```sql
CREATE DIRECTORY "DATA_PUMP_DIR4" AS '/nfs/datapump/export/';
```

- SQL files for directory creation are kept one level up from the table parfiles.

---

## Identifying LOB Storage Type (Pre-Parfile Check)

**Always run this before creating parfiles for LOB/CLOB tables** to determine the correct export approach.

### Check a Specific Table

```sql
SELECT owner, table_name, column_name, segment_name, securefile
FROM   dba_lobs
WHERE  owner = '<SCHEMA>'
  AND  table_name = '<TABLE>';
```

### Check All LOBs in a Schema

```sql
SELECT owner, table_name, column_name, segment_name, securefile
FROM   dba_lobs
WHERE  owner = '<SCHEMA>'
ORDER BY securefile, table_name;
```

| `SECUREFILE` | Storage Type | Export Approach |
|----|----|----|
| `NO` | BasicFile LOB | No parallel access — use ROWID/MOD split (multiple concurrent parfiles) |
| `YES` | SecureFile LOB | Supports native parallel export (standard parfile with `parallel=`) |

**Import rule:** Always use `transform=lob_storage:securefile` regardless of source LOB type.

---

## LOB / CLOB Table Exports

### Problem

BasicFile LOBs do not support parallel access. Data Pump assigns only **one worker** to a table with a BasicFile LOB, making large table exports extremely slow.

### Solution: Split the Table Across Multiple Data Pump Jobs

Instead of a single export with one worker, start **N concurrent exports**, each processing a dedicated slice of the table using the `query=` parameter.

#### Generating Predicates with ROWID (Generic — No Table Structure Knowledge Needed)

Use `MOD` on the block number to split evenly:

| Job | Predicate |
|-----|-----------|
| Job 0 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 0` |
| Job 1 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 1` |
| Job 2 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 2` |
| Job 3 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 3` |

#### Generating Predicates with Primary Key (Faster If Available)

| Job | Predicate |
|-----|-----------|
| Job 0 | `WHERE MOD(pk_column, 4) = 0` |
| Job 1 | `WHERE MOD(pk_column, 4) = 1` |
| Job 2 | `WHERE MOD(pk_column, 4) = 2` |
| Job 3 | `WHERE MOD(pk_column, 4) = 3` |

Increase the modulus value to add more concurrent workers.

#### Example Export Parfiles (ROWID Split, 4 Jobs)

```
# exp_lob_0.par
job_name=expdp_LOB_TABLE_0
tables=SCHEMA.LOB_TABLE
query=SCHEMA.LOB_TABLE:"WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 0"
directory=data_pump_dir5
dumpfile=expdp_LOB_TABLE_0_%U.dmp
logfile=expdp_LOB_TABLE_0.log
parallel=32
metrics=Y
logtime=ALL
compression=ALL
compression_algorithm=MEDIUM
exclude=STATISTICS
cluster=N
```

Each subsequent parfile changes the serial number in `job_name`, `dumpfile`, `logfile`, and the modulus remainder (0 → 1 → 2 → 3).

Run all 4 exports concurrently (in separate terminals or via the parallel runner):

```bash
expdp ... parfile=exp_lob_0.par &
expdp ... parfile=exp_lob_1.par &
expdp ... parfile=exp_lob_2.par &
expdp ... parfile=exp_lob_3.par &
```

---

## Importing LOB Tables — Convert BasicFile to SecureFile

**Always convert LOBs to SecureFile during import.** SecureFile LOBs support full parallel access.

#### Step 1: Import the First Dump (Creates the Table + Converts LOB)

```bash
impdp ... \
    dumpfile=expdp_LOB_TABLE_0_%U.dmp \
    logfile=imp_lob_0.log \
    transform=lob_storage:securefile \
    parallel=4
```

- `transform=lob_storage:securefile` converts BasicFile LOBs to SecureFile on-the-fly.
- This first job also creates the table itself.

#### Step 2: Import Remaining Dumps in Serial (Append)

```bash
impdp ... \
    dumpfile=expdp_LOB_TABLE_1_%U.dmp \
    logfile=imp_lob_1.log \
    parallel=4 \
    table_exists_action=append

impdp ... \
    dumpfile=expdp_LOB_TABLE_2_%U.dmp \
    logfile=imp_lob_2.log \
    parallel=4 \
    table_exists_action=append

impdp ... \
    dumpfile=expdp_LOB_TABLE_3_%U.dmp \
    logfile=imp_lob_3.log \
    parallel=4 \
    table_exists_action=append
```

- Run these **in serial** (one at a time). Each job uses Data Pump native parallelism since the LOB is now SecureFile.

### Important Cautions

1. **Index management** — Postpone index creation until the last job finishes loading. Otherwise, expensive index maintenance happens during each append.
2. **Streams pool** — Data Pump uses Advanced Queueing (streams pool in SGA). When running multiple concurrent Data Pump sessions, ensure adequate sizing:
   ```sql
   ALTER SYSTEM SET streams_pool_size=2G SCOPE=MEMORY;
   ```
3. **All rows, no duplicates** — The MOD-based split guarantees every row is exported exactly once across all jobs.

---

## Faster Export of SecureFile LOBs

### How Data Pump Parallelism Works with SecureFile LOBs

SecureFile LOBs allow parallel access, enabling Data Pump to unload and load data faster. To identify SecureFile LOBs:

```sql
SELECT owner, table_name, column_name
FROM   dba_lobs
WHERE  securefile = 'YES';
```

**Key mechanics:**
- Data Pump assigns **one worker per table data object** (table, partition, or subpartition).
- If the object is big enough (default: **250 MB**), that worker uses **parallel query (PQ)** to unload data.
- The threshold is configurable via the `parallel_threshold` parameter.
- You must set `parallel=` in the parfile for any of this to activate.

**Size determination methods:**
- `estimate=statistics` (default) — uses optimizer statistics
- `estimate=blocks` — uses actual block calculation (slower startup but more accurate)

### The Out-of-Row LOB Problem

LOBs smaller than 4000 bytes are stored **in-row** (counted in table segment size). LOBs larger than 4000 bytes are stored **out-of-row** in a separate LOB segment.

**The issue:** Table statistics (`dba_tab_statistics`) only reflect the table segment size, **not** the LOB segment. A table with 100 rows and 1 TB of out-of-row LOB data looks tiny to Data Pump. As a result, Data Pump skips parallel query for that table.

This also applies to **partitioned tables** — Data Pump examines partition statistics, not table-level.

### Solutions for Faster LOB Exports

#### 1. Apply the 19.23.0 Data Pump Bundle Patch (Best Option)

The issue is fixed in the **19.23.0 Data Pump Bundle Patch**. Always stay current.

#### 2. Use `estimate=blocks`

```
expdp ... estimate=blocks
```

- Forces Data Pump to calculate size from actual blocks instead of statistics.
- Startup phase takes longer.
- **Requires 19.18.0+ with the Data Pump bundle patch** due to a bug.

#### 3. Fake Statistics (Workaround)

Trick Data Pump into believing the table is large by inflating statistics:

```sql
BEGIN
  dbms_stats.set_table_stats(
    ownname  => 'APPUSER',
    tabname  => 'T1',
    numrows  => 10000000,
    numblks  => 1000000);
END;
/
```

**Cautions:**
- Must be done for **all tables with large out-of-row LOBs**.
- Fake statistics influence optimizer plan choices — only do this during maintenance windows.
- Setting statistics **invalidates cursors** in the library cache.
- Ensure the statistics gathering job doesn't overwrite your fake stats.
- Requires testing to find optimal values.

#### 4. Use Partitioning

- Data Pump assigns **one worker per partition/subpartition**.
- More workers = more simultaneous dump file writes = faster reads and writes.
- Still subject to the same statistics-based sizing issue per partition.

### Reminder

Always convert LOBs to SecureFile on import:

```
impdp ... transform=lob_storage:securefile
```
