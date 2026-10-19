import { DatabaseSync, type SQLInputValue } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';

export type Collection = 'rooms' | 'repairs' | 'visitors';
export type RecordData = { id: string; [key: string]: unknown };

// 同步 SQLite 连接串行运行短事务。仅面向本地学习，无连接池或后台任务。
export class Store {
  onRepairSaved?: (owner: string, record: RecordData) => void;
  beforeClose?: () => void;
  readonly db: DatabaseSync;
  constructor(path: string) {
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true });
    this.db = new DatabaseSync(path);
    this.db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;');
    const version = this.db.prepare('PRAGMA user_version').get()?.user_version;
    if (version !== 0 && version !== 1 && version !== 2 && version !== 3) throw new Error('数据库版本不兼容');
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
    if (version !== 3) this.transaction(() => {
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
  }
  private depth = 0;
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
