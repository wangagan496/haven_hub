import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { backup } from 'node:sqlite';
import { Store, type RecordData } from '../src/database.js';
import { repairSchema } from '../src/repair/service.js';

// Explicitly targets the already running 3010 acceptance environment.
// Existing records outside the two original fixture repairs are preserved.
const batch = 'repair-acceptance-20261015';
const directory = resolve('../output/repair-fixtures-20261015');
const store = new Store(resolve('data/workflow-demo.sqlite'));
const base = 'http://127.0.0.1:3010';
const photos = JSON.parse(readFileSync(resolve(directory, 'photo-sources.json'), 'utf8')) as
  Array<{ key: string; file: string; source: string; author: string; license: string; licenseUrl: string }>;
const communities = [
  { point: '丹桂苑', building: '2幢', room: '302', floor: '3',
    address: '浙江省金华市婺城区李渔路988号', poi: '12978222480640284812', buildingPoi: '10945491304882634159' },
  { point: '寺前皇小区', building: '77号楼', room: '201', floor: '2',
    address: '浙江省金华市婺城区丹南街10号', poi: '753290192301501085', buildingPoi: '11853730000278464885' },
  { point: '丹溪花园(西区)', building: '5幢', room: '402', floor: '4',
    address: '浙江省金华市婺城区兰溪街388号', poi: '8717882293759171953', buildingPoi: '8125201826475594801' },
];
const cases = [
  { status: 1, house: 0, worker: 0, item: '1001', images: ['tap-1', 'tap-2'], description: '厨房水龙头已经关紧，出水口仍持续滴水，晚上安静时滴水声比较明显。希望检查阀芯和密封垫，预约上午上门。' },
  { status: 1, house: 1, worker: 1, item: '1002', images: ['hinge'], description: '厨房吊柜左侧柜门下垂，关门时会蹭到旁边的门板。上方铰链螺丝有松动，请带合适的螺丝和铰链检查。' },
  { status: 1, house: 2, worker: 2, item: '1002', images: ['window'], description: '卧室窗户把手转动发涩，关窗后不能完全扣紧，刮风时窗扇轻微晃动。请检查把手连杆和锁点。' },
  { status: 5, house: 0, worker: 0, item: '1001', images: ['tap-2', 'tap-1'], description: '洗手盆龙头关闭后还会流出一小股水，需要反复旋紧才能停下。近期漏水越来越频繁，请检修内部阀芯。' },
  { status: 5, house: 1, worker: 1, item: '1002', images: ['hinge-pin'], description: '次卧木门开合时有吱呀声，门扇略微下沉，锁舌需要抬一下门才能对准。请检查门铰链固定和轴销磨损。' },
  { status: 5, house: 2, worker: 2, item: '1002', images: ['window-catch', 'window'], description: '书房窗户锁扣有松动，扳手扣下后仍留有缝隙，夜间有明显风声。希望调整锁扣位置并加固固定螺丝。' },
  { status: 2, house: 0, worker: 0, item: '1001', images: ['tap-1', 'tap-2'], description: '卫生间水龙头连续滴水，龙头口周围有水垢。已关闭附近角阀，等师傅检查后更换磨损的密封件。' },
  { status: 2, house: 1, worker: 1, item: '1002', images: ['hinge'], description: '玄关柜门上方铰链松动，柜门关上后左右不齐。开合时有轻微碰撞声，请调平柜门并检查螺丝孔是否滑牙。' },
  { status: 2, house: 2, worker: 2, item: '1002', images: ['window', 'window-catch'], description: '客厅窗户把手回位不顺，锁扣不能稳定扣住。窗框本身没有破损，请优先检查五金件，必要时更换同规格配件。' },
  { status: 3, house: 0, worker: 0, item: '1001', images: ['tap-2', 'tap-1'], description: '厨房龙头关闭后出水口滴水，旋钮手感偏松。希望更换磨损部件并检查维修后是否还会渗漏。', result: '检查发现阀芯密封圈老化，已更换同规格阀芯及密封圈，清理起泡器水垢。连续开关测试10次，关闭后观察15分钟无滴漏，台面周边已擦干。' },
  { status: 3, house: 1, worker: 1, item: '1002', images: ['hinge', 'hinge-pin'], description: '厨房柜门无法完全合拢，合页处有松动，关门时门板碰到柜体。请上门调整并检查连接件。', result: '已重新固定上方铰链，补强松动的螺丝孔并调整门板间隙。开合20次无刮碰，柜门可以正常闭合，五金连接处已清洁。' },
  { status: 3, house: 2, worker: 2, item: '1002', images: ['window-catch', 'window'], description: '卧室窗户锁扣偏位，关窗时需要用力推拉，风大时会发出响声。希望检查锁扣和窗扇间隙。', result: '已调整锁扣位置并紧固把手底座，更换松动螺丝，清洁并润滑活动部位。开关窗测试正常，锁闭后窗扇无明显晃动。' },
];

