import { existsSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { Store } from './database.js';
import { readConfig } from './config.js';
import { mobileSchema } from './auth.js';

// 仅在本机通过 CLI 配置第一个物业账号；HTTP 登录不能指定或提升角色。
if (existsSync('.env')) process.loadEnvFile('.env');
const [mobileInput, role] = process.argv.slice(2);
const mobile = mobileSchema.parse(mobileInput);
if (role !== 'admin' && role !== 'worker') throw new Error('用法：npm run role -- 手机号 admin或worker');
const store = new Store(readConfig().databasePath);
try {
  store.transaction(() => {
    const existing = store.one('SELECT id FROM users WHERE mobile = ?', mobile);
    if (existing) {
      store.run('UPDATE users SET role = ? WHERE id = ?', role, String(existing.id));
      store.run('DELETE FROM sessions WHERE userId = ?', String(existing.id));
    } else store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)', randomUUID(), mobile, role === 'admin' ? '物业管理员' : '维修师傅', role);
  });
  process.stdout.write(`已配置${role === 'admin' ? '物业' : '维修'}账号，请使用开发验证码重新登录。\n`);
} finally { store.close(); }
