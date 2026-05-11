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

#### Step 1. Export SQL Plan Baselines (run on SOURCE as APP_OWNER)

**1a. Create the baseline staging table:**

```sql
BEGIN
  DBMS_SPM.CREATE_STGTAB_BASELINE('baseline_staging_table', 'APP_OWNER');
END;
/
```

**1b. Pack all baselines into it** (NULL packs all baselines):

```sql
DECLARE
  x NUMBER;
BEGIN
  x := DBMS_SPM.PACK_STGTAB_BASELINE('baseline_staging_table', 'APP_OWNER');
  DBMS_OUTPUT.PUT_LINE(TO_CHAR(x) || ' plan baselines packed');
END;
/
```

#### Step 2. Export SQL Profiles (run on SOURCE as APP_OWNER)

**2a. Create the SQL Profile staging table:**

```sql
BEGIN
  DBMS_SQLTUNE.CREATE_STGTAB_SQLPROF('sqlprof_staging_table', 'APP_OWNER');
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
Enter tables            : APP_OWNER.baseline_staging_table,APP_OWNER.sqlprof_staging_table
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

#### Step 4. Unpack on TARGET (run as APP_OWNER)

**4a. Unpack baselines:**

```sql
DECLARE
  x NUMBER;
BEGIN
  x := DBMS_SPM.UNPACK_STGTAB_BASELINE('baseline_staging_table', 'APP_OWNER');
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
impdp APP_OWNER@SOURCE_DB parfile=impdp_RITM1096665_DDL_sqlfile.par
```

#### Step 4. Retrieve the SQL file from the Oracle DIRECTORY

The file `RITM1096665_ddl_scripts.sql` is written to the OS path of
`DATA_PUMP_DIR`. Use `get_datapump_logfile.sh` to find the directory path:

```bash
./get_datapump_logfile.sh SOURCE_DB RITM1096665_DDL/expdp_RITM1096665_DDL.par
```

Then copy the SQL file from the directory path it returns, e.g.:

```bash
cp /oracle/admin/SOURCE_DB/dpdump/RITM1096665_ddl_scripts.sql \
   /export/home/oracle/scripts/RITM1096665_DDL/
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

## Use Case 4 — Sync QA/DEV-Specific Objects Back After a Production Refresh

### What it does

When QA/DEV is refreshed from a production backup, all QA/DEV-specific objects
are overwritten — test schemas, QA-only grants, custom synonyms, DB links, and
non-production packages are wiped back to the production baseline. This use case
preserves those objects **before** the refresh by exporting them from the current
QA/DEV database, then re-imports them into the newly refreshed QA/DEV immediately
after.

> If the refresh has already happened and no pre-refresh export exists, see the
> **Post-Refresh Recovery (No Prior Export)** section below.

### Scripts used

| Script | Role |
|--------|------|
| `datapump.sh` | Generate parfiles — job type **#2 (Schema)** for full schema sync, or **#6 (Metadata-Only)** for DDL-only |
| `datapump_workflow.sh` | Run export from current QA/DEV, then import to refreshed QA/DEV |
| `get_datapump_logfile.sh` | Resolve export log path |
| `list_dumpfiles.sh` | Confirm dumpfiles before import |
| `fetch_pdbs_dynamic.sh` | Identify the PDB/CDB of the QA/DEV target after refresh |

---

### Pre-Refresh Export (run BEFORE the refresh window)

#### Step 1. Identify what will be lost after the refresh

A production refresh wipes two distinct categories of QA/DEV-specific content:

| Category | Description | Risk |
|----------|-------------|------|
| **QA-only schemas** | Entire schemas that exist in QA/DEV but not in prod | Fully dropped |
| **QA-only objects within shared schemas** | Packages, procedures, tables, synonyms, grants added to schemas that also exist in prod (e.g. a debug package in `APP_OWNER`) | Overwritten back to prod baseline |

Both must be captured. Running only a schema-level export misses the second category.

**1a. Find schemas that exist in QA/DEV but not in prod:**

```sql
-- Run on QA/DEV DB
SELECT username
FROM   dba_users
WHERE  username NOT IN (
    SELECT username FROM dba_users@<PROD_DB_LINK>
)
AND    account_status = 'OPEN'
ORDER  BY username;
```

**1b. Find objects within shared schemas that exist in QA/DEV but not in prod:**

