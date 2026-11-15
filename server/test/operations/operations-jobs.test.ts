import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, basename, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { OperationsJournal, operationsMonitorFingerprint, type OperationsMonitorConfig } from '../../src/operations-monitor.js';
import type { OperationsCheckConfig } from '../../src/operations-check.js';

const windows = { skip: process.platform !== 'win32' };
const repo = fileURLToPath(new URL('../../../', import.meta.url));
const launcher = join(repo, 'tool/run_operations_job.ps1');
const exporter = join(repo, 'tool/export_operations_tasks.ps1');
const helper = join(repo, 'server/test/operations/operations-task-fixture.ps1');

function powershell(script: string, args: string[], cwd = tmpdir()) {
  return new Promise<{ code: number | null; output: string; errors: string }>((resolve, reject) => {
    const child = spawn('pwsh', ['-NoLogo', '-NoProfile', '-NonInteractive', '-File', script, ...args],
      { cwd, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '', errors = '';
    const timeout = setTimeout(() => { child.kill(); reject(new Error('Operations job test timed out')); }, 25000);
    child.stdout.on('data', data => { output += String(data); });
    child.stderr.on('data', data => { errors += String(data); });
    child.once('error', error => { clearTimeout(timeout); reject(error); });
    child.once('close', code => { clearTimeout(timeout); resolve({ code, output, errors }); });
  });
}

function fixture(t: TestContext) {
  const root = mkdtempSync(join(tmpdir(), "haven-operations-jobs-中文 & 引号' $()-"));
  const config: OperationsMonitorConfig = { directory: join(root, 'journal'), checkConfigFile: join(root, 'check.json'),
    intervalSeconds: 30, failureSamples: 2, recoverySamples: 2, retentionEvents: 100 };
  const check: OperationsCheckConfig = { baseUrl: 'http://127.0.0.1:1', tokenFile: join(root, 'token.json'),
    authentication: 'operations-key', clientVersion: '1.0.0', timeoutMs: 100,
    thresholds: { minimumRequests: 1, maxServerErrorRate: 0, maxAuthRejected: 0, maxAborted: 0, maxP95Ms: 10000,
      maxDue: 0, maxDueDelayMs: 0, maxStopped: 0, maxExpiredLeases: 0, maxUnconfigured: 0, maxBackgroundFailures: 0 } };
  const file = join(root, 'monitor config.json');
  writeFileSync(file, JSON.stringify(config));
  writeFileSync(config.checkConfigFile, JSON.stringify(check));
  writeFileSync(check.tokenFile, JSON.stringify({ token: 'ops_v1_' + 'a'.repeat(64) }));
  let journal: OperationsJournal | undefined;
  t.after(() => {
    journal?.close();
    assert.equal(dirname(root), tmpdir());
    assert(basename(root).startsWith('haven-operations-jobs-'));
    rmSync(root, { recursive: true, force: true });
  });
  return { root, config, check, file, open: () => {
    journal = new OperationsJournal(config, operationsMonitorFingerprint(config, check));
    return journal;
  } };
}

const records = (output: string): Array<Record<string, unknown>> => output.trim().split(/\r?\n/).filter(Boolean).map(line => JSON.parse(line));
const contents = (directory: string) => readdirSync(directory).sort().map(name => [name, readFileSync(join(directory, name)).toString('base64')]);

test('Windows status launcher preserves startup, fresh, stale, stopped and failure exit codes', windows, async t => {
  const f = fixture(t), journal = f.open();
  const run = () => powershell(launcher, ['-Mode', 'Status', '-ConfigFile', f.file, '-NodePath', process.execPath]);
  journal.lifecycle('collector_started');
  const starting = await run(); assert.equal(starting.code, 3, starting.output + starting.errors);
  journal.record({ status: 'alert', reasons: ['push_stopped'] });
  const fresh = await run(); assert.equal(fresh.code, 0, fresh.output + fresh.errors);
  assert.equal(records(fresh.output)[0]!.status, 'fresh');
  journal.lifecycle('collector_stopped'); journal.close();
  const stopped = await run(); assert.equal(stopped.code, 2, stopped.output + stopped.errors);
  assert.equal(records(stopped.output)[0]!.status, 'stopped');
  const again = f.open(), staleAt = Date.now() - 45000;
  again.lifecycle('collector_started', staleAt);
  again.record({ status: 'ok', reasons: [] }, staleAt);
  const stale = await run(); assert.equal(stale.code, 2, stale.output + stale.errors);
  assert.equal(records(stale.output)[0]!.status, 'stale');
  writeFileSync(f.file, 'private-configuration');
  const invalid = await run(); assert.equal(invalid.code, 1, invalid.output + invalid.errors);
  for (const result of [starting, fresh, stopped, stale, invalid]) {
    assert.equal(records(result.output).at(-1)!.exitCode, result.code);
    assert.doesNotMatch(result.output + result.errors, /ops_v1_|private-configuration|token\.json|monitor config/);
  }
});

test('Windows launcher rejects invalid modes, cycles and missing files with sanitized errors', windows, async t => {
  const f = fixture(t);
  for (const args of [ ['-Mode', 'PrivateInvalid', '-ConfigFile', f.file],
    ['-Mode', 'Status', '-ConfigFile', f.file, '-Cycles', '1'],
    ['-Mode', 'Monitor', '-ConfigFile', f.file, '-Cycles', '-1'],
    ['-Mode', 'Monitor', '-ConfigFile', f.file, '-Cycles', '0'],
    ['-Mode', 'Monitor', '-ConfigFile', f.file, '-Cycles', '1000001'],
    ['-Mode', 'Status', '-ConfigFile', join(f.root, 'private-missing.json')] ]) {
    const result = await powershell(launcher, args);
    assert.equal(result.code, 1, result.output + result.errors);
    assert.match(result.output, /operations_job_launcher_failed/);
    assert.doesNotMatch(result.output + result.errors, /PrivateInvalid|private-missing|ops_v1_|Exception|At line/);
  }
  assert(!existsSync(f.config.directory));
});

test('Windows launcher checks the pinned runtime and compiled entries before running a job', windows, async t => {
  const f = fixture(t), isolated = join(f.root, 'isolated');
  mkdirSync(join(isolated, 'tool'), { recursive: true });
  for (const name of ['run_operations_job.ps1', 'operations_runtime.ps1']) {
    copyFileSync(join(repo, 'tool', name), join(isolated, 'tool', name));
  }
  const toolchain = join(isolated, 'tool/toolchain.json');
  const local = join(isolated, 'tool/run_operations_job.ps1');
  writeFileSync(toolchain, JSON.stringify({ node: '0.0.0' }));
  const mismatch = await powershell(local, ['-Mode', 'Status', '-ConfigFile', f.file, '-NodePath', process.execPath]);
  assert.equal(mismatch.code, 1, mismatch.output + mismatch.errors);
  assert.equal(records(mismatch.output)[0]!.stage, 'runtime');
  copyFileSync(join(repo, 'tool/toolchain.json'), toolchain);
  const missingBuild = await powershell(local, ['-Mode', 'Status', '-ConfigFile', f.file, '-NodePath', process.execPath]);
  assert.equal(missingBuild.code, 1, missingBuild.output + missingBuild.errors);
  assert.equal(records(missingBuild.output)[0]!.stage, 'runtime');
  assert(!existsSync(f.config.directory));
});

test('Windows exporter creates native-valid least-privilege logon definitions without registering tasks', windows, async t => {
  const f = fixture(t), output = join(f.root, 'definitions');
  const prefix = 'HavenTest' + randomUUID().replaceAll('-', '').slice(0, 20);
  const before = await powershell(helper, ['-InspectPrefix', prefix]);
  assert.equal(before.code, 0, before.output + before.errors);
  assert.equal(records(before.output)[0]!.registeredTasks, 0);
  const exported = await powershell(exporter, ['-ConfigFile', f.file, '-OutputDirectory', output,
    '-NodePath', process.execPath, '-TaskPrefix', prefix]);
  assert.equal(exported.code, 0, exported.output + exported.errors);
  assert.equal(records(exported.output)[0]!.registered, false);
  const monitor = readFileSync(join(output, `${prefix}-Monitor.xml`), 'utf16le');
  const status = readFileSync(join(output, `${prefix}-Status.xml`), 'utf16le');
  for (const xml of [monitor, status]) {
    assert.match(xml, /<LogonType>InteractiveToken<\/LogonType>/);
    assert.match(xml, /<RunLevel>LeastPrivilege<\/RunLevel>/);
    assert.match(xml, /<MultipleInstancesPolicy>IgnoreNew<\/MultipleInstancesPolicy>/);
    assert.match(xml, /<WakeToRun>false<\/WakeToRun>/);
    assert.match(xml, /<Hidden>false<\/Hidden>/);
    assert.match(xml, /<RunOnlyIfNetworkAvailable>false<\/RunOnlyIfNetworkAvailable>/);
    assert.match(xml, /<LogonTrigger>/);
    assert.match(xml, /-WindowStyle Hidden -File /);
    assert.match(xml, /&amp;/);
    assert.doesNotMatch(xml, /ops_v1_|BEGIN PRIVATE|ExecutionPolicy|HighestAvailable|-Command |<BootTrigger>/);
  }
  assert.match(monitor, /<ExecutionTimeLimit>PT0S<\/ExecutionTimeLimit>/);
  assert.match(monitor, /<RestartOnFailure>[\s\S]*?<Interval>PT1M<\/Interval>[\s\S]*?<Count>3<\/Count>/);
  assert.match(status, /<Repetition>[\s\S]*?<Interval>PT1M<\/Interval>/);
  assert.match(status, /<ExecutionTimeLimit>PT1M<\/ExecutionTimeLimit>/);
  assert.doesNotMatch(status, /<RestartOnFailure>/);
  const after = await powershell(helper, ['-InspectPrefix', prefix]);
  assert.equal(after.code, 0, after.output + after.errors);
  assert.equal(records(after.output)[0]!.registeredTasks, 0);
  assert(!existsSync(f.config.directory));
});

test('Windows exporter refuses existing output, missing parents and invalid prefixes without overwrites', windows, async t => {
  const f = fixture(t), output = join(f.root, 'existing');
  mkdirSync(output); writeFileSync(join(output, 'keep.txt'), 'keep');
  const before = contents(output);
  for (const args of [ ['-OutputDirectory', output],
    ['-OutputDirectory', join(f.root, 'missing', 'tasks')],
    ['-OutputDirectory', join(f.root, 'not-created'), '-TaskPrefix', 'bad;private-prefix'] ]) {
    const result = await powershell(exporter, ['-ConfigFile', f.file, ...args]);
    assert.equal(result.code, 1, result.output + result.errors);
    assert.match(result.output, /operations_tasks_export_failed/);
    assert.doesNotMatch(result.output + result.errors, /private-prefix|Exception|At line/);
  }
  assert.deepEqual(contents(output), before);
  assert(!existsSync(join(f.root, 'not-created')));
});

test('exact exported Windows action runs from its working directory with quoted paths and propagates child status', windows, async t => {
  const f = fixture(t), output = join(f.root, 'definitions');
  const server = createServer((_req, res) => { res.end(JSON.stringify({ code: 10000, data: { mode: 'maintenance' } })); });
  server.listen(0, '127.0.0.1');
  await new Promise<void>(resolve => server.once('listening', resolve));
  t.after(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  const address = server.address(); assert(address && typeof address !== 'string');
  writeFileSync(f.config.checkConfigFile, JSON.stringify({ ...f.check, baseUrl: `http://127.0.0.1:${address.port}` }));
  const exported = await powershell(exporter, ['-ConfigFile', f.file, '-OutputDirectory', output]);
  assert.equal(exported.code, 0, exported.output + exported.errors);
  const collected = await powershell(helper, ['-TaskFile', join(output, 'HavenHubLocal-Monitor.xml')]);
  assert.equal(collected.code, 0, collected.output + collected.errors);
  const events = records(collected.output);
  assert.equal(events.find(event => event.event === 'sample')!.status, 'maintenance');
  assert.equal(events.at(-1)!.exitCode, 0);
  assert(!existsSync(join(f.config.directory, 'collector.lock')));
  const before = contents(f.config.directory);
  const status = await powershell(helper, ['-TaskFile', join(output, 'HavenHubLocal-Status.xml')]);
  assert.equal(status.code, 2, status.output + status.errors);
  assert.equal(records(status.output)[0]!.status, 'stopped');
  assert.deepEqual(contents(f.config.directory), before);
  assert.doesNotMatch(collected.output + collected.errors + status.output + status.errors, /ops_v1_|token\.json|127\.0\.0\.1/);
});

test('Windows launcher never removes a live or abandoned collector lock to force a restart', windows, async t => {
  const f = fixture(t), journal = f.open();
  journal.lifecycle('collector_started');
  journal.record({ status: 'ok', reasons: [] });
  const lockPath = join(f.config.directory, 'collector.lock');
  const owned = readFileSync(lockPath);
  const run = () => powershell(launcher, ['-Mode', 'Monitor', '-ConfigFile', f.file, '-Cycles', '1']);
  const before = contents(f.config.directory);
  const live = await run();
  assert.equal(live.code, 1, live.output + live.errors);
  assert.deepEqual(contents(f.config.directory), before);
  journal.close();
  writeFileSync(lockPath, owned);
  const abandoned = contents(f.config.directory);
  const retry = await run();
  assert.equal(retry.code, 1, retry.output + retry.errors);
  assert.deepEqual(contents(f.config.directory), abandoned);
});
