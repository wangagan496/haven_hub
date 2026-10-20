import { randomUUID } from 'node:crypto';
import type { RecordData } from '../database.js';
import { addEvent, openPending, requiredSkill } from './model.js';
import { parseSlot, scheduleRules, setSlot, type Capacity } from './schedule.js';
import { inRepairPool, StaffingContext } from './workforce.js';

export type RescheduleOffer = { id: string; offeredAt: string; deadline: string; slot: string; incident: number;
  resolvedAt?: string; resolution?: 'stale' | 'expired' | 'resident_kept' | 'resident_rescheduled'; staleReason?: string };
export const offerOf = (record: RecordData) => record.rescheduleOffer as RescheduleOffer | undefined;
export const openOffer = (record: RecordData) => { const offer = offerOf(record); return offer && !offer.resolvedAt ? offer : undefined; };
export function unstaffed(record: RecordData, context: StaffingContext) {
  return inRepairPool(record) && Boolean(parseSlot(record.slot)) && !openPending(record, 'reschedule')
    && !openPending(record, 'revoke') && context.eligible(record).length === 0;
}

/** 查询、offer 生成、住户和物业写入共同使用；不放宽普通改约。 */
export function unstaffedOptions(record: RecordData, now: number, context: StaffingContext, capacities: (date: string) => Capacity) {
  return context.alternatives(requiredSkill(record), now, capacities).filter(slot => slot.slot !== record.slot);
}

export function closeOffer(record: RecordData, now: number, resolution: NonNullable<RescheduleOffer['resolution']>, staleReason?: string) {
  const offer = openOffer(record);
  if (!offer) return false;
  Object.assign(offer, { resolvedAt: new Date(now).toISOString(), resolution, ...(staleReason ? { staleReason } : {}) });
  return true;
}

export function settleOffer(record: RecordData, now: number, context: StaffingContext, options: () => ReturnType<typeof unstaffedOptions>) {
  const before = JSON.stringify([record.rescheduleOffer, record.unstaffedFallback]);
  const offer = offerOf(record);
  if (!unstaffed(record, context)) {
    closeOffer(record, now, 'stale');
    if (record.unstaffedFallback) record.unstaffedFallback = '';
  } else if (openOffer(record) && offer!.slot !== record.slot) {
    closeOffer(record, now, 'stale');
  } else if (openOffer(record) && Date.parse(offer!.deadline) <= now) {
    closeOffer(record, now, 'expired');
  } else if (openOffer(record)) {
    if (!options().length) closeOffer(record, now, 'stale', 'no_options');
  } else if (!offer || offer.resolution === 'stale' || offer.slot !== record.slot
    || offer.incident !== Number(record.staffingIncident ?? 0)) {
    const deadline = Math.min(now + scheduleRules.responseMs, parseSlot(record.slot)!.startsAt - scheduleRules.leadMs);
    if (deadline - now < scheduleRules.minimumResponseMs) record.unstaffedFallback = 'insufficient_response';
    else if (options().length) {
      record.unstaffedFallback = '';
      record.rescheduleOffer = { id: randomUUID(), offeredAt: new Date(now).toISOString(), deadline: new Date(deadline).toISOString(),
        slot: String(record.slot), incident: Number(record.staffingIncident ?? 0) } satisfies RescheduleOffer;
    }
  }
  return before !== JSON.stringify([record.rescheduleOffer, record.unstaffedFallback]);
}

export function applyUnstaffedSlot(record: RecordData, slot: string, now: number, by: 'resident' | 'admin') {
  const previous = String(record.agreedTime);
  setSlot(record, slot);
  closeOffer(record, now, by === 'resident' ? 'resident_rescheduled' : 'stale');
  record.unstaffedFallback = '';
  addEvent(record, { action: by === 'resident' ? 'resident_unstaffed_rescheduled' : 'admin_unstaffed_rescheduled',
    label: by === 'resident' ? '住户因排不开师傅改选上门时间' : '物业电话确认后改时间',
    at: new Date(now).toISOString(), by, detail: `${previous} → ${record.agreedTime}` });
}
