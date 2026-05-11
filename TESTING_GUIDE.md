# Datapump Scripts — Testing Guide

This document describes how to retest the scripts after editing them. Follow the steps in order. Each section maps to a checklist item in `TEST_REPORT.md`.

---

## Prerequisites

### Docker Containers Required

| Container | Image | Port | Service | Password |
|-----------|-------|------|---------|---------|
| `oracle-free` | `oracle/free:23.26.0.0-arm64` | 1521 | `FREEPDB1` | `SentinelDBA1` |
| `oracle-19c` | `gvenzl/oracle-xe:21-slim` | 1522 | `XEPDB1` | `SentinelDBA1` |

Both containers must be running and healthy before testing.

### Oracle Client Required

`sqlplus` must be in PATH. Install Oracle Instant Client:
```bash
# macOS — download DMG from Oracle, then:
export ORACLE_HOME=/usr/local/lib/oracle/21/client64/lib/instantclient_21_x
export DYLD_LIBRARY_PATH=$ORACLE_HOME
export PATH=$ORACLE_HOME:$PATH
```

### One-time DB Setup (run once per fresh container)

```bash
# Unlock dbsnmp in both containers
docker exec oracle-free bash -c "sqlplus -s '/ as sysdba' <<'EOF'
ALTER USER dbsnmp IDENTIFIED BY DBsnmp123 ACCOUNT UNLOCK CONTAINER=ALL;
EOF"

docker exec oracle-19c bash -c "sqlplus -s '/ as sysdba' <<'EOF'
ALTER USER dbsnmp IDENTIFIED BY DBsnmp123 ACCOUNT UNLOCK CONTAINER=ALL;
EOF"

# Create test schema DPTEST in oracle-free FREEPDB1
docker exec oracle-free bash -c "sqlplus -s 'system/SentinelDBA1@localhost/FREEPDB1' <<'EOF'
DROP USER dptest CASCADE;
CREATE USER dptest IDENTIFIED BY DPTest123 DEFAULT TABLESPACE USERS QUOTA UNLIMITED ON USERS;
GRANT CONNECT, RESOURCE TO dptest;
GRANT READ, WRITE ON DIRECTORY DATA_PUMP_DIR TO dptest;
CONNECT dptest/DPTest123@localhost/FREEPDB1
CREATE TABLE countries (country_code VARCHAR2(3) PRIMARY KEY, country_name VARCHAR2(50), continent VARCHAR2(20), population NUMBER);
INSERT INTO countries VALUES ('USA','United States','North America',331000000);
INSERT INTO countries VALUES ('GBR','United Kingdom','Europe',67000000);
INSERT INTO countries VALUES ('IND','India','Asia',1380000000);
INSERT INTO countries VALUES ('AUS','Australia','Oceania',25000000);
COMMIT;
EOF"
```

---

## Test Execution

Run from the scripts directory:
```bash
cd /Users/arvindregukumar/Documents/Datapump
```

---

### 1. `datapump.sh` — Parfile Generator

**What it tests:** Interactive parfile generation for all 8 job types.

```bash
rm -rf DP_TEST001
printf 'DP_TEST001\nDATA_PUMP_DIR\n1\n2\nDPTEST\nreplace\n\n\n\n\n' | bash datapump.sh

# Verify all 3 parfiles exist and contain correct content
cat DP_TEST001/expdp_DP_TEST001.par
cat DP_TEST001/expdp_DP_TEST001_BKP.par
cat DP_TEST001/impdp_DP_TEST001.par
```

**Pass criteria:** 3 parfiles created inside `DP_TEST001/`, with correct `schemas=`, `directory=`, `dumpfile=`, `logfile=`, `parallel=`, `job_name=` entries.

---

### 2. `run_get_resource_limit.sh` — Resource Limits (Backend)

```bash
echo "DBsnmp123" | bash run_get_resource_limit.sh -c "localhost:1521/FREEPDB1" -p -
```

**Pass criteria:** Outputs three sections: `Resource Limits`, `Top 5 Users by Session Count`, `Top 5 Users by Process Count`. No ORA- errors. `SP2-0042` warning is acceptable (known minor artifact).

---

### 3. `get_resource_limit.sh` — Resource Limits (Frontend)

**Requires:** `/export/home/oracle/bin/get_pw.sh` — only testable on the production server.

```bash
# On production server:
bash get_resource_limit.sh <DB_NAME>
```

**Pass criteria:** Resource limits table displayed, high-utilization detection triggers drill-down prompt for instances ≥ 85%.

---

### 4. `run_get_resource_drilldown.sh` — Drill-Down (Backend)

```bash
echo "DBsnmp123" | bash run_get_resource_drilldown.sh -c "localhost:1521/FREEPDB1" -i 1 -p -
```

