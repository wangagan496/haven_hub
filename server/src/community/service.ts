import { randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { Collection, RecordData, Store } from '../database.js';
import { mobileSchema } from '../auth.js';
import { ApiError, requireValue } from '../errors.js';
import { RepairService } from '../repair/service.js';
import { date, houseInfo, ownedUpload } from './resources.js';

const text = z.string().trim().min(1).max(100);
export const announcements = [{ id: 'local-welcome', title: '欢迎使用享家本地学习版',
  content: '这里的数据保存在本机 SQLite 数据库。验证码仅供开发使用，不会发送短信。请使用虚构资料和示例图片。',
  createdAt: '2026-10-12T00:00:00.000Z', creatorName: '本地学习服务' }];

export const roomSchema = z.object({
  id: z.string().uuid().optional(), point: text, building: text, room: text,
  floor: z.string().trim().regex(/^(?:[1-9]\d{0,3}|B[1-9]\d?)?$/).default(''),
  name: z.string().trim().regex(/^(?=.{2,15}$)[\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z '-]*[\u4e00-\u9fa5A-Za-z]$/), gender: z.union([z.literal(0), z.literal(1)]),
  mobile: mobileSchema, idcardFrontUrl: z.url(), idcardBackUrl: z.url(),
}).strict();

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
    return this.mutate('rooms', userId, () => {
      const previous = input.id ? this.detail('rooms', userId, input.id) : undefined;
      this.ownedUpload(userId, input.idcardFrontUrl);
      this.ownedUpload(userId, input.idcardBackUrl);
      const nameKey = englishOwnerKey(input.name);
      if (nameKey !== null && this.store.roomOwnerNames().some(room =>
        room.id !== input.id && englishOwnerKey(room.name) === nameKey)) {
        throw new ApiError(200, 40002, '该英文姓名已被登记，请更换姓名');
      }
      this.store.save('rooms', userId, { ...input, id: input.id ?? randomUUID(), status: 1,
        revision: Number(previous?.revision ?? 0) + 1, reviewReason: '', reviewedAt: '',
        submittedAt: this.iso() }, Boolean(input.id));
    });
  }
  deleteRoom(userId: string, id: string) {
    return this.mutate('rooms', userId, () => {
      this.detail('rooms', userId, id);
      this.store.delete('rooms', userId, id);
    });
  }
  /** 兼容演示脚本；创建逻辑统一由报修模块负责，保留原来的完整列表响应。 */
  createRepair(userId: string, raw: unknown) {
    // 仅供演示脚本和旧测试使用；新代码一律调用 RepairService.createRepair。
    return new RepairService(this.store, this.now, '', undefined, this.publicBaseUrl)
      .createRepair(userId, raw, () => this.list('repairs', userId));
  }
  createVisitor(userId: string, input: z.infer<typeof visitorSchema>, image: Uint8Array, imageId: string) {
    return this.mutate('visitors', userId, () => {
      const house = this.detail('rooms', userId, input.houseId);
      this.store.run('INSERT INTO uploads VALUES (?, ?, ?, ?)', imageId, userId, 'image/png', image);
      this.store.save('visitors', userId, { ...input, id: randomUUID(), status: 1, houseInfo: this.houseInfo(house), createdAt: this.iso(),
        validTime: 1440, url: `${this.publicBaseUrl}/media/${imageId}`, encryptedData: 'LOCAL-DEMO-NOT-A-REAL-PASS' });
    });
  }
  private houseInfo(house: RecordData) { return houseInfo(house); }
  ownedUpload(userId: string, url: string) { ownedUpload(this.store, this.publicBaseUrl, userId, url); }
  profile(userId: string) {
    const user = this.store.one('SELECT id, nickName, avatar, role FROM users WHERE id = ?', userId);
    requireValue(user, '用户不存在');
    return user;
  }
  updateProfile(userId: string, raw: unknown) {
    const input = z.object({ nickName: z.string().trim().min(2).max(10), avatar: z.string().max(2048) }).strict().parse(raw);
    if (input.avatar) this.ownedUpload(userId, input.avatar);
    return this.store.transaction(() => {
      this.store.run('UPDATE users SET nickName = ?, avatar = ? WHERE id = ?', input.nickName, input.avatar, userId);
      return this.profile(userId);
    });
  }
}
