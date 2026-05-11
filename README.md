A space for capturing database migration approaches — the complexity encountered in real-world large-scale data movements, and the solutions built to address them. Covers Oracle-to-Oracle migrations, cross-platform transitions, and PostgreSQL migrations. Documents operational scripts alongside the architectural decisions, constraints, trade-offs, and lessons that shaped each approach.

---

## Further Reading

| Document | Description |
|----------|-------------|
| [Scripts Usage Guide](datapump/Datapump_Scripts_Guide.md) | End-to-end workflow, parfile generation, export/import best practices, log archiving, and dumpfile cleanup |
| [Advanced Use Cases](datapump/Advanced_Use_Cases.md) | LOB/CLOB export-import, full metadata exports, SQL Plan Baseline migration, DDL extraction to SQL file, QA/DEV object sync |
| [Large-Scale Parallel Runs — Architecture & Article](Parallel_datapump_runner/Large_Scale_Parallel_Runs.md) | Deep-dive on running 400 export jobs over 72 hours against 400 TB+ Exadata databases — architecture, LOB handling, constraints, and recommendations |
| [Parallel Runner — Usage](Parallel_datapump_runner/README.md) | How to use `run_exports_parallel.sh` and `run_imports_parallel.sh` |
| [Parallel Runner — Learnings](Parallel_datapump_runner/learnings.md) | Operational lessons: single-quote escaping, LOB identification SQL, ROWID-split parfile patterns, SecureFile import transforms |
| [Resource Utilisation — PGA & TEMP](resource_utilization/README.md) | Scripts for monitoring PGA memory and TEMP tablespace under parallel export load — live snapshot, AWR trend, 80% threshold detection |
| [PostgreSQL Migration](postgres_migration/README.md) | Approaches and tooling for migrating to PostgreSQL |
