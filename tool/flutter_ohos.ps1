param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArguments,
  [string] $FlutterOhosSdk = $env:FLUTTER_OHOS_HOME,
  [Alias('d')]
  [string] $DeviceId
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$localDartDefines = Join-Path $PSScriptRoot 'dart_defines.local.env'
$devecoHome = if ($env:DEVECO_HOME) {
  $env:DEVECO_HOME
} else {
  'C:\Huawei\DevEco Studio'
}

function Test-FlutterOhosSdk {
  param([string] $SdkRoot)

  if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    return $false
  }

  $flutterExecutable = Join-Path $SdkRoot 'bin\flutter.bat'
  $platformSource = Join-Path $SdkRoot `
    'packages\flutter\lib\src\foundation\platform.dart'
  if (
    -not (Test-Path -LiteralPath $flutterExecutable -PathType Leaf) -or
    -not (Test-Path -LiteralPath $platformSource -PathType Leaf)
  ) {
    return $false
  }

  return [bool](Select-String `
      -LiteralPath $platformSource `
      -SimpleMatch 'ohos,' `
      -Quiet)
}

$candidateRoots = [System.Collections.Generic.List[string]]::new()
if ($FlutterOhosSdk) {
  $candidateRoots.Add($FlutterOhosSdk)
}
$candidateRoots.Add('C:\flutter_flutter')

Get-ChildItem -LiteralPath 'C:\' -Directory -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^flutter.*ohos' } |
  Sort-Object LastWriteTime -Descending |
  ForEach-Object { $candidateRoots.Add($_.FullName) }

$pathFlutter = Get-Command flutter.bat -ErrorAction SilentlyContinue
if ($pathFlutter) {
  $candidateRoots.Add(
    (Split-Path -Parent (Split-Path -Parent $pathFlutter.Source))
  )
}

$seenRoots = @{}
$flutterOhosRoot = $null
foreach ($candidateRoot in $candidateRoots) {
  $normalizedRoot = [System.IO.Path]::GetFullPath($candidateRoot)
  if ($seenRoots.ContainsKey($normalizedRoot)) {
    continue
  }
  $seenRoots[$normalizedRoot] = $true
  if (Test-FlutterOhosSdk $normalizedRoot) {
    $flutterOhosRoot = $normalizedRoot
    break
  }
}

if (-not $flutterOhosRoot) {
  throw 'Flutter OH SDK not found. Set FLUTTER_OHOS_HOME or pass ' +
    '-FlutterOhosSdk with the SDK root path.'
}

$flutterOhos = Join-Path $flutterOhosRoot 'bin\flutter.bat'
$flutterOhosBin = Join-Path $flutterOhosRoot 'bin'

if (
  (-not $env:JAVA_HOME -or
    -not (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) -and
  (Test-Path -LiteralPath 'C:\java\bin\java.exe')
) {
  $env:JAVA_HOME = 'C:\java'
}
if (
  -not $env:DEVECO_SDK_HOME -or
  -not (Test-Path -LiteralPath $env:DEVECO_SDK_HOME)
) {
  $env:DEVECO_SDK_HOME = Join-Path $devecoHome 'sdk'
}
$env:PUB_CACHE = Join-Path $projectRoot '.pub-cache'

if (
  (Test-Path -LiteralPath $localDartDefines -PathType Leaf) -and
  $FlutterArguments.Count -gt 0 -and
  $FlutterArguments[0] -in @('run', 'build')
) {
  $remainingArguments = @()
  if ($FlutterArguments.Count -gt 1) {
    $remainingArguments = $FlutterArguments[1..($FlutterArguments.Count - 1)]
  }
  $FlutterArguments = @(
    $FlutterArguments[0]
    "--dart-define-from-file=$localDartDefines"
  ) + $remainingArguments
}

$toolPaths = @(
  $flutterOhosBin
  (Join-Path $devecoHome 'tools\ohpm\bin')
  (Join-Path $devecoHome 'tools\hvigor\bin')
  (Join-Path $devecoHome 'tools\node')
  (Join-Path $devecoHome 'sdk\default\openharmony\toolchains')
) | Where-Object { Test-Path -LiteralPath $_ }
$env:PATH = ($toolPaths + $env:PATH) -join ';'

Write-Host "Using Flutter OH SDK: $flutterOhosRoot"
if (-not [string]::IsNullOrWhiteSpace($DeviceId)) {
  $FlutterArguments += @('-d', $DeviceId)
}
& $flutterOhos @FlutterArguments
exit $LASTEXITCODE
