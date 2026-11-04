param(
  [string] $ConfigFile,
  [string] $OutputDirectory,
  [string] $NodePath,
  [string] $TaskPrefix = 'HavenHubLocal'
)
$ErrorActionPreference = 'Stop'
$result = 1
$stage = 'configuration'
$scheduler = $null
try {
  . (Join-Path $PSScriptRoot 'operations_runtime.ps1')
  if ($TaskPrefix -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,39}$') { throw 'Invalid prefix' }
  if ([string]::IsNullOrWhiteSpace($OutputDirectory) -or -not [System.IO.Path]::IsPathFullyQualified($OutputDirectory)) {
    throw 'Output directory must be absolute'
  }
  $output = [System.IO.Path]::GetFullPath($OutputDirectory)
  if (Test-Path -LiteralPath $output) { throw 'Output already exists' }
  if (-not [System.IO.Directory]::Exists([System.IO.Path]::GetDirectoryName($output))) { throw 'Parent must exist' }
  $runtime = Get-OperationsRuntime -ConfigFile $ConfigFile -NodePath $NodePath
  $launcher = Join-Path $PSScriptRoot 'run_operations_job.ps1'
  if (-not [System.IO.File]::Exists($launcher)) { throw 'Launcher missing' }
  $pwsh = (Get-Process -Id $PID).Path
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $stage = 'definition'
  $scheduler = New-Object -ComObject Schedule.Service
  $scheduler.Connect()
  $definitions = @{}
  foreach ($mode in @('Monitor', 'Status')) {
    $task = $scheduler.NewTask(0)
    try {
      $task.RegistrationInfo.Description = "Haven Hub local $mode; current-user logon only; no external notification."
      $task.RegistrationInfo.URI = "\$TaskPrefix-$mode"
      $task.Principal.Id = 'Operator'
      $task.Principal.UserId = $sid
      $task.Principal.LogonType = 3 # TASK_LOGON_INTERACTIVE_TOKEN: no password saved.
      $task.Principal.RunLevel = 0 # TASK_RUNLEVEL_LUA: no elevation.
      $task.Settings.MultipleInstances = 2 # TASK_INSTANCES_IGNORE_NEW.
      $task.Settings.DisallowStartIfOnBatteries = $false
      $task.Settings.StopIfGoingOnBatteries = $false
      $task.Settings.RunOnlyIfNetworkAvailable = $false
      $task.Settings.RunOnlyIfIdle = $false
      $task.Settings.StartWhenAvailable = $true
      $task.Settings.AllowDemandStart = $true
      $task.Settings.AllowHardTerminate = $true
      $task.Settings.Enabled = $true
      $task.Settings.Hidden = $false
      $task.Settings.WakeToRun = $false
      $task.Settings.ExecutionTimeLimit = if ($mode -eq 'Monitor') { 'PT0S' } else { 'PT1M' }
      if ($mode -eq 'Monitor') {
        $task.Settings.RestartCount = 3
        $task.Settings.RestartInterval = 'PT1M'
      }
      $trigger = $task.Triggers.Create(9) # TASK_TRIGGER_LOGON.
      $trigger.UserId = $sid
      $trigger.Enabled = $true
      $trigger.Delay = if ($mode -eq 'Monitor') { 'PT10S' } else { 'PT30S' }
      if ($mode -eq 'Status') {
        $trigger.Repetition.Interval = 'PT1M'
        $trigger.Repetition.StopAtDurationEnd = $false
      }
      $task.Actions.Context = 'Operator'
      $action = $task.Actions.Create(0) # TASK_ACTION_EXEC.
      $action.Path = $pwsh
      $action.WorkingDirectory = $runtime.Server
      $action.Arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -File ' +
        (ConvertTo-OperationsArgument $launcher) + ' -Mode ' + $mode + ' -ConfigFile ' +
        (ConvertTo-OperationsArgument $runtime.Config) + ' -NodePath ' + (ConvertTo-OperationsArgument $runtime.Node)
      $xml = $task.XmlText
      # Native parsing validates the definition without registering or starting any task.
      $validation = $scheduler.NewTask(0)
      try { $validation.XmlText = $xml }
      finally { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($validation) }
      $definitions[$mode] = $xml
    } finally { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($task) }
  }
  $stage = 'write'
  [void](New-Item -ItemType Directory -Path $output -ErrorAction Stop)
  foreach ($mode in @('Monitor', 'Status')) {
    $file = Join-Path $output ("$TaskPrefix-$mode.xml")
    $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write)
    try {
      $bytes = [System.Text.Encoding]::Unicode.GetPreamble() + [System.Text.Encoding]::Unicode.GetBytes($definitions[$mode])
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush($true)
    } finally { $stream.Dispose() }
  }
  Write-Output (@{ event = 'operations_tasks_exported'; count = 2; registered = $false;
    scope = 'current-user-logon'; message = '两个任务定义已生成并通过本机解析，尚未安装或启动任务' } | ConvertTo-Json -Compress)
  $result = 0
} catch {
  Write-Output (@{ event = 'operations_tasks_export_failed'; stage = $stage;
    message = '任务定义生成失败，请检查Windows工具链、构建、配置文件和全新输出目录' } | ConvertTo-Json -Compress)
} finally {
  if ($null -ne $scheduler) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($scheduler) }
  Write-Output (@{ event = 'operations_tasks_export_finished'; exitCode = $result } | ConvertTo-Json -Compress)
}
exit $result
