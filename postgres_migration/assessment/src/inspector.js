'use strict';

const { query } = require('./connector');

const OBJECT_TYPES = "'TABLE','VIEW','PROCEDURE','FUNCTION','TRIGGER','PACKAGE','SEQUENCE','SYNONYM'";

async function inspectSchema(connection, schema) {
  const countRows = await query(connection, `
    SELECT object_type, COUNT(*) AS cnt
    FROM   dba_objects
    WHERE  owner       = UPPER(:1)
      AND  object_type IN (${OBJECT_TYPES})
      AND  status      = 'VALID'
    GROUP BY object_type
  `, [schema]);

  const counts = {
    tables: 0, views: 0, procedures: 0, functions: 0,
    triggers: 0, packages: 0, sequences: 0, synonyms: 0,
  };

  const typeMap = {
    TABLE: 'tables', VIEW: 'views', PROCEDURE: 'procedures',
    FUNCTION: 'functions', TRIGGER: 'triggers', PACKAGE: 'packages',
    SEQUENCE: 'sequences', SYNONYM: 'synonyms',
  };

  for (const row of countRows) {
    const key = typeMap[row.OBJECT_TYPE];
    if (key) counts[key] = Number(row.CNT);
  }

  counts.total = Object.values(counts).reduce((a, b) => a + b, 0);

  // Index type breakdown
  const indexRows = await query(connection, `
    SELECT index_type, COUNT(*) AS cnt
    FROM   dba_indexes
    WHERE  table_owner = UPPER(:1)
    GROUP BY index_type
    ORDER BY cnt DESC
  `, [schema]);

  counts.indexTypes = indexRows.map(r => ({ type: r.INDEX_TYPE, count: Number(r.CNT) }));

  // Constraint counts
  const constraintRows = await query(connection, `
    SELECT constraint_type, COUNT(*) AS cnt
    FROM   dba_constraints
    WHERE  owner           = UPPER(:1)
      AND  constraint_type IN ('P','U','R','C')
    GROUP BY constraint_type
  `, [schema]);

  const ctMap = { P: 'primaryKeys', U: 'uniqueConstraints', R: 'foreignKeys', C: 'checkConstraints' };
  counts.constraints = { primaryKeys: 0, uniqueConstraints: 0, foreignKeys: 0, checkConstraints: 0 };
  for (const row of constraintRows) {
    const key = ctMap[row.CONSTRAINT_TYPE];
    if (key) counts.constraints[key] = Number(row.CNT);
  }

  return counts;
}

async function fetchPlsqlSource(connection, schema) {
  const rows = await query(connection, `
    SELECT type, name, text
    FROM   dba_source
    WHERE  owner = UPPER(:1)
      AND  type  IN ('PROCEDURE','FUNCTION','TRIGGER','PACKAGE','PACKAGE BODY')
    ORDER BY type, name, line
  `, [schema]);

  // Group into { type -> { name -> fullSource } }
  const grouped = {};
  for (const row of rows) {
    const t = row.TYPE;
    const n = row.NAME;
    if (!grouped[t])    grouped[t]    = {};
    if (!grouped[t][n]) grouped[t][n] = '';
    grouped[t][n] += row.TEXT;
  }
  return grouped;
}

module.exports = { inspectSchema, fetchPlsqlSource };
