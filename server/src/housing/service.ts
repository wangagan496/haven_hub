import { createHash, randomUUID } from 'node:crypto';
import { z } from 'zod';
import type { RecordData, Store } from '../database.js';
import { ApiError, requireValue } from '../errors.js';
import { ManagementAudit, type AuditTarget } from '../management-audit.js';
import { ownedUpload } from '../media.js';
import { englishOwnerKey, housingSchema, housingReviewSchema, housingValidationMessage,
  type HousingInput, type HousingMutationResult, type HousingSubmissionResult, type HousingReviewResult } from './model.js';

/** 住房登记、编辑、删除、回执和审核共用同一版本与事务规则。 */
export class HousingService {
  private readonly audit: ManagementAudit;
  constructor(private readonly store: Store, private readonly publicBaseUrl: string,
    private readonly now: () => number = Date.now) {
    this.audit = new ManagementAudit(store, now);
  }

  list(userId: string): RecordData[] {
    return this.store.list('rooms', userId);
  }

  detail(userId: string, id: string): RecordData {
    const value = this.store.get('rooms', userId, id);
    if (!value) throw new ApiError(404, 40400, '记录不存在或无权访问');
    return value;
  }

  // 写入和权威列表是一个结果：构造列表失败也必须回滚写入、回执和媒体绑定。
  private mutate(userId: string, operation: () => void): HousingMutationResult {
    return this.store.transaction(() => {
      operation();
      const rows = this.list(userId);
      return { complete: true, rows, total: rows.length };
    });
  }

  save(userId: string, raw: unknown): HousingMutationResult {
    const parsed = housingSchema.safeParse(raw);
    if (!parsed.success) throw new ApiError(200, 40000, housingValidationMessage(parsed.error));
    const input = parsed.data;
    return this.store.transaction(() => {
      const { submissionId, ...content } = input;
      const requestHash = this.requestHash(input);
      if (submissionId) {
        const receipt = this.store.one('SELECT requestHash,roomId FROM room_submissions WHERE userId=? AND submissionId=?', userId, submissionId);
        if (receipt) {
          if (receipt.roomId === null) throw new ApiError(409, 40903, '本次提交已停止，请使用新的提交回执');
          if (receipt.requestHash !== requestHash) throw new ApiError(409, 40902, '该提交回执对应的内容不同，请先查看原提交结果');
          if (!this.store.get('rooms', userId, String(receipt.roomId))) throw new ApiError(409, 40904, '原房屋已删除，本次提交不会重新创建');
          const rows = this.list(userId);
          return { complete: true, rows, total: rows.length, createdId: String(receipt.roomId) };
        }
      }
      const id = input.id ?? randomUUID();
      const result = this.mutate(userId, () => {
        const previous = input.id ? this.detail(userId, input.id) : undefined;
        // 先核对所属账号，再比较版本；不能通过版本错误暴露别人的住房资料。
        if (previous && input.revision !== Number(previous.revision ?? 0)) {
          throw new ApiError(409, 40900, '房屋资料或审核状态已更新，请重新加载后再提交');
        }
        ownedUpload(this.store, this.publicBaseUrl, userId, input.idcardFrontUrl, 'identity');
        ownedUpload(this.store, this.publicBaseUrl, userId, input.idcardBackUrl, 'identity');
        const nameKey = englishOwnerKey(input.name);
        if (nameKey !== null && this.store.roomOwnerNames().some(room =>
          room.id !== input.id && englishOwnerKey(room.name) === nameKey)) {
          throw new ApiError(200, 40002, '该英文姓名已被登记，请更换姓名');
        }
        this.store.save('rooms', userId, { ...content, id, status: 1,
          revision: Number(previous?.revision ?? 0) + 1, reviewReason: '', reviewedAt: '',
          submittedAt: new Date(this.now()).toISOString() }, Boolean(input.id));
        if (submissionId) this.store.run('INSERT INTO room_submissions VALUES (?,?,?,?,?)',
          userId, submissionId, requestHash, id, this.now());
      });
      return input.id ? result : { ...result, createdId: id };
    });
  }

