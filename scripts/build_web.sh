#!/usr/bin/env bash
# Flutter Web 构建 + canvaskit 本地加载修复。
#
# 本地与 CI 通用。canvaskit 坑（README 详述）：默认从 gstatic CDN 加载 .wasm，
# 国内不可达 → 白屏。build 后跑 fix_canvaskit.py 注入 canvasKitBaseUrl=/canvaskit/。
#
# 用法：bash scripts/build_web.sh
# 产物：build/web/（可直接静态托管，或 wrangler/vercel 部署）
set -euo pipefail

cd "$(dirname "$0")/.."

echo "[build_web] flutter build web --release"
flutter build web --release

echo "[build_web] 注入 canvaskit 本地加载"
python3 scripts/fix_canvaskit.py

echo "[build_web] 完成 → build/web/"
ls -la build/web/flutter_bootstrap.js | awk '{print "  bootstrap:", $5, "bytes"}'
grep -q 'canvasKitBaseUrl' build/web/flutter_bootstrap.js \
  && echo "  ✓ canvaskit 本地加载已配置" \
  || { echo "  ✗ canvaskit 注入失败"; exit 1; }
