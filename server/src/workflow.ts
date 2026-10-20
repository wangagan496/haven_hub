import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import { Store, type RecordData } from './database.js';
import { ApiError, requireValue } from './errors.js';
import { mobileSchema } from './auth.js';
import { scheduleRules, validDate } from './repair/schedule.js';
import { inRepairPool, readWorkforce, StaffingContext, workforceOrderSummary } from './repair/workforce.js';
import { workforceImpact } from './repair/workforce-change.js';

const revision = z.number().int().min(0);
const note = z.string().trim().max(1000);
const leaveDate = z.string().refine(validDate, '休假日期无效');
const leaveHour = z.string().refine(value => value === '' || scheduleRules.hours.some(hour => String(hour).padStart(2, '0') === value), '休假时段无效').default('');

/** 角色校验、房屋审核和维修人员名册。报修工单流转见 repair/service.ts。 */
export class WorkflowService {
  constructor(private readonly store: Store, private readonly now: () => number = Date.now,
    private readonly workforceChanged: () => void = () => {}) {}

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
    const rows = this.store.db.prepare("SELECT id, nickName, mobile, workforceRevision AS revision FROM users WHERE role = 'worker' ORDER BY nickName").all();
    return rows.map(row => ({ ...row, id: String(row.id), revision: Number(row.revision),
      skillChange: this.store.one('SELECT actorId, actorName, changedAt FROM worker_skill_audit WHERE workerId=?', String(row.id)) ?? null,
      skills: this.store.db.prepare('SELECT skill FROM worker_skills WHERE workerId=? ORDER BY skill').all(String(row.id)).map(item => String(item.skill)),
      leaves: this.store.db.prepare('SELECT date,hour,reason FROM worker_leaves WHERE workerId=? ORDER BY date,hour').all(String(row.id)),
    }));
  }

  workforceSummary() {
    return { unregisteredCount: Number(this.store.one("SELECT COUNT(*) AS count FROM users u WHERE role='worker' AND NOT EXISTS (SELECT 1 FROM worker_skills s WHERE s.workerId=u.id)")!.count) };
  }

  saveWorker(raw: unknown) {
    const input = z.object({ mobile: mobileSchema, nickName: z.string().trim().min(2).max(20),
      revision: revision.optional() }).strict().parse(raw);
    return this.store.transaction(() => {
      const existing = this.store.one('SELECT id, role FROM users WHERE mobile = ?', input.mobile);
      requireValue(!existing || existing.role === 'worker', '该手机号已用于其他角色，请使用独立的维修账号');
      if (existing) {
        this.checkWorkforceRevision(String(existing.id), input.revision);
        this.store.run('UPDATE users SET nickName = ?, workforceRevision=workforceRevision+1 WHERE id = ?', input.nickName, String(existing.id));
      }
      else this.store.run("INSERT INTO users(id, mobile, nickName, role) VALUES (?, ?, ?, 'worker')", randomUUID(), input.mobile, input.nickName);
      this.workforceChanged();
      return this.workers();
    });
  }

  saveLeave(workerId: string, raw: unknown) {
    const input = z.object({ revision, date: leaveDate, hour: leaveHour, reason: note.default(''), preview: z.boolean().default(false) }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.revision);
      const worker = readWorkforce(this.store).find(item => item.id === workerId)!;
      const impact = this.calculateImpact({ ...worker, leaves: [...worker.leaves, { date: input.date, hour: input.hour }] });
      if (input.preview) return this.previewImpact(impact);
      this.store.run('INSERT INTO worker_leaves(workerId,date,hour,reason) VALUES (?,?,?,?) ON CONFLICT(workerId,date,hour) DO UPDATE SET reason=excluded.reason', workerId, input.date, input.hour, input.reason);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      this.saveImpact(impact);
      this.workforceChanged();
      return this.workers();
    });
  }

  workerSkills(workerId: string) {
    this.requireRole(workerId, 'worker');
    const worker = this.workers().find(item => item.id === workerId)!;
    return { skills: worker.skills, workforceRevision: Number(worker.revision), skillChange: worker.skillChange };
  }

  saveSkills(workerId: string, raw: unknown, actorId = workerId) {
    this.requireRole(actorId, actorId === workerId ? 'worker' : 'admin');
    const input = z.object({ workforceRevision: revision, skills: z.array(z.enum(['plumbing', 'electrical', 'doors'])).max(3),
      preview: z.boolean().default(false) }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.workforceRevision);
      const worker = readWorkforce(this.store).find(item => item.id === workerId)!;
      const skills = [...new Set(input.skills)];
      if (actorId !== workerId) requireValue(skills.every(skill => worker.skills.includes(skill)), '物业只能撤销已登记技能');
      // 本次保存会写入审计记录；预览也按保存后的已登记状态计算。
      const impact = this.calculateImpact({ ...worker, skills, skillsKnown: true });
      if (input.preview) return this.previewImpact(impact, actorId === workerId);
      this.store.run('DELETE FROM worker_skills WHERE workerId=?', workerId);
      for (const skill of skills) this.store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)', workerId, skill);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      const actor = this.store.one('SELECT nickName FROM users WHERE id=?', actorId)!;
      this.store.run('INSERT INTO worker_skill_audit(workerId,actorId,actorName,changedAt) VALUES (?,?,?,?) ON CONFLICT(workerId) DO UPDATE SET actorId=excluded.actorId,actorName=excluded.actorName,changedAt=excluded.changedAt',
        workerId, actorId, String(actor.nickName), new Date(this.now()).toISOString());
      this.saveImpact(impact);
      this.workforceChanged();
      return this.workerSkills(workerId);
    });
  }

  private calculateImpact(worker: ReturnType<typeof readWorkforce>[number]) {
    const rows = this.store.db.prepare('SELECT payload FROM repairs WHERE json_valid(payload)').all();
    const records = rows.map(row => JSON.parse(String(row.payload)) as RecordData)
      .filter(record => record && typeof record === 'object' && !Array.isArray(record));
    const impact = workforceImpact(records, worker, this.now());
    const replacements = new Map(impact.returned.map(record => [record.id, record]));
    const workers = readWorkforce(this.store);
    const before = new Map(new StaffingContext(workers, records).shortages().map(item => [item.slot, item.shortage]));
    const context = new StaffingContext(workers.map(current => current.id === worker.id ? worker : current),
      records.map(record => replacements.get(record.id) ?? record));
    const propertyIds = new Set(impact.property.map(record => record.id));
    for (const record of impact.returned) {
      if (!propertyIds.has(record.id) && inRepairPool(record) && !context.eligible(record).length) {
        impact.property.push(record);
        propertyIds.add(record.id);
      }
    }
    return { ...impact, shortages: context.shortages().filter(item => item.shortage > (before.get(item.slot) ?? 0)) };
  }

  private previewImpact(impact: ReturnType<WorkflowService['calculateImpact']>, hideIds = false) {
    const summary = (record: RecordData) => {
      const value = workforceOrderSummary(record);
      if (!hideIds) return value;
      const { id: _id, ...visible } = value;
      return visible;
    };
    return { returned: impact.returned.map(summary), property: impact.property.map(summary),
      shortages: impact.shortages.map(item => ({ ...item, orders: item.orders.map(summary) })) };
  }

  private saveImpact(impact: ReturnType<typeof workforceImpact>) {
    for (const record of impact.returned) {
      const owner = this.store.one('SELECT userId FROM repairs WHERE id=?', record.id)!;
      record.revision = Number(record.revision ?? 0) + 1;
      this.store.save('repairs', String(owner.userId), record, true);
    }
  }

  removeLeave(workerId: string, raw: unknown) {
    const input = z.object({ revision, date: leaveDate, hour: leaveHour }).strict().parse(raw);
    return this.store.transaction(() => {
      this.checkWorkforceRevision(workerId, input.revision);
      this.store.run('DELETE FROM worker_leaves WHERE workerId=? AND date=? AND hour=?', workerId, input.date, input.hour);
      this.store.run('UPDATE users SET workforceRevision=workforceRevision+1 WHERE id=?', workerId);
      this.workforceChanged();
      return this.workers();
    });
  }

  private checkWorkforceRevision(workerId: string, expected: number | undefined) {
    const worker = this.store.one("SELECT workforceRevision FROM users WHERE id=? AND role='worker'", workerId);
    if (!worker) throw new ApiError(404, 40400, '维修人员不存在');
    if (expected !== Number(worker.workforceRevision)) throw new ApiError(409, 40900, '人员安排已更新，请刷新后再操作');
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
