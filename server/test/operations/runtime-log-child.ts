import { createApp } from '../../src/app.js';
import { readConfig } from '../../src/config.js';

const instance = createApp(readConfig({ DATABASE_PATH: ':memory:', RUNTIME_LOG_DIRECTORY: process.argv[2] }), { pushTimer: false });
const server = instance.app.listen(0, '127.0.0.1', () => {
  const address = server.address();
  if (address && typeof address !== 'string') process.send?.({ port: address.port });
});
process.on('message', message => {
  if (message === 'poison') {
    instance.store.one = () => {
      const error = new Error('password=private-example token=private-token mobile=13800138000');
      error.name = 'private-error-name';
      throw error;
    };
    process.send?.({ poisoned: true });
  }
  if (message === 'close') {
    server.close(() => {
      void instance.notifications.stop().then(() => {
        instance.store.close();
        process.exit(instance.runtimeLog?.failed ? 1 : 0);
      });
    });
    server.closeIdleConnections();
  }
});
