import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Collection, RecordData, Store } from '../database.js';
import { mobileSchema } from '../auth.js';
import { ApiError, requireValue } from '../errors.js';
import { RepairService } from '../repair/service.js';
import { date, houseInfo } from './resources.js';
import { bindMedia, ownedUpload, type MediaPurpose } from '../media.js';

const text = z.string().trim().min(1).max(100);
export const announcements = [{ id: 'local-welcome', title: '欢迎使用享家本地学习版',
  content: '这里的数据保存在本机 SQLite 数据库。验证码仅供开发使用，不会发送短信。请使用虚构资料和示例图片。',
  createdAt: '2026-10-12T00:00:00.000Z', creatorName: '本地学习服务' }];

export const visitorSchema = z.object({
  submissionId: z.string().uuid().optional(),
  houseId: z.string().uuid(), name: text, gender: z.union([z.literal(0), z.literal(1)]), mobile: mobileSchema, visitDate: date,
}).strict();

export class CommunityService {
  constructor(private readonly store: Store, private readonly publicBaseUrl: string,
    private readonly now: () => number = Date.now) {}
  private iso() { return new Date(this.now()).toISOString(); }
  list(table: Collection, userId: string) {
    return this.store.list(table, userId);
  }
  detail(table: Collection, userId: string, id: string) {
    const value = this.store.get(table, userId, id);
    if (!value) throw new ApiError(404, 40400, '记录不存在或无权访问');
    return value;
  }
  // 写入与完整列表读取处于同一事务：查询失败则回滚，不会把已提交误报为失败。
  mutate(table: Collection, userId: string, operation: () => void) {
    return this.store.transaction(() => {
      operation();
      const rows = this.list(table, userId);
      return { complete: true, rows, total: rows.length };
    });
  }
  /** 兼容演示脚本；创建逻辑统一由报修模块负责，保留原来的完整列表响应。 */
  createRepair(userId: string, raw: unknown) {
    // 仅供演示脚本和旧测试使用；新代码一律调用 RepairService.createRepair。
    return new RepairService(this.store, this.now, '', undefined, this.publicBaseUrl)
      .createRepair(userId, raw, () => this.list('repairs', userId));
  }
  private visitorRequestHash(input: z.infer<typeof visitorSchema>) {
    const { submissionId: _, ...content } = visitorSchema.parse(input);
    return createHash('sha256').update(JSON.stringify(content)).digest('hex');
  }
  private visitorReplay(userId: string, input: z.infer<typeof visitorSchema>) {
    if (!input.submissionId) return undefined;
    const receipt = this.store.one('SELECT requestHash,visitorId FROM visitor_submissions WHERE userId=? AND submissionId=?', userId, input.submissionId);
    if (!receipt) return undefined;
    if (receipt.visitorId === null) throw new ApiError(409, 40903, '本次提交已停止，请使用新的提交回执');
    if (receipt.requestHash !== this.visitorRequestHash(input)) throw new ApiError(409, 40902, '该提交回执对应的内容不同，请先查看原提交结果');
    this.detail('visitors', userId, String(receipt.visitorId));
    const rows = this.list('visitors', userId);
    return { complete: true, rows, total: rows.length, createdId: String(receipt.visitorId) };
  }
  // 图片生成前先查询回执；最终写事务仍须复查，避免异步生成图片期间发生竞争。
  prepareVisitor(userId: string, input: z.infer<typeof visitorSchema>) {
    return this.store.transaction(() => {
      const replay = this.visitorReplay(userId, input);
      if (replay) return replay;
      this.detail('rooms', userId, input.houseId);
      return undefined;
    });
  }
  createVisitor(userId: string, raw: unknown, image: Uint8Array, imageId: string) {
    const input = visitorSchema.parse(raw);
    return this.store.transaction(() => {
      const replay = this.visitorReplay(userId, input);
      if (replay) return replay;
      const { submissionId, ...content } = input;
      const id = randomUUID();
      const result = this.mutate('visitors', userId, () => {
        const house = this.detail('rooms', userId, input.houseId);
        this.store.run('INSERT INTO uploads VALUES (?, ?, ?, ?)', imageId, userId, 'image/png', image);
        this.store.save('visitors', userId, { ...content, id, status: 1, houseInfo: this.houseInfo(house), createdAt: this.iso(),
          validTime: 1440, url: `${this.publicBaseUrl}/media/${imageId}`, encryptedData: 'LOCAL-DEMO-NOT-A-REAL-PASS' });
        if (submissionId) this.store.run('INSERT INTO visitor_submissions VALUES (?,?,?,?,?)',
          userId, submissionId, this.visitorRequestHash(input), id, this.now());
      });
      return { ...result, createdId: id };
    });
  }
  visitorSubmissionResult(userId: string, rawId: unknown) {
    const id = z.string().uuid().parse(rawId);
    const receipt = this.store.one('SELECT visitorId FROM visitor_submissions WHERE userId=? AND submissionId=?', userId, id);
    // unknown 不能证明原请求失败；它可能仍在生成图片或等待写锁。
    if (!receipt) return { state: 'unknown', createdId: '' };
    if (receipt.visitorId === null) return { state: 'closed', createdId: '' };
    this.detail('visitors', userId, String(receipt.visitorId));
    return { state: 'created', createdId: String(receipt.visitorId) };
  }
  closeVisitorSubmission(userId: string, rawId: unknown) {
    const id = z.string().uuid().parse(rawId);
    return this.store.transaction(() => {
      const result = this.visitorSubmissionResult(userId, id);
      if (result.state !== 'unknown') return result;
      this.store.run('INSERT INTO visitor_submissions VALUES (?,?,?,NULL,?)', userId, id, '', this.now());
      return { state: 'closed', createdId: '' };
    });
  }
  private houseInfo(house: RecordData) { return houseInfo(house); }
  ownedUpload(userId: string, url: string, purpose?: MediaPurpose) { ownedUpload(this.store, this.publicBaseUrl, userId, url, purpose); }
  profile(userId: string) {
    const user = this.store.one('SELECT id, nickName, avatar, role FROM users WHERE id = ?', userId);
    requireValue(user, '用户不存在');
    return user;
  }
  updateProfile(userId: string, raw: unknown) {
    const input = z.object({ nickName: z.string().trim().min(2).max(10), avatar: z.string().max(2048) }).strict().parse(raw);
    return this.store.transaction(() => {
      if (input.avatar) this.ownedUpload(userId, input.avatar, 'avatar');
      this.store.run('UPDATE users SET nickName = ?, avatar = ? WHERE id = ?', input.nickName, input.avatar, userId);
      bindMedia(this.store.db, userId, 'avatar', userId, [input.avatar]);
      return this.profile(userId);
    });
  }
}
