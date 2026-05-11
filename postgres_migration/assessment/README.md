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

## Sample Output

```
╔══════════════════════════════════════════════════════════════════╗
║           ORA-Migrate-Assess v1.0 — Assessment Report           ║
║           Source: Oracle 19c | Schema: FINANCE_PROD             ║
╚══════════════════════════════════════════════════════════════════╝

SCHEMA INVENTORY
─────────────────────────────────────────
  Tables              : 847
  Views               : 203
  Stored Procedures   : 412
  Functions           : 89
  Triggers            : 156
  Packages            : 67
  Sequences           : 134
  Synonyms            : 298
  Total Objects       : 2,206

COMPLEXITY SCORE: HIGH (73/100)
  → PL/SQL package usage is the primary complexity driver
  → 34 packages contain Oracle-specific DBMS_* calls
  → 12 procedures use autonomous transactions
  → 8 triggers use :NEW/:OLD with complex conditional logic

TOOL COMPARISON
─────────────────────────────────────────────────────────────────────
Object Type      │ Ora2Pg  │ AWS SCT │ AWS DMS │ EDB Portal
─────────────────┼─────────┼─────────┼─────────┼────────────
Tables           │ ✅ 98%  │ ✅ 97%  │ ✅ 96%  │ ✅ 99%
Indexes          │ ✅ 91%  │ ✅ 89%  │ ⚠️ 72%  │ ✅ 93%
Views            │ ✅ 87%  │ ✅ 84%  │ ❌ 41%  │ ✅ 88%
Stored Procs     │ ⚠️ 71%  │ ⚠️ 68%  │ ❌ 12%  │ ⚠️ 74%
Functions        │ ⚠️ 73%  │ ⚠️ 69%  │ ❌ 15%  │ ⚠️ 76%
Triggers         │ ⚠️ 64%  │ ⚠️ 61%  │ ❌ 8%   │ ⚠️ 67%
Packages         │ ⚠️ 52%  │ ⚠️ 49%  │ ❌ 0%   │ ⚠️ 58%
Sequences        │ ✅ 95%  │ ✅ 94%  │ ✅ 90%  │ ✅ 97%

ZERO-DOWNTIME STRATEGY RECOMMENDATION
─────────────────────────────────────────
  Recommended : GoldenGate CDC + Ora2Pg schema migration
  Alternative : AWS DMS full-load + CDC (if targeting AWS RDS)
  Rationale   : Package complexity requires manual conversion;
                CDC replication ensures zero data loss during
                the extended conversion and testing window.

TOOL RECOMMENDATION: Ora2Pg + EDB Migration Portal
  → Ora2Pg for bulk schema/data migration
  → EDB Portal for PL/SQL package conversion assistance
  → AWS DMS for live CDC replication during cutover

ESTIMATED EFFORT
─────────────────────────────────────────
  Automated conversion  : 6-8 weeks
  Manual PL/SQL rework  : 10-14 weeks
  Testing & validation  : 4-6 weeks
  Total estimate        : 20-28 weeks

Full report saved to: ./reports/FINANCE_PROD_assessment_2026-05-11.json
```

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
