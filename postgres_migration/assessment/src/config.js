'use strict';

const fs   = require('fs');
const path = require('path');
const yaml = require('js-yaml');

const REQUIRED = ['oracle.host', 'oracle.port', 'oracle.service', 'oracle.user', 'oracle.password'];

function expandEnvVars(obj) {
  if (typeof obj === 'string') {
    return obj.replace(/\$\{([^}]+)\}/g, (_, name) => {
      const val = process.env[name];
      if (val === undefined) throw new Error(`Environment variable not set: ${name}`);
      return val;
    });
  }
  if (Array.isArray(obj)) return obj.map(expandEnvVars);
  if (obj !== null && typeof obj === 'object') {
    return Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, expandEnvVars(v)]));
  }
  return obj;
}

function get(obj, dotPath) {
  return dotPath.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);
}

function loadConfig(configPath) {
  const abs = path.resolve(configPath);
  if (!fs.existsSync(abs)) throw new Error(`Config file not found: ${abs}`);

  const raw  = fs.readFileSync(abs, 'utf8');
  const ext  = path.extname(abs).toLowerCase();
  let parsed = ext === '.json' ? JSON.parse(raw) : yaml.load(raw);

  parsed = expandEnvVars(parsed);

  for (const field of REQUIRED) {
    if (get(parsed, field) == null) throw new Error(`Config missing required field: ${field}`);
  }

  // Defaults
  parsed.assessment         = parsed.assessment         || {};
  parsed.assessment.schemas = (parsed.assessment.schemas || []).map(s => s.toUpperCase());
  if (parsed.assessment.schemas.length === 0) throw new Error('Config must list at least one schema under assessment.schemas');

  return parsed;
}

module.exports = loadConfig;
