param(
  [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9_-]*$')]
  [string] $OutputName = 'local'
)

# Keep the local login backend and the CORS-enabled map proxy together.
# Start server/ on port 3000 and web_api_proxy.dart 3001 --direct first.
& "$PSScriptRoot\flutter_ohos.ps1" build web --no-pub `
  --dart-define=API_BASE_URL=http://127.0.0.1:3000/ `
  --dart-define=LOCAL_BACKEND=true `
  --dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/ `
  --dart-define=AMAP_API_BASE_URL=http://127.0.0.1:3001/amap-map/ `
  "--base-href=/$OutputName/" `
  "--output=build/web/$OutputName"
exit $LASTEXITCODE
