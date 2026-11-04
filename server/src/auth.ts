import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { SmsDeliveryError, type SmsSender } from './sms.js';

export const mobileSchema = z.string().regex(/^1[3-9]\d{9}$/, '手机号格式不正确');
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
export type AuthOptions = { mode: 'development' } | {
  mode: 'tencent'; sender: SmsSender; hourlyLimit: number; dailyLimit: number; globalDailyLimit: number;
  log?: (event: object) => void;
};
export class AuthService {
  constructor(private readonly store: Store, private readonly now = Date.now,
    private readonly options: AuthOptions = { mode: 'development' }) {}
  async sendCode(raw: unknown) {
    const mobile = mobileSchema.parse(raw);
    const now = this.now();
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    const codeHash = hash(`${mobile}:${code}`);
    this.store.transaction(() => {
      this.requireEnabled(mobile);
      const old = this.store.one('SELECT sentAt FROM codes WHERE mobile = ?', mobile);
      if (old && now - Number(old.sentAt) < 60_000) throw new ApiError(429, 42900, '请等待60秒再获取验证码');
      if (this.options.mode === 'tencent') {
        const mobileHash = hash(mobile);
        const lastAttempt = this.store.one('SELECT sentAt FROM sms_send_attempts WHERE mobileHash=? ORDER BY sentAt DESC LIMIT 1', mobileHash);
        if (lastAttempt && now - Number(lastAttempt.sentAt) < 60_000)
          throw new ApiError(429, 42900, '请等待60秒再获取验证码');
        const dailyStart = now - 86400_000;
        const globalCount = Number(this.store.one('SELECT COUNT(*) AS n FROM sms_send_attempts WHERE sentAt>?', dailyStart)!.n);
        const mobileCount = this.store.one(`SELECT COUNT(*) AS daily,
          COALESCE(SUM(sentAt>?),0) AS hourly FROM sms_send_attempts WHERE mobileHash=? AND sentAt>?`, now - 3600_000, mobileHash, dailyStart)!;
        if (globalCount >= this.options.globalDailyLimit || Number(mobileCount.daily) >= this.options.dailyLimit ||
            Number(mobileCount.hourly) >= this.options.hourlyLimit)
          throw new ApiError(429, 42900, '短信请求次数已达上限，请稍后重试或联系物业');
        this.store.run('DELETE FROM sms_send_attempts WHERE sentAt<=?', dailyStart);
        this.store.run('INSERT INTO sms_send_attempts(mobileHash,sentAt) VALUES (?,?)', mobileHash, now);
      }
      // Pending codes cannot log in. Reservations and charged/uncertain attempts survive restart.
      this.store.run('INSERT OR REPLACE INTO codes(mobile,hash,expires,sentAt,attempts,authMode) VALUES (?,?,?,?,0,?)',
        mobile, codeHash, this.options.mode === 'development' ? now + 300_000 : 0, now, this.options.mode);
    });
    if (this.options.mode === 'development') return { code, development: true, expiresIn: 300 };
    try { await this.options.sender(mobile, code); }
    catch (error) {
      this.options.log?.({ event: 'sms_send_failed', reason: error instanceof SmsDeliveryError ? error.reason : 'network' });
      throw new ApiError(503, 50301, '验证码发送未确认，请稍后重新获取');
    }
    this.store.transaction(() => {
      this.requireEnabled(mobile);
      // A late result must not revive a replaced/deleted challenge or a stopped account.
      const updated = this.store.run(`UPDATE codes SET expires=? WHERE mobile=? AND hash=? AND sentAt=? AND authMode='tencent' AND expires=0`,
        this.now() + 300_000, mobile, codeHash, now);
      if (Number(updated.changes) !== 1) throw new ApiError(409, 40901, '验证码请求已更新，请使用最新验证码');
    });
    return { development: false, expiresIn: 300 };
  }
  login(raw: unknown) {
    const input = z.object({ mobile: mobileSchema, code: z.string().regex(/^\d{6}$/) }).strict().parse(raw);
    const result = this.store.transaction(() => {
      this.requireEnabled(input.mobile);
      const code = this.store.one('SELECT * FROM codes WHERE mobile = ? AND authMode=?', input.mobile, this.options.mode);
      requireValue(code && Number(code.expires) > this.now() && Number(code.attempts) < 5, '验证码无效或已过期，请重新获取');
      if (code.hash !== hash(`${input.mobile}:${input.code}`)) {
        this.store.run('UPDATE codes SET attempts = attempts + 1 WHERE mobile = ?', input.mobile);
        // Throw after commit: throwing here would undo the failed-attempt counter.
        return new ApiError(200, 40002, '验证码错误');
      }
      this.store.run('DELETE FROM codes WHERE mobile = ?', input.mobile);
      let user = this.store.one('SELECT id FROM users WHERE mobile = ?', input.mobile);
      if (!user) {
        const id = randomUUID();
        this.store.run('INSERT INTO users(id, mobile, nickName) VALUES (?, ?, ?)', id, input.mobile,
          this.options.mode === 'development' ? '学习用户' : '住户');
        user = { id };
      }
      return this.issue(String(user.id));
    });
    if (result instanceof ApiError) throw result;
    return result;
  }
  private requireEnabled(mobile: string) {
    if (Number(this.store.one('SELECT disabledAt FROM users WHERE mobile=?', mobile)?.disabledAt ?? 0) > 0)
      throw new ApiError(403, 40301, '账号已停用，请联系物业');
  }
  private issue(userId: string) {
    const user = this.store.one('SELECT role,disabledAt FROM users WHERE id=?', userId);
    if (!user || Number(user.disabledAt) > 0) throw new ApiError(403, 40301, '账号已停用，请联系物业');
    const token = randomBytes(32).toString('hex');
    const refreshToken = randomBytes(32).toString('hex');
    this.store.run('DELETE FROM sessions WHERE refreshExpires <= ?', this.now());
    this.store.run('INSERT INTO sessions(accessHash,refreshHash,userId,accessExpires,refreshExpires,authMode) VALUES (?, ?, ?, ?, ?, ?)', hash(token), hash(refreshToken), userId,
      this.now() + 30 * 60_000, this.now() + 7 * 86400_000, this.options.mode);
    return { token, refreshToken, role: user?.role ?? 'resident' };
  }
  authenticate(header: string | undefined) {
    const token = this.bearer(header);
    const session = this.store.one('SELECT s.userId FROM sessions s JOIN users u ON u.id=s.userId WHERE s.accessHash=? AND s.accessExpires>? AND u.disabledAt=0 AND s.authMode=?', hash(token), this.now(), this.options.mode);
    if (!session) throw new ApiError(401, 40100, '登录已失效，请重新登录');
    return String(session.userId);
  }
  refresh(header: string | undefined) {
    const token = this.bearer(header);
    return this.store.transaction(() => {
      const session = this.store.one('SELECT userId FROM sessions WHERE refreshHash = ? AND refreshExpires > ? AND authMode=?', hash(token), this.now(), this.options.mode);
      if (!session) throw new ApiError(401, 40100, '刷新凭证已失效');
      this.store.run('DELETE FROM sessions WHERE refreshHash = ?', hash(token));
      return this.issue(String(session.userId));
    });
  }
  private bearer(header: string | undefined) {
    if (!header || !/^Bearer [a-f0-9]{64}$/.test(header)) throw new ApiError(401, 40100, '请先登录');
    return header.slice(7);
  }
}
