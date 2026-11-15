param([string] $TaskFile, [string] $InspectPrefix)
$ErrorActionPreference = 'Stop'
if ($InspectPrefix) {
  if ($InspectPrefix -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,39}$') { throw 'Invalid test prefix' }
  $service = New-Object -ComObject Schedule.Service
  $service.Connect()
  try {
    $root = $service.GetFolder('\')
    $found = 0
    foreach ($task in $root.GetTasks(1)) {
      if ($task.Name -in @("$InspectPrefix-Monitor", "$InspectPrefix-Status")) { $found++ }
      [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($task)
    }
    Write-Output (@{ registeredTasks = $found } | ConvertTo-Json -Compress)
  } finally { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($service) }
  exit 0
}
$xml = [xml](Get-Content -LiteralPath $TaskFile -Raw)
$action = $xml.Task.Actions.Exec
$expected = (Get-Process -Id $PID).Path
if ([System.IO.Path]::GetFullPath($action.Command) -ne [System.IO.Path]::GetFullPath($expected)) { throw 'Unexpected test executable' }
$arguments = [string]$action.Arguments
if ($arguments -notmatch '^-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File ') { throw 'Unexpected test action' }
if ($arguments -match ' -Mode Monitor ') { $arguments += ' -Cycles 1' }
$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = $action.Command
$start.Arguments = $arguments
$start.WorkingDirectory = $action.WorkingDirectory
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$child = [System.Diagnostics.Process]::new()
$child.StartInfo = $start
try {
  [void]$child.Start()
  $stdout = $child.StandardOutput.ReadToEndAsync()
  $stderr = $child.StandardError.ReadToEndAsync()
  if (-not $child.WaitForExit(15000)) { $child.Kill($true); $child.WaitForExit(); throw 'Test action timed out' }
  [Console]::Out.Write($stdout.Result)
  [Console]::Error.Write($stderr.Result)
  $result = $child.ExitCode
} finally { $child.Dispose() }
exit $result
