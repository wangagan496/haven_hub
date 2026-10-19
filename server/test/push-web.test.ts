import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const id='12345678-1234-1234-1234-123456789abc';
function worker() {
  const handlers: Record<string,(event: any)=>void> = {};
  const shown: any[]=[];
  const posted: any[]=[];
  const opened: string[]=[];
  let state={active:true,profileId:'current'};
  const self={
    registration:{scope:'https://example.test/admin/push/',showNotification:async(title:string,options:any)=>{shown.push({title,...options});}},
    addEventListener:(name:string,handler:(event:any)=>void)=>{handlers[name]=handler;},
    clients:{matchAll:async()=>[{url:'https://example.test/admin/',focus:async()=>{},postMessage:(data:any)=>posted.push(data)}],
      openWindow:async(url:string)=>{opened.push(url);},claim:async()=>{}},
    skipWaiting:async()=>{},
  };
  const caches={open:async()=>({match:async()=>({json:async()=>state})})};
  runInNewContext(readFileSync(new URL('../../web/push/sw.js',import.meta.url),'utf8'),{self,caches,URL});
  return {shown,posted,opened,setState:(next:typeof state)=>{state=next;},
    emit:async(name:string,event:any)=>{let wait:Promise<void>=Promise.resolve();handlers[name]!({...event,waitUntil:(promise:Promise<void>)=>{wait=promise;}});await wait;}};
}

test('service worker ignores old-account and disabled pushes; accepted push uses a stable tag',async()=>{
  const w=worker();
  await w.emit('push',{data:{json:()=>({profileId:'old',notificationId:id})}});
  assert.equal(w.shown.length,0);
  await w.emit('push',{data:{json:()=>({profileId:'current',notificationId:id})}});
  assert.equal(w.shown.length,1);
  assert.equal(w.shown[0].tag,'haven-'+id);
  assert.equal(w.shown[0].body,'有报修事项需要处理，请打开查看。');
  w.setState({active:false,profileId:'current'});
  await w.emit('push',{data:{json:()=>({profileId:'current',notificationId:id})}});
  assert.equal(w.shown.length,1);
});

test('notification click forwards only a valid task id to the existing workbench',async()=>{
  const w=worker();
  await w.emit('notificationclick',{notification:{close:()=>{},data:{notificationId:id}}});
  assert.equal(w.posted.length,1);
  assert.equal(w.posted[0].notificationId,id);
  assert.equal(w.opened.length,0);
  await w.emit('notificationclick',{notification:{close:()=>{},data:{notificationId:'https://evil.test/'}}});
  assert.equal(w.posted.length,1);
});
