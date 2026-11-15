param(
  [ValidateSet('all', 'server', 'flutter')][string] $Scope = 'all',
  [switch] $SkipRestore,
  [string] $LogDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) ('haven-checks-' + (Get-Date -Format 'yyyyMMdd-HHmmss')))
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
function Invoke-Check([string] $Name, [scriptblock] $Command) {
  $path = Join-Path $LogDirectory "$Name.log"
  $global:LASTEXITCODE = 0
  & $Command *> $path
  $code = $LASTEXITCODE
  Get-Content -LiteralPath $path -Tail 55
  if ($code -ne 0) { throw "$Name failed (exit=$code); log=$path" }
  Write-Output "CHECK $Name passed"
}
$exitCode = 1
Push-Location $repo
try {
  if ($Scope -in @('all', 'server')) {
    $nodeVersion = & node --version
    if ($LASTEXITCODE -ne 0 -or $nodeVersion.Trim() -ne "v$($toolchain.node)") { throw 'Node version does not match tool/toolchain.json' }
    Push-Location (Join-Path $repo 'server')
    try {
      if (-not $SkipRestore) { Invoke-Check 'server-install' { & npm.cmd ci } }
      Invoke-Check 'server-audit' { & npm.cmd run audit:security }
      Invoke-Check 'server-build' { & npm.cmd run build }
      Invoke-Check 'server-test' { & npm.cmd test }
      Invoke-Check 'admin-syntax' {
        foreach ($script in Get-ChildItem -LiteralPath public/admin -Filter '*.js' -File) {
          & node --check $script.FullName
          if ($LASTEXITCODE -ne 0) { break }
        }
      }
    } finally { Pop-Location }
  }
  if ($Scope -in @('all', 'flutter')) {
    $wrapper = Join-Path $PSScriptRoot 'flutter_ohos.ps1'
    Invoke-Check 'flutter-version' { & pwsh -File $wrapper --version --machine }
    $versionLog = Get-Content -LiteralPath (Join-Path $LogDirectory 'flutter-version.log') -Raw
    if ($versionLog -notmatch [regex]::Escape($toolchain.flutterRevision)) { throw 'Flutter revision does not match tool/toolchain.json' }
    if (-not $SkipRestore) {
      # Use dart pub get instead of flutter pub get to avoid triggering HOS_SDK_HOME check in
      # flutter's platform-specific tooling generation (hvigor.updateLocalProperties).
      $flutterSdk = if ($env:FLUTTER_OHOS_HOME) { $env:FLUTTER_OHOS_HOME } else { $env:FLUTTER_HOME }
      if (-not $flutterSdk) { throw 'FLUTTER_OHOS_HOME or FLUTTER_HOME must be set' }
      $dartExe = Join-Path $flutterSdk 'bin/cache/dart-sdk/bin/dart'
      if ($IsWindows) { $dartExe += '.exe' }
      # dart needs FLUTTER_ROOT to locate Flutter SDK packages like sky_engine.
      # Use existing FLUTTER_ROOT if set, otherwise set it from FLUTTER_OHOS_HOME.
      if (-not $env:FLUTTER_ROOT) { $env:FLUTTER_ROOT = $flutterSdk }
      Invoke-Check 'flutter-install' { & $dartExe pub get --enforce-lockfile }
    }
    Invoke-Check 'flutter-analyze' { & pwsh -File $wrapper analyze --no-pub lib test }
    Invoke-Check 'flutter-test' { & pwsh -File $wrapper test --no-pub --reporter expanded }
  }
  if ($Scope -eq 'all') {
    Invoke-Check 'integration' { & pwsh -File (Join-Path $PSScriptRoot 'test_local_backend.ps1') -SkipBuild -LogDirectory (Join-Path $LogDirectory 'integration') }
  }
  $exitCode = 0
} catch {
  Write-Output "CHECK FAILED: $($_.Exception.Message)"
} finally {
  Pop-Location
  Write-Output "RESULT script=$PSCommandPath scope=$Scope exit=$exitCode logs=$LogDirectory"
}
exit $exitCode
