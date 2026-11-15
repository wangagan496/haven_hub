import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { initialCapacities, scheduleDefaults } from './repair/schedule.js';
import { bindMedia, bindRecordMedia } from './media.js';
import { migrateManagementAudit } from './management-audit.js';

export type Collection = 'rooms' | 'repairs' | 'visitors';
export type RecordData = { id: string; [key: string]: unknown };

// 同步 SQLite 连接串行运行短事务；外部网络请求必须在事务之外等待。
export class Store {
  onRepairSaved?: (owner: string, record: RecordData) => void;
  beforeClose?: () => void;
  readonly db: DatabaseSync;
  private mediaReady = false;
  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    try { this.initialize(); }
    catch (error) { this.db.close(); throw error; }
  }

  private initialize() {
    this.db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;');
    const version = this.db.prepare('PRAGMA user_version').get()?.user_version;
    if (![0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13].includes(Number(version))) throw new Error('数据库版本不兼容');
    if (version === 0) this.transaction(() => {
      this.db.exec(`
        CREATE TABLE users (id TEXT PRIMARY KEY, mobile TEXT NOT NULL UNIQUE, nickName TEXT NOT NULL, avatar TEXT NOT NULL DEFAULT '');
        CREATE TABLE sessions (accessHash TEXT PRIMARY KEY, refreshHash TEXT NOT NULL UNIQUE,
          userId TEXT NOT NULL REFERENCES users(id), accessExpires INTEGER NOT NULL, refreshExpires INTEGER NOT NULL);
        CREATE TABLE codes (mobile TEXT PRIMARY KEY, hash TEXT NOT NULL, expires INTEGER NOT NULL, sentAt INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE uploads (id TEXT PRIMARY KEY, userId TEXT NOT NULL REFERENCES users(id), mime TEXT NOT NULL, bytes BLOB NOT NULL);
      `);
      for (const table of ['rooms', 'repairs', 'visitors']) {
        // 表名完全来自代码常量，不接收请求值；业务字段保存在校验过的 JSON 中。
        this.db.exec(`CREATE TABLE ${table} (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE,
          userId TEXT NOT NULL REFERENCES users(id), payload TEXT NOT NULL CHECK(json_valid(payload)));
          CREATE INDEX ${table}_owner ON ${table}(userId, seq DESC);`);
      }
      this.db.exec('PRAGMA user_version = 1;');
    });
    if (version === 0 || version === 1) this.transaction(() => {
      this.db.exec("ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'resident' CHECK(role IN ('resident','admin','worker')); PRAGMA user_version = 2;");
    });
    // 推送表。早期版本在 user_version 2 下直接建过这些表，所以用 IF NOT EXISTS 兼容。
    if (Number(version) < 3) this.transaction(() => {
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS push_settings (name TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS push_devices (id TEXT PRIMARY KEY, userId TEXT NOT NULL REFERENCES users(id), platform TEXT NOT NULL,
          endpointHash TEXT NOT NULL UNIQUE, payload TEXT NOT NULL, updatedAt INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS notifications (id TEXT PRIMARY KEY, userId TEXT NOT NULL REFERENCES users(id), repairId TEXT NOT NULL,
          taskKey TEXT NOT NULL, role TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, active INTEGER NOT NULL, createdAt INTEGER NOT NULL,
          readAt INTEGER, remindedAt INTEGER NOT NULL DEFAULT 0, UNIQUE(userId,repairId,taskKey));
        CREATE TABLE IF NOT EXISTS push_deliveries (notificationId TEXT NOT NULL REFERENCES notifications(id), deviceId TEXT NOT NULL,
          status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, nextAt INTEGER NOT NULL, reason TEXT NOT NULL DEFAULT '',
          lease TEXT NOT NULL DEFAULT '', PRIMARY KEY(notificationId,deviceId));
        CREATE INDEX IF NOT EXISTS notifications_user ON notifications(userId,active,createdAt);
      `);
      if (!this.db.prepare('PRAGMA table_info(push_deliveries)').all().some(column => column.name === 'lease')) {
        this.db.exec("ALTER TABLE push_deliveries ADD COLUMN lease TEXT NOT NULL DEFAULT ''");
      }
      this.db.exec('PRAGMA user_version = 3;');
    });
    if (Number(version) < 4) this.transaction(() => {
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS repair_capacity_defaults (hour TEXT PRIMARY KEY, capacity INTEGER NOT NULL CHECK(capacity >= 0));
        CREATE TABLE IF NOT EXISTS repair_capacity_overrides (date TEXT NOT NULL, hour TEXT NOT NULL,
          capacity INTEGER NOT NULL CHECK(capacity >= 0), PRIMARY KEY(date,hour));
        CREATE INDEX IF NOT EXISTS repairs_slot ON repairs(json_extract(payload,'$.slot')) WHERE json_valid(payload);
      `);
      for (const [hour, capacity] of Object.entries(initialCapacities)) {
        this.run('INSERT OR IGNORE INTO repair_capacity_defaults(hour,capacity) VALUES (?,?)', hour, capacity);
      }
      for (const row of this.db.prepare("SELECT id,userId,payload FROM repairs WHERE json_valid(payload) AND json_type(payload) = 'object'").all()) {
        const record = JSON.parse(String(row.payload)) as RecordData;
        this.save('repairs', String(row.userId), { ...scheduleDefaults(record), ...record }, true);
      }
      this.db.exec('PRAGMA user_version = 4;');
    });
    if (Number(version) < 5) this.transaction(() => {
      this.db.exec(`CREATE TABLE repair_capacity_weekdays (
        weekday INTEGER NOT NULL CHECK(weekday BETWEEN 1 AND 7), hour TEXT NOT NULL,
        capacity INTEGER NOT NULL CHECK(capacity >= 0), PRIMARY KEY(weekday,hour));
        PRAGMA user_version = 5;`);
    });
    if (Number(version) < 6) this.transaction(() => {
      this.db.exec(`CREATE TABLE IF NOT EXISTS worker_skills (
          workerId TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          skill TEXT NOT NULL CHECK(skill IN ('plumbing','electrical','doors')), PRIMARY KEY(workerId, skill));
        CREATE TABLE IF NOT EXISTS worker_leaves (
          workerId TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
          date TEXT NOT NULL, hour TEXT NOT NULL DEFAULT '', reason TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(workerId, date, hour));
        CREATE INDEX IF NOT EXISTS worker_leaves_slot ON worker_leaves(date, hour);`);
      if (!this.db.prepare('PRAGMA table_info(users)').all().some(column => column.name === 'workforceRevision')) {
        this.db.exec('ALTER TABLE users ADD COLUMN workforceRevision INTEGER NOT NULL DEFAULT 0');
      }
      this.db.exec('PRAGMA user_version = 6');
    });
    if (Number(version) < 7) this.transaction(() => {
      this.db.exec(`CREATE TABLE IF NOT EXISTS worker_skill_audit (
        workerId TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        actorId TEXT NOT NULL, actorName TEXT NOT NULL, changedAt TEXT NOT NULL);
        PRAGMA user_version = 7;`);
    });
    if (Number(version) < 8) this.transaction(() => {
      this.db.exec(`CREATE TABLE IF NOT EXISTS repair_submissions (
        userId TEXT NOT NULL REFERENCES users(id), submissionId TEXT NOT NULL,
        requestHash TEXT NOT NULL, repairId TEXT REFERENCES repairs(id), createdAt INTEGER NOT NULL,
        PRIMARY KEY(userId, submissionId));
        PRAGMA user_version = 8;`);
    });
    if (Number(version) < 9) this.transaction(() => {
      if (!this.db.prepare('PRAGMA table_info(users)').all().some(column => column.name === 'disabledAt')) {
        this.db.exec('ALTER TABLE users ADD COLUMN disabledAt INTEGER NOT NULL DEFAULT 0');
      }
      this.db.exec(`CREATE TABLE IF NOT EXISTS account_events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, userId TEXT NOT NULL REFERENCES users(id),
        actorId TEXT NOT NULL REFERENCES users(id), enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
        reason TEXT NOT NULL, createdAt INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS account_events_user ON account_events(userId,seq DESC);`);
      this.db.exec(`CREATE TABLE IF NOT EXISTS upload_bindings (
        imageId TEXT NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
        purpose TEXT NOT NULL CHECK(purpose IN ('identity','repair','visitor','avatar')),
        recordId TEXT NOT NULL, PRIMARY KEY(imageId,purpose,recordId));`);
      for (const table of ['rooms', 'repairs', 'visitors'] as const) {
        for (const row of this.db.prepare(`SELECT userId,payload FROM ${table} WHERE json_valid(payload) AND json_type(payload)='object'`).all()) {
          bindRecordMedia(this.db, table, String(row.userId), JSON.parse(String(row.payload)) as RecordData);
        }
      }
      for (const user of this.db.prepare("SELECT id,avatar FROM users WHERE avatar<>''").all()) {
        bindMedia(this.db, String(user.id), 'avatar', String(user.id), [user.avatar]);
      }
      this.db.exec('PRAGMA user_version = 9;');
    });
    if (Number(version) < 10) this.transaction(() => {
      this.db.exec(`CREATE TABLE IF NOT EXISTS visitor_submissions (
        userId TEXT NOT NULL REFERENCES users(id), submissionId TEXT NOT NULL,
        requestHash TEXT NOT NULL, visitorId TEXT REFERENCES visitors(id), createdAt INTEGER NOT NULL,
        PRIMARY KEY(userId, submissionId));
        PRAGMA user_version = 10;`);
    });
    if (Number(version) < 11) this.transaction(() => {
      // 房屋可删除，回执仍保留原编号；不以外键删除回执，防止迟到重试重建房屋。
      this.db.exec(`CREATE TABLE IF NOT EXISTS room_submissions (
        userId TEXT NOT NULL REFERENCES users(id), submissionId TEXT NOT NULL,
        requestHash TEXT NOT NULL, roomId TEXT, createdAt INTEGER NOT NULL,
        PRIMARY KEY(userId, submissionId));
        PRAGMA user_version = 11;`);
    });
    if (Number(version) < 12) this.transaction(() => migrateManagementAudit(this.db));
    if (Number(version) < 13) this.transaction(() => {
      for (const table of ['codes', 'sessions']) {
        if (!this.db.prepare(`PRAGMA table_info(${table})`).all().some(column => column.name === 'authMode'))
          this.db.exec(`ALTER TABLE ${table} ADD COLUMN authMode TEXT NOT NULL DEFAULT 'development'`);
      }
      this.db.exec(`
        CREATE TABLE IF NOT EXISTS sms_send_attempts (id INTEGER PRIMARY KEY, mobileHash TEXT NOT NULL, sentAt INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS sms_attempts_time ON sms_send_attempts(sentAt);
        CREATE INDEX IF NOT EXISTS sms_attempts_mobile_time ON sms_send_attempts(mobileHash,sentAt);
        CREATE TABLE IF NOT EXISTS deployment_identity (id INTEGER PRIMARY KEY CHECK(id=1), environment TEXT NOT NULL);
        PRAGMA user_version = 13;
      `);
    });
    this.mediaReady = true;
  }
  private depth = 0;
  get isInTransaction() { return this.depth > 0; }
  bindEnvironment(environment: 'production' | 'non-production') {
    this.transaction(() => {
      const identity = this.one('SELECT environment FROM deployment_identity WHERE id=1');
      if (identity && identity.environment !== environment)
        throw new Error('生产与非生产环境必须使用独立数据库，禁止切换现有数据库用途');
      if (!identity && environment === 'production' && Number(this.one('SELECT COUNT(*) AS n FROM users')!.n) > 0)
        throw new Error('旧数据库含有未核实账号，不能直接作为生产数据库');
      this.run('INSERT OR IGNORE INTO deployment_identity(id,environment) VALUES (1,?)', environment);
    });
  }
  // 可重入：外层已在事务中时直接执行，由外层统一提交或回滚。
  transaction<T>(operation: () => T): T {
    if (this.depth > 0) {
      this.depth++;
      try { return operation(); } finally { this.depth--; }
    }
    this.db.exec('BEGIN IMMEDIATE');
    this.depth = 1;
    try {
      const result = operation();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    } finally {
      this.depth = 0;
    }
  }
  /** 在当前事务内开一个保存点：operation 失败只回滚它自己的写入，外层事务继续。 */
  savepoint<T>(operation: () => T): T {
    return this.transaction(() => {
      this.db.exec('SAVEPOINT nested');
      try {
        const result = operation();
        this.db.exec('RELEASE nested');
        return result;
      } catch (error) {
        this.db.exec('ROLLBACK TO nested; RELEASE nested');
        throw error;
      }
    });
  }
  list(table: Collection, userId: string): RecordData[] {
    return this.db.prepare(`SELECT payload FROM ${table} WHERE userId = ? ORDER BY seq DESC`).all(userId)
      .map(row => JSON.parse(String(row.payload)) as RecordData);
  }
  roomOwnerNames(): { id: string; name: string }[] {
    return this.db.prepare("SELECT id, json_extract(payload, '$.name') AS name FROM rooms").all()
      .map(row => ({ id: String(row.id), name: String(row.name ?? '') }));
  }
  get(table: Collection, userId: string, id: string): RecordData | undefined {
    const row = this.db.prepare(`SELECT payload FROM ${table} WHERE userId = ? AND id = ?`).get(userId, id);
    return row ? JSON.parse(String(row.payload)) as RecordData : undefined;
  }
  save(table: Collection, userId: string, record: RecordData, editing = false) {
    this.transaction(() => {
    if (editing) this.db.prepare(`UPDATE ${table} SET payload = ? WHERE userId = ? AND id = ?`)
      .run(JSON.stringify(record), userId, record.id);
    else this.db.prepare(`INSERT INTO ${table}(id, userId, payload) VALUES (?, ?, ?)`)
      .run(record.id, userId, JSON.stringify(record));
      if (this.mediaReady) bindRecordMedia(this.db, table, userId, record);
      if (table === 'repairs') this.onRepairSaved?.(userId, record);
    });
  }
  delete(table: Collection, userId: string, id: string) {
    this.db.prepare(`DELETE FROM ${table} WHERE userId = ? AND id = ?`).run(userId, id);
  }
  one(sql: string, ...values: SQLInputValue[]) { return this.db.prepare(sql).get(...values); }
  run(sql: string, ...values: SQLInputValue[]) { return this.db.prepare(sql).run(...values); }
  close() { this.beforeClose?.(); this.db.close(); }
}
