import { resolve } from 'node:path';
import { z } from 'zod';

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  if (env.NODE_ENV === 'production') {
    throw new Error('本服务仅供本地学习，开发验证码不能部署到生产环境');
  }
  const config = z.object({
    HOST: z.string().default('127.0.0.1'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    PUBLIC_BASE_URL: z.url().default('http://127.0.0.1:3000'),
    CORS_ORIGINS: z.string().default('http://localhost:8080,http://127.0.0.1:8080'),
    DATABASE_PATH: z.string().default('data/haven.sqlite'),
    AUTH_MODE: z.literal('development').default('development'),
  }).parse(env);
  const url = new URL(config.PUBLIC_BASE_URL);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('PUBLIC_BASE_URL 必须是无路径、无凭证的 HTTP(S) 地址');
  }
  return {
    host: config.HOST, port: config.PORT,
    publicBaseUrl: url.origin,
    origins: config.CORS_ORIGINS.split(',').map(value => value.trim()).filter(Boolean),
    databasePath: resolve(config.DATABASE_PATH),
  };
}
export type Config = ReturnType<typeof readConfig>;
