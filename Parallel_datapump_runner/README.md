# Parallel Datapump Runner

Execute multiple Oracle Data Pump parfiles concurrently using a fixed-size worker pool.
As soon as one job completes, the next parfile in the queue is picked up — keeping all slots busy.

---

## Scripts

| Script | Purpose |
|--------|---------|
| `run_exports_parallel.sh` | Run `expdp` for a set of export parfiles |
| `run_imports_parallel.sh` | Run `impdp` for a set of import parfiles |
| `dp_parallel_lib.sh` | Shared library (sourced automatically — do not run directly) |

---

## Usage

```bash
# Export — 12 parfiles, 3 concurrent sessions (default)
./run_exports_parallel.sh -u SYSTEM -d PRODDB /ticket/parfiles/expdp_*.par

# Import — 8 parfiles, 4 concurrent sessions, output logs to /tmp/logs
./run_imports_parallel.sh -u SYSTEM -d PRODDB -j 4 -o /tmp/logs /ticket/parfiles/impdp_*.par

# Dry-run — see what would be executed without running anything
./run_exports_parallel.sh -u SYSTEM -d PRODDB -n /ticket/parfiles/expdp_*.par
```

---

## Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `-u <user>` | Yes | — | Oracle database username |
| `-d <tns>` | Yes | — | TNS alias or connect string |
| `-j <N>` | No | `3` | Maximum concurrent Data Pump sessions |
| `-n` | No | off | Dry-run mode (print commands, do not execute) |
| `-o <dir>` | No | `.` | Directory for per-job output log files |
| `-h` | No | — | Show help |

Positional arguments after the flags are the parfile paths. Globs are supported.

---

## Behavior

1. **Password prompt** — Asked once at start; reused for all jobs. Never written to disk.
2. **Worker pool** — Up to `-j` jobs run simultaneously. When one finishes, the next queued parfile launches immediately.
3. **Failure handling** — A failed job is logged but does **not** block remaining jobs. The script exits with code `1` if any job failed, `0` if all succeeded.
4. **Per-job output** — Each job's stdout/stderr is captured in `<output_dir>/<parfile_basename>.out`.
5. **Signal handling** — On `SIGINT`/`SIGTERM` (Ctrl-C), all running children are killed and the password variable is cleared.
6. **Summary table** — Printed at the end showing parfile, exit code, start time, end time, and elapsed duration.

---

## Requirements

- **bash 4.3+** (for `wait -n` and associative arrays; falls back to polling on older bash)
- `expdp` / `impdp` on `$PATH` (Oracle client or server install)
- Parfiles must already exist and contain valid Data Pump parameters

---

## Example Output

```
===========================================================
 Parallel expdp Runner
 User: SYSTEM@PRODDB | Concurrency: 3 | Parfiles: 6
===========================================================

[14:02:01] LAUNCH  [1/6] expdp_TICKET_01.par
[14:02:01] LAUNCH  [2/6] expdp_TICKET_02.par
[14:02:01] LAUNCH  [3/6] expdp_TICKET_03.par
[14:05:23] DONE         expdp_TICKET_01.par — exit code 0 (success)
[14:05:23] LAUNCH  [4/6] expdp_TICKET_04.par
[14:06:10] DONE         expdp_TICKET_02.par — exit code 0 (success)
[14:06:10] LAUNCH  [5/6] expdp_TICKET_05.par
[14:07:45] FAILED       expdp_TICKET_03.par — exit code 5
[14:07:45] LAUNCH  [6/6] expdp_TICKET_06.par
[14:09:00] DONE         expdp_TICKET_04.par — exit code 0 (success)
[14:10:30] DONE         expdp_TICKET_05.par — exit code 0 (success)
[14:11:15] DONE         expdp_TICKET_06.par — exit code 0 (success)

 SUMMARY
===========================================================
PARFILE                                  RC    START                END                  ELAPSED
--------                                 --    ------               ---                  -------
expdp_TICKET_01.par                      0     2026-05-07 14:02:01  2026-05-07 14:05:23  00:03:22
expdp_TICKET_02.par                      0     2026-05-07 14:02:01  2026-05-07 14:06:10  00:04:09
expdp_TICKET_03.par                      5     2026-05-07 14:02:01  2026-05-07 14:07:45  00:05:44
expdp_TICKET_04.par                      0     2026-05-07 14:05:23  2026-05-07 14:09:00  00:03:37
expdp_TICKET_05.par                      0     2026-05-07 14:06:10  2026-05-07 14:10:30  00:04:20
expdp_TICKET_06.par                      0     2026-05-07 14:07:45  2026-05-07 14:11:15  00:03:30

Total: 6 | Succeeded: 5 | Failed: 1
Per-job output logs are in: ./
===========================================================
```

---

## Security Notes

- The password is stored only in a bash variable and cleared on exit/signal via trap.
- Credentials appear briefly in the process table (`expdp user/pass@tns ...`). This matches the standard invocation pattern used across the Datapump scripts. For higher security, consider using an Oracle Wallet or external password store.
