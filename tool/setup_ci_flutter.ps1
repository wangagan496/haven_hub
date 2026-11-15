param([Parameter(Mandatory = $true)][string] $Destination)
$ErrorActionPreference = 'Stop'
$toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $Destination)) {
  & git init $Destination
  if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize Flutter SDK directory' }
  & git -C $Destination remote add origin $toolchain.flutterRepository
  if ($LASTEXITCODE -ne 0) { throw 'Cannot configure Flutter SDK source' }
  & git -C $Destination -c core.longpaths=true fetch --depth 1 origin $toolchain.flutterRevision
  if ($LASTEXITCODE -ne 0) { throw 'Cannot download pinned Flutter OH SDK' }
  & git -C $Destination -c core.longpaths=true checkout --detach FETCH_HEAD
  if ($LASTEXITCODE -ne 0) { throw 'Cannot check out pinned Flutter OH SDK' }
}
$revision = & git -C $Destination rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $revision.Trim() -ne $toolchain.flutterRevision) {
  throw 'Existing SDK does not match tool/toolchain.json; refusing to replace it'
}
Write-Output "RESULT script=$PSCommandPath flutterRevision=$revision"
