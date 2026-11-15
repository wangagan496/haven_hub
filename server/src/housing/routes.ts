import { Router } from 'express';
import type { HousingService } from './service.js';

/** 挂载在登录和版本校验之后；账号来自已验证的 locals，审核还在模块内校验角色。 */
export function createHousingRouter(housing: HousingService) {
  const router = Router();
  const ok = (data: unknown) => ({ code: 10000, message: '成功', data });
  router.get('/room', (_req, res) => res.json(ok(housing.list(res.locals.userId))));
  router.get('/room-submissions/:id', (req, res) => res.json(ok(housing.submissionResult(res.locals.userId, req.params.id))));
  router.put('/room-submissions/:id/close', (req, res) => res.json(ok(housing.closeSubmission(res.locals.userId, req.params.id))));
  router.get('/room/:id', (req, res) => res.json(ok(housing.detail(res.locals.userId, req.params.id))));
  router.post('/room', (req, res) => res.json(ok(housing.save(res.locals.userId, req.body))));
  router.delete('/room/:id', (req, res) => res.json(ok(housing.remove(res.locals.userId, req.params.id, req.body))));
  router.get('/management/rooms', (_req, res) => res.json(ok(housing.reviewQueue(res.locals.userId))));
  router.put('/management/rooms/:id/review', (req, res) => res.json(ok(housing.review(req.params.id, res.locals.userId, req.body))));
  return router;
}
