#!/usr/bin/env node
'use strict';

const { Command }        = require('commander');
const fs                 = require('fs');
const chalk              = require('chalk');
const loadConfig         = require('./config');
const { connect, close } = require('./connector');
const { inspectSchema }  = require('./inspector');
const { analysePlsql, scoreComplexity, estimateEffort } = require('./analyser');
const { buildTypeMatrix }  = require('./mapper');
const { evaluate, recommend } = require('./evaluator');
const { saveReport, toMarkdown } = require('./reporter');

const program = new Command();

program
  .name('ora-migrate-assess')
  .description('Oracle-to-PostgreSQL migration assessment tool')
  .version('1.0.0')
  .requiredOption('-c, --config <file>',    'Path to config YAML/JSON file')
  .option('-m, --mode <mode>',             'Assessment mode: full | inventory',   'full')
  .option('-t, --tools <tools>',           'Comma-separated tools to compare',    'ora2pg,aws_sct,aws_dms,edb_portal')
  .option('-o, --output <format>',         'Output format(s): markdown,json,csv,html', 'markdown')
  .option('-s, --schemas <schemas>',       'Comma-separated schemas (overrides config)')
  .option('-d, --output-dir <dir>',        'Directory for saved reports',          './reports')
  .parse(process.argv);

const opts = program.opts();

async function main() {
  const config = loadConfig(opts.config);

  if (opts.schemas) {
    config.assessment.schemas = opts.schemas.split(',').map(s => s.trim().toUpperCase());
  }

  const tools         = opts.tools.split(',').map(t => t.trim());
  const outputFormats = opts.output.split(',').map(f => f.trim());

  printBanner();

  let connection;
  try {
    process.stdout.write(chalk.yellow(`Connecting to ${config.oracle.host}:${config.oracle.port}/${config.oracle.service} ...`));
    connection = await connect(config.oracle);
    console.log(chalk.green(' connected\n'));

    const allReports = [];

    for (const schema of config.assessment.schemas) {
      console.log(chalk.bold.cyan(`Schema: ${schema}`));
      console.log('─'.repeat(52));

      step('Inspecting schema objects');
      const inventory = await inspectSchema(connection, schema);
      ok();
      printInventoryLine(inventory);

      if (opts.mode === 'inventory') {
        allReports.push({ schema, inventory, mode: 'inventory', generatedAt: new Date().toISOString() });
        console.log('');
        continue;
      }

      step('Analysing PL/SQL source');
      const plsqlAnalysis = await analysePlsql(connection, schema);
      ok();

      step('Mapping column data types');
      const typeMatrix = await buildTypeMatrix(connection, schema);
      ok();

      const complexity = scoreComplexity(inventory, plsqlAnalysis);
      const effort     = estimateEffort(inventory, plsqlAnalysis, complexity);
      const toolComp   = evaluate(inventory, plsqlAnalysis, tools);
      const recommendation = recommend(toolComp, inventory, plsqlAnalysis);

      const report = {
        schema, inventory, plsqlAnalysis, typeMatrix,
        complexity, effort, toolComparison: toolComp, recommendation,
        generatedAt: new Date().toISOString(),
        mode: 'full',
      };

      allReports.push(report);

      // Print summary to console
      printConsoleSummary(report);
    }

    // Save reports to disk
    if (!fs.existsSync(opts.outputDir)) fs.mkdirSync(opts.outputDir, { recursive: true });

    for (const report of allReports) {
      if (report.mode === 'inventory') continue;
      for (const fmt of outputFormats) {
        const file = saveReport(report, fmt, opts.outputDir);
        console.log(chalk.green(`\n✓ Saved: ${file}`));
      }
    }

  } finally {
    if (connection) await close(connection);
  }
}

// ─── Console helpers ─────────────────────────────────────────────────────────

function printBanner() {
  console.log(chalk.cyan('\n╔══════════════════════════════════════════════════════════════════╗'));
  console.log(chalk.cyan('║           ORA-Migrate-Assess v1.0 — Assessment Report           ║'));
  console.log(chalk.cyan('╚══════════════════════════════════════════════════════════════════╝\n'));
}

function step(msg) { process.stdout.write(`  ${msg.padEnd(38)}...`); }
function ok()      { console.log(chalk.green(' ✓')); }

function printInventoryLine(inv) {
  const parts = ['tables', 'views', 'procedures', 'functions', 'triggers', 'packages', 'sequences'].map(
    t => `${t}: ${inv[t]}`
  );
  console.log(chalk.dim(`  ${parts.join(' | ')}`));
}

function printConsoleSummary(report) {
  const { schema, complexity, effort, toolComparison, recommendation } = report;
  const levelColour = { HIGH: chalk.red, MEDIUM: chalk.yellow, LOW: chalk.green }[complexity.level] || chalk.white;

  console.log('');
  console.log(chalk.bold('COMPLEXITY SCORE:'), levelColour(`${complexity.level} (${complexity.score}/100)`));
  for (const d of complexity.drivers.slice(0, 5)) console.log(chalk.dim(`  → ${d}`));

  console.log('');
  console.log(chalk.bold('TOOL FITNESS SCORES:'));
  const sorted = Object.values(toolComparison).sort((a, b) => b.adjustedScore - a.adjustedScore);
  for (const p of sorted) {
    const bar = '█'.repeat(Math.round(p.adjustedScore / 5));
    console.log(`  ${p.name.padEnd(42)} ${bar} ${p.adjustedScore}%`);
  }

  console.log('');
  console.log(chalk.bold('RECOMMENDATION:'), chalk.green(recommendation.primary.name));
  if (recommendation.cdcComplement) {
    console.log(chalk.bold('CDC COMPLEMENT: '), chalk.green(recommendation.cdcComplement.name));
  }
  console.log(chalk.bold('ESTIMATED EFFORT:'), effort.total);
  console.log('');
}

main().catch(err => {
  console.error(chalk.red('\nFatal:'), err.message);
  process.exit(1);
});
