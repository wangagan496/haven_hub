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
import { createTencentSmsSender } from './sms.js';
import { CommunityService, announcements, visitorSchema } from './community/service.js';
import { ApiError, requireValue } from './errors.js';
import { readMedia } from './media.js';
import { clientCompatibility } from './client-compatibility.js';
import { WorkflowService } from './workflow.js';
import { ManagementAudit } from './management-audit.js';
import { RepairService } from './repair/service.js';
import { createRepairRouter } from './repair/routes.js';
import { HousingService } from './housing/service.js';
import { createHousingRouter } from './housing/routes.js';
import { RepairPath } from './repair/paths.js';
import { Notifications } from './notifications.js';
import { createPushTransport, type PushTransport } from './push-transport.js';
import { OperationsMetrics, pushOperationsSnapshot } from './operations.js';
import { operationsKeyAuthentication } from './operations-credentials.js';
import { RuntimeLog, projectRuntimeEvent } from './runtime-log.js';

/**
 * web/push.js 所在目录的候选位置：tsx 直接运行 server/src/app.ts 时是 ../../web/，
 * npm start 运行 server/dist/src/app.js 时是 ../../../web/。
 */
export function pushRootCandidates(moduleUrl: string) {
  return ['../../web/', '../../../web/'].map(path => fileURLToPath(new URL(path, moduleUrl)));
}

type AppOptions = { now?: () => number; log?: (event: object) => void; workflowWebRoot?: string; pushTransport?: PushTransport; pushTimer?: boolean; smsFetch?: typeof fetch };

export function createApp(config: Config, options: AppOptions = {}) {
  if (config.authMode === 'tencent' && !config.sms) throw new Error('腾讯云短信配置不完整');
  if (config.environment === 'production' && options.workflowWebRoot) throw new Error('生产环境禁止流程演示网页');
  const runtimeLog = config.runtimeLog ? new RuntimeLog(config.runtimeLog,
    JSON.stringify([config.environment, config.databasePath])) : undefined;
  let store: Store | undefined;
  try {
    store = new Store(config.databasePath);
    return configureApp(config, options, store, runtimeLog);
  } catch (error) {
    runtimeLog?.write({ event: 'server_start_failed' });
    try { store?.close(); } finally { runtimeLog?.close(); }
    throw error;
  }
}

