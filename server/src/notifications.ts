import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Store, RecordData } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { notificationKind, repairNotificationTasks } from './repair/notification-tasks.js';
import type { PushTransport, PushDevice } from './push-transport.js';

const hash = (s: string) => createHash('sha256').update(s).digest('hex');
const installation = z.string().regex(/^[a-f0-9]{64}$/);
const registration = z.discriminatedUnion('platform', [
  z.object({ platform: z.literal('web'), installationId: installation, subscription: z.object({
    endpoint: z.url().max(4096), keys: z.object({ p256dh: z.string().regex(/^[A-Za-z0-9_-]{87,88}$/), auth: z.string().regex(/^[A-Za-z0-9_-]{22,24}$/) }).strict(),
  }).strict() }).strict(),
  z.object({ platform: z.literal('harmony'), installationId: installation, token: z.string().min(1).max(4096) }).strict(),
]);

export function validatePushEndpoint(endpoint: string) {
  const url = new URL(endpoint);
  const host = url.hostname.toLowerCase();
  const valid = host === 'fcm.googleapis.com' || host === 'updates.push.services.mozilla.com'
    || host === 'web.push.apple.com' || host.endsWith('.notify.windows.com');
  if (!valid || url.protocol !== 'https:' || url.port || url.username || url.password || url.hash) {
    throw new ApiError(200, 40000, '不支持此浏览器推送地址');
  }
}

export const MAX_ATTEMPTS = 5;
export const REMIND_INTERVAL_MS = 60_000;
// 实际推送请求超时为10秒；领取保留60秒，供进程中断后的定时恢复使用。
export const DELIVERY_LEASE_MS = 60_000;
const STOPPED_REASON = '已停止自动重试，请手动重试';

export class Notifications {
  private running: Promise<void> | undefined;
  private stopped = false;
  constructor(private readonly store: Store, private readonly transport: PushTransport, private readonly now = Date.now,
    private readonly log: (event: object) => void = () => {}) {
    this.recoverExpiredDeliveries();
  }

  config(userId: string) { return { ...this.transport.publicConfig(), profileId: hash('haven-push:' + userId) }; }

  /**
   * 按工单当前状态生成或关闭待办。在保存点里执行：待办写入失败只回滚待办本身，
   * 不影响调用方的工单保存。返回 false 表示本次同步失败，待下次保存或启动时重算。
   */
  sync(owner: string, record: RecordData): boolean {
    try {
      this.store.savepoint(() => this.syncTasks(owner, record));
      return true;
    } catch (error) {
      this.log({ event: 'notification_sync_failed', repairId: record.id, type: error instanceof Error ? error.name : 'unknown' });
      return false;
    }
  }

  private syncTasks(owner: string, record: RecordData) {
    const admins = this.store.db.prepare("SELECT id FROM users WHERE role = 'admin' AND disabledAt=0").all().map(row => String(row.id));
    const tasks = repairNotificationTasks(record, owner, admins).filter(task => {
      const user = this.store.one('SELECT disabledAt FROM users WHERE id=?', task.userId);
      // Missing users are corrupt data, not intentionally disabled recipients.
      if (!user) throw new Error('Notification recipient missing');
      return Number(user.disabledAt) === 0;
    });
    this.store.transaction(() => {
      const existing = this.store.db.prepare('SELECT id,userId,taskKey,active FROM notifications WHERE repairId = ?').all(record.id);
      for (const old of existing) {
        if (old.active && !tasks.some(task => task.userId === old.userId && task.key === old.taskKey)) {
          this.store.run('UPDATE notifications SET active = 0 WHERE id = ?', String(old.id));
          this.store.run("UPDATE push_deliveries SET status = 'cancelled' WHERE notificationId = ? AND status IN ('queued','failed','sending','unconfigured')", String(old.id));
        }
      }
      for (const task of tasks) {
        const old = existing.find(row => row.userId === task.userId && row.taskKey === task.key);
        if (old?.active) continue;
        const id = old ? String(old.id) : randomUUID();
        // 生成即视为第一次提醒，"每分钟最多提醒一次"从这里起算。
        if (old) this.store.run('UPDATE notifications SET active = 1, readAt = NULL, createdAt = ?, remindedAt = ? WHERE id = ?', this.now(), this.now(), id);
        else this.store.run('INSERT INTO notifications(id,userId,repairId,taskKey,role,title,body,active,createdAt,remindedAt) VALUES (?,?,?,?,?,?,?,1,?,?)',
          id, task.userId, record.id, task.key, task.role, task.title, task.body, this.now(), this.now());
        this.queue(id, task.userId);
      }
    });
  }