**Pass criteria:** Seven sections output (sessions, wait events, top programs, long-running sessions, open transactions, blocking sessions, blocked sessions). No ORA- errors.

---

### 5. `run_get_db_host.sh` — Instance & Machine (Backend)

```bash
echo "DBsnmp123" | bash run_get_db_host.sh -c "localhost:1521/FREEPDB1" -p -
```

**Pass criteria:** `INSTANCE:` block shows instance name. `MACHINES_BACKGROUND:` block shows at least one hostname.

---

### 6. `get_host.sh` — Instance & Machine (Frontend)

**Requires:** Production server. Test on server:
```bash
bash get_host.sh <DB_NAME>
```

---

### 7. `run_get_db_size.sh` — Database Size (Backend)

```bash
echo "DBsnmp123" | bash run_get_db_size.sh -c "localhost:1521/FREEPDB1" -p -
```

**Pass criteria:** Output shows DATA, TEMP, and TOTAL sizes in GB and TB. *(Note: script is currently incomplete — SQL section missing. Fix before retesting.)*

---

### 8. `run_get_datapump_logfile.sh` — Log Path Resolver (Backend)

```bash
echo "DBsnmp123" | bash run_get_datapump_logfile.sh "//localhost:1521/FREEPDB1" "DP_TEST001/expdp_DP_TEST001.par"
```

**Pass criteria:** Outputs `FULL_LOG_PATH` with the full OS path to the log file.

---

### 9. `expdp` — Source Export

Run inside the container (expdp is not installed locally):

```bash
FREE_DPDUMP="/opt/oracle/admin/FREE/dpdump/423AC35F110D08DAE0630800580A5061"
docker cp DP_TEST001/expdp_DP_TEST001.par oracle-free:${FREE_DPDUMP}/expdp_DP_TEST001.par
docker exec oracle-free bash -c \
  "expdp system/SentinelDBA1@localhost/FREEPDB1 parfile=${FREE_DPDUMP}/expdp_DP_TEST001.par"

# Check log
docker exec oracle-free bash -c "cat ${FREE_DPDUMP}/expdp_DP_TEST001.log"
```

**Pass criteria:** Log ends with `Job "SYSTEM"."EXPDP_DP_TEST001" successfully completed`. Dumpfile(s) written to the dpdump directory.

> **Known issue:** Oracle 23c Free ARM64 consistently fails with `ORA-39029`. If this still occurs after fixes, the issue is a container platform limitation, not a script bug.

---

### 10. `run_datapump_longops.sh` — Job Progress Monitor (Backend)

Run *while* an expdp/impdp job is active:

```bash
# In one terminal: start expdp (see step 9)
# In another terminal:
echo "DBsnmp123" | bash run_datapump_longops.sh -m DP_TEST001 -c "localhost:1521/FREEPDB1" -p -
```

**Pass criteria:** Output shows rows with `OPNAME`, `DONE_PCT`, `TIME_REMAINING_SEC`. No active job returns empty result (also acceptable).

---

### 11. `get_dumpfiles.sh` — Dumpfile Path Extractor

Requires a successful expdp log (from step 9):

```bash
# Copy log from container
FREE_DPDUMP="/opt/oracle/admin/FREE/dpdump/423AC35F110D08DAE0630800580A5061"
docker cp oracle-free:${FREE_DPDUMP}/expdp_DP_TEST001.log /tmp/expdp_DP_TEST001.log

bash get_dumpfiles.sh /tmp/expdp_DP_TEST001.log
```

**Pass criteria:** Prints full paths to `.dmp` files. Exit code 0.

---

### 12. `list_dumpfiles.sh` — Dumpfile Size Listing

```bash
bash list_dumpfiles.sh /tmp/expdp_DP_TEST001.log
```

**Pass criteria:** `ls -loch` output for each dumpfile showing size and timestamps.

---

### 13. `impdp` — Target Import

After a successful export, copy dumpfiles to target and import:

```bash
FREE_DPDUMP="/opt/oracle/admin/FREE/dpdump/423AC35F110D08DAE0630800580A5061"

# Copy dumpfile to target container (or same container with remap_schema)
docker exec oracle-free bash -c \
  "impdp system/SentinelDBA1@localhost/FREEPDB1 \
   directory=DATA_PUMP_DIR dumpfile=expdp_DP_TEST001_%U.dmp \
   logfile=impdp_DP_TEST001.log job_name=impdp_DP_TEST001 \
   remap_schema=DPTEST:DPTEST2 table_exists_action=replace parallel=1"

# Verify rows imported
docker exec oracle-free bash -c "sqlplus -s 'system/SentinelDBA1@localhost/FREEPDB1' <<'EOF'
SELECT count(*) FROM dptest2.countries;
exit
EOF"
```

