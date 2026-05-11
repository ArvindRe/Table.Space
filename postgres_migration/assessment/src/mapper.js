'use strict';

const { query } = require('./connector');

// Oracle → PostgreSQL type mapping
// risk: 'auto' = tools handle it cleanly, 'review' = check precision/semantics, 'manual' = no direct equivalent
const TYPE_MAP = {
  NUMBER:           { postgres: 'NUMERIC / INTEGER / BIGINT',  risk: 'review',  notes: 'Inspect precision/scale: NUMBER(p,0) → INTEGER, NUMBER(p,s) → NUMERIC(p,s), bare NUMBER → NUMERIC' },
  VARCHAR2:         { postgres: 'VARCHAR(n)',                  risk: 'auto',    notes: 'Direct mapping; byte vs char semantics differ — verify NLS_LENGTH_SEMANTICS' },
  NVARCHAR2:        { postgres: 'VARCHAR(n)',                  risk: 'auto',    notes: 'Unicode implicit in PG; no separate N-type needed' },
  CHAR:             { postgres: 'CHAR(n)',                     risk: 'auto',    notes: 'Direct mapping' },
  NCHAR:            { postgres: 'CHAR(n)',                     risk: 'auto',    notes: 'Unicode implicit in PG' },
  DATE:             { postgres: 'TIMESTAMP(0)',                risk: 'review',  notes: 'Oracle DATE includes time component; PG DATE is date-only — use TIMESTAMP(0)' },
  TIMESTAMP:        { postgres: 'TIMESTAMP',                   risk: 'auto',    notes: 'Direct mapping' },
  'TIMESTAMP WITH TIME ZONE':       { postgres: 'TIMESTAMPTZ',              risk: 'auto',    notes: 'Direct mapping' },
  'TIMESTAMP WITH LOCAL TIME ZONE': { postgres: 'TIMESTAMPTZ',              risk: 'review',  notes: 'PG stores in UTC; Oracle stores in DB timezone — verify offset handling' },
  'INTERVAL YEAR TO MONTH':         { postgres: 'INTERVAL',                 risk: 'review',  notes: 'PG INTERVAL is more general; validate year/month arithmetic' },
  'INTERVAL DAY TO SECOND':         { postgres: 'INTERVAL',                 risk: 'review',  notes: 'Direct mapping for most uses' },
  CLOB:             { postgres: 'TEXT',                        risk: 'review',  notes: 'PG TEXT is unlimited; streaming semantics differ from LOB locators' },
  NCLOB:            { postgres: 'TEXT',                        risk: 'review',  notes: 'Unicode implicit in PG TEXT' },
  BLOB:             { postgres: 'BYTEA',                       risk: 'review',  notes: 'PG BYTEA loads fully into memory; consider large object (lo) for multi-GB BLOBs' },
  RAW:              { postgres: 'BYTEA',                       risk: 'auto',    notes: 'Direct mapping' },
  'LONG RAW':       { postgres: 'BYTEA',                       risk: 'manual',  notes: 'LONG RAW is deprecated in Oracle; migrate data carefully' },
  LONG:             { postgres: 'TEXT',                        risk: 'manual',  notes: 'LONG is deprecated in Oracle; migrate to TEXT' },
  XMLTYPE:          { postgres: 'XML or TEXT',                 risk: 'manual',  notes: 'PG XML type available; XMLTYPE methods require rewrite; consider JSONB for document workloads' },
  BINARY_FLOAT:     { postgres: 'FLOAT4',                      risk: 'auto',    notes: 'Direct mapping' },
  BINARY_DOUBLE:    { postgres: 'FLOAT8',                      risk: 'auto',    notes: 'Direct mapping' },
  FLOAT:            { postgres: 'FLOAT8',                      risk: 'review',  notes: 'Oracle FLOAT(p) uses binary precision; map to FLOAT8 or NUMERIC depending on use' },
  ROWID:            { postgres: 'TEXT',                        risk: 'manual',  notes: 'ROWID used as stable row pointer in Oracle; no equivalent in PG — redesign queries' },
  UROWID:           { postgres: 'TEXT',                        risk: 'manual',  notes: 'As per ROWID' },
};

async function buildTypeMatrix(connection, schema) {
  const rows = await query(connection, `
    SELECT data_type, COUNT(*) AS cnt
    FROM   dba_tab_columns
    WHERE  owner = UPPER(:1)
    GROUP BY data_type
    ORDER BY cnt DESC
  `, [schema]);

  const matrix = [];
  for (const row of rows) {
    const oraType  = row.DATA_TYPE;
    const mapping  = TYPE_MAP[oraType] || { postgres: '— no direct mapping', risk: 'manual', notes: 'Requires manual review' };
    matrix.push({
      oracleType:   oraType,
      columnCount:  Number(row.CNT),
      postgresType: mapping.postgres,
      risk:         mapping.risk,
      notes:        mapping.notes,
    });
  }
  return matrix;
}

module.exports = { buildTypeMatrix, TYPE_MAP };
