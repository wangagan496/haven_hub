<#
.SYNOPSIS
将设备回环端口转发到电脑上的本地业务服务。
.EXAMPLE
.\tool\forward_local_backend.ps1
.EXAMPLE
.\tool\forward_local_backend.ps1 -Platform Android -DeviceId emulator-5554
.EXAMPLE
.\tool\forward_local_backend.ps1 -DeviceId 设备ID -List
#>
[CmdletBinding()]
param(
  [ValidateSet('HarmonyOS', 'Android')]
  [string] $Platform = 'HarmonyOS',
  [string] $DeviceId,
  [ValidateRange(1, 65535)]
  [int] $Port = 3000,
  [string] $ToolPath,
  [switch] $List
)

$ErrorActionPreference = 'Stop'

try {
  $toolName = if ($Platform -eq 'HarmonyOS') { 'hdc.exe' } else { 'adb.exe' }
  if (-not $ToolPath) {
    $candidates = @()
    if ($Platform -eq 'HarmonyOS') {
      if ($env:DEVECO_SDK_HOME) {
        $candidates += Join-Path $env:DEVECO_SDK_HOME 'default\openharmony\toolchains\hdc.exe'
        $candidates += Join-Path $env:DEVECO_SDK_HOME 'toolchains\hdc.exe'
      }
      $devecoRoot = if ($env:DEVECO_HOME) { $env:DEVECO_HOME } else { 'C:\Program Files\Huawei\DevEco Studio' }
      $candidates += Join-Path $devecoRoot 'sdk\default\openharmony\toolchains\hdc.exe'
    } else {
      foreach ($sdkRoot in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)) {
        if ($sdkRoot) { $candidates += Join-Path $sdkRoot 'platform-tools\adb.exe' }
      }
    }
    $ToolPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $ToolPath) {
      $command = Get-Command $toolName -CommandType Application -ErrorAction SilentlyContinue
      if ($command) { $ToolPath = $command.Source }
    }
  }
  if (-not $ToolPath -or -not (Test-Path -LiteralPath $ToolPath -PathType Leaf)) {
    throw "找不到 $toolName。请安装对应 SDK，或用 -ToolPath 指定工具的完整路径。"
  }
  $ToolPath = (Resolve-Path -LiteralPath $ToolPath).Path

  function Invoke-DeviceTool {
    param([string[]] $ToolArguments)
    $output = @(& $ToolPath @ToolArguments 2>&1)
    $exitCode = $LASTEXITCODE
    $message = ($output | ForEach-Object { "$_" }) -join "`n"
    # 部分 HDC 失败会输出 [Fail]，但进程退出码仍为 0。
    if ($exitCode -ne 0 -or $message -match '(?im)^\s*(\[Fail\]|\[Error\]|error:|failed\b)') {
      throw "$toolName $($ToolArguments -join ' ') 失败（退出码 $exitCode）：`n$message"
    }
    return $message
  }

  $deviceOutput = if ($Platform -eq 'HarmonyOS') {
    Invoke-DeviceTool -ToolArguments @('list', 'targets')
  } else {
    Invoke-DeviceTool -ToolArguments @('devices')
  }
  $devices = @(
    foreach ($line in ($deviceOutput -split '\r?\n')) {
      $value = $line.Trim()
      if ($Platform -eq 'HarmonyOS') {
        if ($value -and $value -ne '[Empty]' -and $value -notmatch '^\[') { $value }
      } elseif ($value -match '^(\S+)\s+device$') {
        $Matches[1]
      }
    }
  )
  if ($devices.Count -eq 0) {
    throw '没有已连接且可用的设备。请启动模拟器或连接并授权设备后重试。'
  }
  if ($DeviceId) {
    if ($DeviceId -notin $devices) { throw "设备 '$DeviceId' 不可用。可用设备：$($devices -join ', ')" }
  } elseif ($devices.Count -eq 1) {
    $DeviceId = $devices[0]
  } else {
    throw "检测到多台设备，请用 -DeviceId 指定：$($devices -join ', ')"
  }

  $selector = if ($Platform -eq 'HarmonyOS') { @('-t', $DeviceId) } else { @('-s', $DeviceId) }
  if (-not $List) {
    $forwardArguments = if ($Platform -eq 'HarmonyOS') {
      @('rport', "tcp:$Port", "tcp:$Port")
    } else {
      @('reverse', "tcp:$Port", "tcp:$Port")
    }
    $result = Invoke-DeviceTool -ToolArguments ($selector + $forwardArguments)
    if ($result) { Write-Host $result }
  }
  $listArguments = if ($Platform -eq 'HarmonyOS') { @('fport', 'ls') } else { @('reverse', '--list') }
  $tasks = Invoke-DeviceTool -ToolArguments ($selector + $listArguments)
  Write-Host "设备：$DeviceId；当前转发任务："
  Write-Host $tasks
  if (-not $List) {
    Write-Host "转发命令已成功执行：设备 tcp:$Port -> 电脑 tcp:$Port。"
    Write-Host '请保持电脑上的 server 运行，并在设备 App 中验证登录或公告；命令成功不代表接口已连通。'
  }
  exit 0
} catch {
  Write-Error -Message $_.Exception.Message -ErrorAction Continue
  exit 1
}
