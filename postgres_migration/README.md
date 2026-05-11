---
name: PostgreSQL Migration
description: Approaches and tooling for migrating to PostgreSQL
type: project
---

# PostgreSQL Migration

This section captures approaches for migrating database workloads to PostgreSQL — from Oracle, SQL Server, or other relational engines.

PostgreSQL migrations require careful handling of proprietary features (Oracle packages, hierarchical queries, sequences, partitioning syntax) and involve decisions around tooling choice, extension usage, and performance validation on the new engine.

Content will cover:

- **Schema migration** — translating Oracle DDL to PostgreSQL: data types, sequences, constraints, partitioning, and index strategies
- **Code migration** — converting PL/SQL packages, procedures, and functions to PL/pgSQL; replacing Oracle-specific SQL constructs
- **Data movement** — bulk load strategies using `COPY`, `pg_dump`/`pg_restore`, foreign data wrappers, and CDC-based approaches
- **Feature mapping** — Oracle to PostgreSQL equivalents: `CONNECT BY` → recursive CTEs, `ROWNUM` → `ROW_NUMBER()`, `MERGE`, `UPSERT`, hints
- **Extension landscape** — `pg_partman`, `timescaledb`, `pglogical`, `pgaudit`, and others that fill Oracle feature gaps
- **Performance tuning** — `autovacuum`, `work_mem`, parallel query, and query plan analysis with `EXPLAIN (ANALYZE, BUFFERS)`
- **Validation** — row count reconciliation, data type fidelity checks, and regression testing

---

*Scripts and documentation will be added as approaches are developed and tested in production.*
