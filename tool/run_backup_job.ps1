param(
  [Parameter(Mandatory = $true)][string] $ConfigFile,
  [Parameter(Mandatory = $true)][string] $KeyFile,
  [Parameter(Mandatory = $true)][string] $LogDirectory
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$previousKeyFile = $env:BACKUP_KEY_FILE
$result = 1
$stage = 'toolchain'
try {
  $node = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  $toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
  $version = & $node --version
  if ($LASTEXITCODE -ne 0 -or $version.Trim() -ne "v$($toolchain.node)") { throw 'Node version mismatch' }
  $entry = Join-Path $repo 'server/dist/tool/backup-job.js'
  if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { throw 'Build server before running backup job' }
  $stage = 'configuration'
  $configPath = (Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop).Path
  $env:BACKUP_KEY_FILE = (Resolve-Path -LiteralPath $KeyFile -ErrorAction Stop).Path
  New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
  $log = Join-Path $LogDirectory ('backup-job-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.log')
  $stage = 'execution'
  & $node $entry $configPath *> $log
  $result = $LASTEXITCODE
  $stage = 'read-log'
  Get-Content -LiteralPath $log
} catch {
  # Raw PowerShell exceptions can contain paths or configuration contents.
  Write-Output (@{ event = 'database_backup_job_launcher_failed'; stage = $stage; message = '备份入口失败，请检查工具链、构建、配置文件与日志目录权限' } | ConvertTo-Json -Compress)
  $result = 1
} finally {
  if ($null -eq $previousKeyFile) { Remove-Item Env:BACKUP_KEY_FILE -ErrorAction SilentlyContinue }
  else { $env:BACKUP_KEY_FILE = $previousKeyFile }
  Write-Output "RESULT script=$PSCommandPath exit=$result"
}
exit $result
