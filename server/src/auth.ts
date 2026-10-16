import { createHash, randomBytes, randomInt, randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store } from './database.js';
import { ApiError, requireValue } from './errors.js';

export const mobileSchema = z.string().regex(/^1[3-9]\d{9}$/, '手机号格式不正确');
const hash = (value: string) => createHash('sha256').update(value).digest('hex');
export class AuthService {
  constructor(private readonly store: Store, private readonly now = Date.now) {}
  sendCode(raw: unknown) {
    const mobile = mobileSchema.parse(raw);
    const now = this.now();
    const old = this.store.one('SELECT sentAt FROM codes WHERE mobile = ?', mobile);
    if (old && now - Number(old.sentAt) < 60_000) throw new ApiError(429, 42900, '请等待60秒再获取验证码');
    const code = String(randomInt(0, 1_000_000)).padStart(6, '0');
    this.store.run('INSERT OR REPLACE INTO codes(mobile, hash, expires, sentAt, attempts) VALUES (?, ?, ?, ?, 0)',
      mobile, hash(`${mobile}:${code}`), now + 300_000, now);
    return { code, development: true, expiresIn: 300 };
  }
  login(raw: unknown) {
    const input = z.object({ mobile: mobileSchema, code: z.string().regex(/^\d{6}$/) }).strict().parse(raw);
    const code = this.store.one('SELECT * FROM codes WHERE mobile = ?', input.mobile);
    requireValue(code && Number(code.expires) > this.now() && Number(code.attempts) < 5, '验证码无效或已过期，请重新获取');
    if (code.hash !== hash(`${input.mobile}:${input.code}`)) {
      this.store.run('UPDATE codes SET attempts = attempts + 1 WHERE mobile = ?', input.mobile);
      throw new ApiError(200, 40002, '验证码错误');
    }
    return this.store.transaction(() => {
      this.store.run('DELETE FROM codes WHERE mobile = ?', input.mobile);
      let user = this.store.one('SELECT id FROM users WHERE mobile = ?', input.mobile);
      if (!user) {
        const id = randomUUID();
        this.store.run('INSERT INTO users(id, mobile, nickName) VALUES (?, ?, ?)', id, input.mobile, '学习用户');
        user = { id };
      }
      return this.issue(String(user.id));
    });
  }
  private issue(userId: string) {
    const token = randomBytes(32).toString('hex');
    const refreshToken = randomBytes(32).toString('hex');
    this.store.run('DELETE FROM sessions WHERE refreshExpires <= ?', this.now());
    this.store.run('INSERT INTO sessions VALUES (?, ?, ?, ?, ?)', hash(token), hash(refreshToken), userId,
      this.now() + 30 * 60_000, this.now() + 7 * 86400_000);
    const user = this.store.one('SELECT role FROM users WHERE id = ?', userId);
    return { token, refreshToken, role: user?.role ?? 'resident' };
  }
  authenticate(header: string | undefined) {
    const token = this.bearer(header);
    const session = this.store.one('SELECT userId FROM sessions WHERE accessHash = ? AND accessExpires > ?', hash(token), this.now());
    if (!session) throw new ApiError(401, 40100, '登录已失效，请重新登录');
    return String(session.userId);
  }
  refresh(header: string | undefined) {
    const token = this.bearer(header);
    return this.store.transaction(() => {
      const session = this.store.one('SELECT userId FROM sessions WHERE refreshHash = ? AND refreshExpires > ?', hash(token), this.now());
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
