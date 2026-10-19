import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store, type RecordData } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { mobileSchema } from './auth.js';

const revision = z.number().int().min(0);
const note = z.string().trim().max(1000);

/** 角色校验、房屋审核和维修人员名册。报修工单流转见 repair-service.ts。 */
export class WorkflowService {
  constructor(private readonly store: Store, private readonly now: () => number = Date.now) {}

  requireRole(userId: string, role: 'admin' | 'worker') {
    if (this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role !== role) {
      throw new ApiError(403, 40300, role === 'admin' ? '仅物业管理员可操作' : '仅维修人员可操作');
    }
  }

  role(userId: string) {
    return String(this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role ?? '');
  }

  rooms(): RecordData[] {
    return this.store.db.prepare('SELECT payload FROM rooms ORDER BY seq DESC').all()
      .map(row => JSON.parse(String(row.payload)) as RecordData);
  }

  workers() {
    return this.store.db.prepare("SELECT id, nickName, mobile FROM users WHERE role = 'worker' ORDER BY nickName").all();
  }

  saveWorker(raw: unknown) {
    const input = z.object({ mobile: mobileSchema, nickName: z.string().trim().min(2).max(20) }).strict().parse(raw);
    return this.store.transaction(() => {
      const existing = this.store.one('SELECT id, role FROM users WHERE mobile = ?', input.mobile);
      requireValue(!existing || existing.role === 'worker', '该手机号已用于其他角色，请使用独立的维修账号');
      if (existing) this.store.run('UPDATE users SET nickName = ? WHERE id = ?', input.nickName, String(existing.id));
      else this.store.run("INSERT INTO users(id, mobile, nickName, role) VALUES (?, ?, ?, 'worker')", randomUUID(), input.mobile, input.nickName);
      return this.workers();
    });
  }

  review(id: string, adminId: string, raw: unknown) {
    this.requireRole(adminId, 'admin');
    const input = z.object({ revision, decision: z.enum(['approve', 'reject']), reason: note.default('') }).strict().parse(raw);
    requireValue(input.decision !== 'reject' || input.reason.length > 0, '请填写打回原因');
    return this.store.transaction(() => {
      const row = this.store.one('SELECT userId, payload FROM rooms WHERE id = ?', id);
      if (!row) throw new ApiError(404, 40400, '记录不存在');
      const record = JSON.parse(String(row.payload)) as RecordData;
      if (Number(record.revision ?? 0) !== input.revision) throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      requireValue(record.status === 1, '只能审核待审核的资料');
      const updated = { ...record, status: input.decision === 'approve' ? 2 : 3,
        reviewReason: input.decision === 'reject' ? input.reason : '', reviewedAt: new Date(this.now()).toISOString(),
        reviewedBy: adminId, revision: input.revision + 1 };
      this.store.save('rooms', String(row.userId), updated, true);
      return updated;
    });
  }
}
