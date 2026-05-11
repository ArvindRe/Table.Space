'use strict';

const oracledb = require('oracledb');

oracledb.outFormat = oracledb.OUT_FORMAT_OBJECT;
oracledb.fetchAsString = [oracledb.CLOB];

async function connect(cfg) {
  return oracledb.getConnection({
    user:             cfg.user,
    password:         cfg.password,
    connectString:    `${cfg.host}:${cfg.port}/${cfg.service}`,
  });
}

async function close(connection) {
  try { await connection.close(); } catch (_) {}
}

async function query(connection, sql, binds = []) {
  const result = await connection.execute(sql, binds, { outFormat: oracledb.OUT_FORMAT_OBJECT });
  return result.rows;
}

module.exports = { connect, close, query };
