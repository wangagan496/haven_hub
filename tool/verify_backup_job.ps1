param([switch] $InspectOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$paths = @('server/src/backup-job.ts', 'server/tool/backup-job.ts', 'server/test/operations/backup-job.test.ts', 'server/package.json', 'server/backup-job.example.json', 'tool/run_backup_job.ps1', 'tool/verify_backup_job.ps1', 'docs/backup_restore_runbook.md', 'docs/enterprise_readiness_goals.md', 'server/README.md')
foreach ($relative in $paths) {
  $path = Join-Path $repo $relative
  $item = Get-Item -LiteralPath $path
  Write-Output "WRITE path=$($item.FullName) bytes=$($item.Length)"
  Get-Content -LiteralPath $path -TotalCount 3
}
if ($InspectOnly) {
  Write-Output "RESULT script=$PSCommandPath inspectOnly=true exit=0"
  exit 0
}
Push-Location (Join-Path $repo 'server')
$result = 1
try {
  & node --import tsx --test test/operations/backup-job.test.ts test/operations/encrypted-backup.test.ts test/operations/backup.test.ts
  $result = $LASTEXITCODE
} finally {
  Pop-Location
  Write-Output "RESULT script=$PSCommandPath exit=$result"
}
exit $result
