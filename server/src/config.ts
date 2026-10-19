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
    WEB_PUSH_SUBJECT: z.string().regex(/^(mailto:|https:)/).default('https://localhost'),
    HUAWEI_PUSH_PROJECT_ID: z.string().regex(/^[0-9]*$/).default(''),
    HUAWEI_PUSH_KEY_FILE: z.string().default(''),
    HUAWEI_PUSH_CATEGORY: z.string().regex(/^[A-Z_]+$/).default('MARKETING'),
    HUAWEI_PUSH_TEST_MESSAGE: z.enum(['true','false']).default('true'),
    // 物业联系电话对住户和师傅可见；默认是虚构号码，演示时可在 .env 中修改。
    PROPERTY_PHONE: z.string().trim().regex(/^[0-9+\- ]{5,20}$/, 'PROPERTY_PHONE 格式不正确').default('020-88888888'),
  }).parse(env);
  const url = new URL(config.PUBLIC_BASE_URL);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== '/') {
    throw new Error('PUBLIC_BASE_URL 必须是无路径、无凭证的 HTTP(S) 地址');
  }
  // 只允许回环地址，拒绝 0.0.0.0 或其他可从外网访问的配置
  const loopbackHosts = ['127.0.0.1', 'localhost', '::1', '[::1]'];
  if (!loopbackHosts.includes(config.HOST)) {
    throw new Error(`HOST 只能使用回环地址（${loopbackHosts.join('、')}），不能监听 ${config.HOST}。设备访问请使用 HDC/ADB 端口转发。`);
  }
  return {
    host: config.HOST, port: config.PORT,
    publicBaseUrl: url.origin,
    origins: config.CORS_ORIGINS.split(',').map(value => value.trim()).filter(Boolean),
    databasePath: config.DATABASE_PATH === ':memory:' ? ':memory:' : resolve(config.DATABASE_PATH),
    propertyPhone: config.PROPERTY_PHONE,
    webPushSubject: config.WEB_PUSH_SUBJECT,
    huaweiProjectId: config.HUAWEI_PUSH_PROJECT_ID,
    huaweiKeyFile: config.HUAWEI_PUSH_KEY_FILE ? resolve(config.HUAWEI_PUSH_KEY_FILE) : '',
    huaweiPushCategory: config.HUAWEI_PUSH_CATEGORY,
    huaweiTestMessage: config.HUAWEI_PUSH_TEST_MESSAGE === 'true',
  };
}
export type Config = ReturnType<typeof readConfig>;
