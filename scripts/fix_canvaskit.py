#!/usr/bin/env python3
"""注入 canvaskit 本地加载配置到 build/web/flutter_bootstrap.js。

国内网络坑（README 已记录）：canvaskit.wasm 默认从 gstatic.com CDN 加载不可达 → 白屏。
flutter build web 每次覆盖 flutter_bootstrap.js，故每次 build 后跑本脚本。

新版 Flutter（engineRevision 5a2a6a...）bootstrap 的 load() 是未混淆对象，
直接在 serviceWorkerSettings 前插 config.canvasKitBaseUrl。
"""
import re
import sys
from pathlib import Path

BOOTSTRAP = Path(__file__).resolve().parent.parent / "build" / "web" / "flutter_bootstrap.js"
NEEDLE = "_flutter.loader.load({"
INJECT = (
    "_flutter.loader.load({\n"
    "  config: { canvasKitBaseUrl: \"/canvaskit/\" },"
)


def main() -> int:
    if not BOOTSTRAP.exists():
        print(f"[canvaskit-fix] 找不到 {BOOTSTRAP}，先 flutter build web", file=sys.stderr)
        return 1
    src = BOOTSTRAP.read_text(encoding="utf-8")
    # 注意：minified 行里 E() 函数定义本身就含 "canvasKitBaseUrl" 字符串字面量，
    # 不能用它判定是否已注入。只在未混淆的 load({...}) 调用块里看有没有 config 键。
    if NEEDLE not in src:
        print(f"[canvaskit-fix] 未找到锚点 {NEEDLE!r}，bootstrap 格式可能已变，需人工检查", file=sys.stderr)
        return 2
    # 取 load({ 到首个 }); 之间的片段判断。
    call_start = src.index(NEEDLE)
    call_block = src[call_start:call_start + 400]
    if "config:" in call_block and "canvasKitBaseUrl" in call_block:
        print("[canvaskit-fix] load() 调用块已含 canvasKitBaseUrl，跳过")
        return 0
    patched = src.replace(NEEDLE, INJECT, 1)
    BOOTSTRAP.write_text(patched, encoding="utf-8")
    print(f"[canvaskit-fix] 已注入 canvasKitBaseUrl → {BOOTSTRAP.relative_to(Path.cwd())}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
