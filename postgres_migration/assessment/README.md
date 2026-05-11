# ORA-Migrate-Assess

> **CLI-based Oracle-to-PostgreSQL migration assessment tool**  
> Evaluate, compare, and plan your Oracle database migration to PostgreSQL-compatible targets using industry-leading conversion tools.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Oracle](https://img.shields.io/badge/Source-Oracle%2019c-red.svg)](https://www.oracle.com/database/)
[![PostgreSQL](https://img.shields.io/badge/Target-PostgreSQL%2FAlloyDB-336791.svg)](https://www.postgresql.org/)
[![Node.js](https://img.shields.io/badge/Runtime-Node.js-339933.svg)](https://nodejs.org/)

---

## The Problem

Migrating from Oracle to PostgreSQL is one of the most complex database transitions an enterprise can undertake. Schema incompatibilities, PL/SQL-to-PL/pgSQL conversion gaps, data type mismatches, and zero-downtime cutover requirements make it a high-risk programme.

Most teams pick a migration tool without a structured assessment — and discover the gaps mid-project.

**ORA-Migrate-Assess solves this.** It runs a structured, automated assessment of your Oracle schema against four leading migration tools and gives you a side-by-side comparison of conversion coverage, effort, and risk — before you commit to a migration approach.

---

## What It Does

ORA-Migrate-Assess connects to your Oracle source database, inspects the schema, and produces a comparative assessment across:

| Tool | Type | Best For |
|------|------|----------|
| **Ora2Pg** | Open source CLI | Schema + data migration, PL/SQL conversion |
| **AWS Schema Conversion Tool (SCT)** | AWS-managed GUI/CLI | AWS RDS/Aurora PostgreSQL targets |
| **AWS Database Migration Service (DMS)** | AWS-managed CDC | Live replication, zero-downtime cutover |
| **EDB Migration Portal** | EDB-managed SaaS | EnterpriseDB Postgres Advanced Server targets |

### Assessment outputs

- **Schema complexity score** per object type (tables, views, procedures, functions, triggers, packages, sequences)
- **PL/SQL conversion coverage** — which constructs each tool handles automatically vs manually
- **Data type mapping** — Oracle-to-PostgreSQL type compatibility matrix
- **Estimated conversion effort** — Low / Medium / High per object category
- **Zero-downtime strategy recommendation** — GoldenGate CDC vs AWS DMS vs logical replication
- **Tool recommendation** — ranked by fit for your specific schema profile
- **Migration readiness report** — exportable as JSON, CSV, or Markdown

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    ORA-Migrate-Assess CLI                │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ┌──────────────┐    ┌──────────────────────────────┐  │
│  │ Oracle       │    │     Assessment Engine         │  │
│  │ Connector    │───▶│                              │  │
│  │ (oracledb)   │    │  Schema Inspector             │  │
│  └──────────────┘    │  Object Classifier            │  │
│                      │  PL/SQL Analyser              │  │
│  ┌──────────────┐    │  Data Type Mapper             │  │
│  │ Config       │───▶│  Complexity Scorer            │  │
│  │ (YAML/JSON)  │    └──────────────┬───────────────┘  │
│  └──────────────┘                   │                   │
│                                     ▼                   │
│                    ┌────────────────────────────────┐   │
│                    │     Tool Comparison Engine      │   │
│                    │                                │   │
│                    │  Ora2Pg Evaluator              │   │
│                    │  AWS SCT Evaluator             │   │
│                    │  AWS DMS Evaluator             │   │
│                    │  EDB Portal Evaluator          │   │
│                    └──────────────┬─────────────────┘   │
│                                   │                     │
│                                   ▼                     │
│                    ┌────────────────────────────────┐   │
│                    │     Report Generator            │   │
│                    │  JSON │ CSV │ Markdown │ HTML   │   │
│                    └────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## Quick Start

### Prerequisites

- Node.js 18+
- Oracle Instant Client (for live schema inspection)
- Oracle DB user with `SELECT_CATALOG_ROLE` or equivalent
- (Optional) AWS CLI configured for SCT/DMS comparison data

### Install

```bash
git clone https://github.com/ArvindRe/Table.Space.git
cd Table.Space
npm install
```

### Configure

```yaml
# config.yaml
oracle:
  host: your-oracle-host
  port: 1521
  service: ORCLPDB1
  user: assessment_user
  password: ${ORACLE_PASSWORD}   # use env var, never hardcode

assessment:
  schemas:
    - SCHEMA_A
    - SCHEMA_B
  include_data_profiling: true
  output_formats:
    - markdown
    - json
    - csv

targets:
  - ora2pg
  - aws_sct
  - aws_dms
  - edb_portal
```

### Run

```bash
# Full assessment — all tools, all schemas
npm run assess -- --config config.yaml

# Quick schema inventory only
npm run assess -- --config config.yaml --mode inventory

# Compare specific tools only
npm run assess -- --config config.yaml --tools ora2pg,aws_sct

# Export to specific format
npm run assess -- --config config.yaml --output html
```

---

## Demo

The following output was produced by running the tool against a `MIGRATE_DEMO` schema loaded onto two local Docker instances — Oracle 23c Free (FREEPDB1, port 1521) and Oracle 21c XE (XEPDB1, port 1522). The schema contains 6 tables, 4 views, 3 procedures, 1 package, 2 triggers, and 8 sequences, with Oracle-specific constructs including `DBMS_OUTPUT`, an autonomous transaction pragma, `DECODE`, `BULK COLLECT`/`FORALL`, and complex `:NEW`/`:OLD` trigger logic.

### Console output

```
npm run assess -- --config config.yaml

╔══════════════════════════════════════════════════════════════════╗
║           ORA-Migrate-Assess v1.0 — Assessment Report           ║
╚══════════════════════════════════════════════════════════════════╝

Connecting to localhost:1521/FREEPDB1 ... connected

Schema: MIGRATE_DEMO
────────────────────────────────────────────────────
  Inspecting schema objects             ... ✓
  tables: 6 | views: 4 | procedures: 3 | functions: 0 | triggers: 2 | packages: 1 | sequences: 8
  Analysing PL/SQL source               ... ✓
  Mapping column data types             ... ✓

COMPLEXITY SCORE: LOW (3/100)
  → 1 packages — primary complexity driver
  → DBMS_* calls: DBMS_OUTPUT
  → 1 autonomous transaction pragma(s)
  → 1 trigger(s) with :NEW/:OLD conditional logic
  → DECODE (3 occurrence(s))

TOOL FITNESS SCORES:
  EDB Migration Portal                       ██████████████████ 89%
  Ora2Pg                                     █████████████████ 87%
  AWS Schema Conversion Tool (SCT)           █████████████████ 85%
  AWS Database Migration Service (DMS)       █████████████ 63%

RECOMMENDATION: EDB Migration Portal
CDC COMPLEMENT:  AWS Database Migration Service (DMS)
ESTIMATED EFFORT: 3–6 weeks

✓ Saved: reports/MIGRATE_DEMO_assessment_2026-05-11.md
```

### Full Markdown report

The tool saves a detailed report to `reports/`. Below is the full output for the demo run:

---

**Schema:** MIGRATE_DEMO  |  **Generated:** 2026-05-11 07:59:24

#### Schema Inventory
```
  Tables                  : 6
  Views                   : 4
  Procedures              : 3
  Functions               : 0
  Triggers                : 2
  Packages                : 1
  Sequences               : 8
  Synonyms                : 0
  ─────────────────────────────
  Total Objects           : 24
```

#### Complexity Score: LOW (3/100) 🟢
```
  → 1 packages — primary complexity driver
  → DBMS_* calls: DBMS_OUTPUT
  → 1 autonomous transaction pragma(s)
  → 1 trigger(s) with :NEW/:OLD conditional logic
  → DECODE (3 occurrence(s))
  → BULK COLLECT (1 occurrence(s))
  → FORALL (1 occurrence(s))
  → TYPE ... TABLE OF (collection) (2 occurrence(s))
  → EXCEPTION (Oracle-specific) (2 occurrence(s))
```

#### Oracle-Specific Constructs Detected
```
  - DECODE (3 occurrence(s))
  - BULK COLLECT (1 occurrence(s))
  - FORALL (1 occurrence(s))
  - TYPE ... TABLE OF (collection) (2 occurrence(s))
  - EXCEPTION (Oracle-specific) (2 occurrence(s))
```

#### Tool Comparison

```
Object Type         Ora2Pg        AWS SCT       AWS DMS       EDB Portal
────────────────────────────────────────────────────────────────────────
Tables              ✅ 98%        ✅ 97%        ✅ 96%        ✅ 99%
Views               ⚠️  87%       ⚠️  84%       ❌ 41%        ⚠️  88%
Procedures          ⚠️  71%       ⚠️  68%       ❌ 12%        ⚠️  74%
Triggers            ⚠️  64%       ⚠️  61%       ❌  8%        ⚠️  67%
Packages            ❌ 52%        ❌ 49%        ❌  0%        ❌ 58%
Sequences           ✅ 95%        ✅ 94%        ✅ 90%        ✅ 97%

Weighted Fitness Score (by schema composition):
  EDB Migration Portal                      : 89%
  Ora2Pg                                    : 87%
  AWS Schema Conversion Tool (SCT)          : 85%
  AWS Database Migration Service (DMS)      : 63%
```

#### Data Type Mapping

| Oracle Type | Columns | PostgreSQL Type | Risk | Notes |
|---|---|---|---|---|
| NUMBER | 28 | NUMERIC / INTEGER / BIGINT | 🟡 review | Inspect precision/scale: NUMBER(p,0) → INTEGER, NUMBER(p,s) → NUMERIC(p,s), bare NUMBER → NUMERIC |
| VARCHAR2 | 17 | VARCHAR(n) | 🟢 auto | Direct mapping; verify NLS_LENGTH_SEMANTICS |
| DATE | 4 | TIMESTAMP(0) | 🟡 review | Oracle DATE includes time component; PG DATE is date-only |
| CLOB | 3 | TEXT | 🟡 review | PG TEXT is unlimited; streaming semantics differ from LOB locators |
| TIMESTAMP(6) | 2 | — no direct mapping | 🔴 manual | Requires manual review |
| CHAR | 2 | CHAR(n) | 🟢 auto | Direct mapping |
| RAW | 1 | BYTEA | 🟢 auto | Direct mapping |

#### Estimated Migration Effort
```
  Automated schema/data conversion : 1–2 weeks
  Manual PL/SQL rework             : 1–3 weeks
  Testing & validation             : 1–1 weeks
  ──────────────────────────────────────────────
  Total estimate                   : 3–6 weeks
```

#### Recommendation
```
  Primary tool          : EDB Migration Portal (89% weighted fit)
  CDC complement        : AWS Database Migration Service (DMS)
  Zero-downtime strategy: AWS DMS full-load + CDC, paired with EDB Migration
                          Portal for schema/code migration

  Rationale:
    - EDB Migration Portal scores highest (89%) weighted by schema composition
    - AWS DMS recommended for live CDC replication during the cutover window
```

---

---

## Why This Tool Exists

I manage 300+ Oracle databases on Exadata X10M at enterprise scale (largest: 430TB). Oracle-to-PostgreSQL migration requests from customers are increasing rapidly — driven by licensing cost, cloud-native mandates, and the rise of AlloyDB and Cloud SQL.

Every migration assessment I ran manually took days. Schema complexity varied wildly. Tool recommendations changed based on PL/SQL package depth, trigger complexity, and target platform. I built ORA-Migrate-Assess to turn a multi-day manual process into a 20-minute automated report.

The tool reflects real production migration experience — not theoretical knowledge.

---

## Roadmap

- [ ] Google Cloud AlloyDB as explicit target
- [ ] Cloud SQL for PostgreSQL comparison
- [ ] Spanner migration path assessment
- [ ] HTML report with interactive charts
- [ ] GitHub Actions CI for automated schema drift detection
- [ ] LLM-powered PL/SQL conversion complexity analyser (Gemini API)
- [ ] Docker image for zero-install runs

---

## Related Project

**[Table.Space / Sentinel DBA](https://github.com/ArvindRe/sentinel-dba)** — Real-time Oracle database monitoring dashboard (Node.js + React). Aggregates AWR metrics, active session data, and alert log events into a unified observability interface.

---

## Author

**Arvind Regukumar**  
Senior Oracle DBA | OCP 19c | 15+ Years Enterprise Database Architecture  
[LinkedIn](https://linkedin.com/in/arvind-regukumar) · [GitHub](https://github.com/ArvindRe)

> *"I manage what your customers are trying to migrate away from — and I built tooling to help them do it right."*

---

## License

MIT — see [LICENSE](LICENSE) for details.