  private queue(notificationId: string, userId: string) {
    for (const device of this.store.db.prepare('SELECT id FROM push_devices WHERE userId = ?').all(userId)) {
      this.store.run("INSERT INTO push_deliveries(notificationId,deviceId,status,nextAt) VALUES (?,?,'queued',?) ON CONFLICT(notificationId,deviceId) DO UPDATE SET status='queued',attempts=0,nextAt=excluded.nextAt,reason='',lease=''",
        notificationId, String(device.id), this.now());
    }
  }

  register(userId: string, raw: unknown) {
    const input = registration.parse(raw);
    if (input.platform === 'web') validatePushEndpoint(input.subscription.endpoint);
    const endpoint = input.platform === 'web' ? input.subscription.endpoint : input.token;
    const id = hash(input.installationId);
    const endpointHash = hash(endpoint);
    const payload: PushDevice = input.platform === 'web' ? { platform: 'web', subscription: input.subscription, profileId: this.config(userId).profileId }
      : { platform: 'harmony', token: input.token, profileId: this.config(userId).profileId };
    this.store.transaction(() => {
      const old = this.store.db.prepare('SELECT id,userId,endpointHash,payload FROM push_devices WHERE id = ? OR endpointHash = ?').all(id, endpointHash);
      // 同一安装（installationId 相同）换账号属于正常转移；不同安装拿同一 endpoint/token 登记到另一个账号，
      // 不能顶掉原账号的绑定。原账号退出登录会先解绑，之后即可登记。
      requireValue(!old.some(item => item.id !== id && item.userId !== userId),
        '此设备的系统通知仍绑定在其他账号，请先在该账号退出登录或停用本机推送');
      for (const item of old) {
        if (item.userId !== userId || item.id !== id || item.endpointHash !== endpointHash || item.payload !== JSON.stringify(payload)) {
          this.store.run('DELETE FROM push_deliveries WHERE deviceId = ?', String(item.id));
          this.store.run('DELETE FROM push_devices WHERE id = ?', String(item.id));
        }
      }
      const count = Number(this.store.one('SELECT COUNT(*) AS count FROM push_devices WHERE userId = ?', userId)?.count ?? 0);
      if (count >= 10 && !this.store.one('SELECT id FROM push_devices WHERE id = ?', id)) throw new ApiError(429,42900,'此账号登记设备过多');
      this.store.run('INSERT INTO push_devices(id,userId,platform,endpointHash,payload,updatedAt) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET userId=excluded.userId,platform=excluded.platform,endpointHash=excluded.endpointHash,payload=excluded.payload,updatedAt=excluded.updatedAt',
        id, userId, input.platform, endpointHash, JSON.stringify(payload), this.now());
      for (const note of this.store.db.prepare('SELECT id FROM notifications WHERE userId = ? AND active = 1').all(userId)) {
        this.store.run("INSERT INTO push_deliveries(notificationId,deviceId,status,nextAt) VALUES (?,?,'queued',?) ON CONFLICT(notificationId,deviceId) DO UPDATE SET status='queued',attempts=0,nextAt=excluded.nextAt,reason='',lease='' WHERE push_deliveries.status IN ('expired','unconfigured')", String(note.id),id,this.now());
      }
    });
    return { registered: true };
  }

