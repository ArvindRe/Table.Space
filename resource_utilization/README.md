# Resource Utilization Scripts

Scripts for monitoring PGA memory and TEMP tablespace utilisation across Oracle RAC instances. Each area follows the same pattern: a frontend wrapper queries live and historical data, flags instances that exceed an 80% threshold, and offers an interactive drilldown to the top consumers on flagged instances.

---

## Scripts

| Script | Role |
|--------|------|
| `get_pga.sh` | Frontend — PGA utilisation check. Shows current `GV$PGASTAT` snapshot, N-day historical trend from AWR, and peak per instance. Flags instances where PGA allocation exceeds 80% of `pga_aggregate_target` and offers drilldown. |
| `run_get_pga.sh` | Backend SQL runner invoked by `get_pga.sh`. Queries `GV$PGASTAT`, `GV$PARAMETER`, and `DBA_HIST_PGASTAT`. Emits `PGACHK` sentinel lines for threshold detection. |
| `run_get_pga_drilldown.sh` | Backend SQL runner invoked by `get_pga.sh` on flagged instances. Shows top PGA consumers by session. |
| `get_temp_usage.sh` | Frontend — TEMP tablespace utilisation check. Shows current allocation vs capacity per tempfile, active sort/hash consumers, and N-day AWR peak. Flags instances where used TEMP exceeds 80% of total capacity and offers drilldown. |
| `run_get_temp_usage.sh` | Backend SQL runner invoked by `get_temp_usage.sh`. Queries `GV$TEMP_SPACE_HEADER`, `GV$TEMPSEG_USAGE`, and `DBA_HIST_SNAPSHOT`. Emits `TEMPCHK` sentinel lines for threshold detection. |
| `run_get_temp_drilldown.sh` | Backend SQL runner invoked by `get_temp_usage.sh` on flagged instances. Shows active TEMP consumers by session with SQL text. |

---

## Usage

```bash
# PGA check — last 7 days of history (default)
./get_pga.sh <DB_NAME>

# PGA check — last 14 days of history
./get_pga.sh <DB_NAME> --days 14

# TEMP check — last 7 days of history (default)
./get_temp_usage.sh <DB_NAME>

# TEMP check — last 14 days of history
./get_temp_usage.sh <DB_NAME> --days 14
```

The frontend scripts call `get_pw.sh` to retrieve the `dbsnmp` password. See the root [README](../README.md) for `get_pw.sh` configuration.

---

## Requirements

- `sqlplus` on `$PATH`
- `dbsnmp` user with `SELECT_CATALOG_ROLE` (covers `GV$PGASTAT`, `GV$PARAMETER`, `DBA_HIST_PGASTAT`, `GV$TEMP_SPACE_HEADER`, `GV$TEMPSEG_USAGE`)
- AWR historical queries require **Diagnostics Pack** licence
- `get_pw.sh` configured at `/export/home/oracle/bin/get_pw.sh`

---

## How It Works

Both scripts follow the same detection pattern:

1. Run the report SQL via the backend runner, display output live, and capture it to a temp file
2. Parse `PGACHK` / `TEMPCHK` sentinel lines emitted by the backend to identify flagged instances
3. If any instance exceeds the 80% threshold, prompt: **[I]nvestigate** or **[E]xit**
4. On `[I]nvestigate`, pass the flagged instance IDs to the drilldown runner

```
get_pga.sh  ──►  run_get_pga.sh        (live report + PGACHK sentinels)
                run_get_pga_drilldown.sh  (top PGA consumers, on demand)

get_temp_usage.sh  ──►  run_get_temp_usage.sh      (live report + TEMPCHK sentinels)
                        run_get_temp_drilldown.sh   (active TEMP consumers, on demand)
```

---

## Context

These scripts were developed to pre-flight resource headroom before and during large-scale Oracle Data Pump migration windows. Running a 300 TB export across 400 concurrent jobs against a 430 TB Exadata database puts significant pressure on PGA (parallel query workarea memory) and TEMP tablespace (sort and hash join operations). Monitoring these during the 72-hour window allowed the team to detect and respond to resource saturation before it caused job failures.

See the [Large-Scale Parallel Runs article](../Parallel_datapump_runner/Large_Scale_Parallel_Runs.md) for the full migration context.
