import type { DatabaseSync, SQLInputValue } from 'node:sqlite';
import { z } from 'zod';
import type { RecordData, Store } from './database.js';
import { ApiError } from './errors.js';

export const managementActions = [
  'room.review', 'worker.save', 'worker.access', 'worker.leave.save', 'worker.leave.remove', 'worker.skills',
  'repair.assign', 'repair.priority', 'repair.shift', 'repair.dispatch', 'repair.skill',
  'repair.aftersale', 'repair.note', 'repair.reschedule.propose', 'repair.reschedule.respond', 'repair.unstaffed',
  'capacity.save', 'capacity.clear',
] as const;
export type ManagementAction = typeof managementActions[number];
export type AuditActor = { actorId: string; action: ManagementAction };
export type AuditTarget = { type: 'room' | 'repair' | 'worker' | 'capacity-default' | 'capacity-weekday' | 'capacity-date'; id: string };
type Snapshot = Record<string, unknown> | null;

/** Version 12: existing legacy records retain their provenance; no invented old snapshots. */
export function migrateManagementAudit(db: DatabaseSync) {
  // Older migration rehearsals may retain newer tables; never re-import their legacy history.
  if (db.prepare("SELECT 1 FROM sqlite_schema WHERE type='table' AND name='management_audit'").get()) {
    db.exec('PRAGMA user_version = 12;');
    return;
  }
  db.exec(`CREATE TABLE management_audit (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, actorId TEXT NOT NULL, actorRole TEXT NOT NULL,
    action TEXT NOT NULL, targetType TEXT NOT NULL, targetId TEXT NOT NULL, createdAt INTEGER NOT NULL,
    beforeJson TEXT NOT NULL CHECK(json_valid(beforeJson)), afterJson TEXT NOT NULL CHECK(json_valid(afterJson)),
    source TEXT NOT NULL CHECK(source IN ('live','legacy-account','legacy-skill-latest')));
    CREATE INDEX management_audit_actor ON management_audit(actorId,seq DESC);
    CREATE INDEX management_audit_target ON management_audit(targetType,targetId,seq DESC);
    INSERT INTO management_audit(actorId,actorRole,action,targetType,targetId,createdAt,beforeJson,afterJson,source)
      SELECT actorId,'unknown','worker.access','worker',userId,createdAt,'null',json_object('enabled',enabled),'legacy-account'
      FROM account_events ORDER BY seq;
    INSERT INTO management_audit(actorId,actorRole,action,targetType,targetId,createdAt,beforeJson,afterJson,source)
      SELECT actorId,'unknown','worker.skills','worker',workerId,COALESCE(CAST(unixepoch(changedAt)*1000 AS INTEGER),0),
        'null','null','legacy-skill-latest' FROM worker_skill_audit ORDER BY changedAt,workerId;
    CREATE TRIGGER management_audit_no_update BEFORE UPDATE ON management_audit
      BEGIN SELECT RAISE(ABORT,'management audit is append-only'); END;
    CREATE TRIGGER management_audit_no_delete BEFORE DELETE ON management_audit
      BEGIN SELECT RAISE(ABORT,'management audit is append-only'); END;
    PRAGMA user_version = 12;`);
}

const finiteNumber = (value: unknown) => typeof value === 'number' && Number.isFinite(value) ? value : null;
const enumValue = (value: unknown, choices: readonly string[]) => typeof value === 'string' && choices.includes(value) ? value : '';

/** Only decision fields, never names, phones, images, tokens, reasons or arbitrary payload keys. */
export function repairAuditSnapshot(record: RecordData): Snapshot {
  const pending = Array.isArray(record.pendings) ? record.pendings as Record<string, unknown>[] : [];
  return {
    revision: finiteNumber(record.revision ?? 0), status: finiteNumber(record.status),
    workerId: typeof record.workerId === 'string' ? record.workerId : '',
    priority: enumValue(record.priority, ['urgent', 'medium', 'light']),
    requiredSkill: enumValue(record.requiredSkill, ['plumbing', 'electrical', 'doors']),
    slot: typeof record.slot === 'string' && /^\d{4}-\d{2}-\d{2}#\d{2}$/.test(record.slot) ? record.slot : '',
    needsAdmin: record.needsAdmin === true,
    roundCount: Array.isArray(record.rounds) ? record.rounds.length : 0,
    eventCount: Array.isArray(record.timeline) ? record.timeline.length : 0,
    pendingCounts: Object.fromEntries(['reschedule', 'revoke', 'aftersale', 'feedback'].map(kind => [kind, {
      open: pending.filter(item => item?.kind === kind && !item.resolvedAt).length,
      resolved: pending.filter(item => item?.kind === kind && item.resolvedAt).length,
    }])),
  };
}

export class ManagementAudit {
  constructor(private readonly store: Store, private readonly now: () => number = Date.now) {}

