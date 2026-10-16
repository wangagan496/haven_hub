import { randomBytes, randomUUID } from 'node:crypto';
import express, { type ErrorRequestHandler } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { rateLimit } from 'express-rate-limit';
import multer from 'multer';
import sharp from 'sharp';
import QRCode from 'qrcode';
import { z } from 'zod';
import { fileURLToPath } from 'node:url';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import type { Config } from './config.js';
import { Store } from './database.js';
import { AuthService } from './auth.js';
import { CommunityService, announcements, repairItems, visitorSchema } from './community.js';
import { ApiError, requireValue } from './errors.js';
import { WorkflowService } from './workflow.js';

export function createApp(config: Config, options: { now?: () => number; log?: (event: object) => void; workflowWebRoot?: string } = {}) {
  const store = new Store(config.databasePath);
  const auth = new AuthService(store, options.now);
  const service = new CommunityService(store, config.publicBaseUrl);
  const workflow = new WorkflowService(store);
  const app = express();
  app.disable('x-powered-by');
  const log = options.log ?? ((event: object) => process.stdout.write(`${JSON.stringify(event)}\n`));
  app.use((req, res, next) => {
    const requestId = randomUUID();
    const started = Date.now();
    res.setHeader('X-Request-Id', requestId);
    res.setHeader('Cache-Control', 'no-store');
    res.on('finish', () => log({ requestId, method: req.method, status: res.statusCode, durationMs: Date.now() - started }));
    next();
  });
  app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' } }));
  app.use(cors({ origin(origin, callback) {
    if (!origin || origin === config.publicBaseUrl || config.origins.includes(origin)) callback(null, true);
    else callback(new ApiError(403, 40300, '不允许此页面访问本地服务'));
  } }));
  app.use(express.json({ limit: '128kb' }));
  const sourcePublic = fileURLToPath(new URL('../public/admin/', import.meta.url));
  app.use('/admin', express.static(existsSync(sourcePublic) ? sourcePublic : fileURLToPath(new URL('../../public/admin/', import.meta.url))));
  if (options.workflowWebRoot) {
    // Only the demo opts in to serving the compiled Flutter app. API authorization stays below.
    const webRoot = options.workflowWebRoot;
    app.use('/workflow', helmet.contentSecurityPolicy({ directives: {
      'script-src': ["'self'", "'wasm-unsafe-eval'"],
      'connect-src': ["'self'", 'https://fonts.gstatic.com', 'http://127.0.0.1:3001/tencent-map/', 'http://127.0.0.1:3001/amap-map/'],
      'img-src': ["'self'", 'data:', 'blob:'],
      'worker-src': ["'self'", 'blob:'],
      'upgrade-insecure-requests': null,
    } }), (_req, res, next) => {
      if (!existsSync(join(webRoot, 'index.html'))) {
        res.status(503).type('text/plain').send('网页尚未构建，请在项目根目录运行 .\\tool\\build_workflow_web.ps1，再刷新此页。');
        return;
      }
      next();
    }, express.static(webRoot), (_req, res) => {
      res.status(404).type('text/plain').send('网页资源不存在，请重新构建流程演示网页。');
    });
  }
  const ok = (data: unknown) => ({ code: 10000, message: '成功', data });
  const authLimit = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false,
    message: { code: 42900, message: '请求过于频繁，请稍后重试', data: null } });
  app.use(['/code', '/login', '/refreshToken'], authLimit);
  app.get('/health', (_req, res) => res.json(ok({ mode: 'local-learning', sms: false })));
  app.get('/ready', (_req, res) => { store.one('SELECT 1'); res.json(ok({ ready: true })); });
  app.get('/code', (req, res) => res.json(ok(auth.sendCode(req.query.mobile))));
  app.post('/login', (req, res) => res.json(ok(auth.login(req.body))));
  app.post('/refreshToken', (req, res) => res.json(ok(auth.refresh(req.get('authorization')))));
  app.get('/announcement', (_req, res) => res.json(ok(announcements)));
  app.get('/announcement/:id', (req, res) => {
    const value = announcements.find(item => item.id === req.params.id);
    if (!value) throw new ApiError(404, 40400, '公告不存在');
    res.json(ok(value));
  });
  // 兼容现有图片组件/系统分享：随机不可枚举 URL 作为访问凭据，仅使用演示图片。
  app.get('/media/:id', (req, res) => {
    const id = z.string().regex(/^[a-f0-9]{64}$/).parse(req.params.id);
    const image = store.one('SELECT mime, bytes FROM uploads WHERE id = ?', id);
    if (!image) throw new ApiError(404, 40400, '图片不存在');
    res.type(String(image.mime)).send(Buffer.from(image.bytes as Uint8Array));
  });
  app.use((req, res, next) => {
    res.locals.userId = auth.authenticate(req.get('authorization'));
    next();
  });
  app.get('/userInfo', (_req, res) => res.json(ok(service.profile(res.locals.userId))));
  app.put('/userInfo', (req, res) => res.json(ok(service.updateProfile(res.locals.userId, req.body))));
  app.use('/management', (_req, res, next) => { workflow.requireRole(res.locals.userId, 'admin'); next(); });
  app.get('/management/rooms', (_req, res) => res.json(ok(workflow.list('rooms'))));
  app.put('/management/rooms/:id/review', (req, res) => res.json(ok(workflow.review(req.params.id, res.locals.userId, req.body))));
  app.get('/management/repairs', (_req, res) => res.json(ok(workflow.list('repairs'))));
  app.get('/management/workers', (_req, res) => res.json(ok(workflow.workers())));
  app.post('/management/workers', (req, res) => res.json(ok(workflow.saveWorker(req.body))));
  app.put('/management/repairs/:id/assign', (req, res) => res.json(ok(workflow.assign(req.params.id, res.locals.userId, req.body))));
  app.use('/worker', (_req, res, next) => { workflow.requireRole(res.locals.userId, 'worker'); next(); });
  app.get('/worker/repairs', (_req, res) => res.json(ok(workflow.list('repairs', res.locals.userId))));
  app.get('/worker/repairs/:id', (req, res) => res.json(ok(workflow.workerDetail(req.params.id, res.locals.userId))));
  app.put('/worker/repairs/:id/accept', (req, res) => res.json(ok(workflow.process(req.params.id, res.locals.userId, 'accept', req.body))));
  app.put('/worker/repairs/:id/complete', (req, res) => res.json(ok(workflow.process(req.params.id, res.locals.userId, 'complete', req.body))));
  app.get('/room', (_req, res) => res.json(ok(service.list('rooms', res.locals.userId))));
  app.get('/room/:id', (req, res) => res.json(ok(service.detail('rooms', res.locals.userId, req.params.id))));
  app.post('/room', (req, res) => res.json(ok(service.saveRoom(res.locals.userId, req.body))));
  app.delete('/room/:id', (req, res) => res.json(ok(service.deleteRoom(res.locals.userId, req.params.id))));
  app.get('/repairItem', (_req, res) => res.json(ok(repairItems)));
  app.get('/repair', (req, res) => {
    const { current, pageSize } = z.object({ current: z.coerce.number().int().min(1).default(1),
      pageSize: z.coerce.number().int().min(1).max(200).default(20) }).parse(req.query);
    const rows = service.list('repairs', res.locals.userId);
    res.json(ok({ rows: rows.slice((current - 1) * pageSize, current * pageSize), total: rows.length,
      pageTotal: Math.ceil(rows.length / pageSize), current }));
  });
  app.get('/repair/:id', (req, res) => res.json(ok(service.detail('repairs', res.locals.userId, req.params.id))));
  app.post('/repair', (req, res) => res.json(ok(service.createRepair(res.locals.userId, req.body))));
  app.put('/cancel/repaire/:id', (req, res) => res.json(ok(service.cancelRepair(res.locals.userId, req.params.id))));
  app.get('/visitor', (_req, res) => res.json(ok({ rows: service.list('visitors', res.locals.userId) })));
  app.get('/visitor/:id', (req, res) => res.json(ok(service.detail('visitors', res.locals.userId, req.params.id))));
  app.post('/visitor', async (req, res) => {
    const input = visitorSchema.parse(req.body);
    service.detail('rooms', res.locals.userId, input.houseId);
    const imageId = randomBytes(32).toString('hex');
    const png = await QRCode.toBuffer(`HAVEN-LOCAL-DEMO:${randomUUID()}`, { type: 'png', width: 440, margin: 2 });
    const label = Buffer.from('<svg width="440" height="480"><rect width="440" height="480" fill="white"/><text x="220" y="465" text-anchor="middle" font-size="18" fill="black">LOCAL DEMO - NOT VALID FOR ENTRY</text></svg>');
    const image = await sharp(label).composite([{ input: png, top: 0, left: 0 }]).png().toBuffer();
    res.json(ok(service.createVisitor(res.locals.userId, input, image, imageId)));
  });
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 8 * 1024 * 1024, files: 1, fields: 1, parts: 2 } });
  app.post('/upload', upload.single('file'), async (req, res) => {
    requireValue(req.file, '请选择图片');
    z.object({ type: z.literal('avatar').optional() }).strict().parse(req.body);
    let bytes: Buffer;
    try {
      const image = sharp(req.file.buffer, { limitInputPixels: 16_000_000, animated: false });
      const metadata = await image.metadata();
      requireValue(['jpeg', 'png', 'webp'].includes(metadata.format ?? ''), '只支持 JPEG、PNG、WebP 图片');
      bytes = await image.rotate().resize({ width: 2048, height: 2048, fit: 'inside', withoutEnlargement: true }).png().toBuffer();
    } catch {
      throw new ApiError(200, 40003, '图片无法解码或超过尺寸限制');
    }
    const id = randomBytes(32).toString('hex');
    store.run('INSERT INTO uploads VALUES (?, ?, ?, ?)', id, res.locals.userId, 'image/png', bytes);
    res.json(ok({ url: `${config.publicBaseUrl}/media/${id}` }));
  });
  app.use((_req, _res, next) => next(new ApiError(404, 40400, '接口不存在')));
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    if (error instanceof ApiError) res.status(error.status).json({ code: error.code, message: error.message, data: null });
    else if (error instanceof z.ZodError) res.status(200).json({ code: 40000, message: '参数格式不正确，请检查输入', data: null });
    else if (error instanceof multer.MulterError) res.status(413).json({ code: 41300, message: '图片超过8MB或上传字段不正确', data: null });
    else if (error instanceof SyntaxError && 'body' in error) res.status(400).json({ code: 40000, message: 'JSON 格式不正确', data: null });
    else if (error && typeof error === 'object' && 'type' in error && error.type === 'entity.too.large')
      res.status(413).json({ code: 41300, message: '请求体过大', data: null });
    else {
      log({ requestId: res.getHeader('X-Request-Id'), event: 'internal_error', type: error instanceof Error ? error.name : 'unknown' });
      res.status(500).json({ code: 50000, message: '本地服务处理失败', data: null });
    }
  };
  app.use(handleError);
  return { app, store };
}