These are objects inside schemas that exist in both environments, but the
individual object was added only in QA/DEV (test packages, debug procedures,
QA integration tables, etc.):

```sql
-- Objects in QA/DEV that do not exist in prod (same owner, same name, same type)
SELECT owner, object_name, object_type
FROM   dba_objects
WHERE  object_type IN (
    'TABLE','VIEW','PACKAGE','PACKAGE BODY','PROCEDURE',
    'FUNCTION','TRIGGER','SYNONYM','SEQUENCE','TYPE','TYPE BODY',
    'DATABASE LINK','MATERIALIZED VIEW','SCHEDULER JOB'
)
AND    (owner, object_name, object_type) NOT IN (
    SELECT owner, object_name, object_type
    FROM   dba_objects@<PROD_DB_LINK>
)
AND    owner NOT IN (
    -- Exclude system/Oracle-owned schemas
    'SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN','ORACLE_OCM',
    'APPQOSSYS','WMSYS','EXFSYS','CTXSYS','XDB','ANONYMOUS',
    'MDSYS','OLAPSYS','ORDSYS','ORDDATA','SI_INFORMTN_SCHEMA',
    'DIP','FLOWS_FILES','APEX_PUBLIC_USER'
)
ORDER  BY owner, object_type, object_name;
```

Save this output — it is your authoritative list of what must be preserved.

**1c. Find grants on QA/DEV-specific objects (both categories):**

```sql
-- Grants on objects that don't exist in prod (covers both schema and object gaps)
SELECT grantee, owner, table_name, privilege, grantable
FROM   dba_tab_privs
WHERE  (owner, table_name) NOT IN (
    SELECT owner, table_name FROM dba_tab_privs@<PROD_DB_LINK>
)
ORDER  BY owner, table_name, grantee;
```

**1d. Find public synonyms pointing to QA/DEV-specific objects:**

```sql
SELECT synonym_name, table_owner, table_name
FROM   dba_synonyms
WHERE  owner = 'PUBLIC'
AND    (table_owner, table_name) NOT IN (
    SELECT table_owner, table_name
    FROM   dba_synonyms@<PROD_DB_LINK>
    WHERE  owner = 'PUBLIC'
);
```

#### Step 2. Export — two separate jobs, one per category

Run two exports. Keep them separate so each can be re-imported independently
if only part of the restore is needed.

**Export A — QA-only schemas (entire schemas missing from prod):**

```bash
./datapump.sh
```

```
Enter Ticket Name       : RITM_QAREFRESH_SCHEMAS
Enter Oracle DIRECTORY  : DATA_PUMP_DIR
Enter PARALLEL degree   : 4
Select job type         : 2          # Schema
Enter schemas           : QA_APP_OWNER,QA_TEST_USER,QA_INTEGRATION
Enter remap_schema      : <Enter to skip>
Enter remap_tablespace  : <Enter to skip>
```

> Use job type **#6 (Metadata-Only)** if no data rows are needed — test
> packages, synonyms, and grants only.

```bash
./datapump_workflow.sh
```

- **Steps 1–4** → proceed (generate parfiles, export, resolve log, inspect sizes)
- **Steps 5–6** → `[S]kip`

**Export B — QA-only objects within shared schemas:**

Use job type **#6 (Metadata-Only)** scoped to the shared schemas, with an
`include=` filter covering all object types identified in Step 1b.
This avoids re-exporting the prod-baseline objects that already live in those schemas.

The full set of object types to sync, and their Data Pump `include=` names:

| Object category | `dba_objects.object_type` | Data Pump `include=` name | Notes |
|-----------------|--------------------------|--------------------------|-------|
| Tables | `TABLE` | `TABLE` | Includes constraints, indexes by default |
| Materialized views | `MATERIALIZED VIEW` | `MATERIALIZED_VIEW` | Base tables must exist first |
| PL/SQL — packages | `PACKAGE`, `PACKAGE BODY` | `PACKAGE`, `PACKAGE_BODY` | Export spec and body separately |
| PL/SQL — standalone | `PROCEDURE`, `FUNCTION`, `TRIGGER` | `PROCEDURE`, `FUNCTION`, `TRIGGER` | |
| Types | `TYPE`, `TYPE BODY` | `TYPE`, `TYPE_BODY` | Imported before dependents automatically |
| Synonyms | `SYNONYM` | `SYNONYM` | Covers private synonyms; public synonyms need `PUBLIC_SYNONYM` |
| Sequences | `SEQUENCE` | `SEQUENCE` | |
| Views | `VIEW` | `VIEW` | |
| DB links | `DATABASE LINK` | `DB_LINK` | **Passwords not exported** — must be re-set manually post-import |
| Scheduler jobs | `SCHEDULER JOB` | `PROCOBJ` | **Credentials not exported** — re-attach job credentials post-import; review schedule times for QA context |

