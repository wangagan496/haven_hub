$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'client_version.ps1')
$pubspec = Join-Path (Split-Path -Parent $PSScriptRoot) 'pubspec.yaml'
$declared = [regex]::Match((Get-Content -LiteralPath $pubspec -Raw), '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)').Groups[1].Value
if ((Get-HavenClientVersion -PubspecPath $pubspec -Arguments @()) -cne $declared) { throw 'Default must match pubspec' }
foreach ($arguments in @(@('build','web','--build-name=2.3.4'), @('build','web','--build-name','2.3.4'), @('build','web','--build-name=1.0.0','--build-name','2.3.4'))) {
  if ((Get-HavenClientVersion -PubspecPath $pubspec -Arguments $arguments) -cne '2.3.4') { throw 'Build name override mismatch' }
}
foreach ($value in @('1.2','01.2.3','1.2.3-beta','1.2.3+4','9999999.0.0','1.2.3,2.0.0')) {
  $rejected = $false
  try { Get-HavenClientVersion -PubspecPath $pubspec -Arguments @('build',"--build-name=$value") | Out-Null } catch { $rejected = $true }
  if (-not $rejected) { throw "Invalid version accepted: $value" }
}
$rejected = $false
try { Get-HavenClientVersion -PubspecPath $pubspec -Arguments @('build','--build-name') | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Missing build name accepted' }
Write-Output "RESULT script=$PSCommandPath version-source=pubspec build-name-overrides=passed malformed=passed"
