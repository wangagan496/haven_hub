import { randomBytes, randomUUID } from 'node:crypto';
import { resolve } from 'node:path';
import sharp from 'sharp';
import { createApp } from '../src/app.js';
import { readConfig } from '../src/config.js';
import { CommunityService } from '../src/community/service.js';

// 独立演示数据库，所有资料均为虚构；不会修改原 haven.sqlite。
const config = { ...readConfig({}), port: 3010, publicBaseUrl: 'http://127.0.0.1:3010', databasePath: resolve('data/workflow-demo.sqlite') };
const { app, store } = createApp(config, { workflowWebRoot: resolve('../build/web/workflow') });
const service = new CommunityService(store, config.publicBaseUrl);
const accounts = [
  {mobile:'19900000001',role:'resident',name:'演示住户'},
  {mobile:'19900000002',role:'admin',name:'演示物业'},
  {mobile:'19900000003',role:'worker',name:'张师傅'},
] as const;
for (const account of accounts) {
  if (!store.one('SELECT id FROM users WHERE mobile = ?', account.mobile)) {
    store.run('INSERT INTO users(id,mobile,nickName,role) VALUES (?,?,?,?)',randomUUID(),account.mobile,account.name,account.role);
  }
  if(account.role==='worker') {
    const worker=store.one("SELECT id FROM users WHERE mobile=? AND role='worker'",account.mobile);
    if(worker && !store.one('SELECT 1 FROM worker_skills WHERE workerId=?',String(worker.id))) {
      for(const skill of ['plumbing','electrical','doors']) store.run('INSERT INTO worker_skills(workerId,skill) VALUES (?,?)',String(worker.id),skill);
    }
  }
}
const resident = String(store.one('SELECT id FROM users WHERE mobile = ?',accounts[0].mobile)!.id);
if (!store.list('rooms',resident).length) {
  const id=randomBytes(32).toString('hex');
  const svg=Buffer.from('<svg width="640" height="400"><rect width="640" height="400" fill="#e5edf1"/><path d="M100 200 H310 V320 H520" stroke="#5591af" stroke-width="30" fill="none"/><text x="40" y="60" font-size="28" fill="#263744">DEMO PHOTO - NO PERSONAL DATA</text></svg>');
  const image=await sharp(svg).png().toBuffer();
  store.run('INSERT INTO uploads VALUES (?,?,?,?)',id,resident,'image/png',image);
  const url=`${config.publicBaseUrl}/media/${id}`;
  const house=service.saveRoom(resident,{point:'演示小区',building:'1栋',room:'101',name:'测试住户',gender:1,mobile:accounts[0].mobile,idcardFrontUrl:url,idcardBackUrl:url}).rows[0]!;
  // 演示种子使用“等待安排”，避免写死日期过期或绕过时段规则。
  service.createRepair(resident,{houseId:house.id,repairItemId:'1004',mobile:accounts[0].mobile,slot:'',description:'厨房水管接口漏水，请检查。此记录仅用于流程演示。',attachment:[url]});
}
const server=app.listen(config.port,config.host,()=>process.stdout.write('物业后台：http://127.0.0.1:3010/admin/\n维修工作台：http://127.0.0.1:3010/workflow/#/worker\n住户19900000001 / 物业19900000002 / 师傅19900000003，均使用开发验证码。\n'));
server.on('error',error=>{process.stderr.write(`${error.message}\n`);store.close();process.exitCode=1;});
for(const signal of ['SIGINT','SIGTERM'] as const)process.on(signal,()=>server.close(()=>{store.close();process.exit(0);}));
