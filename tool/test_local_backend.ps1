param(
  [switch] $SkipBuild,
  [string] $LogDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) ('haven-integration-' + [guid]::NewGuid().ToString('N')))
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
$serverProcess = $null
$exitCode = 1
Push-Location $repo
try {
  if (-not $SkipBuild) {
    Push-Location (Join-Path $repo 'server')
    try {
      & npm.cmd run build *> (Join-Path $LogDirectory 'build.log')
      if ($LASTEXITCODE -ne 0) { throw 'Backend build failed' }
    } finally { Pop-Location }
  }
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = $listener.LocalEndpoint.Port
  $listener.Stop()
  $baseUrl = "http://127.0.0.1:$port"
  . (Join-Path $PSScriptRoot 'client_version.ps1')
  $clientVersion = Get-HavenClientVersion -PubspecPath (Join-Path $repo 'pubspec.yaml') -Arguments @()
  $serverProcess = Start-Process -FilePath (Get-Command node.exe).Source -ArgumentList @((Join-Path $repo 'server\dist\src\main.js')) -WorkingDirectory $LogDirectory -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDirectory 'server.log') -RedirectStandardError (Join-Path $LogDirectory 'server-error.log') -Environment @{
    NODE_ENV = 'development'; HOST = '127.0.0.1'; PORT = [string]$port;
    PUBLIC_BASE_URL = $baseUrl; DATABASE_PATH = (Join-Path $LogDirectory 'integration.sqlite');
    AUTH_MODE = 'development'; HUAWEI_PUSH_PROJECT_ID = ''; HUAWEI_PUSH_KEY_FILE = '';
    CLIENT_MIN_VERSION = $clientVersion
  }
  $ready = $false
  for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if ($serverProcess.HasExited) { throw 'Backend exited before readiness' }
    try {
      $response = Invoke-RestMethod -Uri "$baseUrl/ready" -TimeoutSec 2
      if ($response.code -eq 10000 -and $response.data.ready) { $ready = $true; break }
    } catch { Start-Sleep -Milliseconds 250 }
  }
  if (-not $ready) { throw 'Backend readiness timed out' }
  & pwsh -File (Join-Path $PSScriptRoot 'flutter_ohos.ps1') test --no-pub --reporter expanded --dart-define 'RUN_LOCAL_BACKEND_TEST=true' --dart-define "API_BASE_URL=$baseUrl/" test/integration/local_backend_integration_test.dart *> (Join-Path $LogDirectory 'flutter-test.log')
  $exitCode = $LASTEXITCODE
  Get-Content -LiteralPath (Join-Path $LogDirectory 'flutter-test.log') -Tail 60
} catch {
  Write-Output "INTEGRATION FAILED: $($_.Exception.Message)"
  $exitCode = 1
  if (Test-Path -LiteralPath (Join-Path $LogDirectory 'server-error.log')) { Get-Content -LiteralPath (Join-Path $LogDirectory 'server-error.log') -Tail 25 }
} finally {
  if ($serverProcess -and -not $serverProcess.HasExited) { Stop-Process -InputObject $serverProcess -Force }
  Pop-Location
  Write-Output "RESULT script=$PSCommandPath exit=$exitCode logs=$LogDirectory"
}
exit $exitCode
