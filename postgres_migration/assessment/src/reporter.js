'use strict';

const fs   = require('fs');
const path = require('path');

// ─── Markdown ────────────────────────────────────────────────────────────────

function toMarkdown(report) {
  const { schema, inventory, plsqlAnalysis, typeMatrix, complexity, effort, toolComparison, recommendation, generatedAt } = report;
  const ts = new Date(generatedAt).toISOString().replace('T', ' ').slice(0, 19);
  const lines = [];

  lines.push(`# ORA-Migrate-Assess — Migration Assessment Report`);
  lines.push(`**Schema:** ${schema}  |  **Generated:** ${ts}`);
  lines.push('');

  // Schema inventory
  lines.push('## Schema Inventory');
  lines.push('```');
  const invRows = [
    ['Tables',      inventory.tables],
    ['Views',       inventory.views],
    ['Procedures',  inventory.procedures],
    ['Functions',   inventory.functions],
    ['Triggers',    inventory.triggers],
    ['Packages',    inventory.packages],
    ['Sequences',   inventory.sequences],
    ['Synonyms',    inventory.synonyms],
    ['─────────────', '──────'],
    ['Total Objects', inventory.total],
  ];
  for (const [label, val] of invRows) lines.push(`  ${label.padEnd(24)}: ${val}`);
  lines.push('```');
  lines.push('');

  // Complexity
  const levelEmoji = { HIGH: '🔴', MEDIUM: '🟡', LOW: '🟢' }[complexity.level] || '';
  lines.push(`## Complexity Score: ${complexity.level} (${complexity.score}/100) ${levelEmoji}`);
  for (const d of complexity.drivers) lines.push(`  → ${d}`);
  lines.push('');

  // PL/SQL analysis
  if (plsqlAnalysis.oracleConstructs.length > 0) {
    lines.push('## Oracle-Specific Constructs Detected');
    for (const c of plsqlAnalysis.oracleConstructs) lines.push(`  - ${c.name} (${c.occurrences} occurrence(s))`);
    lines.push('');
  }

  // Tool comparison table
  lines.push('## Tool Comparison');
  lines.push('');
  const toolIds  = Object.keys(toolComparison);
  const toolNames = toolIds.map(id => toolComparison[id].name);
  const objTypes = ['tables', 'views', 'procedures', 'functions', 'triggers', 'packages', 'sequences'];

  const col = 12;
  const hdr = 'Object Type'.padEnd(20) + toolNames.map(n => n.slice(0, col).padEnd(col + 2)).join('');
  lines.push(hdr);
  lines.push('─'.repeat(hdr.length));

  for (const t of objTypes) {
    if (inventory[t] === 0) continue;
    let row = (t.charAt(0).toUpperCase() + t.slice(1)).padEnd(20);
    for (const id of toolIds) {
      const score = toolComparison[id].scores[t];
      const icon  = score >= 90 ? '✅' : score >= 60 ? '⚠️ ' : '❌';
      row += `${icon} ${score}%`.padEnd(col + 2);
    }
    lines.push(row);
  }
  lines.push('');

  // Weighted fitness scores
  lines.push('**Weighted Fitness Score** (by schema composition)');
  lines.push('');
  for (const id of toolIds) {
    const p = toolComparison[id];
    lines.push(`  ${p.name.padEnd(42)}: ${p.adjustedScore}%`);
  }
  lines.push('');

  // Data type matrix
  if (typeMatrix && typeMatrix.length > 0) {
    lines.push('## Data Type Mapping');
    lines.push('');
    lines.push(`| Oracle Type | Columns | PostgreSQL Type | Risk | Notes |`);
    lines.push(`|-------------|---------|-----------------|------|-------|`);
    for (const row of typeMatrix.slice(0, 20)) {
      const riskIcon = { auto: '🟢', review: '🟡', manual: '🔴' }[row.risk] || '';
      lines.push(`| ${row.oracleType} | ${row.columnCount} | ${row.postgresType} | ${riskIcon} ${row.risk} | ${row.notes} |`);
    }
    lines.push('');
  }

  // Effort
  lines.push('## Estimated Migration Effort');
  lines.push('```');
  lines.push(`  Automated schema/data conversion : ${effort.automated}`);
  lines.push(`  Manual PL/SQL rework             : ${effort.manualPlsql}`);
  lines.push(`  Testing & validation             : ${effort.testing}`);
  lines.push(`  ─────────────────────────────────────────────────────`);
  lines.push(`  Total estimate                   : ${effort.total}`);
  lines.push('```');
  lines.push('');

  // Recommendation
  lines.push('## Recommendation');
  lines.push('');
  lines.push(`**Primary tool:** ${recommendation.primary.name} (${recommendation.primary.score}% weighted fit)`);
  if (recommendation.cdcComplement) {
    lines.push(`**CDC complement:** ${recommendation.cdcComplement.name}`);
  }
  lines.push('');
  lines.push(`**Zero-downtime strategy:** ${recommendation.zeroDowntimeStrategy}`);
  lines.push('');
  lines.push('**Rationale:**');
  for (const r of recommendation.rationale) lines.push(`  - ${r}`);

  return lines.join('\n');
}

// ─── JSON ─────────────────────────────────────────────────────────────────────

function toJson(report) {
  return JSON.stringify(report, null, 2);
}

// ─── CSV ──────────────────────────────────────────────────────────────────────

function toCsv(report) {
  const { schema, toolComparison } = report;
  const rows = ['schema,tool,object_type,coverage_pct,weighted_fitness'];
  for (const [id, profile] of Object.entries(toolComparison)) {
    for (const [type, data] of Object.entries(profile.perType)) {
      rows.push(`${schema},${profile.name},${type},${data.score},${profile.adjustedScore}`);
    }
  }
  return rows.join('\n');
}

// ─── HTML ─────────────────────────────────────────────────────────────────────

function toHtml(report) {
  const md = toMarkdown(report);
  const escaped = md.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>ORA-Migrate-Assess — ${report.schema}</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', monospace; max-width: 960px; margin: 40px auto; padding: 0 20px; color: #222; }
  h1 { color: #1a3c5e; border-bottom: 2px solid #1a3c5e; padding-bottom: 8px; }
  h2 { color: #2c5282; margin-top: 32px; }
  pre { background: #f4f4f4; border: 1px solid #ddd; border-radius: 4px; padding: 16px; overflow-x: auto; white-space: pre-wrap; }
  table { border-collapse: collapse; width: 100%; margin: 16px 0; }
  th, td { border: 1px solid #ccc; padding: 8px 12px; text-align: left; font-size: 0.9em; }
  th { background: #2c5282; color: white; }
  tr:nth-child(even) { background: #f8f9fa; }
</style>
</head>
<body>
<pre>${escaped}</pre>
</body>
</html>`;
}

// ─── Save ─────────────────────────────────────────────────────────────────────

function saveReport(report, format, outputDir) {
  const ts       = new Date(report.generatedAt).toISOString().slice(0, 10);
  const filename = `${report.schema}_assessment_${ts}.${format === 'markdown' ? 'md' : format}`;
  const filepath = path.join(outputDir, filename);

  let content;
  switch (format) {
    case 'markdown': content = toMarkdown(report); break;
    case 'json':     content = toJson(report);     break;
    case 'csv':      content = toCsv(report);      break;
    case 'html':     content = toHtml(report);     break;
    default: throw new Error(`Unknown output format: ${format}`);
  }

  fs.writeFileSync(filepath, content, 'utf8');
  return filepath;
}

module.exports = { saveReport, toMarkdown, toJson, toCsv, toHtml };
