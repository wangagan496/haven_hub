# 独立流程演示：先在 server 目录执行 npm run demo。
& "$PSScriptRoot\flutter_ohos.ps1" build web --no-pub `
  --dart-define=API_BASE_URL=http://127.0.0.1:3010/ `
  --dart-define=LOCAL_BACKEND=true `
  --dart-define=TENCENT_MAP_API_BASE_URL=http://127.0.0.1:3001/tencent-map/ `
  --dart-define=AMAP_API_BASE_URL=http://127.0.0.1:3001/amap-map/ `
  --base-href=/workflow/ --output=build/web/workflow
exit $LASTEXITCODE
