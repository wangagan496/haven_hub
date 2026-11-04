import { Store } from '../src/database.js';
import { AuthService } from '../src/auth.js';
const [path, action, mobile, code, timestamp] = process.argv.slice(2) as [string,string,string,string,string];
const store = new Store(path);
const auth = new AuthService(store, () => Number(timestamp), action === 'login' ? { mode: 'development' } : {
  mode: 'tencent', hourlyLimit: 5, dailyLimit: 10, globalDailyLimit: action === 'send-phone' ? 100 : 1,
  sender: async () => { process.send?.({ vendorCall: true }); },
});
process.once('message', async () => {
  let success = false;
  try {
    if (action === 'login') auth.login({ mobile, code });
    else await auth.sendCode(mobile);
    success = true;
  } catch { /* Report only the result, never the generated code or credentials. */ }
  finally { store.close(); }
  process.send?.({ success }, () => process.disconnect());
});
process.send?.({ ready: true });
