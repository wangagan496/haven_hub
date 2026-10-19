import { constants, sign } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import webpush from 'web-push';
import { z } from 'zod';
import type { Config } from './config.js';
import type { Store } from './database.js';

export type PushDevice = { platform: 'web'; subscription: webpush.PushSubscription; profileId: string }
  | { platform: 'harmony'; token: string; profileId: string };
export type PushMessage = { notificationId: string; title: string; body: string };
export type PushResult = { status: 'accepted' | 'failed' | 'expired' | 'unconfigured'; reason: string };
export interface PushTransport {
  publicConfig(): { webPublicKey: string; harmonyConfigured: boolean };
  send(device: PushDevice, message: PushMessage): Promise<PushResult>;
}

export function huaweiJwt(raw: unknown, now = Date.now()) {
  const key = z.object({ key_id: z.string().min(1), sub_account: z.string().min(1), private_key: z.string().min(1) }).parse(raw);
  const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
  const issued = Math.floor(now / 1000);
  const content = encode({ typ: 'JWT', alg: 'PS256', kid: key.key_id }) + '.' + encode({
    iss: key.sub_account, aud: 'https://oauth-login.cloud.huawei.com/oauth2/v3/token', iat: issued, exp: issued + 3600,
  });
  const signature = sign('sha256', Buffer.from(content), {
    key: key.private_key, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32,
  }).toString('base64url');
  return content + '.' + signature;
}

// 仅这两类说明 Token 本身需要重新获取；noRight、noPushTypeRight 等属于项目或权益配置问题，不删除设备。
const tokenInvalidReasons = ['tokenFormatError', 'tokenPlatformNotSupport'];

/** 解析华为 v3 messages:send 响应。官方说明：80300007 全部 Token 无效、80100000 部分成功，msg 为 JSON 字符串。 */
export function huaweiResult(httpOk: boolean, body: unknown): PushResult & { resetJwt?: boolean } {
  const parsed = z.object({ code: z.string(), msg: z.string().optional() }).safeParse(body);
  if (!parsed.success) return { status: 'failed', reason: '华为推送响应无法识别，将自动重试' };
  const { code, msg } = parsed.data;
  if (httpOk && code === '80000000') return { status: 'accepted', reason: '华为推送服务已接收，尚未确认设备送达' };
  if (code === '80200001' || code === '80200005') return { status: 'failed', reason: '华为推送鉴权失败，将重新生成令牌后重试', resetJwt: true };
  if (code === '80300007' || code === '80100000') {
    let illegal: Record<string, unknown> = {};
    try { illegal = z.object({ illegalTokens: z.record(z.string(), z.unknown()) }).parse(JSON.parse(msg ?? '')).illegalTokens; } catch { /* 按普通失败处理 */ }
    if (tokenInvalidReasons.some(reason => reason in illegal)) return { status: 'expired', reason: '设备推送标识失效，请重新开启系统通知' };
  }
  return { status: 'failed', reason: '华为推送未接受请求，请检查凭据、分类权益和设备订阅' };
}

type TransportOptions = {
  fetch?: typeof fetch;
  webPush?: (subscription: webpush.PushSubscription, payload: string, options: webpush.RequestOptions) => Promise<{ statusCode: number }>;
  log?: (event: object) => void;
};

export function createPushTransport(config: Config, store: Store, options: TransportOptions = {}): PushTransport {
  const request = options.fetch ?? fetch;
  const webPush = options.webPush ?? webpush.sendNotification;
  const log = options.log ?? (() => {});
  const keySchema = z.object({ publicKey: z.string().min(1), privateKey: z.string().min(1) });
  const saved = store.one("SELECT value FROM push_settings WHERE name='vapid'");
  const keys = saved ? keySchema.parse(JSON.parse(String(saved.value))) : webpush.generateVAPIDKeys();
  if (!saved) store.run("INSERT INTO push_settings(name,value) VALUES ('vapid',?)",JSON.stringify(keys));
  let cachedJwt = '';
  let jwtExpires = 0;
  const harmonyConfigured = Boolean(config.huaweiProjectId && config.huaweiKeyFile && existsSync(config.huaweiKeyFile));
  return {
    publicConfig: () => ({ webPublicKey: keys.publicKey, harmonyConfigured }),
    async send(device, message) {
      if (device.platform === 'web') {
        try {
          const result = await webPush(device.subscription, JSON.stringify({ ...message, profileId: device.profileId }), {
            TTL: 3600, urgency: 'normal', timeout: 10_000,
            vapidDetails: { subject: config.webPushSubject, ...keys },
          });
          return result.statusCode >= 200 && result.statusCode < 300
            ? { status: 'accepted', reason: '推送服务已接收，尚未确认设备送达' }
            : { status: 'failed', reason: '推送服务未接受请求' };
        } catch (error) {
          const code = error && typeof error === 'object' && 'statusCode' in error ? Number(error.statusCode) : 0;
          log({ event: 'web_push_failed', statusCode: code });
          return code === 404 || code === 410 ? { status: 'expired', reason: '设备订阅失效，请重新开启系统通知' }
            : { status: 'failed', reason: '浏览器推送失败，将自动重试' };
        }
      }
      if (!harmonyConfigured) return { status: 'unconfigured', reason: '鸿蒙推送服务端凭据尚未配置' };
      try {
        if (!cachedJwt || Date.now() >= jwtExpires) {
          cachedJwt = huaweiJwt(JSON.parse(readFileSync(config.huaweiKeyFile,'utf8')));
          jwtExpires = Date.now() + 3_000_000;
        }
        const response = await request('https://push-api.cloud.huawei.com/v3/' + encodeURIComponent(config.huaweiProjectId) + '/messages:send', {
          method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10_000),
          headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + cachedJwt, 'push-type': '0' },
          body: JSON.stringify({
            payload: { notification: { title: message.title, body: message.body, category: config.huaweiPushCategory,
              profileId: device.profileId, foregroundShow: true,
              clickAction: { actionType: 0, data: { notificationId: message.notificationId } } } },
            target: { token: [device.token] }, pushOptions: { testMessage: config.huaweiTestMessage, ttl: 3600 },
          }),
        });
        const body: unknown = await response.json();
        const { resetJwt, ...result } = huaweiResult(response.ok, body);
        if (resetJwt) cachedJwt = '';
        // 只记录状态码和业务码，不记录 Token、msg 原文。
        if (result.status !== 'accepted') log({ event: 'huawei_push_rejected', httpStatus: response.status, code: (body as { code?: unknown })?.code });
        return result;
      } catch (error) {
        log({ event: 'huawei_push_failed', type: error instanceof Error ? error.name : 'unknown' });
        return { status: 'failed', reason: '鸿蒙推送失败，请检查配置或网络，将自动重试' };
      }
    },
  };
}
