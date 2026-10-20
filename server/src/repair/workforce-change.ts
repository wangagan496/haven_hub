import type { RecordData } from '../database.js';
import { release } from './actions.js';
import { events, openPending, Status, voidReschedule } from './model.js';
import { parseSlot, scheduleRules, type WorkerAvailability } from './schedule.js';
import { holdingEligibility } from './workforce.js';

/** 预览与保存使用完全相同的纯计算；不改变输入工单。 */
export function workforceImpact(records: readonly RecordData[], worker: WorkerAvailability, now: number) {
  const returned: RecordData[] = [];
  const property: RecordData[] = [];
  for (const original of records) {
    if (original.workerId !== worker.id || ![Status.assigned, Status.processing].includes(Number(original.status) as 2 | 5)) continue;
    const why = holdingEligibility(worker, original, String(original.slot ?? ''));
    if (!why) continue;
    const start = parseSlot(original.slot)?.startsAt ?? Date.parse(String(original.agreedTime ?? ''));
    if (Number.isFinite(start) && start <= now) { property.push(structuredClone(original)); continue; }
    const record = structuredClone(original);
    const proposal = openPending(record, 'reschedule');
    if (proposal?.firstSchedule && proposal.by === 'worker') {
      voidReschedule(record, new Date(now).toISOString(), 'workforce_changed');
      Object.assign(record, { slot: '', agreedTime: '', autoAccepted: false });
    } else if (proposal?.by === 'worker') voidReschedule(record, new Date(now).toISOString(), 'workforce_changed');
    release(record, { workerId: worker.id, reason: why }, now);
    Object.assign(events(record).at(-1)!, { action: 'workforce_returned', label: '人手变化，重新安排师傅' });
    record.workforceReturned = true;
    returned.push(record);
    if (record.slot && start - now < scheduleRules.leadMs) property.push(record);
  }
  return { returned, property };
}