```bash
./datapump.sh
```

```
Enter Ticket Name       : RITM_QAREFRESH_OBJECTS
Enter Oracle DIRECTORY  : DATA_PUMP_DIR
Enter PARALLEL degree   : 4
Select job type         : 6          # Metadata-Only
Select metadata scope   : 2          # Schema
Enter schemas           : APP_OWNER,SHARED_SCHEMA   # shared schemas containing QA-only objects
Enter include filter    : TABLE,MATERIALIZED_VIEW,VIEW,PACKAGE,PACKAGE_BODY,PROCEDURE,FUNCTION,TRIGGER,TYPE,TYPE_BODY,SYNONYM,SEQUENCE,DB_LINK,PROCOBJ
Enter exclude filter    : STATISTICS
```

> The `include=` filter limits the dumpfile to only QA-added object types.
> At import time, `table_exists_action=SKIP` ensures prod-baseline objects
> already on the refreshed target are untouched — only absent QA-specific
> objects get created.

**Post-import manual steps for DB links and scheduler jobs:**

```sql
-- Re-set DB link passwords after import (passwords are stripped by Data Pump)
-- Run on refreshed QA/DEV for each DB link exported:
CREATE OR REPLACE DATABASE LINK <link_name>
  CONNECT TO <remote_user> IDENTIFIED BY <password>
  USING '<tns_alias>';

-- Re-attach scheduler job credentials after import:
BEGIN
  DBMS_SCHEDULER.SET_ATTRIBUTE(
    name      => '<schema>.<job_name>',
    attribute => 'credential_name',
    value     => '<credential_name>'
  );
END;
/
```

```bash
./datapump_workflow.sh
```

- **Steps 1–4** → proceed
- **Steps 5–6** → `[S]kip`

Note both dumpfile paths. Ensure they are on a mount that **survives the refresh**
(NFS, separate ASM diskgroup, or copied off-host).

---

### Post-Refresh Import (run AFTER the refresh completes)

#### Step 3. Confirm the refreshed target is accessible

```bash
./fetch_pdbs_dynamic.sh
```

Verify the QA/DEV PDB is open and not in restricted mode before importing.

#### Step 4. Import A — QA-only schemas

```bash
./datapump_workflow.sh
```

```
Ticket name  : RITM_QAREFRESH_SCHEMAS
Source DB    : <QA_DEV_DB>
Target DB    : <QA_DEV_DB>
DB username  : <DBA_USER>
```

- **Steps 1–2** → `[S]kip` (export already done)
- **Step 3** → provide source log path manually
- **Step 4** → `[P]roceed` — confirm dumpfiles visible on refreshed host
- **Step 5** → `[S]kip`
- **Step 6** → `[P]roceed` — import QA-only schemas

If tablespace names differ post-refresh, add `remap_tablespace` in the import
parfile before running step 6.

#### Step 5. Import B — QA-only objects within shared schemas

Before running, open the generated import parfile (`impdp_RITM_QAREFRESH_OBJECTS.par`)
and add `table_exists_action=SKIP`. This is critical — it tells impdp to skip
any object that already exists on the refreshed target (the prod-baseline objects),
and only create the ones that are absent (the QA-specific ones):

```
# impdp_RITM_QAREFRESH_OBJECTS.par  — add this line before importing
table_exists_action=SKIP
```

```bash
./datapump_workflow.sh
```

```
Ticket name  : RITM_QAREFRESH_OBJECTS
Source DB    : <QA_DEV_DB>
Target DB    : <QA_DEV_DB>
DB username  : <DBA_USER>
```

- **Steps 1–2** → `[S]kip`
- **Step 3** → provide log path manually
- **Step 4** → `[P]roceed` — inspect dumpfile
- **Step 5** → `[S]kip`
- **Step 6** → `[P]roceed`

Check the impdp log after this step — any `ORA-39151` (object already exists,
skipped) lines are expected for prod-baseline objects. Lines without errors
confirm the QA-specific objects were created.

#### Step 6. Re-apply grants and public synonyms

