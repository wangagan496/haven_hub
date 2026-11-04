import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Collection, RecordData, Store } from '../database.js';
import { mobileSchema } from '../auth.js';
import { ApiError, requireValue } from '../errors.js';
import { RepairService } from '../repair/service.js';
import { date, houseInfo, ownedUpload } from './resources.js';
import { bindMedia, type MediaPurpose } from '../media.js';

const text = z.string().trim().min(1).max(100);
export const announcements = [{ id: 'local-welcome', title: '欢迎使用享家本地学习版',
  content: '这里的数据保存在本机 SQLite 数据库。验证码仅供开发使用，不会发送短信。请使用虚构资料和示例图片。',
  createdAt: '2026-10-12T00:00:00.000Z', creatorName: '本地学习服务' }];

export const roomSchema = z.object({
  submissionId: z.string().uuid().optional(),
  id: z.string().uuid().optional(), revision: z.number().int().min(0).optional(),
  point: text, building: text, room: text,
  floor: z.string().trim().regex(/^(?:[1-9]\d{0,3}|B[1-9]\d?)?$/).default(''),
  name: z.string().trim().regex(/^(?=.{2,15}$)[\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z '-]*[\u4e00-\u9fa5A-Za-z]$/), gender: z.union([z.literal(0), z.literal(1)]),
  mobile: mobileSchema, idcardFrontUrl: z.url(), idcardBackUrl: z.url(),
}).strict().refine(input => !(input.id && input.submissionId), { message: '编辑不能使用创建回执' });

// 中文姓名可重名；含英文字母的姓名按大小写及连续空格归一后全局唯一。
function englishOwnerKey(name: string): string | null {
  return /[A-Za-z]/.test(name) ? name.trim().replace(/ +/g, ' ').toLowerCase() : null;
}

function roomValidationMessage(error: z.ZodError): string {
  const labels: Record<string, string> = {
    id: '房屋编号', point: '小区', building: '楼栋', room: '房间', floor: '楼层',
    name: '业主姓名', gender: '性别', mobile: '手机号',
    idcardFrontUrl: '身份证正面照片', idcardBackUrl: '身份证背面照片',
  };
  const issue = error.issues[0];
  const field = typeof issue?.path[0] === 'string' ? issue.path[0] : '';
  if (!field) return '参数格式不正确，请检查输入';
  if (field === 'revision') return '房屋版本无效，请重新加载后再提交';
  const label = labels[field] ?? '房屋信息';
  if (field === 'mobile') return '手机号格式不正确';
  if (field === 'floor') return '请输入有效楼层，例如33、100或B1';
  if (field === 'name') return '业主姓名格式不正确，请填写2-15个中文或英文字符';
  if (field === 'idcardFrontUrl' || field === 'idcardBackUrl') {
    return `${label}无效，请重新上传`;
  }
  if (issue?.code === 'too_big') return `${label}不能超过100个字符`;
  if (field && (issue?.code === 'too_small' || issue?.code === 'invalid_type')) {
    return `${label}不能为空`;
  }
  return `${label}格式不正确，请检查输入`;
}
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
  saveRoom(userId: string, raw: unknown) {
    const parsed = roomSchema.safeParse(raw);
    if (!parsed.success) {
      throw new ApiError(200, 40000, roomValidationMessage(parsed.error));
    }
    const input = parsed.data;
    return this.store.transaction(() => {
      const { submissionId, ...content } = input;
      const requestHash = this.roomRequestHash(input);
      if (submissionId) {
        const receipt = this.store.one('SELECT requestHash,roomId FROM room_submissions WHERE userId=? AND submissionId=?', userId, submissionId);
        if (receipt) {
          if (receipt.roomId === null) throw new ApiError(409, 40903, '本次提交已停止，请使用新的提交回执');
          if (receipt.requestHash !== requestHash) throw new ApiError(409, 40902, '该提交回执对应的内容不同，请先查看原提交结果');
          if (!this.store.get('rooms', userId, String(receipt.roomId))) throw new ApiError(409, 40904, '原房屋已删除，本次提交不会重新创建');
          const rows = this.list('rooms', userId);
          return { complete: true, rows, total: rows.length, createdId: String(receipt.roomId) };
        }
      }
      const id = input.id ?? randomUUID();
      const result = this.mutate('rooms', userId, () => {
        const previous = input.id ? this.detail('rooms', userId, input.id) : undefined;
        // 所属关系、版本检查及写入共用事务，旧表单不能覆盖较新的资料或审核结果。
        if (previous && input.revision !== Number(previous.revision ?? 0)) {
          throw new ApiError(409, 40900, '房屋资料或审核状态已更新，请重新加载后再提交');
        }
        this.ownedUpload(userId, input.idcardFrontUrl, 'identity');
        this.ownedUpload(userId, input.idcardBackUrl, 'identity');
        const nameKey = englishOwnerKey(input.name);
        if (nameKey !== null && this.store.roomOwnerNames().some(room =>
          room.id !== input.id && englishOwnerKey(room.name) === nameKey)) {
          throw new ApiError(200, 40002, '该英文姓名已被登记，请更换姓名');
        }
        this.store.save('rooms', userId, { ...content, id, status: 1,
          revision: Number(previous?.revision ?? 0) + 1, reviewReason: '', reviewedAt: '',
          submittedAt: this.iso() }, Boolean(input.id));
        if (submissionId) this.store.run('INSERT INTO room_submissions VALUES (?,?,?,?,?)',
          userId, submissionId, requestHash, id, this.now());
      });
      return input.id ? result : { ...result, createdId: id };
    });
  }
  private roomRequestHash(input: z.infer<typeof roomSchema>) {
    const { submissionId: _, id: _id, revision: _revision, ...content } = input;
    return createHash('sha256').update(JSON.stringify(content)).digest('hex');
  }
  roomSubmissionResult(userId: string, rawId: unknown) {
    const id = z.string().uuid().parse(rawId);
    const receipt = this.store.one('SELECT roomId FROM room_submissions WHERE userId=? AND submissionId=?', userId, id);
    if (!receipt) return { state: 'unknown', createdId: '' };
    if (receipt.roomId === null) return { state: 'closed', createdId: '' };
    const createdId = String(receipt.roomId);
    return { state: this.store.get('rooms', userId, createdId) ? 'created' : 'deleted', createdId };
  }
  closeRoomSubmission(userId: string, rawId: unknown) {
    const id = z.string().uuid().parse(rawId);
    return this.store.transaction(() => {
      const result = this.roomSubmissionResult(userId, id);
      if (result.state !== 'unknown') return result;
      this.store.run('INSERT INTO room_submissions VALUES (?,?,?,NULL,?)', userId, id, '', this.now());
      return { state: 'closed', createdId: '' };
    });
  }
  deleteRoom(userId: string, id: string, raw: unknown) {
    return this.mutate('rooms', userId, () => {
      const previous = this.detail('rooms', userId, id);
      const { revision } = z.object({ revision: z.number().int().min(0).optional() }).strict().parse(raw ?? {});
      if (revision !== Number(previous.revision ?? 0)) {
        throw new ApiError(409, 40900, '房屋资料或审核状态已更新，请刷新核对后再删除');
      }
      this.store.delete('rooms', userId, id);
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
