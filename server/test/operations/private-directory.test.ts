import test, { type TestContext } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import childProcess, { execFileSync } from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';
import { tmpdir } from 'node:os';
import { basename, dirname, join } from 'node:path';
import { createPrivateDirectory } from '../../src/backup.js';
import { createOperationsKey } from '../../src/operations-key.js';

const windows = process.platform === 'win32';
const permissionError = '无法限制备份目录权限，尚未写入任何数据';

function temporary(t: TestContext) {
  const root = fs.mkdtempSync(join(tmpdir(), 'haven-private-directory-'));
  t.after(() => {
    assert.equal(dirname(root), tmpdir());
    assert(basename(root).startsWith('haven-private-directory-'));
    fs.rmSync(root, { recursive: true, force: true });
  });
  return root;
}

function powershell(root: string, script: string, path: string) {
  const file = join(root, 'acl-fixture.ps1');
  fs.writeFileSync(file, '$ErrorActionPreference = "Stop"\n' + script);
  return execFileSync('pwsh', ['-NoProfile', '-NonInteractive', '-File', file, path],
    { encoding: 'utf8', windowsHide: true, timeout: 15000 });
}

interface Acl {
  protected: boolean; current: string; sddl: string;
  rules: { sid: string; inherited: boolean; rights: string; type: string; inheritance: string; propagation: string }[];
}

function inspect(root: string, path: string): Acl {
  return JSON.parse(powershell(root, `
$acl = Get-Acl -LiteralPath $args[0]
$rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
  @{ sid=$_.IdentityReference.Value; inherited=$_.IsInherited; rights=$_.FileSystemRights.ToString();
     type=$_.AccessControlType.ToString(); inheritance=$_.InheritanceFlags.ToString(); propagation=$_.PropagationFlags.ToString() }
})
@{ protected=$acl.AreAccessRulesProtected; current=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value;
   sddl=$acl.Sddl; rules=$rules } | ConvertTo-Json -Depth 4 -Compress
`, path));
}

function assertPrivate(acl: Acl, directory: boolean) {
  assert.deepEqual(acl.rules.map(rule => rule.sid).sort(), [...new Set([acl.current, 'S-1-5-18'])].sort());
  if (directory) assert.equal(acl.protected, true);
  for (const rule of acl.rules) {
    assert.equal(rule.rights, 'FullControl');
    assert.equal(rule.type, 'Allow');
    assert.equal(rule.inherited, !directory);
    assert.equal(rule.inheritance, directory ? 'ContainerInherit, ObjectInherit' : 'None');
    assert.equal(rule.propagation, 'None');
  }
}

test('private directory removes extra explicit grants before credential files are written', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, 'credentials');
  const mkdir = fs.mkdirSync;
  let injected = false;
  const fault = t.mock.method(fs, 'mkdirSync', (...args: Parameters<typeof fs.mkdirSync>) => {
    const result = mkdir(...args);
    if (args[0] === target) {
      // Reproduce explicit default-DACL entries on a newly created directory, not just inherited ACEs.
      execFileSync('icacls.exe', [target, '/grant:r', '*S-1-1-0:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F'],
        { stdio: 'pipe', windowsHide: true });
      const before = inspect(root, target);
      assert(before.rules.some(rule => rule.sid === 'S-1-1-0' && !rule.inherited));
      assert(before.rules.some(rule => rule.sid === 'S-1-5-32-544' && !rule.inherited));
      injected = true;
    }
    return result;
  });
  syncBuiltinESMExports();
  try { createOperationsKey(target, '2030-01-02T00:00:00.000Z', Date.parse('2030-01-01T00:00:00Z')); }
  finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert(injected);
  assertPrivate(inspect(root, target), true);
  for (const name of ['token.json', 'keys.json']) assertPrivate(inspect(root, join(target, name)), false);
});

test('private directory replaces the native default DACL under a parent without inheritable rules', { skip: !windows }, t => {
  const root = temporary(t), parent = join(root, 'no-inheritance');
  fs.mkdirSync(parent);
  powershell(root, `
$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'None', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -LiteralPath $args[0] -AclObject $acl
`, parent);
  const target = join(parent, 'private');
  createPrivateDirectory(target);
  assertPrivate(inspect(root, target), true);
  fs.writeFileSync(join(target, 'sample'), 'synthetic');
  assertPrivate(inspect(root, join(target, 'sample')), false);
});

test('private directory handles literal Unicode paths and uses the actual account instead of USERDOMAIN', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, "私有 [目录] & '$() 空格");
  const original = process.env.USERDOMAIN;
  process.env.USERDOMAIN = 'HAVEN-NONEXISTENT-DOMAIN';
  try { createPrivateDirectory(target); }
  finally {
    if (original === undefined) delete process.env.USERDOMAIN;
    else process.env.USERDOMAIN = original;
  }
  assertPrivate(inspect(root, target), true);
});

test('private directory never changes or clears an existing destination', t => {
  const root = temporary(t), target = join(root, 'existing');
  fs.mkdirSync(target);
  fs.writeFileSync(join(target, 'keep'), 'unchanged');
  const before = windows ? inspect(root, target).sddl : fs.statSync(target).mode;
  assert.throws(() => createPrivateDirectory(target), { code: 'EEXIST' });
  assert.equal(fs.readFileSync(join(target, 'keep'), 'utf8'), 'unchanged');
  assert.equal(windows ? inspect(root, target).sddl : fs.statSync(target).mode, before);
});

test('private directory permission failure stops credential creation and hides native error details', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, 'failed');
  const fault = t.mock.method(childProcess, 'execFileSync', () => { throw new Error('private-native-error'); });
  syncBuiltinESMExports();
  try {
    assert.throws(() => createOperationsKey(target, '2030-01-02T00:00:00.000Z', Date.parse('2030-01-01T00:00:00Z')),
      { message: permissionError });
  } finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(fs.existsSync(target), false);
});

test('private directory cleanup failure leaves only an empty directory and retains the safe error', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, 'cleanup-failed');
  const command = t.mock.method(childProcess, 'execFileSync', () => { throw new Error('private-native-error'); });
  const cleanup = t.mock.method(fs, 'rmdirSync', () => { throw new Error('private-cleanup-error'); });
  syncBuiltinESMExports();
  try { assert.throws(() => createPrivateDirectory(target), { message: permissionError }); }
  finally { command.mock.restore(); cleanup.mock.restore(); syncBuiltinESMExports(); }
  assert.deepEqual(fs.readdirSync(target), []);
});

test('private directory rejects a successful command without a verified permission receipt', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, 'unverified');
  const fault = t.mock.method(childProcess, 'execFileSync', () => '');
  syncBuiltinESMExports();
  try { assert.throws(() => createPrivateDirectory(target), { message: permissionError }); }
  finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert.equal(fs.existsSync(target), false);
});

test('private directory permission failure never recursively removes unexpected content', { skip: !windows }, t => {
  const root = temporary(t), target = join(root, 'unexpected-content');
  const fault = t.mock.method(childProcess, 'execFileSync', () => {
    fs.writeFileSync(join(target, 'keep'), 'unrelated-content');
    throw new Error('private-native-error');
  });
  syncBuiltinESMExports();
  try { assert.throws(() => createPrivateDirectory(target), { message: permissionError }); }
  finally { fault.mock.restore(); syncBuiltinESMExports(); }
  assert.deepEqual(fs.readdirSync(target), ['keep']);
  assert.equal(fs.readFileSync(join(target, 'keep'), 'utf8'), 'unrelated-content');
});
