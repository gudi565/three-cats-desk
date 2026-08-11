#!/usr/bin/env bash
# Flutter Web 构建 + canvaskit 本地加载修复。
#
# canvaskit 坑（README 详述）：默认从 gstatic CDN 加载 .wasm，国内不可达 → 白屏。
# build 后跑 fix_canvaskit.py 注入 canvasKitBaseUrl（相对路径，适配任意部署路径）。
#
# base-href：子路径部署（如 GitHub Pages /repo/）必须设置，否则资源按根 / 解析 → 404 白屏。
#   - 本地验证（127.0.0.1:8099 根路径）：不传，默认 /
#   - CI GitHub Pages：BASE_HREF=/three-cats-desk/
#
# 用法：
#   bash scripts/build_web.sh                          # 本地（base-href=/）
#   BASE_HREF=/three-cats-desk/ bash scripts/build_web.sh   # CI 子路径
set -euo pipefail

cd "$(dirname "$0")/.."

BASE_FLAG=""
if [ -n "${BASE_HREF:-}" ]; then
  BASE_FLAG="--base-href=$BASE_HREF"
  echo "[build_web] base-href=$BASE_HREF"
fi

echo "[build_web] flutter build web --release $BASE_FLAG"
flutter build web --release $BASE_FLAG

echo "[build_web] 注入 canvaskit 本地加载（相对路径）"
python3 scripts/fix_canvaskit.py

echo "[build_web] 完成 → build/web/"
ls -la build/web/flutter_bootstrap.js | awk '{print "  bootstrap:", $5, "bytes"}'
grep -q 'canvasKitBaseUrl' build/web/flutter_bootstrap.js \
  && echo "  ✓ canvaskit 本地加载已配置" \
  || { echo "  ✗ canvaskit 注入失败"; exit 1; }
