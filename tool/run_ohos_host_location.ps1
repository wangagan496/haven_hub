param(
  [string] $HostIp,
  [int] $ProxyPort = 3001,
  [string] $FlutterOhosSdk = $env:FLUTTER_OHOS_HOME,
  [Alias('d')]
  [string] $DeviceId
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$flutterLauncher = Join-Path $PSScriptRoot 'flutter_ohos.ps1'
$proxyScript = Join-Path $PSScriptRoot 'web_api_proxy.dart'

function Resolve-HostLanIp {
  $candidates = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
    Where-Object {
      $_.AddressState -eq 'Preferred' -and
      $_.IPAddress -notmatch '^(127\.|169\.254\.|198\.18\.)' -and
      $_.InterfaceAlias -notmatch '(?i)(mihomo|vpn|tun|tap|virtual|vethernet|loopback)'
    } |
    Sort-Object InterfaceIndex

  $candidate = $candidates | Select-Object -First 1
  if ($null -eq $candidate) {
    throw 'Unable to find a host LAN IPv4 address. Pass -HostIp explicitly.'
  }
  return $candidate.IPAddress
}

if ($ProxyPort -lt 1 -or $ProxyPort -gt 65535) {
  throw 'ProxyPort must be between 1 and 65535.'
}

if ([string]::IsNullOrWhiteSpace($HostIp)) {
  $HostIp = Resolve-HostLanIp
}

$parsedHostIp = [System.Net.IPAddress]::Parse($HostIp)
if ($parsedHostIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
  throw 'HostIp must be an IPv4 address.'
}

$dartCommand = Get-Command dart -ErrorAction Stop
$proxyProcess = Start-Process `
  -FilePath $dartCommand.Source `
  -ArgumentList @(
    'run',
    $proxyScript,
    $ProxyPort.ToString(),
    "--bind=$HostIp",
    '--direct'
  ) `
  -WorkingDirectory $projectRoot `
  -WindowStyle Hidden `
  -PassThru

$mapApiBaseUrl = "http://${HostIp}:$ProxyPort/tencent-map/"
Write-Host "Host location proxy: $mapApiBaseUrl"
Write-Host 'Tencent requests will be made with DIRECT networking.'

try {
  & $flutterLauncher `
    -FlutterOhosSdk $FlutterOhosSdk `
    -DeviceId $DeviceId `
    run `
    "--dart-define=TENCENT_MAP_API_BASE_URL=$mapApiBaseUrl"
  exit $LASTEXITCODE
} finally {
  if (-not $proxyProcess.HasExited) {
    Stop-Process -Id $proxyProcess.Id
  }
}