  private requestHash(input: HousingInput): string {
    const { submissionId: _, id: _id, revision: _revision, ...content } = input;
    return createHash('sha256').update(JSON.stringify(content)).digest('hex');
  }

  submissionResult(userId: string, rawId: unknown): HousingSubmissionResult {
    const id = z.string().uuid().parse(rawId);
    const receipt = this.store.one('SELECT roomId FROM room_submissions WHERE userId=? AND submissionId=?', userId, id);
    if (!receipt) return { state: 'unknown', createdId: '' };
    if (receipt.roomId === null) return { state: 'closed', createdId: '' };
    const createdId = String(receipt.roomId);
    return { state: this.store.get('rooms', userId, createdId) ? 'created' : 'deleted', createdId };
  }

  closeSubmission(userId: string, rawId: unknown): HousingSubmissionResult {
    const id = z.string().uuid().parse(rawId);
    return this.store.transaction<HousingSubmissionResult>(() => {
      const result = this.submissionResult(userId, id);
      if (result.state !== 'unknown') return result;
      this.store.run('INSERT INTO room_submissions VALUES (?,?,?,NULL,?)', userId, id, '', this.now());
      return { state: 'closed', createdId: '' };
    });
  }

  remove(userId: string, id: string, raw: unknown): HousingMutationResult {
    return this.mutate(userId, () => {
      const previous = this.detail(userId, id);
      const { revision } = z.object({ revision: z.number().int().min(0).optional() }).strict().parse(raw ?? {});
      if (revision !== Number(previous.revision ?? 0)) {
        throw new ApiError(409, 40900, '房屋资料或审核状态已更新，请刷新核对后再删除');
      }
      this.store.delete('rooms', userId, id);
    });
  }

  private requireAdministrator(userId: string): void {
    if (this.store.one('SELECT role FROM users WHERE id = ?', userId)?.role !== 'admin') {
      throw new ApiError(403, 40300, '仅物业管理员可操作');
    }
  }

  reviewQueue(reviewerUserId: string): RecordData[] {
    this.requireAdministrator(reviewerUserId);
    return this.store.db.prepare('SELECT payload FROM rooms ORDER BY seq DESC').all()
      .map(row => JSON.parse(String(row.payload)) as RecordData);
  }

  review(houseId: string, reviewerUserId: string, raw: unknown): HousingReviewResult {
    this.requireAdministrator(reviewerUserId);
    const input = housingReviewSchema.parse(raw);
    if (input.decision === 'reject') requireValue(input.reason.length > 0, '请填写打回原因');
    return this.store.transaction(() => {
      const stored = this.store.one('SELECT userId, payload FROM rooms WHERE id = ?', houseId);
      if (!stored) throw new ApiError(404, 40400, '记录不存在');
      const ownerUserId = String(stored.userId);
      const house = JSON.parse(String(stored.payload)) as RecordData;
      const target: AuditTarget = { type: 'room', id: houseId };
      const before = this.audit.snapshot(target);
      const currentRevision = Number(house.revision ?? 0);
      if (currentRevision !== input.revision) throw new ApiError(409, 40900, '记录已更新，请刷新后再操作');
      if (house.status !== 1) throw new ApiError(409, 40900, '这份房屋资料已审核，请刷新查看最新状态');
      const reviewed: HousingReviewResult = {
        ...house,
        status: input.decision === 'approve' ? 2 : 3,
        reviewReason: input.decision === 'reject' ? input.reason : '',
        reviewedAt: new Date(this.now()).toISOString(),
        reviewedBy: reviewerUserId,
        revision: currentRevision + 1,
      };
      this.store.save('rooms', ownerUserId, reviewed, true);
      // 审核及审计记录必须一起提交；审计写入失败不能留下未留痕的审核结果。
      this.audit.append({ actorId: reviewerUserId, action: 'room.review' }, target, before);
      return reviewed;
    });
  }
}
