import { createServer } from 'node:http';
import { writeFileSync } from 'node:fs';
import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';
import { manageServerLifecycle } from '../../src/server-lifecycle.js';
import type { PushTransport } from '../../src/push-transport.js';

const report = { sends: 0, sendFinished: false, responseFinished: false, closeCalls: 0,
  closedBeforeSend: false, closedBeforeResponse: false, sending: 0, queued: 0 };
const transport: PushTransport = {
  publicConfig: () => ({ webPublicKey: '', harmonyConfigured: true }),
  send: async () => {
    report.sends++;
    process.send?.({ kind: 'sending' });
    await new Promise(resolve => setTimeout(resolve, 250));
    report.sendFinished = true;
    return { status: 'accepted', reason: 'synthetic' };
  },
};
const instance = createApp(readConfig(), { pushTimer: false, pushTransport: transport });
const server = createServer((request, response) => {
  if (request.url === '/fixture-slow') {
    response.on('finish', () => { report.responseFinished = true; });
    response.writeHead(200, { 'Content-Type': 'text/plain' }); response.write('first-');
    if (process.env.TEST_HTTP_TIMEOUT !== 'true') setTimeout(() => response.end('finished'), 250);
    return;
  }
  instance.app(request, response);
});
manageServerLifecycle(server, { stopBackgroundTasks: instance.stopBackgroundTasks, runtimeLog: instance.runtimeLog,
  closeResources: () => {
    report.closeCalls++;
    report.closedBeforeSend = report.sends > 0 && !report.sendFinished;
    report.closedBeforeResponse = process.env.TEST_HTTP === 'true' && !report.responseFinished;
    report.sending = Number(instance.store.one("SELECT COUNT(*) AS count FROM push_deliveries WHERE status='sending'")!.count);
    report.queued = Number(instance.store.one("SELECT COUNT(*) AS count FROM push_deliveries WHERE status='queued'")!.count);
    instance.store.close();
  },
}, process.env.TEST_HTTP_TIMEOUT === 'true' ? 150 : 5000);
process.on('exit', () => writeFileSync(process.argv[2]!, JSON.stringify(report)));
process.on('message', message => {
  if (message === 'stop') process.emit('SIGTERM');
  if (message === 'send-push') {
    instance.store.run("INSERT INTO users(id,mobile,nickName,role) VALUES ('owner','synthetic-owner','owner','resident')");
    instance.notifications.register('owner', { platform: 'harmony', token: 'synthetic-device', installationId: 'a'.repeat(64) });
    for (const id of ['one', 'two']) instance.notifications.sync('owner', { id, status: 6, rounds: [{ number: 1 }], pendings: [] });
    void instance.notifications.dispatch();
  }
});
server.listen(Number(process.env.PORT), '127.0.0.1');