**Pass criteria:** Import log ends with `successfully completed`. `SELECT count(*)` returns 4 (or 8 if all rows were exported).

---

### 14. `remove_dumpfiles_15d.sh` — Cleanup (Dry Run)

Requires a successful expdp log:

```bash
DRY_RUN=1 bash remove_dumpfiles_15d.sh /tmp/expdp_DP_TEST001.log
```

**Pass criteria:** Prints `Would remove (older than 15d): ...` for files older than 15 days. Prints `Skipping (newer than 15d): ...` for recent files. No files deleted.

---

### 15. `schedule_cleanup_cron_16d.sh` — Cron Entry Generator

```bash
printf '/nfs/xs/expdp/EXP-to-STG/expdp_DP_TEST001.log\n14:00\n' | bash schedule_cleanup_cron_16d.sh
```

**Pass criteria:** Prints a crontab line with correct date 16 days from now, correct minute/hour, and self-removing `grep -v | crontab -` suffix. Does NOT modify crontab.

---

### 16. `run_get_pq_diag.sh` — PQ Diagnostics (Backend)

```bash
echo "DBsnmp123" | bash run_get_pq_diag.sh -m "localhost:1521/FREEPDB1" -p -
```

**Pass criteria:** Seven sections output (process headroom, PQ parameters, slave usage, active QCs, slave wait events, non-PQ consumers, stale sessions). *(Note: script is currently non-functional due to missing `HELP` delimiter — fix before retesting.)*

---

### 17. `get_pq_diag.sh` — PQ Diagnostics (Frontend)

**Requires:** Production server.
```bash
bash get_pq_diag.sh <DB_NAME>
bash get_pq_diag.sh <DB_NAME> 3,4    # scoped to instances 3 and 4
```

---

### 18. `list_pdbs.sh` — PDB Discovery

Deploy and run on a real Oracle Linux server:
```bash
scp list_pdbs.sh oracle@<server>:/tmp/
ssh oracle@<server> "chmod +x /tmp/list_pdbs.sh && /tmp/list_pdbs.sh"
```

**Pass criteria:** Lists all CDBs found via `pmon` processes and their PDBs with `SHOW PDBS` output.

---

### 19. `fetch_pdbs_dynamic.sh` — Remote PDB Discovery

**Requires:** SSH access to remote Oracle server.
```bash
bash fetch_pdbs_dynamic.sh <oracle_server_hostname>
```

**Pass criteria:** `list_pdbs.sh` output printed for each CDB on the target host.

---

### 20. `datapump_workflow.sh` — End-to-End Orchestrator

Requires both DBs healthy and all upstream scripts working.

```bash
bash datapump_workflow.sh
# Follow prompts: enter ticket, source DB, target DB, username
```

**Pass criteria:** Steps 1-6 complete without errors. `dp_log_entry` writes to `rj_dba.datapump_log`.

---

## Quick Re-run Checklist

After editing a script, re-run only the tests relevant to that script:

| Script edited | Tests to re-run |
|--------------|----------------|
| `datapump.sh` | Test 1 |
| `run_get_resource_limit.sh` | Test 2 |
| `get_resource_limit.sh` | Test 3 |
| `run_get_resource_drilldown.sh` | Test 4 |
| `run_get_db_host.sh` | Test 5 |
| `run_get_db_size.sh` | Test 7 |
| `run_get_datapump_logfile.sh` | Test 8 |
| `get_dumpfiles.sh` | Test 11 (requires step 9 first) |
| `list_dumpfiles.sh` | Test 12 (requires step 9 first) |
| `remove_dumpfiles_15d.sh` | Test 14 (requires step 9 first) |
| `schedule_cleanup_cron_16d.sh` | Test 15 |
| `run_datapump_longops.sh` | Test 10 (requires active expdp) |
| `run_get_pq_diag.sh` | Test 16 |
| `datapump_workflow.sh` | Test 20 |

---

## Known Environment Constraints

| Constraint | Workaround |
|-----------|-----------|
| `get_pw.sh` missing locally | Test `run_*.sh` backends directly using `echo "password" \| bash run_*.sh ... -p -` |
| `expdp`/`impdp` not installed locally | Use `docker exec oracle-free bash -c "expdp ..."` |
| Oracle 23c Free ARM64 ORA-39029 worker crash | No workaround yet — platform bug. May resolve with a newer container image. |
| Oracle 21c slim — no Data Pump | Use `gvenzl/oracle-xe:21` (non-slim) for full Data Pump support |
| macOS `date -d` failure | Scripts with GNU date only work correctly on Linux server |
| macOS BSD awk | `get_dumpfiles.sh` awk regex needs fix for portability |
| All scripts lack execute bit | Run as `bash script.sh` locally; apply `chmod +x *.sh` on server |
