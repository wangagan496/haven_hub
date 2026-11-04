import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readConfig } from '../src/config.js';
import { existsSync, writeFileSync } from 'node:fs';
import { createApp } from '../src/app.js';
import { productionEnv } from './sms-fixture.js';

test('default config uses loopback address', () => {
  const config = readConfig({});
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 3000);
  assert.equal(config.trustProxy, 0);
});

test('development refuses public base URLs and never trusts forwarded headers by default', () => {
  assert.throws(() => readConfig({ PUBLIC_BASE_URL: 'https://haven.example.com' }), /开发模式 PUBLIC_BASE_URL/);
  assert.equal(readConfig({ 'X-Forwarded-For': '198.51.100.8' } as NodeJS.ProcessEnv).trustProxy, 0);
  assert.equal(readConfig({ TRUST_PROXY: '1' }).trustProxy, 1);
  assert.throws(() => readConfig({ TRUST_PROXY: 'true' }), /TRUST_PROXY/);
});

test('localhost is accepted', () => {
  const config = readConfig({ HOST: 'localhost' });
  assert.equal(config.host, 'localhost');
});

test('IPv6 loopback is accepted', () => {
  const config = readConfig({ HOST: '::1' });
  assert.equal(config.host, '::1');
});

test('0.0.0.0 is rejected with clear message', () => {
  assert.throws(
    () => readConfig({ HOST: '0.0.0.0' }),
    (err: Error) => {
      assert.match(err.message, /HOST 只能使用回环地址/);
      assert.match(err.message, /HDC\/ADB 端口转发/);
      return true;
    }
  );
});

test('LAN address is rejected', () => {
  assert.throws(
    () => readConfig({ HOST: '192.168.1.100' }),
    (err: Error) => {
      assert.match(err.message, /HOST 只能使用回环地址/);
      return true;
    }
  );
});

test('production mode rejects development authentication', () => {
  assert.throws(
    () => readConfig({ NODE_ENV: 'production' }),
    /生产环境必须配置 AUTH_MODE=tencent/
  );
});

test('complete production settings require real SMS and keep the API on loopback', t => {
  const config = readConfig(productionEnv(t));
  assert.equal(config.environment, 'production');
  assert.equal(config.authMode, 'tencent');
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.publicBaseUrl, 'https://haven.example.com');
  assert.deepEqual(config.origins, []);
  assert.equal(config.sms!.templateParams, 'code,minutes');
});

test('incomplete production or SMS settings fail before opening a database', t => {
  const env = productionEnv(t);
  for (const patch of [
    { AUTH_MODE: 'development' }, { AUTH_MODE: 'unknown' }, { NODE_ENV: 'prod' },
    { PUBLIC_BASE_URL: undefined }, { PUBLIC_BASE_URL: 'http://haven.example.com' },
    { PUBLIC_BASE_URL: 'https://localhost' }, { PUBLIC_BASE_URL: 'https://haven.example.com/api' },
    { CORS_ORIGINS: undefined }, { CORS_ORIGINS: '*' }, { CORS_ORIGINS: 'http://haven.example.com' },
    { CORS_ORIGINS: 'https://user:password@haven.example.com' }, { CORS_ORIGINS: 'https://haven.example.com/path' },
    { DATABASE_PATH: ':memory:' }, { DATABASE_PATH: 'data/haven.sqlite' }, { DATABASE_PATH: undefined },
    { PROPERTY_PHONE: undefined }, { CLIENT_MIN_VERSION: '' }, { HOST: '0.0.0.0' },
    { TRUST_PROXY: undefined }, { TRUST_PROXY: '' }, { TRUST_PROXY: 'true' },
    { TENCENT_SMS_APP_ID: undefined }, { TENCENT_SMS_TEMPLATE_ID: '' }, { TENCENT_SMS_SIGN_NAME: '' },
    { TENCENT_SMS_TEMPLATE_PARAMS: undefined }, { TENCENT_SMS_TEMPLATE_PARAMS: 'minutes,code' },
    { TENCENT_SMS_REGION: 'not/region' }, { TENCENT_SMS_KEY_FILE: 'relative.json' },
    { SMS_GLOBAL_DAILY_LIMIT: undefined }, { SMS_GLOBAL_DAILY_LIMIT: '0' }, { SMS_GLOBAL_DAILY_LIMIT: 'NaN' },
    { SMS_PHONE_HOURLY_LIMIT: '20', SMS_PHONE_DAILY_LIMIT: '10' },
  ]) {
    assert.throws(() => createApp(readConfig({ ...env, ...patch })), JSON.stringify(patch));
    assert.equal(existsSync(env.DATABASE_PATH!), false);
  }
});

test('invalid key files never include credentials or file contents in errors', t => {
  const env = productionEnv(t);
  for (const contents of ['secretKeyExample123', JSON.stringify({ secretId: 'AKIDexample123', secretKey: 'secretKeyExample123', extra: 'bad' }),
    JSON.stringify({ secretId: 'AKIDexample123', secretKey: 'bad\nsecretKeyExample123' }), 'x'.repeat(16385)]) {
    writeFileSync(env.TENCENT_SMS_KEY_FILE!, contents);
    assert.throws(() => readConfig(env), error => {
      assert(error instanceof Error);
      assert.equal(error.message, 'TENCENT_SMS_KEY_FILE 无法读取或凭证格式不正确');
      assert.doesNotMatch(error.stack!, /secretKeyExample123|AKIDexample123/);
      return true;
    });
  }
});

test('Tencent mode outside production still requires credentials and an explicit budget', () => {
  assert.throws(() => readConfig({ AUTH_MODE: 'tencent' }), /腾讯云短信配置/);
  assert.throws(() => readConfig({ CORS_ORIGINS: '*' }), /CORS_ORIGINS/);
});
