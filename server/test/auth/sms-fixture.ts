import type { TestContext } from 'node:test';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { TencentSmsConfig } from '../../src/sms.js';

// Synthetic credentials. No test contacts Tencent or sends a message.
export const smsConfig: TencentSmsConfig = { secretId: 'AKIDexample123', secretKey: 'secretKeyExample123',
  appId: '1400000000', templateId: '12345', signName: '享家测试', region: 'ap-guangzhou', templateParams: 'code,minutes',
  hourlyLimit: 5, dailyLimit: 10, globalDailyLimit: 100 };
export function accepted(mobile = '13800138000') {
  return Response.json({ Response: { RequestId: 'request-test', SendStatusSet: [
    { Code: 'Ok', PhoneNumber: `+86${mobile}`, SerialNo: 'synthetic-serial' },
  ] } });
}
export function productionEnv(t: TestContext, beforeCleanup: () => void | Promise<void> = () => {}): NodeJS.ProcessEnv {
  const dir = mkdtempSync(join(tmpdir(), 'haven-sms-test-'));
  t.after(async () => { await beforeCleanup(); rmSync(dir, { force: true, recursive: true }); });
  const keyFile = join(dir, 'sms-key.json');
  writeFileSync(keyFile, JSON.stringify({ secretId: smsConfig.secretId, secretKey: smsConfig.secretKey }));
  return { NODE_ENV: 'production', AUTH_MODE: 'tencent', TRUST_PROXY: '1', PUBLIC_BASE_URL: 'https://haven.example.com', CORS_ORIGINS: '',
    DATABASE_PATH: join(dir, 'production.sqlite'), PROPERTY_PHONE: '020-12345678', CLIENT_MIN_VERSION: '1.0.0',
    TENCENT_SMS_KEY_FILE: keyFile, TENCENT_SMS_APP_ID: smsConfig.appId, TENCENT_SMS_TEMPLATE_ID: smsConfig.templateId,
    TENCENT_SMS_SIGN_NAME: smsConfig.signName, TENCENT_SMS_REGION: smsConfig.region,
    TENCENT_SMS_TEMPLATE_PARAMS: smsConfig.templateParams, SMS_GLOBAL_DAILY_LIMIT: '100' };
}