  unregister(raw: unknown) {
    // The random installation secret only permits revoking that installation, even after auth expiry.
    const input = z.object({ installationId: installation }).strict().parse(raw);
    const id = hash(input.installationId);
    this.store.transaction(() => {
      this.store.run('DELETE FROM push_deliveries WHERE deviceId = ?', id);
      this.store.run('DELETE FROM push_devices WHERE id = ?', id);
    });
    return { removed: true };
  }

  list(userId: string) {
    return this.store.db.prepare(`SELECT id,repairId,taskKey,role,title,body,active,createdAt,readAt FROM notifications
      WHERE userId = ? ORDER BY active DESC,
      CASE WHEN active = 1 AND (taskKey IN ('urgent_dispatch', 'urgent_request') OR taskKey LIKE 'staffing:%') THEN 0 ELSE 1 END, createdAt DESC LIMIT 100`).all(userId).map(note => ({
      id: String(note.id), repairId: String(note.repairId), role: String(note.role), title: String(note.title),
      body: String(note.body), active: Number(note.active), createdAt: Number(note.createdAt), readAt: note.readAt,
      kind: notificationKind(String(note.taskKey)),
      deliveries: this.store.db.prepare('SELECT status,attempts,reason FROM push_deliveries WHERE notificationId = ?').all(String(note.id))
        // stopped：失败次数已到上限，不会再自动重试，只能手动重试。
        .map(item => ({ status: String(item.status), attempts: Number(item.attempts), reason: String(item.reason),
          stopped: item.status === 'failed' && Number(item.attempts) >= MAX_ATTEMPTS })),
    }));
  }

  read(userId: string, id: string) {
    const note = this.store.one('SELECT id,repairId,role,active FROM notifications WHERE id = ? AND userId = ?', id, userId);
    if (!note) throw new ApiError(404,40400,'通知不存在或不属于当前账号');
    this.store.run('UPDATE notifications SET readAt = ? WHERE id = ? AND userId = ?',this.now(),id,userId);
    return note;
  }

  remind(userId: string, repairId: string) {
    const row = this.store.one('SELECT userId,payload FROM repairs WHERE id = ?', repairId);
    const role = this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role;
    const record = row ? JSON.parse(String(row.payload)) as RecordData : undefined;
    if (!record || (row?.userId !== userId && record.workerId !== userId && role !== 'admin')) throw new ApiError(404,40400,'工单不存在或无权访问');
    const notes = this.store.db.prepare('SELECT id,userId,remindedAt FROM notifications WHERE repairId = ? AND active = 1 AND userId != ?').all(repairId,userId);
    requireValue(notes.length, '当前没有等待对方处理的事项');
    if (notes.some(note => this.now() - Number(note.remindedAt) < REMIND_INTERVAL_MS)) throw new ApiError(429,42900,'已提醒，请一分钟后再试');
    this.store.transaction(() => { for (const note of notes) {
      this.queue(String(note.id),String(note.userId));
      this.store.run('UPDATE notifications SET remindedAt = ? WHERE id = ?',this.now(),String(note.id));
    } });
    return { queued: notes.length, message: '已加入提醒队列，送达以设备实际通知为准' };
  }

  retry(userId: string, id: string) {
    const note = this.store.one('SELECT remindedAt FROM notifications WHERE id = ? AND userId = ? AND active = 1',id,userId);
    if (!note) throw new ApiError(404,40400,'待办不存在或已处理');
    if (this.now() - Number(note.remindedAt) < REMIND_INTERVAL_MS) throw new ApiError(429,42900,'请一分钟后再试');
    this.queue(id,userId);
    this.store.run('UPDATE notifications SET remindedAt = ? WHERE id = ?',this.now(),id);
    return { queued: true };
  }

