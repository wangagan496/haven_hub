import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store, type RecordData } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { mobileSchema } from './auth.js';

const revision = z.number().int().min(0);
const note = z.string().trim().max(1000);

export class WorkflowService {
  constructor(private readonly store: Store) {}

  requireRole(userId: string, role: 'admin' | 'worker') {
    if (this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role !== role) {
      throw new ApiError(403, 40300, role === 'admin' ? '仅物业管理员可操作' : '仅维修人员可操作');
    }
  }

  list(table: 'rooms' | 'repairs', workerId?: string): RecordData[] {
    const rows = this.store.db.prepare(`SELECT payload FROM ${table} ORDER BY seq DESC`).all();
    return rows.map(row => JSON.parse(String(row.payload)) as RecordData)
      .filter(row => !workerId || row.workerId === workerId);
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

  private ownedRecord(table: 'rooms' | 'repairs', id: string) {
    const row = this.store.one(`SELECT userId, payload FROM ${table} WHERE id = ?`, id);
    if (!row) throw new ApiError(404, 40400, '记录不存在');
    return { owner: String(row.userId), record: JSON.parse(String(row.payload)) as RecordData };
  }

  private checkRevision(record: RecordData, expected: number) {
    if (Number(record.revision ?? 0) !== expected) throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
  }

  review(id: string, adminId: string, raw: unknown) {
    this.requireRole(adminId, 'admin');
    const input = z.object({ revision, decision: z.enum(['approve', 'reject']), reason: note.default('') }).strict().parse(raw);
    requireValue(input.decision !== 'reject' || input.reason.length > 0, '请填写打回原因');
    return this.store.transaction(() => {
      const { owner, record } = this.ownedRecord('rooms', id);
      this.checkRevision(record, input.revision);
      requireValue(record.status === 1, '只能审核待审核的资料');
      const updated = { ...record, status: input.decision === 'approve' ? 2 : 3,
        reviewReason: input.decision === 'reject' ? input.reason : '', reviewedAt: new Date().toISOString(),
        reviewedBy: adminId, revision: input.revision + 1 };
      this.store.save('rooms', owner, updated, true);
      return updated;
    });
  }

  assign(id: string, adminId: string, raw: unknown) {
    this.requireRole(adminId, 'admin');
    const input = z.object({ revision, workerId: z.string().uuid() }).strict().parse(raw);
    return this.store.transaction(() => {
      const { owner, record } = this.ownedRecord('repairs', id);
      this.checkRevision(record, input.revision);
      requireValue(record.status === 1 || record.status === 5, '只能对未接单的报修派单');
      const worker = this.store.one("SELECT id, nickName, mobile FROM users WHERE id = ? AND role = 'worker'", input.workerId);
      requireValue(worker, '请选择有效的维修人员');
      const at = new Date().toISOString();
      const updated = { ...record, workflowVersion: 1, status: 5, revision: input.revision + 1,
        workerId: input.workerId, workerName: String(worker.nickName), workerMobile: String(worker.mobile),
        assignedAt: at, timeline: [...this.events(record), { action: 'assigned', label: '物业派单',
          detail: `指派给${worker.nickName}`, at }] };
      this.store.save('repairs', owner, updated, true);
      return updated;
    });
  }

  workerDetail(id: string, workerId: string) {
    this.requireRole(workerId, 'worker');
    const { record } = this.ownedRecord('repairs', id);
    if (record.workerId !== workerId) throw new ApiError(404, 40400, '工单不存在或未指派给你');
    return record;
  }

  process(id: string, workerId: string, action: 'accept' | 'complete', raw: unknown) {
    this.requireRole(workerId, 'worker');
    const input = z.object({ revision, result: note.default('') }).strict().parse(raw);
    return this.store.transaction(() => {
      const { owner, record } = this.ownedRecord('repairs', id);
      if (record.workerId !== workerId) throw new ApiError(404, 40400, '工单不存在或未指派给你');
      this.checkRevision(record, input.revision);
      requireValue(record.status === (action === 'accept' ? 5 : 2), action === 'accept' ? '该工单已不在待接单状态' : '仅能完成已接单的工单');
      requireValue(action !== 'complete' || input.result.length > 0, '请填写处理结果后再完成维修');
      const at = new Date().toISOString();
      const updated = { ...record, revision: input.revision + 1, status: action === 'accept' ? 2 : 3,
        ...(action === 'accept' ? { acceptedAt: at } : { completedAt: at, completionNote: input.result }),
        timeline: [...this.events(record), { action, label: action === 'accept' ? '处理中' : '已完成', at,
          detail: action === 'accept' ? `${record.workerName}已接单` : input.result }] };
      this.store.save('repairs', owner, updated, true);
      return updated;
    });
  }

  private events(record: RecordData): unknown[] { return Array.isArray(record.timeline) ? record.timeline : []; }
}
