import { existsSync } from 'node:fs';
import { createApp } from './app.js';
import { readConfig } from './config.js';

if (existsSync('.env')) process.loadEnvFile('.env');
const config = readConfig();
const { app, store } = createApp(config);
const server = app.listen(config.port, config.host, () => {
  process.stdout.write(`享家本地学习服务：http://${config.host}:${config.port}\n开发验证码会返回给 App，不发送短信。请使用虚构资料。\n`);
});
server.on('error', error => { process.stderr.write(`${error.message}\n`); store.close(); process.exitCode = 1; });
for (const signal of ['SIGINT', 'SIGTERM'] as const) process.on(signal, () => {
  server.close(() => { store.close(); process.exit(0); });
  server.closeIdleConnections();
  setTimeout(() => process.exit(1), 5000).unref();
});