try {
  if (store.one("SELECT id FROM repairs WHERE json_extract(payload, '$._fixtureBatch') = ?", batch)) {
    throw new Error('This batch already exists; refusing to reset user verification actions.');
  }
  const resident = store.one('SELECT id FROM users WHERE mobile = ?', '19900000001');
  const admin = store.one('SELECT id FROM users WHERE mobile = ?', '19900000002');
  assert(resident && admin, 'Expected acceptance accounts are missing');
  const residentId = String(resident.id);
  const priorRoom = store.get('rooms', residentId, 'b6b55b99-bc15-4595-ae79-709468759742');
  assert(priorRoom?.point === '演示小区', 'Original fixture house changed; stop instead of overwriting');
  const replaceIds = ['0b4cc2e9-7316-484d-8cf3-bd2a55bb3de5', 'd978c058-6544-4269-80bd-455f7a8c6ddc'];
  for (const id of replaceIds) assert(store.get('repairs', residentId, id)?.houseId === priorRoom.id);
  for (const photo of photos) assert(existsSync(resolve(directory, photo.file)));
  mkdirSync(resolve('data/backups'), { recursive: true });
  const backupPath = resolve('data/backups', `workflow-before-${batch}-${Date.now()}.sqlite`);
  await backup(store.db, backupPath);
  const seeded: RecordData[] = [];
  const workers = [
    { mobile: '19900000003', name: '张建国', specialty: '水路检修' },
    { mobile: '19900000004', name: '刘志强', specialty: '门柜五金' },
    { mobile: '19900000005', name: '陈海峰', specialty: '窗户五金' },
  ];
  store.transaction(() => {
    store.run('UPDATE users SET nickName = ? WHERE id = ?', '林晓峰', residentId);
    store.run('UPDATE users SET nickName = ? WHERE id = ?', '物业服务中心', String(admin.id));
    const workerIds = workers.map(worker => {
      const old = store.one('SELECT id,role FROM users WHERE mobile = ?', worker.mobile);
      assert(!old || old.role === 'worker');
      const id = old ? String(old.id) : randomUUID();
      if (old) store.run('UPDATE users SET nickName = ? WHERE id = ?', worker.name, id);
      else store.run("INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,'worker')", id, worker.mobile, worker.name);
      return id;
    });
    const photoUrls = new Map<string, string>();
    for (const photo of photos) {
      const id = randomBytes(32).toString('hex');
      store.run('INSERT INTO uploads(id,userId,mime,bytes) VALUES (?,?,?,?)', id, residentId,
        'image/jpeg', readFileSync(resolve(directory, photo.file)));
      photoUrls.set(photo.key, `${base}/media/${id}`);
    }
    const rooms = communities.map((community, index) => {
      const room = { id: index === 0 ? priorRoom.id : randomUUID(),
        point: community.point, building: community.building, room: community.room, floor: community.floor,
        name: '林晓峰', gender: 1, mobile: '19900000001', status: 2,
        // Pre-approved local fixture; no fabricated identity document photographs.
        idcardFrontUrl: '', idcardBackUrl: '', revision: index === 0 ? Number(priorRoom.revision ?? 0) + 1 : 1,
        reviewReason: '', reviewedBy: admin.id, submittedAt: '2026-10-10T01:00:00.000Z',
        reviewedAt: '2026-10-10T02:30:00.000Z', _fixtureBatch: batch,
        _locationSource: { provider: 'Tencent Maps', ...community, checkedDate: '2026-10-15', roomIsFictional: true } };
      store.save('rooms', residentId, room, index === 0);
      return room;
    });
    for (const [index, entry] of cases.entries()) {
      const room = rooms[entry.house]!;
      const worker = workers[entry.worker]!;
      const workerId = workerIds[entry.worker]!;
      const done = entry.status === 3;
      const day = done ? 12 + entry.house : 15;
      const at = (hour: number, minute: number) => `2026-10-${day}T${String(hour).padStart(2, '0')}:${String(minute).padStart(2, '0')}:00.000+08:00`;
      const createdAt = at(done ? 8 : 7, entry.house * 8);
      const assignedAt = at(done ? 9 : 7, 30 + entry.house * 5);
      const acceptedAt = at(done ? 9 : 8, 45 + entry.house * 5);
      const completedAt = at(11, entry.house * 10);
      const input = repairSchema.parse({ houseId: room.id, repairItemId: entry.item,
        mobile: '19900000001', appointment: done ? `2026-10-${day}` : '2026-10-16',
        description: entry.description, attachment: entry.images.map(key => photoUrls.get(key)) });
      const timeline = [{ action: 'submitted', label: '住户申请', at: createdAt, detail: '' }];
      if (entry.status !== 1) timeline.push({ action: 'assigned', label: '物业派单', at: assignedAt, detail: `指派给${worker.name}` });
      if (entry.status === 2 || done) timeline.push({ action: 'accept', label: '处理中', at: acceptedAt, detail: `${worker.name}已接单` });
      if (done) timeline.push({ action: 'complete', label: '已完成', at: completedAt, detail: entry.result! });
      const replacement = index === 9 ? replaceIds[0] : index === 6 ? replaceIds[1] : undefined;
      const record = { ...input, id: replacement ?? randomUUID(), status: entry.status,
        workflowVersion: 1, revision: replacement ? 10 : timeline.length,
        houseInfo: `${room.point} ${room.building} ${room.floor}层 ${room.room}`,
        repairItemName: entry.item === '1001' ? '水电维修' : '门窗维修', createdAt, timeline,
        ...(entry.status !== 1 ? { workerId, workerName: worker.name, workerMobile: worker.mobile, assignedAt } : {}),
        ...(entry.status === 2 || done ? { acceptedAt } : {}),
        ...(done ? { completedAt, completionNote: entry.result } : {}),
        _fixtureBatch: batch, _fictional: true,
        _photoSources: entry.images.map(key => photos.find(photo => photo.key === key)),
      };
      store.save('repairs', residentId, record, Boolean(replacement));
      seeded.push(record);
    }
    for (const status of [1, 5, 2, 3]) assert.equal(seeded.filter(row => row.status === status).length, 3);
    assert.equal(store.list('repairs', residentId).length, 12);
    for (const row of seeded) {
      assert(!String(row.houseInfo).includes('演示'));
      assert((row.attachment as string[]).length > 0);
      if (row.status === 3) assert(String(row.completionNote).length > 10);
    }
  });
  const report = { batch, backupPath, service: base, database: 'server/data/workflow-demo.sqlite',
    location: { provider: 'Tencent Maps IP + nearby + building search', city: '浙江省金华市',
      coordinate: { lat: 29.07812, lng: 119.64759 }, preciseHomeLocation: false },
    communities, workers, resident: '19900000001', admin: '19900000002',
    records: seeded.map(row => ({ id: row.id, houseInfo: row.houseInfo, status: row.status,
      description: row.description, workerName: row.workerName, appointment: row.appointment,
      photos: row.attachment, completionNote: row.completionNote })),
    note: 'Real map communities/buildings; fictional rooms, people and events. Related openly licensed photographs, not on-site evidence. Original haven.sqlite untouched.' };
  writeFileSync(resolve(directory, 'seed-report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({ batch, backupPath, rooms: communities.length, repairs: seeded.length,
    counts: { pendingAssignment: 3, waitingAcceptance: 3, processing: 3, completed: 3 }, workers }));
} finally {
  store.close();
}
