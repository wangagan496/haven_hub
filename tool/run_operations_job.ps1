param(
  [string] $Mode,
  [string] $ConfigFile,
  [string] $NodePath,
  [int] $Cycles = 0
)
$ErrorActionPreference = 'Stop'
$result = 1
$stage = 'configuration'
$safeMode = 'unknown'
try {
  if ($Mode -notin @('Monitor', 'Status')) { throw 'Invalid mode' }
  $safeMode = $Mode
  $finite = $PSBoundParameters.ContainsKey('Cycles')
  if ($finite -and ($Cycles -lt 1 -or $Cycles -gt 1000000 -or $Mode -eq 'Status')) { throw 'Invalid cycles' }
  . (Join-Path $PSScriptRoot 'operations_runtime.ps1')
  $stage = 'runtime'
  $runtime = Get-OperationsRuntime -ConfigFile $ConfigFile -NodePath $NodePath
  $arguments = @($runtime.Entries[$Mode], $runtime.Config)
  if ($finite) { $arguments += @('--cycles', [string]$Cycles) }
  $stage = 'execution'
  # Keep the child attached; the host tracks this job for its entire lifetime.
  & $runtime.Node @arguments
  $result = $LASTEXITCODE
  if ($result -notin @(0, 1, 2, 3)) { $result = 1 }
} catch {
  Write-Output (@{ event = 'operations_job_launcher_failed'; mode = $safeMode; stage = $stage;
    message = '监控入口失败，请检查固定工具链、构建产物和配置文件权限' } | ConvertTo-Json -Compress)
  $result = 1
} finally {
  Write-Output (@{ event = 'operations_job_finished'; mode = $safeMode; exitCode = $result } | ConvertTo-Json -Compress)
}
exit $result
