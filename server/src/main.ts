import { existsSync } from 'node:fs';
import { createServer } from 'node:http';
import { createApp } from './app.js';
import { readConfig } from './config.js';
import { createMaintenanceApp } from './maintenance.js';
import { manageServerLifecycle, reportProcessEvent } from './server-lifecycle.js';
import { ProcessLockOccupiedError } from './process-lock.js';

function main() {
  let config: ReturnType<typeof readConfig>;
  try {
    if (existsSync('.env')) process.loadEnvFile('.env');
    config = readConfig();
  } catch { reportProcessEvent('server_config_failed'); process.exitCode = 1; return; }
  let instance: Pick<ReturnType<typeof createApp>, 'app'> & Partial<ReturnType<typeof createApp>>;
  try { instance = config.maintenance ? { app: createMaintenanceApp(config) } : createApp(config); }
  catch (error) {
    if (error instanceof ProcessLockOccupiedError) process.stderr.write(error.message + '\n');
    reportProcessEvent('server_start_failed'); process.exitCode = 1; return;
  }
  const server = createServer(instance.app);
  const lifecycle = manageServerLifecycle(server, { stopBackgroundTasks: instance.stopBackgroundTasks,
    closeResources: () => instance.store?.close(), runtimeLog: instance.runtimeLog });
  try {
    server.listen(config.port, config.host, () => {
      process.stdout.write(config.maintenance ? '维护模式已启动；数据库未打开，业务请求和后台任务均已停止。\n' :
        config.authMode === 'development' ?
          `享家本地学习服务：http://${config.host}:${config.port}\n开发验证码会返回给 App，不发送短信。请使用虚构资料。\n` :
          `享家服务已启动：${config.publicBaseUrl}\n腾讯云短信模式；验证码仅发送到手机，不通过接口返回。\n`);
    });
  } catch { reportProcessEvent('server_listen_failed'); void lifecycle.shutdown(true); }
}
main();