Grants and public synonyms captured in Steps 1c and 1d are **not automatically
carried** by a metadata export unless `include=OBJECT_GRANT` was explicitly in
the parfile. Re-apply from the SQL output saved in Step 1:

```sql
-- Re-apply a grant example
GRANT SELECT ON app_owner.qa_debug_table TO qa_test_user;

-- Re-create a public synonym example
CREATE OR REPLACE PUBLIC SYNONYM qa_config FOR qa_app_owner.config_table;
```

#### Step 7. Validate — confirm all QA-specific objects are restored

Re-run the Step 1b delta query on the refreshed QA/DEV. The result set should
now be empty — meaning everything that was in QA/DEV but not prod is back:

```sql
-- Should return zero rows if all QA-specific objects were successfully restored
SELECT owner, object_name, object_type
FROM   dba_objects
WHERE  object_type IN (
    'TABLE','VIEW','PACKAGE','PACKAGE BODY','PROCEDURE',
    'FUNCTION','TRIGGER','SYNONYM','SEQUENCE','TYPE','TYPE BODY',
    'DATABASE LINK','MATERIALIZED VIEW','SCHEDULER JOB'
)
AND    (owner, object_name, object_type) NOT IN (
    SELECT owner, object_name, object_type
    FROM   dba_objects@<PROD_DB_LINK>
)
AND    owner NOT IN (
    'SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN','ORACLE_OCM',
    'APPQOSSYS','WMSYS','EXFSYS','CTXSYS','XDB','ANONYMOUS',
    'MDSYS','OLAPSYS','ORDSYS','ORDDATA','SI_INFORMTN_SCHEMA',
    'DIP','FLOWS_FILES','APEX_PUBLIC_USER'
)
ORDER  BY owner, object_type, object_name;
```

Check for invalids across all affected owners:

```sql
SELECT owner, object_name, object_type, status
FROM   dba_objects
WHERE  status != 'VALID'
AND    owner NOT IN (
    'SYS','SYSTEM','DBSNMP','SYSMAN','OUTLN','ORACLE_OCM',
    'APPQOSSYS','WMSYS','EXFSYS','CTXSYS','XDB','ANONYMOUS',
    'MDSYS','OLAPSYS','ORDSYS','ORDDATA','SI_INFORMTN_SCHEMA',
    'DIP','FLOWS_FILES','APEX_PUBLIC_USER'
)
ORDER  BY owner, object_type;
```

Recompile invalids:

```sql
-- Per schema
EXEC DBMS_UTILITY.COMPILE_SCHEMA(schema => 'QA_APP_OWNER', compile_all => FALSE);

-- Or recompile all invalid objects database-wide
@?/rdbms/admin/utlrp.sql
```

---

### Post-Refresh Recovery (No Prior Export)

