'use strict';

const { fetchPlsqlSource } = require('./inspector');

// Oracle-specific constructs that require manual rewrite in PostgreSQL
const ORACLE_PATTERNS = [
  { name: 'CONNECT BY (hierarchical query)',  re: /\bCONNECT\s+BY\b/gi },
  { name: 'ROWNUM',                           re: /\bROWNUM\b/gi },
  { name: 'DECODE',                           re: /\bDECODE\s*\(/gi },
  { name: 'NVL2',                             re: /\bNVL2\s*\(/gi },
  { name: 'MERGE (Oracle syntax)',            re: /\bMERGE\s+INTO\b/gi },
  { name: 'BULK COLLECT',                     re: /\bBULK\s+COLLECT\b/gi },
  { name: 'FORALL',                           re: /\bFORALL\b/gi },
  { name: 'EXECUTE IMMEDIATE',               re: /\bEXECUTE\s+IMMEDIATE\b/gi },
  { name: 'TYPE ... TABLE OF (collection)',   re: /\bTYPE\s+\w+\s+IS\s+TABLE\s+OF\b/gi },
  { name: 'REF CURSOR',                       re: /\bSYS_REFCURSOR\b|\bREF\s+CURSOR\b/gi },
  { name: 'EXCEPTION (Oracle-specific)',      re: /\bNO_DATA_FOUND\b|\bTOO_MANY_ROWS\b|\bDUP_VAL_ON_INDEX\b/gi },
];

function scanSource(allSource) {
  let fullText = '';
  for (const types of Object.values(allSource)) {
    for (const src of Object.values(types)) fullText += src + '\n';
  }

  // Distinct DBMS_* and UTL_* package references
  const dbmsMatches = fullText.match(/\bDBMS_([A-Z0-9_]+)\b/gi) || [];
  const utlMatches  = fullText.match(/\bUTL_([A-Z0-9_]+)\b/gi)  || [];
  const distinctDbms = [...new Set(dbmsMatches.map(m => m.toUpperCase()))];
  const distinctUtl  = [...new Set(utlMatches.map(m => m.toUpperCase()))];

  // Autonomous transactions
  const autonomousTransactions = (fullText.match(/PRAGMA\s+AUTONOMOUS_TRANSACTION/gi) || []).length;

  // Trigger complexity — :NEW / :OLD references
  const triggerSource = allSource['TRIGGER'] || {};
  let complexTriggers = 0;
  for (const src of Object.values(triggerSource)) {
    const hasNewOld   = /(:NEW\.|:OLD\.)/i.test(src);
    const hasConditional = /\bIF\b|\bCASE\b/i.test(src);
    if (hasNewOld && hasConditional) complexTriggers++;
  }

  // Oracle-specific SQL constructs across all source
  const oracleConstructs = [];
  for (const pattern of ORACLE_PATTERNS) {
    const matches = fullText.match(pattern.re) || [];
    if (matches.length > 0) oracleConstructs.push({ name: pattern.name, occurrences: matches.length });
  }

  return {
    distinctDbmsPackages: distinctDbms,
    distinctUtlPackages:  distinctUtl,
    autonomousTransactions,
    complexTriggers,
    oracleConstructs,
  };
}

function scoreComplexity(inventory, plsql) {
  // Weighted object points
  const objectPoints =
    inventory.packages    * 6.0 +
    inventory.procedures  * 1.5 +
    inventory.functions   * 1.5 +
    inventory.triggers    * 1.0 +
    inventory.views       * 0.3 +
    inventory.tables      * 0.1;

  // PL/SQL complexity additions
  const plsqlPoints =
    plsql.distinctDbmsPackages.length * 5 +
    plsql.distinctUtlPackages.length  * 4 +
    plsql.autonomousTransactions      * 3 +
    plsql.complexTriggers             * 2 +
    plsql.oracleConstructs.length     * 2;

  const raw = objectPoints + plsqlPoints;

  // Exponential normalization calibrated so a heavy Exadata schema (~1500 raw) → ~73/100
  const score = Math.min(100, Math.round(100 * (1 - Math.exp(-raw / 1200))));
  const level = score >= 60 ? 'HIGH' : score >= 30 ? 'MEDIUM' : 'LOW';

  // Identify the top drivers
  const drivers = [];
  if (inventory.packages > 0)
    drivers.push(`${inventory.packages} packages — primary complexity driver`);
  if (plsql.distinctDbmsPackages.length > 0)
    drivers.push(`DBMS_* calls: ${plsql.distinctDbmsPackages.join(', ')}`);
  if (plsql.distinctUtlPackages.length > 0)
    drivers.push(`UTL_* calls: ${plsql.distinctUtlPackages.join(', ')}`);
  if (plsql.autonomousTransactions > 0)
    drivers.push(`${plsql.autonomousTransactions} autonomous transaction pragma(s)`);
  if (plsql.complexTriggers > 0)
    drivers.push(`${plsql.complexTriggers} trigger(s) with :NEW/:OLD conditional logic`);
  for (const c of plsql.oracleConstructs)
    drivers.push(`${c.name} (${c.occurrences} occurrence(s))`);

  return { score, level, raw, drivers };
}

function estimateEffort(inventory, plsql, complexity) {
  // Automated conversion weeks — scales with total object count
  const total = inventory.total;
  let autoMin, autoMax;
  if (total < 200)       { autoMin = 1; autoMax = 2; }
  else if (total < 500)  { autoMin = 2; autoMax = 4; }
  else if (total < 1000) { autoMin = 4; autoMax = 6; }
  else if (total < 2000) { autoMin = 6; autoMax = 8; }
  else                   { autoMin = 8; autoMax = 12; }

  // Manual PL/SQL rework — driven by packages and autonomous transactions
  const manualUnits = inventory.packages * 2 + inventory.procedures + inventory.functions +
                      plsql.autonomousTransactions * 2;
  let manualMin, manualMax;
  if (manualUnits === 0)       { manualMin = 0; manualMax = 0; }
  else if (manualUnits < 50)   { manualMin = 1; manualMax = 3; }
  else if (manualUnits < 150)  { manualMin = 3; manualMax = 6; }
  else if (manualUnits < 400)  { manualMin = 6; manualMax = 10; }
  else if (manualUnits < 800)  { manualMin = 10; manualMax = 14; }
  else                         { manualMin = 14; manualMax = 20; }

  // Testing effort — ~60% of automated conversion time
  const testMin = Math.round(autoMin * 0.6);
  const testMax = Math.round(autoMax * 0.6);

  return {
    automated: `${autoMin}–${autoMax} weeks`,
    manualPlsql: manualUnits === 0 ? 'Minimal (no packages/procedures)' : `${manualMin}–${manualMax} weeks`,
    testing:   `${testMin}–${testMax} weeks`,
    total:     `${autoMin + manualMin + testMin}–${autoMax + manualMax + testMax} weeks`,
  };
}

async function analysePlsql(connection, schema) {
  const source = await fetchPlsqlSource(connection, schema);
  return scanSource(source);
}

module.exports = { analysePlsql, scoreComplexity, estimateEffort };
