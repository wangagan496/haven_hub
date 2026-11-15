import { isAbsolute, relative, resolve, sep } from 'node:path';
import { closeSync, fstatSync, openSync, readFileSync } from 'node:fs';
import { z } from 'zod';
import { clientVersionPattern } from './client-compatibility.js';
import type { TencentSmsConfig } from './sms.js';
import { readOperationsKeyring } from './operations-credentials.js';
import type { RuntimeLogSettings } from './runtime-log.js';

function readSmsConfig(env: NodeJS.ProcessEnv): TencentSmsConfig {
  const parsed = z.object({
    TENCENT_SMS_APP_ID: z.string().regex(/^\d+$/),
    TENCENT_SMS_TEMPLATE_ID: z.string().regex(/^\d+$/),
    TENCENT_SMS_SIGN_NAME: z.string().trim().min(1).max(100),
    TENCENT_SMS_REGION: z.string().regex(/^[a-z]+-[a-z]+$/),
    TENCENT_SMS_TEMPLATE_PARAMS: z.enum(['code', 'code,minutes']),
    TENCENT_SMS_KEY_FILE: z.string().refine(isAbsolute),
    SMS_PHONE_HOURLY_LIMIT: z.coerce.number().int().min(1).max(60).default(5),
    SMS_PHONE_DAILY_LIMIT: z.coerce.number().int().min(1).max(100).default(10),
    SMS_GLOBAL_DAILY_LIMIT: z.coerce.number().int().min(1).max(100_000),
  }).safeParse(env);
  if (!parsed.success) throw new Error(`腾讯云短信配置缺失或无效：${[...new Set(parsed.error.issues.map(issue => String(issue.path[0])))].join('、')}`);
  const value = parsed.data;
  if (value.SMS_PHONE_HOURLY_LIMIT > value.SMS_PHONE_DAILY_LIMIT)
    throw new Error('SMS_PHONE_HOURLY_LIMIT 不能超过 SMS_PHONE_DAILY_LIMIT');
  let credentials: { secretId: string; secretKey: string; token?: string };
  try {
    const fd = openSync(value.TENCENT_SMS_KEY_FILE, 'r');
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile() || stat.size > 16 * 1024) throw new Error();
      credentials = z.object({
        secretId: z.string().regex(/^[A-Za-z0-9]{8,128}$/),
        secretKey: z.string().regex(/^[A-Za-z0-9]{8,128}$/),
        token: z.string().regex(/^[\x21-\x7e]{1,8192}$/).optional(),
      }).strict().parse(JSON.parse(readFileSync(fd, 'utf8')));
    } finally { closeSync(fd); }
  } catch { throw new Error('TENCENT_SMS_KEY_FILE 无法读取或凭证格式不正确'); }
  return { ...credentials, appId: value.TENCENT_SMS_APP_ID, templateId: value.TENCENT_SMS_TEMPLATE_ID,
    signName: value.TENCENT_SMS_SIGN_NAME, region: value.TENCENT_SMS_REGION, templateParams: value.TENCENT_SMS_TEMPLATE_PARAMS,
    hourlyLimit: value.SMS_PHONE_HOURLY_LIMIT, dailyLimit: value.SMS_PHONE_DAILY_LIMIT, globalDailyLimit: value.SMS_GLOBAL_DAILY_LIMIT };
}