function configureApp(config: Config, options: AppOptions, store: Store, runtimeLog?: RuntimeLog) {
  const metrics = new OperationsMetrics();
  const outputLog = options.log ?? ((event: object) => process.stdout.write(`${JSON.stringify(projectRuntimeEvent(event))}\n`));
  const log = (event: object) => { metrics.recordEvent(event); runtimeLog?.write(event); outputLog(event); };
  const now = options.now ?? Date.now;
  store.bindEnvironment(config.environment === 'production' ? 'production' : 'non-production');
  const auth = new AuthService(store, now, config.authMode === 'tencent' ? {
    mode: 'tencent', sender: createTencentSmsSender(config.sms!, { fetch: options.smsFetch, now }),
    hourlyLimit: config.sms!.hourlyLimit, dailyLimit: config.sms!.dailyLimit, globalDailyLimit: config.sms!.globalDailyLimit, log,
  } : { mode: 'development' });
  const service = new CommunityService(store, config.publicBaseUrl, now);
  const housing = new HousingService(store, config.publicBaseUrl, now);
  const repairs = new RepairService(store, now, config.propertyPhone, log, config.publicBaseUrl);
  const workflow = new WorkflowService(store, now, () => repairs.settleWorkforceChange());
  const audit = new ManagementAudit(store, now);
  const notifications = new Notifications(store, options.pushTransport ?? createPushTransport(config, store, { log }), now, log);
  // sync 自带保存点并吞掉异常：待办生成失败不会回滚或阻断工单保存。
  store.onRepairSaved = (owner, record) => { notifications.sync(owner, record); };
  repairs.settleAll();
  // sync 只写通知/投递表，不改 repairs；逐条读取，避免启动时保留全部工单原文。
  for (const row of store.db.prepare('SELECT userId,payload FROM repairs').iterate()) {
    // 单条损坏记录只跳过并记日志；游标读取错误在外层失败，不能静默漏掉后续待办。
    try { notifications.sync(String(row.userId), JSON.parse(String(row.payload))); }
    catch (error) { log({ event: 'notification_startup_sync_failed', type: error instanceof Error ? error.name : 'unknown' }); }
  }
  let backgroundStopped = false;
  let backgroundStop: Promise<void> | undefined;
  const pushTimer = options.pushTimer === false ? undefined : setInterval(() => {
    void Promise.resolve().then(() => {
      if (backgroundStopped) return;
      repairs.settleAll();
      return notifications.dispatch();
    }).catch(error => log({ event: 'push_dispatch_failed', type: error instanceof Error ? error.name : 'unknown' }));
  }, 10_000);
  pushTimer?.unref();
  const stopBackgroundTasks = () => {
    backgroundStopped = true;
    clearInterval(pushTimer);
    if (!backgroundStop) {
      try { backgroundStop = notifications.stop(); }
      catch (error) { backgroundStop = Promise.reject(error); }
    }
    return backgroundStop;
  };
  // Synchronous callers retain cleanup compatibility; the process entry awaits this same Promise.
  store.beforeClose = () => { void stopBackgroundTasks().catch(() => {}); runtimeLog?.close(); };
  const app = express();
  app.disable('x-powered-by');
  app.set('trust proxy', config.trustProxy);
  app.use((req, res, next) => {
    const requestId = randomUUID();
    const started = performance.now();
    // Match Express' case-insensitive/trailing-slash routing without retaining paths.
    const path = req.path.toLowerCase().replace(/\/$/, '');
    const excluded = ['/health', '/ready', '/management/operations', '/operations/snapshot'].includes(path)
      || path === '/admin' || path.startsWith('/admin/') || path === '/workflow' || path.startsWith('/workflow/');
    const finish = excluded ? undefined : metrics.begin(['/code', '/login', '/refreshtoken'].includes(path));
    res.setHeader('X-Request-Id', requestId);
    res.setHeader('Cache-Control', 'no-store');
    res.on('finish', () => {
      finish?.({ status: res.statusCode, businessError: res.locals.operationRejected === true });
      log({ requestId, method: req.method, status: res.statusCode, durationMs: Math.max(0, Math.round(performance.now() - started)) });
    });
    res.on('close', () => { if (!res.writableFinished) finish?.(); });
    next();
  });
  app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' },
    contentSecurityPolicy: { directives: { 'img-src': ["'self'", 'data:', 'blob:'] } } }));
  app.use(cors({ exposedHeaders: ['X-Request-Id'], origin(origin, callback) {
    if (!origin || origin === config.publicBaseUrl || config.origins.includes(origin)) callback(null, true);
    else callback(new ApiError(403, 40300, '不允许此页面访问本地服务'));
  } }));
  const parseJson = express.json({ limit: '128kb' });
  app.use((req, res, next) => parseJson(req, res, error => {
    // Only normalize errors originating in the body parser. Its raw decompression/charset
    // messages may contain request data; other application failures still reach the 500 handler.
    const status: unknown = error && typeof error === 'object' && 'status' in error ? error.status : undefined;
    if (status === 400) return next(new ApiError(400, 40000, 'JSON 格式或压缩数据不正确'));
    if (status === 413) return next(new ApiError(413, 41300, '请求体过大'));
    if (status === 415) return next(new ApiError(415, 41500, '不支持的请求体编码'));
    next(error);
  }));
  const sourcePublic = fileURLToPath(new URL('../public/admin/', import.meta.url));
  const pushRoots = pushRootCandidates(import.meta.url);
  const pushRoot = pushRoots.find(root => existsSync(join(root, 'push.js'))) ?? pushRoots[0]!;
  app.get('/admin/client-version.js', (_req, res) => {
    const version = config.clientMinimumVersion || '0.0.0';
    res.type('application/javascript').send(`window.HAVEN_ADMIN_CLIENT_VERSION = ${JSON.stringify(version)};`);
  });
  app.get('/admin/push.js', (_req,res) => res.sendFile(join(pushRoot,'push.js')));
  app.get('/admin/push/sw.js', (_req,res) => res.sendFile(join(pushRoot,'push','sw.js')));
  app.use('/admin', express.static(existsSync(sourcePublic) ? sourcePublic : fileURLToPath(new URL('../../public/admin/', import.meta.url))));
  if (options.workflowWebRoot) {
    // Only the demo opts in to serving the compiled Flutter app. API authorization stays below.
    const webRoot = options.workflowWebRoot;
    app.use('/workflow', helmet.contentSecurityPolicy({ directives: {
      'script-src': ["'self'", "'wasm-unsafe-eval'"],
      'connect-src': ["'self'", 'blob:', 'https://fonts.gstatic.com', 'http://127.0.0.1:3001/tencent-map/', 'http://127.0.0.1:3001/amap-map/'],
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
  const operationsSnapshot = () => ({ schemaVersion: 1, generatedAt: now(), requests: metrics.snapshot(),
    push: pushOperationsSnapshot(store, now()) });
  const operationsLimit = () => rateLimit({ windowMs: 60_000, limit: 12, standardHeaders: 'draft-8', legacyHeaders: false,
    message: { code: 42900, message: '运行状态查询过于频繁，请稍后重试', data: null } });
  const authLimit = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false,
    message: { code: 42900, message: '请求过于频繁，请稍后重试', data: null } });
  app.use(['/code', '/login', '/refreshToken'], authLimit);
  // 解绑单独计数：客户端启动时重试解绑，不能占用同一 IP 的登录配额。
  const unregisterLimit = rateLimit({ windowMs: 60_000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false,
    message: { code: 42900, message: '请求过于频繁，请稍后重试', data: null } });
  app.get('/health', (_req, res) => res.json(ok(config.authMode === 'development' ? { mode: 'local-learning', sms: false } :
    { mode: config.environment === 'production' ? 'production' : 'sms-testing', sms: true })));
  app.get('/ready', (_req, res) => {
    if (runtimeLog && !runtimeLog.healthy) throw new ApiError(503, 50300, '运行日志暂不可用');
    store.one('SELECT 1');
    res.json(ok({ ready: true }));
  });
  // A separate read-only credential cannot authenticate any resident/worker/admin route.
  if (config.operationsKeysFile) {
    app.all('/operations/snapshot', operationsLimit(), operationsKeyAuthentication(config.operationsKeysFile, now),
      (_req, res) => res.json(ok(operationsSnapshot())));
  } else {
    app.all('/operations/snapshot', (_req, res) => res.status(404).json({ code: 40400, message: '接口未启用', data: null }));
  }
  // Revocation stays available even if the app or its login session is obsolete.
  app.post('/notifications/unregister', unregisterLimit, (req,res) => res.json(ok(notifications.unregister(req.body))));
  // Includes GET: code issuance and several queries have deliberate write effects.
  app.use(clientCompatibility(config.clientMinimumVersion));
  app.get('/code', async (req, res) => res.json(ok(await auth.sendCode(req.query.mobile))));
  app.post('/login', (req, res) => res.json(ok(auth.login(req.body))));
  app.post('/refreshToken', (req, res) => res.json(ok(auth.refresh(req.get('authorization')))));
  app.get('/announcement', (_req, res) => res.json(ok(announcements)));
  app.get('/announcement/:id', (req, res) => {
    const value = announcements.find(item => item.id === req.params.id);
    if (!value) throw new ApiError(404, 40400, '公告不存在');
    res.json(ok(value));
  });
  app.use((request, response, next) => {
    // 先验证请求携带的登录凭证，再记下这次请求对应的用户编号。
    const loginCredential = request.get('authorization');
    const loggedInUserId = auth.authenticate(loginCredential);
    response.locals.userId = loggedInUserId;
    next();
  });
  app.get('/media/:id', (req, res) => {
    const image = readMedia(store, res.locals.userId, req.params.id);
    res.setHeader('Cache-Control', 'private, no-store');
    res.vary('Authorization');
    res.type(String(image.mime)).send(Buffer.from(image.bytes as Uint8Array));
  });
  app.get('/userInfo', (_req, res) => res.json(ok(service.profile(res.locals.userId))));
  app.put('/userInfo', (req, res) => res.json(ok(service.updateProfile(res.locals.userId, req.body))));
  app.get('/contacts', (_req, res) => res.json(ok({ propertyPhone: config.propertyPhone })));
  app.get('/notifications/config', (_req,res) => res.json(ok(notifications.config(res.locals.userId))));
  app.post('/notifications/devices', (req,res) => res.json(ok(notifications.register(res.locals.userId,req.body))));
  app.get('/notifications', (_req,res) => {
    repairs.settleAll();
    res.json(ok(notifications.list(res.locals.userId)));
  });
  app.post('/notifications/:id/read', (req,res) => res.json(ok(notifications.read(res.locals.userId,req.params.id))));
  app.post('/notifications/:id/retry', (req,res) => {
    repairs.settleAll();
    res.json(ok(notifications.retry(res.locals.userId,req.params.id)));
  });
  app.post('/notifications/repairs/:id/remind', (req,res) => {
    repairs.settleAll();
    res.json(ok(notifications.remind(res.locals.userId,req.params.id)));
  });
  app.use('/management', (_request, response, next) => {
    const operatorUserId: string = response.locals.userId;
    workflow.requireRole(operatorUserId, 'admin');
    next();
  });
  app.get('/management/operations', operationsLimit(), (_req, res) => res.json(ok(operationsSnapshot())));
  app.get('/management/audit-events', (req, res) => res.json(ok(audit.list(res.locals.userId, req.query))));
  app.get('/management/workers', (_req, res) => res.json(ok(workflow.workers())));
  app.get('/management/workforce-summary', (_req, res) => res.json(ok(workflow.workforceSummary())));
  app.post('/management/workers', (req, res) => res.json(ok(workflow.saveWorker(req.body, res.locals.userId))));
  app.put('/management/workers/:id/access', (req, res) => res.json(ok(workflow.setWorkerEnabled(req.params.id, req.body, res.locals.userId))));
  app.get('/management/workers/:id/account-events', (req, res) => res.json(ok(workflow.workerAccountEvents(req.params.id, res.locals.userId, req.query))));
  app.post('/management/workers/:id/leave', (req, res) => res.json(ok(workflow.saveLeave(req.params.id, req.body, res.locals.userId))));
  app.delete('/management/workers/:id/leave', (req, res) => res.json(ok(workflow.removeLeave(req.params.id, req.body, res.locals.userId))));
  app.put('/management/workers/:id/skills', (req, res) => res.json(ok(workflow.saveSkills(req.params.id, req.body, res.locals.userId))));
  app.use('/worker', (_req, res, next) => { workflow.requireRole(res.locals.userId, 'worker'); next(); });
  app.get(RepairPath.skills, (_req, res) => res.json(ok(workflow.workerSkills(res.locals.userId))));
  app.put(RepairPath.skills, (req, res) => res.json(ok(workflow.saveSkills(res.locals.userId, req.body))));
  app.use(createRepairRouter(repairs));
  app.use(createHousingRouter(housing));
  app.get('/visitor', (_req, res) => res.json(ok({ rows: service.list('visitors', res.locals.userId) })));
  app.get('/visitor-submissions/:id', (req, res) => res.json(ok(service.visitorSubmissionResult(res.locals.userId, req.params.id))));
  app.put('/visitor-submissions/:id/close', (req, res) => res.json(ok(service.closeVisitorSubmission(res.locals.userId, req.params.id))));
  app.get('/visitor/:id', (req, res) => res.json(ok(service.detail('visitors', res.locals.userId, req.params.id))));
  app.post('/visitor', async (req, res) => {
    const input = visitorSchema.parse(req.body);
    const replay = service.prepareVisitor(res.locals.userId, input);
    if (replay) { res.json(ok(replay)); return; }
    const imageId = randomBytes(32).toString('hex');
    const png = await QRCode.toBuffer(`HAVEN-LOCAL-DEMO:${randomUUID()}`, { type: 'png', width: 440, margin: 2 });
    const label = Buffer.from('<svg width="440" height="480"><rect width="440" height="480" fill="white"/><text x="220" y="465" text-anchor="middle" font-size="18" fill="black">LOCAL DEMO - NOT VALID FOR ENTRY</text></svg>');
    const image = await sharp(label).composite([{ input: png, top: 0, left: 0 }]).png().toBuffer();
    res.json(ok(service.createVisitor(res.locals.userId, input, image, imageId)));
  });
  const imageUpload = multer({
    storage: multer.memoryStorage(),
    limits: {
      fileSize: 8 * 1024 * 1024, // 单张图片最多 8 MB
      files: 1,
      fields: 1, // 可选的 type 字段
      parts: 2, // 图片和 type 合计最多两项
    },
  });
  app.post('/upload', imageUpload.single('file'), async (request, response) => {
    requireValue(request.file, '请选择图片');
    z.object({ type: z.literal('avatar').optional() }).strict().parse(request.body);
    let pngImage: Buffer;
    try {
      const uploadedImage = sharp(request.file.buffer, {
        limitInputPixels: 16_000_000,
        animated: false,
      });
      const imageDetails = await uploadedImage.metadata();
      const supportedFormat = ['jpeg', 'png', 'webp'].includes(imageDetails.format ?? '');
      requireValue(supportedFormat, '只支持 JPEG、PNG、WebP 图片');
      // 按照片方向旋转，等比例缩小，再输出 PNG；小图不放大。
      pngImage = await uploadedImage
        .rotate()
        .resize({ width: 2048, height: 2048, fit: 'inside', withoutEnlargement: true })
        .png()
        .toBuffer();
    } catch {
      throw new ApiError(200, 40003, '图片无法解码或超过尺寸限制');
    }
    const imageId = randomBytes(32).toString('hex');
    const uploaderUserId: string = response.locals.userId;
    store.run('INSERT INTO uploads VALUES (?, ?, ?, ?)', imageId, uploaderUserId, 'image/png', pngImage);
    response.json(ok({ url: `${config.publicBaseUrl}/media/${imageId}` }));
  });
  app.use((_req, _res, next) => next(new ApiError(404, 40400, '接口不存在')));
  const handleError: ErrorRequestHandler = (error, _req, res, _next) => {
    // Business failures can intentionally use HTTP 200; do not count them as successful logins.
    res.locals.operationRejected = true;
    if (error instanceof ApiError) res.status(error.status).json({ code: error.code, message: error.message, data: error.data });
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
  return { app, store, notifications, runtimeLog, stopBackgroundTasks };
}
