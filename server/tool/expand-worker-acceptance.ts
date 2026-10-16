import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { backup } from 'node:sqlite';
import { Store } from '../src/database.js';
import { repairSchema } from '../src/community.js';

// Add variety to the primary worker's acceptance data without resetting any
// existing records, assignments, or actions taken during user verification.
const batch = 'worker-variety-20261015';
const store = new Store(resolve('data/workflow-demo.sqlite'));
try {
  const owner = String(store.one('SELECT id FROM users WHERE mobile = ?', '19900000001')?.id ?? '');
  const worker = store.one('SELECT id,nickName FROM users WHERE mobile = ? AND role = ?', '19900000003', 'worker');
  assert(owner && worker);
  assert(!store.one("SELECT id FROM repairs WHERE json_extract(payload, '$._fixtureBatch') = ?", batch),
    'Batch already exists; preserving verification actions.');
  const before = store.list('repairs', owner);
  const rooms = store.list('rooms', owner);
  const template = before.find(row => row._fixtureBatch === 'repair-acceptance-20261015' && row.repairItemId === '1001');
  assert(template);
  const cases = [
    { status: 5, point: '寺前皇小区', date: '2026-10-17', description: '厨房龙头底座渗水，使用后水沿台面流到水槽下方。请检查底座密封圈和连接软管。' },
    { status: 5, point: '丹溪花园(西区)', date: '2026-10-18', description: '阳台洗衣池龙头出水很小，其他位置水压正常。请检查出水口滤网是否被杂质堵住。' },
    { status: 2, point: '寺前皇小区', date: '2026-10-16', description: '卫生间冷热水龙头把手松动，调温时容易滑动。师傅已到场，正在检查固定螺钉和阀芯。' },
    { status: 2, point: '丹溪花园(西区)', date: '2026-10-17', description: '厨房水龙头转动接口处渗水，水流开大时更明显。正在拆检转动接头并核对密封件规格。' },
    { status: 3, point: '寺前皇小区', date: '2026-10-13', description: '洗手盆龙头出水分叉，水花经常溅到镜子和台面。申请清理出水口并检查起泡器。', result: '已拆洗起泡器滤网并清除水垢，更换损坏的滤芯。连续放水测试正常，水束集中，台面无明显溅水。' },
    { status: 3, point: '丹溪花园(西区)', date: '2026-10-14', description: '阳台水龙头把手关不到底，关闭后仍有细小水流。申请更换磨损的阀芯。', result: '已更换同规格阀芯并紧固把手，开关测试15次均正常，关闭后观察10分钟无残余水流。' },
  ];
  mkdirSync(resolve('data/backups'), { recursive: true });
  const backupPath = resolve('data/backups', `workflow-before-${batch}-${Date.now()}.sqlite`);
  await backup(store.db, backupPath);
  const added: object[] = [];
  store.transaction(() => {
    for (const [index, entry] of cases.entries()) {
      const room = rooms.find(row => row.point === entry.point && row._fixtureBatch === 'repair-acceptance-20261015');
      assert(room);
      const done = entry.status === 3;
      const day = done ? entry.date : '2026-10-15';
      const at = (hour: number) => `${day}T${hour}:00:00+08:00`;
      const input = repairSchema.parse({ houseId: room.id, repairItemId: '1001', mobile: '19900000001',
        appointment: entry.date, description: entry.description, attachment: template.attachment });
      const timeline = [
        { action: 'submitted', label: '住户申请', at: at(10), detail: '' },
        { action: 'assigned', label: '物业派单', at: at(11), detail: `指派给${worker.nickName}` },
        ...(entry.status !== 5 ? [{ action: 'accept', label: '处理中', at: at(12), detail: `${worker.nickName}已接单` }] : []),
        ...(done ? [{ action: 'complete', label: '已完成', at: at(13), detail: entry.result! }] : []),
      ];
      const record = { ...input, id: randomUUID(), repairItemName: '水电维修',
        houseInfo: `${room.point} ${room.building} ${room.floor}层 ${room.room}`,
        status: entry.status, workflowVersion: 1, revision: timeline.length,
        workerId: worker.id, workerName: worker.nickName, workerMobile: '19900000003',
        createdAt: at(10), assignedAt: at(11), timeline,
        ...(entry.status !== 5 ? { acceptedAt: at(12) } : {}),
        ...(done ? { completedAt: at(13), completionNote: entry.result } : {}),
        _fixtureBatch: batch, _fictional: true, _photoSources: template._photoSources,
        _fixtureCase: index,
      };
      store.save('repairs', owner, record);
      added.push(record);
    }
    for (const original of before) assert.deepEqual(store.get('repairs', owner, original.id), original);
  });
  const counts = [5, 2, 3].map(status => ({ status,
    count: store.list('repairs', owner).filter(row => row.workerId === worker.id && row.status === status).length }));
  const report = { batch, backupPath, added, counts };
  writeFileSync(resolve('../output/repair-fixtures-20261015/worker-variety-report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ added: added.length, preserved: before.length, backupPath, counts }));
} finally {
  store.close();
}
