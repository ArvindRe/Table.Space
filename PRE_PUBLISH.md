# Pre-Publish Checklist

Items that must be sanitized before pushing this repository to any public or external git host.

---

## Hardcoded Values to Remove or Replace

### `orce01ldb1pd`
- **What it is:** Internal Oracle database server hostname.
- **Where it appears:** `CLAUDE.md`, script comments, and any documentation referencing the deployment location (`/export/home/oracle/arvind/` on `orce01ldb1pd`).
- **Action:** Replace with a generic placeholder such as `<DB_SERVER_HOSTNAME>` in all docs and comments. Remove from `CLAUDE.md` before making it public.

### `rj_dba`
- **What it is:** Internal Oracle schema/user that owns the audit table (`rj_dba.datapump_log`) and the sequence (`"RJ_DBA"."SEQ_FIL_760773"`).
- **Where it appears:** `datapump_workflow.sh` — DDL block that creates `rj_dba.datapump_log`, the `INSERT` statement, and the `all_tables` ownership check.
- **Action:** Replace with a configurable variable (e.g., `AUDIT_SCHEMA`) or a documented placeholder such as `<DBA_SCHEMA>`. The sequence name `SEQ_FIL_760773` should also be replaced with a generic name or made configurable.

---

## Other Sensitive Items to Review

| Item | Location | Action |
|------|----------|--------|
| ZFS Basic Auth header | `ZFS_sync.sh`, `ZFS_SYNC_status.sh` | Remove or replace with an env-var reference |
| `/export/home/oracle/arvind/` | Multiple scripts | Replace with a configurable `BASE_DIR` variable |
| `get_pw.sh` call in `datapump_longops.sh` | `datapump_longops.sh:7` | Remove or document as site-specific; do not publish `get_pw.sh` itself |
| `cx6dapspd` TNS alias | `datapump_longops.sh:7` | Replace with `<TNS_ALIAS>` placeholder |

---

## Suggested Approach

1. Do a global search for internal hostnames, schema names, and paths before any push:
   ```
   grep -rn "orce01ldb1pd\|rj_dba\|SEQ_FIL_760773\|cx6dapspd\|/export/home/oracle/arvind" .
   ```
2. Replace hardcoded values with environment variables or clearly marked placeholders.
3. Add `get_pw.sh` to `.gitignore` if it contains credentials.
4. Review `CLAUDE.md` — it contains deployment details that should be sanitized for public audiences.

---

## Git Publishing Plan

### Phase 1 — Sanitize (do before any remote is added)

- [ ] Run the grep above and resolve every hit
- [ ] Replace `rj_dba` / `SEQ_FIL_760773` in `datapump_workflow.sh` with an `AUDIT_SCHEMA` variable and a generic sequence name; document as "site-specific, create before use"
- [ ] Replace `orce01ldb1pd` and `/export/home/oracle/arvind/` in all scripts and docs with `<DB_SERVER_HOSTNAME>` and `<BASE_DIR>`
- [ ] Replace ZFS Basic Auth header in `ZFS_sync.sh` / `ZFS_SYNC_status.sh` with an environment variable (`ZFS_AUTH_TOKEN`)
- [ ] Replace `cx6dapspd` TNS alias in `datapump_longops.sh` with `<TNS_ALIAS>`
- [ ] Remove or redact `CLAUDE.md` deployment details (server name, NFS paths, user home)

### Phase 2 — Repo hygiene

- [ ] Create `.gitignore`:
  ```
  get_pw.sh
  *.log
  crontab_backup_*.txt
  compiled/
  ```
- [ ] Add a `LICENSE` file (MIT or Apache 2.0 recommended for DBA tooling)
- [ ] Add author headers to any scripts missing them (`# Author: Arvind Regukumar`)
- [ ] Rename or archive internal-only docs (`TEST_REPORT.md`, `FIXES.md`) or move them to a `docs/internal/` folder that is `.gitignore`d

### Phase 3 — Repository setup (GitHub)

- [ ] Create a new **private** repository first — confirm sanitization is complete before flipping to public
- [ ] Initialize with no README (you already have `Datapump_Scripts_Guide.md` to promote)
- [ ] Add remote and push:
  ```bash
  git remote add origin git@github.com:<your-username>/datapump-scripts.git
  git push -u origin main
  ```
- [ ] Enable **branch protection** on `main` (require PR, no force-push)
- [ ] Add a repository description and topics on GitHub: `oracle`, `datapump`, `dba`, `bash`, `expdp`, `impdp`

### Phase 4 — Authorship & provenance

- [ ] Enable **signed commits** going forward:
  ```bash
  git config --global commit.gpgsign true
  ```
- [ ] Verify commit author is set correctly:
  ```bash
  git config user.name   # should be your name
  git config user.email  # should be your email
  ```
- [ ] The existing commit `ed20ce7` with author `ArvindRe` is your timestamp anchor — do not rewrite history before pushing

### Phase 5 — Go public (optional, when ready)

- [ ] Final grep pass for any remaining internal strings
- [ ] Flip GitHub repo from private → public
- [ ] Pin the repo to your GitHub profile if you want it visible as portfolio work
