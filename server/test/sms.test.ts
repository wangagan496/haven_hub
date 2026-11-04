import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { createTencentSmsSender, tencentSmsHeaders, SmsDeliveryError } from '../src/sms.js';
import { accepted, smsConfig } from './sms-fixture.js';

test('TC3 SMS signature matches an independent Python stdlib fixture and uses UTC date', () => {
  const body = JSON.stringify({ PhoneNumberSet: ['+8613800138000'], SmsSdkAppId: '1400000000',
    TemplateId: '12345', SignName: '享家测试', TemplateParamSet: ['123456', '5'] });
  // Formula: https://cloud.tencent.com/document/api/382/52072 ; synthetic credentials.
  const headers = tencentSmsHeaders(smsConfig, body, 1551113065);
  assert.equal(headers.Authorization, 'TC3-HMAC-SHA256 Credential=AKIDexample123/2019-02-25/sms/tc3_request, SignedHeaders=content-type;host;x-tc-action, Signature=0103215abebcc7548fdd9835136e5fbb57420b79ed92f09c8d14415b07784ce6');
  assert.equal(headers['X-TC-Version'], '2021-01-11');
  assert.equal(headers['X-TC-Timestamp'], '1551113065');
  assert.equal(tencentSmsHeaders({ ...smsConfig, token: 'temporary-token' }, body, 1551113065)['X-TC-Token'], 'temporary-token');
});

test('sender uses fixed HTTPS endpoint, one phone, exact signed bytes and explicit template variable order', async () => {
  for (const templateParams of ['code', 'code,minutes'] as const) {
    let calls = 0;
    const config = { ...smsConfig, templateParams };
    const sender = createTencentSmsSender(config, { now: () => 1551113065000,
      fetch: async (url, init) => {
        calls++;
        assert.equal(url, 'https://sms.tencentcloudapi.com/');
        assert.equal(init!.method, 'POST');
        assert.equal(init!.redirect, 'error');
        assert(init!.signal);
        const body = String(init!.body);
        assert.deepEqual(JSON.parse(body), { PhoneNumberSet: ['+8613800138000'], SmsSdkAppId: config.appId,
          TemplateId: config.templateId, SignName: config.signName,
          TemplateParamSet: templateParams === 'code' ? ['000123'] : ['000123', '5'] });
        assert.deepEqual(init!.headers, tencentSmsHeaders(config, body, 1551113065));
        return accepted();
      } });
    assert.equal(await sender('13800138000', '000123'), undefined);
    assert.equal(calls, 1);
  }
});

test('HTTP 200 vendor errors, malformed and mismatched receipts fail without retries or leaking messages', async () => {
  const responses = [
    Response.json({ Response: { Error: { Code: 'AuthFailure', Message: 'secretKeyExample123 123456 13800138000' } } }),
    Response.json({ Response: { SendStatusSet: [{ Code: 'LimitExceeded', PhoneNumber: '+8613800138000', Message: 'sensitive' }] } }),
    Response.json({ Response: { SendStatusSet: [{ Code: 'Ok', PhoneNumber: '+8613900139000', SerialNo: 'wrong-phone' }] } }),
    Response.json({ Response: { SendStatusSet: [{ Code: 'Ok', PhoneNumber: '+8613800138000' }] } }),
    Response.json({ Response: { SendStatusSet: [] } }),
    Response.json({ Response: { SendStatusSet: [null, null] } }),
    Response.json({}), new Response('bad-json'), new Response(null),
    new Response('secret', { status: 503 }), new Response('redirect', { status: 302 }),
    new Response('x'.repeat(65537)),
  ];
  for (const response of responses) {
    let calls = 0;
    const sender = createTencentSmsSender(smsConfig, { fetch: async () => { calls++; return response; } });
    await assert.rejects(sender('13800138000', '123456'), error => {
      assert(error instanceof SmsDeliveryError);
      assert.doesNotMatch(error.message, /secret|123456|13800138000|sensitive/);
      return true;
    });
    assert.equal(calls, 1);
  }
});

test('network errors are sanitized and not retried', async () => {
  let calls = 0;
  const sender = createTencentSmsSender(smsConfig, { fetch: async () => { calls++; throw Error('request with secretKeyExample123 123456'); } });
  await assert.rejects(sender('13800138000', '123456'), { reason: 'network', message: '短信服务暂不可用' });
  assert.equal(calls, 1);
});

test('timeout covers both connecting and streaming the response body', async () => {
  for (const phase of ['headers', 'body']) {
    let calls = 0;
    const sender = createTencentSmsSender(smsConfig, { timeoutMs: 20, fetch: async (_url, init) => {
      calls++;
      if (phase === 'headers') {
        await delay(1000, undefined, { signal: init!.signal! });
        return accepted();
      }
      return new Response(new ReadableStream({ async start(controller) {
        try { await delay(1000, undefined, { signal: init!.signal! }); controller.close(); }
        catch (error) { controller.error(error); }
      } }));
    } });
    await assert.rejects(sender('13800138000', '123456'), { reason: 'timeout' });
    assert.equal(calls, 1);
  }
});

test('invalid mobiles and codes never reach the provider', async () => {
  const sender = createTencentSmsSender(smsConfig, { fetch: async () => { assert.fail('must not send'); } });
  for (const [mobile, code] of [['+8613800138000','123456'], ['13800138000,13900139000','123456'], ['13800138000','12']])
    await assert.rejects(sender(mobile!, code!));
});