If the refresh has already completed and no pre-refresh dumpfile exists, use a
**network link** (job type **#7**) to pull QA/DEV-specific objects directly from
another environment that still has them (e.g. a sister QA instance, or a
preserved pre-refresh snapshot):

```bash
./datapump.sh
```

```
Enter Ticket Name       : RITM_QAREFRESH_RECOVER
Enter Oracle DIRECTORY  : DATA_PUMP_DIR
Enter PARALLEL degree   : 4
Select job type         : 7          # Network Link
Enter network_link      : <DB_LINK_TO_SISTER_QA_OR_SNAPSHOT>
Enter schemas           : QA_APP_OWNER,QA_TEST_USER,QA_INTEGRATION
Enter remap_schema      : <Enter to skip or remap if needed>
```

This pulls directly across the network link — no dumpfile is written to disk.
Run `datapump_workflow.sh` and proceed only steps 6 (import). Steps 2–4 are
irrelevant (no source export dumpfile).

---

### Notes

- Always capture the pre-refresh export **before** the maintenance window opens.
  Once the refresh starts, the current QA/DEV state is gone.
- Dumpfiles must be stored on a path that is **not** on the same ASM diskgroup
  or filesystem being overwritten by the refresh.
- If only packages/procedures need to be synced (not data), prefer job type
  **#6 (Metadata-Only)** with `include=PACKAGE,PACKAGE_BODY,PROCEDURE,FUNCTION` —
  the dumpfile will be small and the import fast.
- The `_BKP` parfile step (step 5 in the workflow) is intentionally skipped in
  this use case — the refreshed state IS the known-good baseline, and you do not
  want to overwrite it with a BKP export.

---

## Use Case 5 — Exporting and Importing LOB / CLOB Tables

### What it does

Handles large tables containing BasicFile or SecureFile LOB columns, where standard single-job exports are either too slow or inaccurate. Covers identifying LOB storage type, splitting BasicFile LOB tables across concurrent export jobs, converting to SecureFile on import, and resolving the out-of-row LOB statistics problem that causes Data Pump to underestimate table size and skip parallelism.

### Scripts used

| Script | Role |
|--------|------|
| `datapump.sh` | Generates the per-slice parfiles (type 5 — Query-Filtered Table) |
| `run_exports_parallel.sh` | Runs all slice parfiles concurrently |

---

### Step 1 — Identify LOB Storage Type

**Always run this before creating parfiles for any table with LOB columns.**

```sql
-- Check a specific table
SELECT owner, table_name, column_name, segment_name, securefile
FROM   dba_lobs
WHERE  owner      = '<SCHEMA>'
  AND  table_name = '<TABLE>';

-- Check all LOBs in a schema
SELECT owner, table_name, column_name, segment_name, securefile
FROM   dba_lobs
WHERE  owner = '<SCHEMA>'
ORDER BY securefile, table_name;
```

| `SECUREFILE` value | Storage type | Export approach |
|--------------------|--------------|-----------------|
| `NO` | BasicFile | No parallel access — use ROWID/MOD split (multiple concurrent parfiles) |
| `YES` | SecureFile | Supports native parallel export — standard parfile with `parallel=` |

---

### Step 2 — Export: BasicFile LOB Tables (ROWID/MOD Split)

BasicFile LOBs do not support parallel access. Data Pump assigns only **one worker** to the entire table, making large LOB table exports extremely slow. The fix is to split the table across N concurrent export jobs, each handling a dedicated block-number slice.

#### Generate predicates using ROWID (no primary key needed)

Use `MOD` on the block number to divide rows evenly:

| Job | `query=` predicate |
|-----|--------------------|
| Job 0 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 0` |
| Job 1 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 1` |
| Job 2 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 2` |
| Job 3 | `WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 3` |

Increase the modulus to add more concurrent workers.

#### Alternative: split by primary key (faster if available)

| Job | `query=` predicate |
|-----|--------------------|
| Job 0 | `WHERE MOD(pk_column, 4) = 0` |
| Job 1 | `WHERE MOD(pk_column, 4) = 1` |
| Job 2 | `WHERE MOD(pk_column, 4) = 2` |
| Job 3 | `WHERE MOD(pk_column, 4) = 3` |

#### Example parfiles (ROWID split, 4 jobs)

```
# exp_lob_0.par
job_name=expdp_LOB_TABLE_0
tables=SCHEMA.LOB_TABLE
query=SCHEMA.LOB_TABLE:"WHERE MOD(dbms_rowid.rowid_block_number(rowid), 4) = 0"
directory=DATA_PUMP_DIR1
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

#### Run all 4 jobs concurrently

```bash
# Via the parallel runner (recommended)
./run_exports_parallel.sh -u db_user -d SOURCE_DB -j 4 \
    exp_lob_0.par exp_lob_1.par exp_lob_2.par exp_lob_3.par

# Or manually in separate terminals
expdp db_user/$$$$$$$$@SOURCE_DB parfile=exp_lob_0.par &
expdp db_user/$$$$$$$$@SOURCE_DB parfile=exp_lob_1.par &
expdp db_user/$$$$$$$$@SOURCE_DB parfile=exp_lob_2.par &
expdp db_user/$$$$$$$$@SOURCE_DB parfile=exp_lob_3.par &
```

The MOD-based split guarantees every row is exported exactly once across all jobs.

---

### Step 3 — Export: SecureFile LOB Tables

SecureFile LOBs support parallel access natively. Use a standard parfile with `parallel=` set — no splitting required.

```
job_name=expdp_SECURELOB_TABLE
tables=SCHEMA.SECURELOB_TABLE
directory=DATA_PUMP_DIR1
dumpfile=expdp_SECURELOB_TABLE_%U.dmp
logfile=expdp_SECURELOB_TABLE.log
parallel=32
metrics=Y
logtime=ALL
compression=ALL
compression_algorithm=MEDIUM
exclude=STATISTICS
cluster=N
```

Data Pump assigns one worker per table, and if the object exceeds the parallel threshold (default **250 MB**) that worker uses parallel query to unload. If exports still run single-threaded on a large SecureFile table, see the out-of-row LOB statistics problem below.

---

### Step 4 — Import: Convert BasicFile LOBs to SecureFile

**Always convert LOBs to SecureFile during import.** SecureFile supports full parallel access; importing as BasicFile locks you back into the same parallelism constraint.

#### Import 1: first dump (creates table + converts LOB storage)

```bash
impdp db_user/$$$$$$$$@TARGET_PDB \
    dumpfile=expdp_LOB_TABLE_0_%U.dmp \
    logfile=imp_lob_0.log \
    transform=lob_storage:securefile \
    parallel=4
```

`transform=lob_storage:securefile` converts BasicFile LOBs to SecureFile on the fly. This first job also creates the table itself.

#### Import 2–N: remaining dumps in serial (append)

```bash
impdp db_user/$$$$$$$$@TARGET_PDB \
    dumpfile=expdp_LOB_TABLE_1_%U.dmp \
    logfile=imp_lob_1.log \
    parallel=4 \
    table_exists_action=append

impdp db_user/$$$$$$$$@TARGET_PDB \
    dumpfile=expdp_LOB_TABLE_2_%U.dmp \
    logfile=imp_lob_2.log \
    parallel=4 \
    table_exists_action=append

impdp db_user/$$$$$$$$@TARGET_PDB \
    dumpfile=expdp_LOB_TABLE_3_%U.dmp \
    logfile=imp_lob_3.log \
    parallel=4 \
    table_exists_action=append
```

Run these **in serial** — each job uses Data Pump native parallelism since the LOB is now SecureFile.

#### Import cautions

- **Postpone index creation** until the last job finishes. Index maintenance on every append is expensive.
- **Size streams pool** before running multiple concurrent Data Pump sessions (Data Pump uses Advanced Queueing internally):
  ```sql
  ALTER SYSTEM SET streams_pool_size=2G SCOPE=MEMORY;
  ```

---

### Step 5 — The Out-of-Row LOB Statistics Problem

LOBs smaller than 4000 bytes are stored **in-row** (counted in the table segment). LOBs larger than 4000 bytes are stored **out-of-row** in a separate LOB segment. Table statistics in `dba_tab_statistics` reflect only the table segment — not the LOB segment.

**Effect on Data Pump:** a table with 100 rows and 1 TB of out-of-row LOB data looks tiny to the size estimator. Data Pump skips parallel query for that table entirely, regardless of the `parallel=` setting. This also applies per partition on partitioned tables.

#### Fix 1: Apply the 19.23.0 Data Pump bundle patch (best option)

The bug is fixed in the **19.23.0 Data Pump bundle patch**. Always stay current with Data Pump bundle patches.

#### Fix 2: Use `estimate=blocks`

```
expdp ... estimate=blocks
```

Forces Data Pump to calculate size from actual blocks rather than statistics. Startup phase takes longer but accurately reflects LOB segment size. **Requires 19.18.0+ with the Data Pump bundle patch** due to a separate bug.

#### Fix 3: Fake statistics (maintenance-window workaround)

```sql
BEGIN
  dbms_stats.set_table_stats(
    ownname  => 'SCHEMA',
    tabname  => 'LOB_TABLE',
    numrows  => 10000000,
    numblks  => 1000000);
END;
/
```

Tricks Data Pump into believing the table is large enough to trigger parallel query. Cautions:
- Must be done for every table with large out-of-row LOBs
- Inflated statistics affect optimizer plan choices — only do this in a maintenance window
- Setting statistics invalidates cursors in the library cache
- Ensure the automatic stats gathering job does not overwrite the inflated values before the export completes

#### Fix 4: Partition the table

Data Pump assigns one worker per partition or subpartition. More partitions = more parallel workers = faster export. Subject to the same per-partition statistics issue, but the impact is smaller per object.

---

### Notes

- `transform=lob_storage:securefile` applies on import regardless of source LOB type — always include it.
- The ROWID/MOD split approach requires no knowledge of the table structure or distribution of data.
- If the modulus is too low and slices are uneven (due to block clustering), increase it (e.g. 8 or 16 concurrent jobs).
- On partitioned LOB tables, consider using partition-level exports (`include=TABLE_PARTITION`) instead of the ROWID split — Data Pump naturally assigns one worker per partition.

---

## Quick Reference — Job Type Selection per Use Case

| Use Case | `datapump.sh` Job Type | Scope | Key Parameters |
|----------|------------------------|-------|----------------|
| Full metadata export/import | **#6** — Metadata-Only | 3 — Full Database | `content=METADATA_ONLY`, `full=Y`, `exclude=STATISTICS` |
| Baselines/profiles pack-and-ship | **#1** — Table | n/a | `tables=APP_OWNER.baseline_staging_table,APP_OWNER.sqlprof_staging_table`, `table_exists_action=replace` |
| DDL extraction to SQL file | **#6** — Metadata-Only | 2 — Schema or 3 — Full | `content=METADATA_ONLY`, `include=PROCEDURE,TRIGGER,PACKAGE,PACKAGE_BODY,FUNCTION,TYPE,TYPE_BODY,VIEW,SYNONYM` on export; `sqlfile=` name `include=` in manual impdp parfile |
| QA/DEV object sync after prod refresh | **#2** — Schema (with data) or **#6** — Metadata-Only (DDL only) | 2 — Schema | `schemas=<QA_SCHEMAS>`; or `network_link=<LINK>` for recovery with no prior export |
| BasicFile LOB table export | **#5** — Query-Filtered Table | 1 — Table | `query=SCHEMA.TABLE:"WHERE MOD(dbms_rowid.rowid_block_number(rowid), N) = K"`, N parfiles run concurrently |
| SecureFile LOB table export | **#1** — Table | 1 — Table | Standard parfile; `estimate=blocks` if parallel query not triggering |

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
SQL: DBMS_SPM.PACK_STGTAB_BASELINE → APP_OWNER.baseline_staging_table
     DBMS_SQLTUNE.PACK_STGTAB_SQLPROF → APP_OWNER.sqlprof_staging_table
datapump.sh (type 1, tables=APP_OWNER.baseline_staging_table,APP_OWNER.sqlprof_staging_table)
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

**Use Case 4 — QA/DEV Object Sync After Production Refresh**

```
PRE-REFRESH (run before maintenance window):
SQL: identify QA-only schemas via dba_users delta vs PROD
datapump.sh (type 2 — Schema, or type 6 — Metadata-Only)
  └─ datapump_workflow.sh
        ├─ Step 2: expdp current QA/DEV  →  dumpfile saved to NFS / off-host path
        ├─ Step 3: get_datapump_logfile.sh  →  note path
        ├─ Step 4: list_dumpfiles.sh  →  confirm sizes
        ├─ Step 5: [skip]
        └─ Step 6: [skip]

[Production refresh executes — QA/DEV overwritten]

POST-REFRESH (run after QA/DEV is back online):
fetch_pdbs_dynamic.sh  →  confirm QA/DEV PDB is OPEN
datapump_workflow.sh
        ├─ Step 3: provide dumpfile log path manually
        ├─ Step 4: list_dumpfiles.sh  →  confirm dumpfiles visible on refreshed host
        ├─ Step 5: [skip]
        └─ Step 6: impdp into refreshed QA/DEV
SQL: recompile invalids — DBMS_UTILITY.COMPILE_SCHEMA
SQL: validate object counts match pre-refresh baseline

RECOVERY PATH (no prior export — network link):
datapump.sh (type 7 — Network Link)
  └─ datapump_workflow.sh
        └─ Step 6: impdp via network_link (no dumpfile)
```

**Use Case 5 — LOB / CLOB Table Export and Import**

```
PRE-EXPORT:
SQL: dba_lobs → identify BasicFile vs SecureFile storage per table

BasicFile path:
datapump.sh (type 5 — Query-Filtered Table)  ×N  (one parfile per ROWID slice)
  └─ run_exports_parallel.sh -j N
        ├─ expdp slice 0: query="WHERE MOD(dbms_rowid.rowid_block_number(rowid), N) = 0"
        ├─ expdp slice 1: query="WHERE MOD(..., N) = 1"
        └─ ... (all N jobs run concurrently)

SecureFile path:
datapump.sh (type 1 — Table, standard parfile)
  └─ expdp with parallel=32  (native parallel query kicks in if object > 250 MB)
     If parallel not triggering → estimate=blocks  or  fake statistics via dbms_stats

IMPORT (both paths):
  impdp slice 0: transform=lob_storage:securefile  (creates table, converts LOB)
  impdp slice 1–N: table_exists_action=append      (run in serial)
```
