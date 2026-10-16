import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readConfig } from '../src/config.js';

test('default config uses loopback address', () => {
  const config = readConfig({});
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 3000);
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

test('production mode is rejected', () => {
  assert.throws(
    () => readConfig({ NODE_ENV: 'production' }),
    /本服务仅供本地学习/
  );
});
