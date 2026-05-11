'use strict';

// Base conversion coverage scores (%) per object type, sourced from published tool benchmarks
// and adjusted for real-world production schema experience.
const TOOL_PROFILES = {
  ora2pg: {
    name:        'Ora2Pg',
    type:        'Open source CLI',
    bestFor:     'Schema + data migration, PL/SQL conversion',
    url:         'https://ora2pg.darold.net',
    scores:      { tables: 98, indexes: 91, views: 87, procedures: 71, functions: 73, triggers: 64, packages: 52, sequences: 95, synonyms: 70 },
    strengths:   ['Free and open source', 'Handles most DDL', 'Partial PL/SQL → PL/pgSQL conversion', 'Active community'],
    limitations: ['No CDC / live replication', 'Packages require significant manual rework', 'No GUI'],
    zeroDowntime: false,
    cdcCapable:   false,
    cloudNative:  false,
  },
  aws_sct: {
    name:        'AWS Schema Conversion Tool (SCT)',
    type:        'AWS-managed GUI/CLI',
    bestFor:     'AWS RDS / Aurora PostgreSQL targets',
    url:         'https://aws.amazon.com/dms/schema-conversion-tool/',
    scores:      { tables: 97, indexes: 89, views: 84, procedures: 68, functions: 69, triggers: 61, packages: 49, sequences: 94, synonyms: 65 },
    strengths:   ['Integrated with AWS DMS for CDC', 'Action items report with manual effort estimate', 'Aurora PostgreSQL native'],
    limitations: ['AWS targets only', 'GUI-heavy for full use', 'No on-prem PostgreSQL'],
    zeroDowntime: false,
    cdcCapable:   false,
    cloudNative:  true,
  },
  aws_dms: {
    name:        'AWS Database Migration Service (DMS)',
    type:        'AWS-managed CDC / full-load',
    bestFor:     'Live replication, zero-downtime cutover to AWS',
    url:         'https://aws.amazon.com/dms/',
    scores:      { tables: 96, indexes: 72, views: 41, procedures: 12, functions: 15, triggers: 8, packages: 0, sequences: 90, synonyms: 0 },
    strengths:   ['CDC for zero-downtime cutover', 'Continuous replication during migration window', 'Pairs with SCT for schema conversion'],
    limitations: ['Virtually no PL/SQL migration', 'AWS targets only', 'Ongoing cost for CDC task', 'Indexes/views often need manual creation'],
    zeroDowntime: true,
    cdcCapable:   true,
    cloudNative:  true,
  },
  edb_portal: {
    name:        'EDB Migration Portal',
    type:        'EDB-managed SaaS',
    bestFor:     'EnterpriseDB Postgres Advanced Server (EPAS) targets',
    url:         'https://www.enterprisedb.com/products/migration-portal',
    scores:      { tables: 99, indexes: 93, views: 88, procedures: 74, functions: 76, triggers: 67, packages: 58, sequences: 97, synonyms: 80 },
    strengths:   ['Highest package conversion rate', 'Oracle compatibility layer in EPAS', 'Cloud or on-prem deployment'],
    limitations: ['Best results on EDB EPAS, not vanilla PostgreSQL', 'Commercial licence required', 'Package conversion still leaves gaps'],
    zeroDowntime: false,
    cdcCapable:   false,
    cloudNative:  false,
  },
};

// Object types that carry code complexity (lower tool scores matter more here)
const CODE_OBJECT_TYPES = ['procedures', 'functions', 'triggers', 'packages'];

function evaluate(inventory, plsqlAnalysis, selectedTools) {
  const results = {};

  for (const toolId of selectedTools) {
    const profile = TOOL_PROFILES[toolId];
    if (!profile) continue;

    // Weighted fitness score: Σ(count[type] * score[type]) / Σ(count[type])
    let weightedSum = 0;
    let totalObjects = 0;

    const objectTypes = ['tables', 'views', 'procedures', 'functions', 'triggers', 'packages', 'sequences', 'synonyms'];
    const perType = {};

    for (const t of objectTypes) {
      const count = inventory[t] || 0;
      const score = profile.scores[t] || 0;
      perType[t] = { count, score, contribution: count * score };
      weightedSum  += count * score;
      totalObjects += count;
    }

    const fitnessScore = totalObjects > 0 ? Math.round(weightedSum / totalObjects) : 0;

    // Penalty if schema is package-heavy and the tool handles packages poorly
    const packageHeavy = inventory.packages > 10;
    const packagePenalty = packageHeavy ? Math.round((100 - profile.scores.packages) * 0.1) : 0;
    const adjustedScore = Math.max(0, fitnessScore - packagePenalty);

    results[toolId] = {
      ...profile,
      perType,
      fitnessScore,
      adjustedScore,
      packageHeavy,
    };
  }

  return results;
}

function recommend(comparison, inventory, plsqlAnalysis) {
  const entries = Object.entries(comparison).sort((a, b) => b[1].adjustedScore - a[1].adjustedScore);

  const [primaryId, primaryProfile] = entries[0];

  // Find the best CDC-capable tool as a complement
  const cdcOption = entries.find(([, p]) => p.cdcCapable);

  const packageHeavy = inventory.packages > 10;
  const highDbms     = plsqlAnalysis.distinctDbmsPackages.length > 5;

  const rationale = [];
  rationale.push(`${primaryProfile.name} scores highest (${primaryProfile.adjustedScore}%) weighted by your schema composition.`);
  if (packageHeavy) rationale.push(`Schema is package-heavy (${inventory.packages} packages) — manual PL/SQL rework required regardless of tool.`);
  if (highDbms) rationale.push(`${plsqlAnalysis.distinctDbmsPackages.length} distinct DBMS_* package types detected — review Oracle-specific API replacements.`);
  if (cdcOption) rationale.push(`${cdcOption[1].name} recommended for live CDC replication during the cutover window.`);

  return {
    primary:      { id: primaryId, name: primaryProfile.name, score: primaryProfile.adjustedScore },
    cdcComplement: cdcOption ? { id: cdcOption[0], name: cdcOption[1].name } : null,
    zeroDowntimeStrategy: cdcOption
      ? `${cdcOption[1].name} full-load + CDC, paired with ${primaryProfile.name} for schema/code migration`
      : `${primaryProfile.name} for schema + data, with a scheduled maintenance-window cutover`,
    rationale,
  };
}

module.exports = { evaluate, recommend, TOOL_PROFILES };
