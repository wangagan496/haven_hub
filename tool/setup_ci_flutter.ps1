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
# Flutter OH derives its version from the tag on HEAD; a depth-1 fetch of the revision alone
# brings no tag, the SDK then reports 0.0.0-unknown and pub rejects every Flutter constraint.
$tagRef = "refs/tags/$($toolchain.flutterTag)"
& git -C $Destination rev-parse --quiet --verify "$tagRef^{commit}" *> $null
if ($LASTEXITCODE -ne 0) {
  & git -C $Destination -c core.longpaths=true fetch --depth 1 origin "${tagRef}:${tagRef}"
  if ($LASTEXITCODE -ne 0) { throw 'Cannot download pinned Flutter OH SDK version tag' }
}
$tagged = & git -C $Destination rev-parse --verify "$tagRef^{commit}"
if ($LASTEXITCODE -ne 0 -or $tagged.Trim() -ne $toolchain.flutterRevision) {
  throw 'Flutter version tag does not point at the pinned revision in tool/toolchain.json'
}
Write-Output "RESULT script=$PSCommandPath flutterRevision=$revision flutterTag=$($toolchain.flutterTag)"