  snapshot(target: AuditTarget): Snapshot {
    if (target.type === 'repair' || target.type === 'room') {
      const table = target.type === 'repair' ? 'repairs' : 'rooms';
      const row = this.store.one(`SELECT payload FROM ${table} WHERE id=?`, target.id);
      if (!row) return null;
      const record = JSON.parse(String(row.payload)) as RecordData;
      return target.type === 'repair' ? repairAuditSnapshot(record) : {
        status: finiteNumber(record.status), revision: finiteNumber(record.revision ?? 0),
      };
    }
    if (target.type === 'worker') {
      const worker = this.store.one('SELECT role,disabledAt,workforceRevision FROM users WHERE id=?', target.id);
      if (!worker) return null;
      return {
        role: worker.role, enabled: Number(worker.disabledAt) === 0, revision: Number(worker.workforceRevision),
        skills: this.store.db.prepare('SELECT skill FROM worker_skills WHERE workerId=? ORDER BY skill').all(target.id).map(row => row.skill),
        leaves: this.store.db.prepare('SELECT date,hour FROM worker_leaves WHERE workerId=? ORDER BY date,hour').all(target.id),
      };
    }
    const rows = target.type === 'capacity-default'
      ? this.store.db.prepare('SELECT hour,capacity FROM repair_capacity_defaults ORDER BY hour').all()
      : target.type === 'capacity-weekday'
        ? this.store.db.prepare('SELECT hour,capacity FROM repair_capacity_weekdays WHERE weekday=? ORDER BY hour').all(Number(target.id))
        : this.store.db.prepare('SELECT hour,capacity FROM repair_capacity_overrides WHERE date=? ORDER BY hour').all(target.id);
    return { capacities: Object.fromEntries(rows.map(row => [String(row.hour), Number(row.capacity)])) };
  }

  /** Called inside the business write transaction, so a failed log insert rolls that write back. */
  append(actor: AuditActor, target: AuditTarget, before: Snapshot, after = this.snapshot(target)) {
    if (!this.store.isInTransaction) throw new Error('Audit requires the business transaction');
    const identity = this.store.one('SELECT role,disabledAt FROM users WHERE id=?', actor.actorId);
    const ownSkills = identity?.role === 'worker' && actor.action === 'worker.skills'
      && target.type === 'worker' && target.id === actor.actorId;
    if (!identity || Number(identity.disabledAt) !== 0 || (identity.role !== 'admin' && !ownSkills)) {
      throw new ApiError(403, 40300, '无权记录此管理操作');
    }
    this.store.run(`INSERT INTO management_audit(actorId,actorRole,action,targetType,targetId,createdAt,beforeJson,afterJson,source)
      VALUES (?,?,?,?,?,?,?,?,'live')`, actor.actorId, String(identity.role), actor.action, target.type, target.id,
      this.now(), JSON.stringify(before), JSON.stringify(after));
  }

  list(actorId: string, raw: unknown) {
    const actor = this.store.one('SELECT role,disabledAt FROM users WHERE id=?', actorId);
    if (actor?.role !== 'admin' || Number(actor.disabledAt) !== 0) throw new ApiError(403, 40300, '仅物业管理员可查看操作记录');
    const id = z.string().trim().min(1).max(128);
    const input = z.object({ before: z.coerce.number().int().positive().optional(),
      limit: z.coerce.number().int().min(1).max(100).default(50), actorId: id.optional(), targetId: id.optional(),
      targetType: z.enum(['room','repair','worker','capacity-default','capacity-weekday','capacity-date']).optional(),
      action: z.enum(managementActions).optional(),
    }).strict().parse(raw);
    const clauses = ['seq < ?'];
    const values: SQLInputValue[] = [input.before ?? Number.MAX_SAFE_INTEGER];
    for (const field of ['actorId', 'targetId', 'targetType', 'action'] as const) {
      if (input[field] !== undefined) { clauses.push(`${field} = ?`); values.push(input[field]); }
    }
    const records = this.store.db.prepare(`SELECT seq,actorId,actorRole,action,targetType,targetId,createdAt,beforeJson,afterJson,source
      FROM management_audit WHERE ${clauses.join(' AND ')} ORDER BY seq DESC LIMIT ?`).all(...values, input.limit + 1);
    const rows = records.slice(0, input.limit).map(({ beforeJson, afterJson, ...record }) => ({ seq: Number(record.seq),
      actorId: String(record.actorId), actorRole: String(record.actorRole), action: String(record.action),
      targetType: String(record.targetType), targetId: String(record.targetId), createdAt: Number(record.createdAt), source: String(record.source),
      before: JSON.parse(String(beforeJson)) as Snapshot, after: JSON.parse(String(afterJson)) as Snapshot }));
    return { rows, nextCursor: records.length > input.limit ? rows.at(-1)!.seq : null };
  }
}
