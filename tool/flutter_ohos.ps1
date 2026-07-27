param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]] $FlutterArguments
)

$flutterOhos = 'C:\flutter_flutter\bin\flutter.bat'
$devecoHome = 'C:\Huawei\DevEco Studio'
$projectRoot = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path -LiteralPath $flutterOhos)) {
  throw "未找到 Flutter OH SDK：$flutterOhos"
}

$env:JAVA_HOME = 'C:\java'
$env:DEVECO_SDK_HOME = Join-Path $devecoHome 'sdk'
$env:PUB_CACHE = Join-Path $projectRoot '.pub-cache'
$env:PATH = @(
  'C:\flutter_flutter\bin'
  (Join-Path $devecoHome 'tools\ohpm\bin')
  (Join-Path $devecoHome 'tools\hvigor\bin')
  (Join-Path $devecoHome 'tools\node')
  (Join-Path $devecoHome 'sdk\default\openharmony\toolchains')
  $env:PATH
) -join ';'

& $flutterOhos @FlutterArguments
exit $LASTEXITCODE