  dispatch(): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (this.running) return this.running;
    this.running = this.sendBatch().finally(() => { this.running = undefined; });
    return this.running;
  }

  private async sendBatch() {
    this.recoverExpiredDeliveries();
    const rows = this.store.db.prepare("SELECT d.notificationId,d.deviceId,p.payload FROM push_deliveries d JOIN notifications n ON n.id=d.notificationId JOIN push_devices p ON p.id=d.deviceId AND p.userId=n.userId WHERE n.active=1 AND d.status IN ('queued','failed') AND d.attempts < ? AND d.nextAt <= ? LIMIT 20").all(MAX_ATTEMPTS, this.now());
    for (const row of rows) {
      if (this.stopped) return;
      const notificationId = String(row.notificationId), deviceId = String(row.deviceId);
      // BEGIN IMMEDIATE 将资格检查与领取串行化；不跨网络等待持有数据库事务。
      const claim = this.store.transaction(() => {
        const current = this.store.one("SELECT n.title,n.body,p.payload,d.attempts FROM push_deliveries d JOIN notifications n ON n.id=d.notificationId JOIN push_devices p ON p.id=d.deviceId AND p.userId=n.userId WHERE d.notificationId=? AND d.deviceId=? AND n.active=1 AND d.status IN ('queued','failed') AND d.attempts < ? AND d.nextAt <= ?", notificationId, deviceId, MAX_ATTEMPTS, this.now());
        // 上一条发送期间设备可能已换号/换Token，退避或尝试次数也可能已改变。
        if (!current || current.payload !== row.payload) return;
        const lease = randomUUID();
        this.store.run("UPDATE push_deliveries SET status='sending',attempts=attempts+1,lease=?,nextAt=? WHERE notificationId=? AND deviceId=?", lease, this.now() + DELIVERY_LEASE_MS, notificationId, deviceId);
        return { payload: String(current.payload), title: String(current.title), body: String(current.body),
          attempts: Number(current.attempts) + 1, lease };
      });
      if (!claim) continue;
      const result = await this.transport.send(JSON.parse(claim.payload) as PushDevice, {
        notificationId, title: claim.title, body: claim.body,
      }).catch(error => {
        this.log({ event: 'push_send_failed', type: error instanceof Error ? error.name : 'unknown' });
        return { status: 'failed' as const, reason: '发送失败，将自动重试' };
      });
      if (this.stopped) return;
      this.store.transaction(() => {
        // 完成确认与设备清理使用同一事务、同一领取标识，迟到响应不能覆盖新任务。
        const pending = this.store.one("SELECT p.payload FROM push_deliveries d JOIN notifications n ON n.id=d.notificationId JOIN push_devices p ON p.id=d.deviceId AND p.userId=n.userId WHERE d.notificationId=? AND d.deviceId=? AND n.active=1 AND d.status='sending' AND d.lease=?", notificationId, deviceId, claim.lease);
        if (pending?.payload !== claim.payload) return;
        const reason = result.status === 'failed' && claim.attempts >= MAX_ATTEMPTS ? STOPPED_REASON : result.reason;
        this.store.run("UPDATE push_deliveries SET status=?,reason=?,nextAt=?,lease='' WHERE notificationId=? AND deviceId=? AND status='sending' AND lease=?",result.status,reason,
          this.now() + Math.min(60_000 * 2 ** (claim.attempts - 1),3_600_000),notificationId,deviceId,claim.lease);
        if (result.status !== 'expired') return;
        // 订阅失效：删除设备及其其他投递，只保留本条 expired 记录供界面提示"需要重新开启"。
        const removed = this.store.run('DELETE FROM push_devices WHERE id=? AND payload=?',deviceId,claim.payload);
        if (Number(removed.changes) > 0) {
          this.store.run('DELETE FROM push_deliveries WHERE deviceId=? AND notificationId != ?',deviceId,notificationId);
        }
      });
    }
  }

  private recoverExpiredDeliveries() {
    // sending 时 nextAt 是领取截止时刻；其他状态下仍为下次尝试时刻。
    // 包括旧版无领取标识、已过期的行；达到上限仍保留为可手动重试的failed。
    this.store.run("UPDATE push_deliveries SET status='failed',lease='',reason=CASE WHEN attempts >= ? THEN ? ELSE ? END WHERE status='sending' AND nextAt <= ?",
      MAX_ATTEMPTS, STOPPED_REASON, '上次发送结果未确认，将重试', this.now());
  }

  async stop() { this.stopped = true; await this.running; }
}
