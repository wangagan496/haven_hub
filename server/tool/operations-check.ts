import { readOperationsCheckConfig, readOperationsToken, runOperationsCheck } from '../src/operations-check.js';

try {
  const [path, ...extra] = process.argv.slice(2);
  if (!path || extra.length) throw new Error('Invalid arguments');
  const config = readOperationsCheckConfig(path);
  const report = await runOperationsCheck(config, readOperationsToken(config.tokenFile));
  process.stdout.write(JSON.stringify(report) + '\n');
  process.exitCode = report.exitCode;
} catch {
  process.stderr.write(JSON.stringify({ status: 'unavailable', reasons: ['invalid_local_configuration'], exitCode: 1 }) + '\n');
  process.exitCode = 1;
}
