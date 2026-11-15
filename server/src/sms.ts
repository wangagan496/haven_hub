import { createHash, createHmac } from 'node:crypto';

export type TencentSmsConfig = {
  secretId: string; secretKey: string; token?: string;
  appId: string; templateId: string; signName: string; region: string;
  templateParams: 'code' | 'code,minutes';
  hourlyLimit: number; dailyLimit: number; globalDailyLimit: number;
};
export type SmsSender = (mobile: string, code: string) => Promise<void>;
type Failure = 'timeout' | 'network' | 'http' | 'response' | 'provider';
export class SmsDeliveryError extends Error {
  constructor(readonly reason: Failure) { super('短信服务暂不可用'); }
}
const host = 'sms.tencentcloudapi.com';
const contentType = 'application/json; charset=utf-8';
const sha256 = (value: string) => createHash('sha256').update(value).digest('hex');
const hmac = (key: string | Buffer, value: string) => createHmac('sha256', key).update(value).digest();

// TC3 signs the exact UTF-8 bytes sent below; the date is UTC, not the host's timezone.
export function tencentSmsHeaders(config: TencentSmsConfig, body: string, timestamp: number) {
  const date = new Date(timestamp * 1000).toISOString().slice(0, 10);
  const signedHeaders = 'content-type;host;x-tc-action';
  const canonicalHeaders = `content-type:${contentType}\nhost:${host}\nx-tc-action:sendsms\n`;
  const canonical = `POST\n/\n\n${canonicalHeaders}\n${signedHeaders}\n${sha256(body)}`;
  const scope = `${date}/sms/tc3_request`;
  const stringToSign = `TC3-HMAC-SHA256\n${timestamp}\n${scope}\n${sha256(canonical)}`;
  const key = hmac(hmac(hmac(`TC3${config.secretKey}`, date), 'sms'), 'tc3_request');
  return {
    Authorization: `TC3-HMAC-SHA256 Credential=${config.secretId}/${scope}, SignedHeaders=${signedHeaders}, Signature=${hmac(key, stringToSign).toString('hex')}`,
    'Content-Type': contentType, Host: host, 'X-TC-Action': 'SendSms',
    'X-TC-Timestamp': String(timestamp), 'X-TC-Version': '2021-01-11', 'X-TC-Region': config.region,
    ...(config.token ? { 'X-TC-Token': config.token } : {}),
  };
}

export function createTencentSmsSender(config: TencentSmsConfig,
  options: { fetch?: typeof fetch; now?: () => number; timeoutMs?: number } = {}): SmsSender {
  const send = options.fetch ?? fetch;
  return async (mobile, code) => {
    if (!/^1[3-9]\d{9}$/.test(mobile) || !/^\d{6}$/.test(code)) throw new SmsDeliveryError('response');
    const phone = `+86${mobile}`;
    const body = JSON.stringify({ PhoneNumberSet: [phone], SmsSdkAppId: config.appId,
      TemplateId: config.templateId, SignName: config.signName,
      TemplateParamSet: config.templateParams === 'code' ? [code] : [code, '5'] });
    const signal = AbortSignal.timeout(options.timeoutMs ?? 10_000);
    try {
      // No redirects or automatic retries: an uncertain result may already have incurred a charge.
      const response = await send(`https://${host}/`, { method: 'POST', redirect: 'error', signal, body,
        headers: tencentSmsHeaders(config, body, Math.floor((options.now ?? Date.now)() / 1000)) });
      if (!response.ok) {
        await response.body?.cancel();
        throw new SmsDeliveryError('http');
      }
      if (!response.body) throw new SmsDeliveryError('response');
      const reader = response.body.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > 64 * 1024) {
            await reader.cancel();
            throw new SmsDeliveryError('response');
          }
          chunks.push(value);
        }
      } finally { reader.releaseLock(); }
      let result: any;
      try { result = JSON.parse(Buffer.concat(chunks).toString('utf8'))?.Response; }
      catch { throw new SmsDeliveryError('response'); }
      if (result?.Error) throw new SmsDeliveryError('provider');
      const statuses = result?.SendStatusSet;
      if (!Array.isArray(statuses) || statuses.length !== 1 || statuses[0]?.PhoneNumber !== phone)
        throw new SmsDeliveryError('response');
      if (statuses[0].Code !== 'Ok') throw new SmsDeliveryError('provider');
      if (typeof statuses[0].SerialNo !== 'string' || !statuses[0].SerialNo) throw new SmsDeliveryError('response');
    } catch (error) {
      if (signal.aborted) throw new SmsDeliveryError('timeout');
      if (error instanceof SmsDeliveryError) throw error;
      // Never propagate vendor messages, request bodies, credentials or transport exceptions.
      throw new SmsDeliveryError('network');
    }
  };
}
