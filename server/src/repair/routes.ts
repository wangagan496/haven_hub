import { Router } from 'express';
import { z } from 'zod';
import type { RepairService } from './service.js';
import { repairItems } from './model.js';
import { RepairPath } from './paths.js';

/** 挂载在 app 的登录校验及 /management、/worker 角色中间件之后。 */
export function createRepairRouter(repairs: RepairService) {
  const router = Router();
  const ok = (data: unknown) => ({ code: 10000, message: '成功', data });
  router.get(RepairPath.pool, (_req, res) => res.json(ok(repairs.repairPool(res.locals.userId))));
  router.put(RepairPath.claim, (req, res) => res.json(ok(repairs.claim(res.locals.userId, req.params.id, req.body))));
  router.get(RepairPath.queue, (_req, res) => res.json(ok(repairs.queue(res.locals.userId))));
  router.put(RepairPath.priority, (req, res) => res.json(ok(repairs.grade(res.locals.userId, req.params.id, req.body))));
  router.get(RepairPath.shiftSuggestions, (req, res) => res.json(ok(repairs.shiftSuggestions(res.locals.userId, req.query))));
  router.put(RepairPath.shift, (req, res) => res.json(ok(repairs.shift(res.locals.userId, req.params.id, req.body))));
  router.get(RepairPath.dispatchOptions, (req, res) => res.json(ok(repairs.dispatchOptions(res.locals.userId, req.params.id, req.query))));
  router.put(RepairPath.dispatch, (req, res) => res.json(ok(repairs.dispatch(res.locals.userId, req.params.id, req.body))));
  router.get(RepairPath.slots, (req, res) => res.json(ok(repairs.slots(res.locals.userId, req.query))));
  router.get('/repair/:id/unstaffed-options', (req, res) => res.json(ok(repairs.unstaffedOptions(res.locals.userId, req.params.id, false, req.query))));
  router.put('/repair/:id/unstaffed-choice', (req, res) => res.json(ok(repairs.unstaffedChoice(res.locals.userId, req.params.id, req.body))));
  router.get('/management/repairs/:id/unstaffed-options', (req, res) => res.json(ok(repairs.unstaffedOptions(res.locals.userId, req.params.id, true))));
  router.put('/management/repairs/:id/unstaffed-reschedule', (req, res) => res.json(ok(repairs.unstaffedReschedule(res.locals.userId, req.params.id, req.body))));
  router.get(RepairPath.capacities, (req, res) => res.json(ok(repairs.capacities(res.locals.userId, req.query))));
  router.put(RepairPath.capacities, (req, res) => res.json(ok(repairs.saveCapacities(res.locals.userId, req.body))));
  router.get(RepairPath.capacityWeekdays, (_req, res) => res.json(ok(repairs.weekdayCapacities(res.locals.userId))));
  router.put(RepairPath.capacityWeekday, (req, res) => res.json(ok(repairs.saveWeekdayCapacities(res.locals.userId, req.params.weekday, req.body))));
  router.delete(RepairPath.capacityWeekday, (req, res) => res.json(ok(repairs.clearWeekdayCapacities(res.locals.userId, req.params.weekday))));
  router.put(RepairPath.capacityDate, (req, res) => res.json(ok(repairs.saveCapacities(res.locals.userId, req.body, req.params.date))));
  router.delete(RepairPath.capacityDate, (req, res) => res.json(ok(repairs.clearCapacities(res.locals.userId, req.params.date))));
  router.post(RepairPath.propose, (req, res) => res.json(ok(repairs.propose(res.locals.userId, 'admin', req.params.id, req.body))));
  router.get('/management/repairs', (_req, res) => res.json(ok(repairs.adminList())));
  router.put('/management/repairs/:id/assign', (req, res) => res.json(ok(repairs.assign(req.params.id, req.body))));
  router.get('/management/repairs/:id/assignment-options', (req, res) => res.json(ok(repairs.assignmentOptions(res.locals.userId, req.params.id))));
  router.put('/management/repairs/:id/skill', (req, res) => res.json(ok(repairs.classify(res.locals.userId, req.params.id, req.body))));
  router.put('/management/repairs/:id/aftersale', (req, res) => res.json(ok(repairs.reviewAftersale(req.params.id, req.body))));
  router.put('/management/repairs/:id/reschedule', (req, res) => res.json(ok(repairs.respond(res.locals.userId, 'admin', req.params.id, req.body))));
  router.post('/management/repairs/:id/notes', (req, res) => res.json(ok(repairs.note(req.params.id, req.body))));
  router.get('/worker/repairs', (_req, res) => res.json(ok(repairs.workerList(res.locals.userId))));
  router.get('/worker/repairs/:id', (req, res) => res.json(ok(repairs.workerDetail(res.locals.userId, req.params.id))));
  router.put('/worker/repairs/:id/accept', (req, res) => res.json(ok(repairs.accept(res.locals.userId, req.params.id, req.body))));
  router.put('/worker/repairs/:id/complete', (req, res) => res.json(ok(repairs.complete(res.locals.userId, req.params.id, req.body))));
  router.put('/worker/repairs/:id/result', (req, res) => res.json(ok(repairs.complete(res.locals.userId, req.params.id, req.body, true))));
  router.put('/worker/repairs/:id/release', (req, res) => {
    repairs.release(res.locals.userId, req.params.id, req.body);
    // 退出后原师傅已无权查看此工单，返回其最新工作台列表。
    res.json(ok({ released: req.params.id, rows: repairs.workerList(res.locals.userId) }));
  });
  router.post('/worker/repairs/:id/reschedule', (req, res) => res.json(ok(repairs.propose(res.locals.userId, 'worker', req.params.id, req.body))));
  router.put('/worker/repairs/:id/reschedule', (req, res) => res.json(ok(repairs.respond(res.locals.userId, 'worker', req.params.id, req.body))));
  router.post('/worker/repairs/:id/progress', (req, res) => res.json(ok(repairs.progress(res.locals.userId, req.params.id, req.body))));
  router.put('/worker/repairs/:id/revoke', (req, res) => res.json(ok(repairs.acknowledgeRevoke(res.locals.userId, req.params.id, req.body))));
  router.post('/worker/repairs/:id/objection', (req, res) => res.json(ok(repairs.objectRevoke(res.locals.userId, req.params.id, req.body))));
  router.get('/repairItem', (_req, res) => res.json(ok(repairItems.filter(item => item.id !== '1001'))));
  router.get('/repair', (req, res) => {
    const { current, pageSize } = z.object({ current: z.coerce.number().int().min(1).default(1),
      pageSize: z.coerce.number().int().min(1).max(200).default(20) }).parse(req.query);
    const rows = repairs.residentList(res.locals.userId);
    res.json(ok({ rows: rows.slice((current - 1) * pageSize, current * pageSize), total: rows.length,
      pageTotal: Math.ceil(rows.length / pageSize), current }));
  });
  router.get('/repair/:id', (req, res) => res.json(ok(repairs.residentDetail(res.locals.userId, req.params.id))));
  router.post('/repair', (req, res) => res.json(ok(repairs.createRepair(res.locals.userId, req.body))));
  // 旧契约保持不变：未接单前直接撤销，返回当前住户的完整报修列表。
  router.put('/cancel/repair/:id', (req, res) => res.json(ok(repairs.legacyRevoke(res.locals.userId, req.params.id, req.body ?? {}))));
  // 撤销报修：未接单前直接撤销；已接单后提交撤销申请。返回该工单最新详情。
  router.put('/repair/:id/revoke', (req, res) => res.json(ok(repairs.revoke(res.locals.userId, req.params.id, req.body))));
  router.put('/repair/:id/confirm', (req, res) => res.json(ok(repairs.confirm(res.locals.userId, req.params.id, req.body))));
  router.put('/repair/:id/reject', (req, res) => res.json(ok(repairs.reject(res.locals.userId, req.params.id, req.body))));
  router.post('/repair/:id/aftersale', (req, res) => res.json(ok(repairs.applyAftersale(res.locals.userId, req.params.id, req.body))));
  router.post('/repair/:id/feedback', (req, res) => res.json(ok(repairs.residentFeedback(res.locals.userId, req.params.id, req.body))));
  router.post('/repair/:id/reschedule', (req, res) => res.json(ok(repairs.propose(res.locals.userId, 'resident', req.params.id, req.body))));
  router.put('/repair/:id/reschedule', (req, res) => res.json(ok(repairs.respond(res.locals.userId, 'resident', req.params.id, req.body))));
  return router;
}