export function readConfig(env: NodeJS.ProcessEnv = process.env) {
  if (env.NODE_ENV === 'production' && env.AUTH_MODE !== 'tencent') {
    throw new Error('生产环境必须配置 AUTH_MODE=tencent，禁止使用开发验证码');
  }
  const config = z.object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    // Trust an exact number of proxy hops; development defaults to no forwarding trust.
    TRUST_PROXY: z.string().regex(/^(0|[1-8])$/).default('0'),
    HOST: z.string().default('127.0.0.1'),
    PORT: z.coerce.number().int().min(1).max(65535).default(3000),
    PUBLIC_BASE_URL: z.url().default('http://127.0.0.1:3000'),
    CORS_ORIGINS: z.string().default('http://localhost:8080,http://127.0.0.1:8080'),
    DATABASE_PATH: z.string().default('data/haven.sqlite'),
    AUTH_MODE: z.enum(['development', 'tencent']).default('development'),
    MAINTENANCE_MODE: z.enum(['true','false']).default('false'),
    OPERATIONS_KEYS_FILE: z.string().default(''),
    CLIENT_MIN_VERSION: z.union([z.literal(''), z.string().regex(clientVersionPattern)]).default(''),
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
  const origins = config.CORS_ORIGINS.split(',').map(value => value.trim()).filter(Boolean).map(origin => {
    let parsed: URL;
    try { parsed = new URL(origin); } catch { throw new Error('CORS_ORIGINS 必须是明确的 HTTP(S) 来源列表'); }
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.search || parsed.hash || parsed.pathname !== '/')
      throw new Error('CORS_ORIGINS 必须是无路径、无凭证的 HTTP(S) 来源列表');
    return parsed.origin;
  });
  if (config.NODE_ENV === 'production') {
    if (env.TRUST_PROXY === undefined || env.TRUST_PROXY === '')
      throw new Error('生产环境必须显式配置 TRUST_PROXY（无代理设0，同机反向代理通常设1）');
    if (!env.PUBLIC_BASE_URL || url.protocol !== 'https:' || loopbackHosts.includes(url.hostname))
      throw new Error('生产 PUBLIC_BASE_URL 必须显式配置 HTTPS 公网来源');
    if (env.CORS_ORIGINS === undefined || origins.some(origin => new URL(origin).protocol !== 'https:' || loopbackHosts.includes(new URL(origin).hostname)))
      throw new Error('生产 CORS_ORIGINS 必须显式配置 HTTPS 来源；同源部署可留空');
    if (!env.DATABASE_PATH || !isAbsolute(config.DATABASE_PATH) || config.DATABASE_PATH === ':memory:')
      throw new Error('生产 DATABASE_PATH 必须是独立持久化数据库的绝对路径');
    if (!env.PROPERTY_PHONE || !config.CLIENT_MIN_VERSION)
      throw new Error('生产环境必须显式配置 PROPERTY_PHONE 和 CLIENT_MIN_VERSION');
  }
  if (config.NODE_ENV !== 'production' && !loopbackHosts.includes(url.hostname))
    throw new Error('开发模式 PUBLIC_BASE_URL 必须使用本机回环地址');
  const sms = config.AUTH_MODE === 'tencent' ? readSmsConfig(env) : undefined;
  if (config.OPERATIONS_KEYS_FILE) {
    if (!isAbsolute(config.OPERATIONS_KEYS_FILE)) throw new Error('OPERATIONS_KEYS_FILE 必须是绝对路径');
    readOperationsKeyring(config.OPERATIONS_KEYS_FILE);
  }
  const logConfig = z.object({
    RUNTIME_LOG_DIRECTORY: z.string().default(''),
    RUNTIME_LOG_MAX_BYTES: z.coerce.number().int().min(1024).max(16 * 1024 * 1024).default(1024 * 1024),
    RUNTIME_LOG_MAX_FILES: z.coerce.number().int().min(2).max(100).default(5),
  }).safeParse(env);
  if (!logConfig.success || (logConfig.data.RUNTIME_LOG_DIRECTORY && !isAbsolute(logConfig.data.RUNTIME_LOG_DIRECTORY)))
    throw new Error('运行日志配置无效，请使用绝对目录和有效的文件大小、数量限制');
  const runtimeLog: RuntimeLogSettings | undefined = logConfig.data.RUNTIME_LOG_DIRECTORY ? {
    directory: resolve(logConfig.data.RUNTIME_LOG_DIRECTORY), maxBytes: logConfig.data.RUNTIME_LOG_MAX_BYTES,
    maxFiles: logConfig.data.RUNTIME_LOG_MAX_FILES,
  } : undefined;
  if (runtimeLog && config.DATABASE_PATH !== ':memory:') {
    const databaseRelativePath = relative(runtimeLog.directory, resolve(config.DATABASE_PATH));
    if (!isAbsolute(databaseRelativePath) && databaseRelativePath !== '..' && !databaseRelativePath.startsWith(`..${sep}`))
      throw new Error('业务数据库必须位于运行日志目录之外');
  }
  return {
    runtimeLog,
    environment: config.NODE_ENV, authMode: config.AUTH_MODE, sms,
    host: config.HOST, port: config.PORT,
    trustProxy: Number(config.TRUST_PROXY),
    maintenance: config.MAINTENANCE_MODE === 'true',
    operationsKeysFile: config.OPERATIONS_KEYS_FILE,
    clientMinimumVersion: config.CLIENT_MIN_VERSION,
    publicBaseUrl: url.origin,
    origins,
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
