import { z } from 'zod';
import { mobileSchema } from '../auth.js';
import type { RecordData } from '../database.js';

const text = z.string().trim().min(1).max(100);

// 这里的房屋是账号提交的住房登记资料，不是跨账号共享的物理房产主数据。
export const housingSchema = z.object({
  submissionId: z.string().uuid().optional(),
  id: z.string().uuid().optional(), revision: z.number().int().min(0).optional(),
  point: text, building: text, room: text,
  floor: z.string().trim().regex(/^(?:[1-9]\d{0,3}|B[1-9]\d?)?$/).default(''),
  name: z.string().trim().regex(/^(?=.{2,15}$)[\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z '-]*[\u4e00-\u9fa5A-Za-z]$/),
  gender: z.union([z.literal(0), z.literal(1)]),
  mobile: mobileSchema, idcardFrontUrl: z.url(), idcardBackUrl: z.url(),
}).strict().refine(input => !(input.id && input.submissionId), { message: '编辑不能使用创建回执' });

export const housingReviewSchema = z.object({
  revision: z.number().int().min(0),
  decision: z.enum(['approve', 'reject']),
  reason: z.string().trim().max(1000).default(''),
}).strict();

export type HousingInput = z.infer<typeof housingSchema>;
export type HousingMutationResult = {
  complete: true; rows: RecordData[]; total: number; createdId?: string;
};
export type HousingSubmissionResult =
  | { state: 'unknown' | 'closed'; createdId: '' }
  | { state: 'created' | 'deleted'; createdId: string };
export type HousingReviewResult = RecordData & {
  status: 2 | 3; revision: number; reviewedBy: string; reviewedAt: string; reviewReason: string;
};

// 中文姓名可重名；含英文字母的姓名按大小写及连续空格归一后全局唯一。
export function englishOwnerKey(name: string): string | null {
  return /[A-Za-z]/.test(name) ? name.trim().replace(/ +/g, ' ').toLowerCase() : null;
}

export function housingValidationMessage(error: z.ZodError): string {
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
  if (field === 'idcardFrontUrl' || field === 'idcardBackUrl') return `${label}无效，请重新上传`;
  if (issue?.code === 'too_big') return `${label}不能超过100个字符`;
  if (field && (issue?.code === 'too_small' || issue?.code === 'invalid_type')) return `${label}不能为空`;
  return `${label}格式不正确，请检查输入`;
}
