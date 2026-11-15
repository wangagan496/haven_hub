function Get-OperationsRuntime {
  param([string] $ConfigFile, [string] $NodePath)
  if (-not $IsWindows -or $PSVersionTable.PSVersion.Major -lt 7) { throw 'Unsupported host' }
  if ([string]::IsNullOrWhiteSpace($ConfigFile)) { throw 'Missing configuration' }
  $config = (Resolve-Path -LiteralPath $ConfigFile -ErrorAction Stop).ProviderPath
  if (-not [System.IO.File]::Exists($config)) { throw 'Configuration is not a file' }
  if ([string]::IsNullOrWhiteSpace($NodePath)) {
    $NodePath = (Get-Command node -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
  }
  $node = (Resolve-Path -LiteralPath $NodePath -ErrorAction Stop).ProviderPath
  if ([System.IO.Path]::GetExtension($node) -ne '.exe') { throw 'Node must be an executable' }
  $toolchain = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'toolchain.json') -Raw | ConvertFrom-Json
  $version = & $node --version 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]$version -ne "v$($toolchain.node)") { throw 'Node version mismatch' }
  $repo = Split-Path -Parent $PSScriptRoot
  $entries = @{
    Monitor = Join-Path $repo 'server/dist/tool/operations-monitor.js'
    Status = Join-Path $repo 'server/dist/tool/operations-monitor-status.js'
  }
  foreach ($entry in $entries.Values) {
    if (-not [System.IO.File]::Exists($entry)) { throw 'Build required' }
  }
  return @{ Node = $node; Config = $config; Entries = $entries; Server = Join-Path $repo 'server' }
}

function ConvertTo-OperationsArgument {
  param([string] $Value)
  # -File receives literal Windows arguments; no -Command, shell expansion or execution-policy bypass.
  if ([string]::IsNullOrEmpty($Value) -or $Value.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) {
    throw 'Invalid task argument'
  }
  return '"' + $Value + '"'
}
