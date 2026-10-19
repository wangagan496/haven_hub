param(
  [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')]
  [string] $OutputName = 'local'
)

# Start server/ on port 3000 and the map-only proxy (web_api_proxy.dart 3001 --direct) first.
& "$PSScriptRoot\flutter_ohos.ps1" build web --no-pub `
  --dart-define=API_BASE_URL=http://127.0.0.1:3000/ `
  --dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/ `
  --dart-define=AMAP_API_BASE_URL=http://127.0.0.1:3001/amap-map/ `
  "--base-href=/$OutputName/" `
  "--output=build/web/$OutputName"
exit $LASTEXITCODE
