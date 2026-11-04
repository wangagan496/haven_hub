import { randomUUID } from 'node:crypto';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import type { Config } from './config.js';

/** Separate entry point: no database connection, migrations, settlement or push workers. */
export function createMaintenanceApp(config: Config) {
  const app = express();
  app.disable('x-powered-by');
  app.use(helmet());
  app.use((_request, response, next) => {
    response.setHeader('X-Request-Id', randomUUID());
    response.setHeader('Cache-Control', 'no-store');
    next();
  });
  app.use(cors({ exposedHeaders: ['X-Request-Id'], origin(origin, callback) {
    callback(null, !origin || origin === config.publicBaseUrl || config.origins.includes(origin));
  } }));
  app.get('/health', (_request, response) => response.json({ code: 10000, message: '维护进程正常', data: { mode: 'maintenance' } }));
  app.use((_request, response) => {
    response.setHeader('Retry-After', '60');
    response.status(503).json({ code: 50300, message: '系统维护中，请稍后重试，尚未受理本次操作', data: null });
  });
  return app;
}
