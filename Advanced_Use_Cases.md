# Advanced Data Pump Use Cases

This document maps three specific DBA workflows to the existing script suite.
Each section explains what Oracle mechanism is involved, which scripts to use,
exactly what to enter at each prompt, and what the output looks like.

---

## Use Case 1 — Full Metadata Export and Import

### What it does

Exports the DDL of every object in the database (tables, indexes, packages,
views, synonyms, grants, sequences, etc.) — **no data rows**. The target
receives a structurally identical schema without any data movement. Useful for
cloning DDL baselines, auditing object structure, or pre-staging an empty
target before a separate data load.

### Scripts used

| Script | Role |
|--------|------|
| `datapump.sh` | Generate parfiles (job type **#6 — Metadata-Only**, scope **#3 — Full Database**) |
| `datapump_workflow.sh` | Run the full end-to-end interactively (steps 1 — 6) |
| `get_datapump_logfile.sh` | Resolve export log path |
| `list_dumpfiles.sh` | Verify dumpfile sizes before moving to import |

### Step-by-step

#### 1. Generate parfiles

```bash
./datapump.sh
```

At the prompts:

```
Enter Ticket Name     : RITM1096665
Enter Oracle DIRECTORY : DATA_PUMP_DIR
Enter PARALLEL degree : 8
Select job type       : 6          # Metadata-Only
Select metadata scope : 3          # Full Database
Enter include filter  : <Enter to skip>
Enter exclude filter  : STATISTICS   # recommended — stats are re-gathered on target
```

Produces under `RITM1096665/`:

```
expdp_RITM1096665.par     → run on SOURCE
expdp_RITM1096665_BKP.par → run on TARGET before import (rollback safety)
impdp_RITM1096665.par     → run on TARGET
```

Key lines generated in the export parfile:
```
full=Y
content=METADATA_ONLY
parallel=8
dumpfile=expdp_RITM1096665_%U.dmp
logfile=expdp_RITM1096665.log
exclude=STATISTICS
```

#### 2. Run the workflow

```bash
./datapump_workflow.sh
```

- **Step 1** → `[S]kip` (parfiles already exist)
- **Step 2** → `[R]un` the source export
- **Step 3** → resolve log path
- **Step 4** → inspect dumpfiles (size should be small — metadata only)
- **Step 5** → `[R]un` BKP export on target (captures current target DDL for rollback)
- **Step 6** → `[R]un` the import

> If `remap_schema` or `remap_tablespace` was populated in `datapump.sh`,
> all objects land in the remapped schema/tablespace on the target automatically.

### Notes

- Metadata-only dumpfiles are typically < 1 GB even for large databases.
- The `_BKP` export is your rollback point if you need to drop imported objects and revert.
- `STATISTICS` should always be excluded: re-gather with `DBMS_STATS` on the target after import.

---

## Use Case 2 — Back SQL Plan Baselines / SQL Profiles, Datapump to Refreshed Target, Unpack

### What it does

Preserves Oracle SQL Plan Management (SPM) baselines and/or SQL Profiles from a
production source and recreates them on a refreshed target (e.g. after a Full
database refresh that would otherwise wipe them). The baselines are packed into
a staging table, that table is exported with datapump, imported on the target,
then unpacked back into the SMB dictionary.

### Scripts used

| Script | Role |
|--------|------|
| `datapump.sh` | Generate parfiles (job type **#1 — Table**) scoped to the staging table |
| `datapump_workflow.sh` | Run export → import (steps 2, 4, 5, 6) |
| `list_dumpfiles.sh` | Confirm staging table dumpfile loaded correctly |

### Step-by-step

#### Step 1. Export SQL Plan Baselines (run on SOURCE as TOURADDNER)

**1a. Create the baseline staging table:**

```sql
BEGIN
  DBMS_SPM.CREATE_STGTAB_BASELINE('baseline_staging_table', 'TOURADDNER');
END;
/
```

**1b. Pack all baselines into it** (NULL packs all baselines):

```sql
DECLARE
  x NUMBER;
BEGIN
  x := DBMS_SPM.PACK_STGTAB_BASELINE('baseline_staging_table', 'TOURADDNER');
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(x) || ' plan baselines packed');
END;
/
```

#### Step 2. Export SQL Profiles (run on SOURCE as TOURADDNER)

**2a. Create the SQL Profile staging table:**

```sql
BEGIN
  DBMS_SQLTUNE.CREATE_STGTAB_SQLPROF('sqlprof_staging_table', 'TOURADDNER');
END;
/
```

**2b. Pack all SQL Profiles into it** (NULL packs all profiles):

```sql
BEGIN
  DBMS_SQLTUNE.PACK_STGTAB_SQLPROF(
    staging_table_name => 'sqlprof_staging_table'
  );
END;
/
```

#### Step 3. Generate parfiles and run Data Pump

```bash
./datapump.sh
```

At the prompts:

```
Enter Ticket Name       : RITM1096665_SPM
Enter Oracle DIRECTORY  : DATA_PUMP_DIR
Enter PARALLEL degree   : 2
Select job type         : 1          # Table
Enter tables            : TOURADDNER.baseline_staging_table,TOURADDNER.sqlprof_staging_table
Enter table_exists_action : replace
Enter remap_table       : <Enter to skip>
Enter remap_tablespace  : <Enter to skip>
Enter remap_schema      : <Enter to skip>
```

```bash
./datapump_workflow.sh
```

- **Step 1** → `[S]kip` (parfiles already exist)
- **Step 2** → `[R]un` source export
- **Step 3** → resolve log path
- **Step 4** → inspect dumpfiles
- **Step 5** → `[S]kip` BKP export (no pre-existing baselines on a freshly refreshed target)
- **Step 6** → `[R]un` import on TARGET

#### Step 4. Unpack on TARGET (run as TOURADDNER)

**4a. Unpack baselines:**

```sql
DECLARE
  x NUMBER;
BEGIN
  x := DBMS_SPM.UNPACK_STGTAB_BASELINE('baseline_staging_table', 'TOURADDNER');
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(x) || ' plan baselines unpacked');
END;
/
```

**4b. Unpack SQL Profiles:**

```sql
BEGIN
  DBMS_SQLTUNE.UNPACK_STGTAB_SQLPROF(
    replace           => TRUE,
    staging_table_name => 'sqlprof_staging_table'
  );
END;
/
```

#### Step 5. Validate on TARGET — confirm counts match SOURCE

**Baselines — count and status breakdown:**

```sql
-- Run on BOTH source and target; row counts and accepted/fixed ratios should match
SELECT origin,
       enabled,
       accepted,
       fixed,
       COUNT(*) AS cnt
FROM   dba_sql_plan_baselines
GROUP  BY origin, enabled, accepted, fixed
ORDER  BY origin, enabled, accepted, fixed;
```

**Baselines — spot-check most recently modified:**

```sql
SELECT sql_handle,
       plan_name,
       origin,
       enabled,
       accepted,
       fixed,
       TO_CHAR(last_modified, 'DD-MON-YYYY HH24:MI') AS last_modified
FROM   dba_sql_plan_baselines
ORDER  BY last_modified DESC
FETCH  FIRST 20 ROWS ONLY;
```

**SQL Profiles — count and status:**

```sql
-- Run on BOTH source and target; counts should match
SELECT status, COUNT(*) AS cnt
FROM   dba_sql_profiles
GROUP  BY status;
```

**SQL Profiles — spot-check most recently created:**

```sql
SELECT name,
       category,
       status,
       TO_CHAR(created,       'DD-MON-YYYY HH24:MI') AS created,
       TO_CHAR(last_modified, 'DD-MON-YYYY HH24:MI') AS last_modified
FROM   dba_sql_profiles
ORDER  BY created DESC
FETCH  FIRST 20 ROWS ONLY;
```

**Quick cross-check query** — run on source then target and compare the two numbers:

```sql
-- Baselines
SELECT COUNT(*) AS total_baselines FROM dba_sql_plan_baselines;

-- Profiles
SELECT COUNT(*) AS total_profiles  FROM dba_sql_profiles;
```

### Notes

- Export the staging tables from source **before** the database refresh wipes the target (or export directly from the production source at refresh time).
- `REPLACE => TRUE` in `UNPACK_STGTAB_SQLPROF` overwrites any stale profiles of the same name already present on the target.
- Both staging tables can be dropped on source and target after a successful unpack and validation.

---

## Use Case 3 — Extract DDL for Fixed Objects (Packages, Procedures, Triggers, Functions) to a SQL File

### What it does

Generates a `.sql` file containing the DDL `CREATE` statements for **fixed
PL/SQL objects only** (packages, package bodies, procedures, functions,
triggers) — "nothing else at all". Uses the `include=` filter
on the export to limit what lands in the dumpfile, and impdp's `SQLFILE`
parameter to write the DDL to a flat file instead of
running DDL. This is the standard Oracle technique for capturing stored code for
audit trails, change-control evidence, and schema comparison.

### Scripts used

| Script | Role |
|--------|------|
| `datapump.sh` | Generate parfiles (job type **#6 — Metadata-Only**, any scope) |
| `datapump_workflow.sh` | Run source export (step 2 only; import step is replaced by manual `impdp SQLFILE=`) |
| `get_datapump_logfile.sh` | Resolve export log path |
| `list_dumpfiles.sh` | Confirm dumpfile is present before running SQLFILE import |

### Step-by-step

#### Step 1. Generate parfiles

```bash
./datapump.sh
```

To capture only fixed PL/SQL object types at schema scope:

```
Enter Ticket Name       : RITM1096665_DDL
Enter Oracle DIRECTORY  : DATA_PUMP_DIR
Enter PARALLEL degree   : 4
Select job type         : 6          # Metadata-Only
Select metadata scope   : 2          # Schema  (or 3 for Full DB)
Enter schemas           : HR_FINANCE_APP_OWNER
Enter include filter    : PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM
Enter exclude filter    : <Enter to skip>
```

> The `include=` filter is passed to expdp as
> `include=PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM` — only those
> object types are written to the dumpfile. Everything else (tables, indexes,
> grants, statistics) is excluded from the dump entirely.

#### Step 2. Run the source export (workflow steps 1–4 only)

```bash
./datapump_workflow.sh
```

- **Steps 1–4** → proceed normally
- **Step 5** (BKP export) → `[S]kip`
- **Step 6** (import) → `[S]kip` — the import is replaced by the SQLFILE run below

#### Step 3. Create a SQLFILE impdp parfile (manual — one-off)

This parfile is not generated by `datapump.sh` because `SQLFILE` is a
read-only inspection mode, not a real import. Create it manually:

```
# impdp_RITM1096665_DDL_sqlfile.par
directory=DATA_PUMP_DIR
dumpfile=expdp_RITM1096665_%U.dmp
logfile=expdp_RITM1096665_ddl_sqlfile.log
sqlfile=RITM1096665_ddl_scripts.sql
content=METADATA_ONLY
include=PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM
```

> The `include=` here acts as a second filter on top of what is already in the
> dumpfile. If the export was already restricted to these types, this line is
> redundant but harmless — it is good practice to keep both in sync.

Run with:

```bash
impdp TOURADDNER@SOURCE_DB parfile=impdp_RITM1096665_DDL_sqlfile.par
```

#### Step 4. Retrieve the SQL file from the Oracle DIRECTORY

The file `RITM1096665_ddl_scripts.sql` is written to the OS path of
`DATA_PUMP_DIR`. Use `get_datapump_logfile.sh` to find the directory path:

```bash
./get_datapump_logfile.sh SOURCE_DB RITM1096665_DDL/expdp_RITM1096665_DDL.par
```

Then copy the SQL file from the directory path it returns, e.g.:

```bash
cp /u01/app/oracle/admin/SOURCEDB/dpdump/RITM1096665_ddl_scripts.sql \
   /export/home/oracle/arvind/RITM1096665_DDL/
```

#### Step 5. What the SQL file contains

With the `include=PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM` filter
applied, the generated file contains PL/SQL code, object types, views, and
synonyms — no table DDL, no index DDL, no grants:

```sql
CREATE OR REPLACE PACKAGE "HR"."HR_UTILITIES" AS
...
END;
/

CREATE OR REPLACE PACKAGE BODY "HR"."HR_UTILITIES" AS
...
END;
/

CREATE OR REPLACE PROCEDURE "FINANCE"."CALC_INTEREST" ( ... ) AS
...
END;
/

CREATE OR REPLACE TRIGGER "APP_OWNER"."ADD_EMPLOYEES_TRG"
BEFORE INSERT OR UPDATE ON "APP_OWNER"."EMPLOYEES"
...
END;
/
```

### Notes

- `SQLFILE` **never modifies the target** — safe to run against a production-connected impdp as long as the dumpfile is already exported.
- `PACKAGE_BODY` must be listed separately from `PACKAGE` in the `include=` filter — omitting it will export only the package spec, not the body.
- The dumpfile is created on the **database server** inside the Oracle DIRECTORY path, not on the client where impdp is invoked.
- To widen scope back to all object types, remove the `include=` line from both the export parfile and the SQLFILE parfile.

---

## Quick Reference — Job Type Selection per Use Case

| Use Case | `datapump.sh` Job Type | Scope | Key Parameters |
|----------|------------------------|-------|----------------|
| Full metadata export/import | **#6** — Metadata-Only | 3 — Full Database | `content=METADATA_ONLY`, `full=Y`, `exclude=STATISTICS` |
| Baselines/profiles pack-and-ship | **#1** — Table | n/a | `tables=TOURADDNER.baseline_staging_table,TOURADDNER.sqlprof_staging_table`, `table_exists_action=replace` |
| DDL extraction to SQL file | **#6** — Metadata-Only | 2 — Schema or 3 — Full | `content=METADATA_ONLY`, `include=PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM` on export; `sqlfile=` name `include=` in manual impdp parfile |

---

## Script Flow Diagram

**Use Case 1 — Full Metadata**

```
datapump.sh (type 6, scope 3)
  └─ datapump_workflow.sh
        ├─ Step 2: expdp SOURCE  (content=METADATA_ONLY, full=Y)
        ├─ Step 3: get_datapump_logfile.sh
        ├─ Step 4: list_dumpfiles.sh
        ├─ Step 5: expdp TARGET BKP  (captures target DDL pre-import)
        └─ Step 6: impdp TARGET
```

**Use Case 2 — Baselines / Profiles**

```
SQL: DBMS_SPM.PACK_STGTAB_BASELINE → TOURADDNER.baseline_staging_table
     DBMS_SQLTUNE.PACK_STGTAB_SQLPROF → TOURADDNER.sqlprof_staging_table
datapump.sh (type 1, tables=TOURADDNER.baseline_staging_table,TOURADDNER.sqlprof_staging_table)
  └─ datapump_workflow.sh
        ├─ Step 2: expdp SOURCE staging table
        ├─ Step 4: list_dumpfiles.sh
        ├─ Step 5: [skip]
        └─ Step 6: impdp TARGET
SQL: DBMS_SPM.UNPACK_STGTAB_BASELINE on TARGET
```

**Use Case 3 — DDL to SQL File**

```
datapump.sh (type 6, scope 2 or 3)
  └─ datapump_workflow.sh
        ├─ Step 2: expdp SOURCE  (content=METADATA_ONLY)
        ├─ Step 3: get_datapump_logfile.sh
        ├─ Step 4: list_dumpfiles.sh
        ├─ Step 5: [skip]
        └─ Step 6: [skip]
Manual: impdp SOURCE_DB parfile=..._sqlfile.par  (SQLFILE= only, no target changes)
```
