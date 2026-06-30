#!/usr/bin/env bash
# 启动《职海杀》(love2d)。优先用 PATH 里的 love，否则用 /Applications/love.app。
set -e
cd "$(dirname "$0")"

if command -v love >/dev/null 2>&1; then
    exec love . "$@"
elif [ -x /Applications/love.app/Contents/MacOS/love ]; then
    exec /Applications/love.app/Contents/MacOS/love . "$@"
else
    echo "未找到 LÖVE。请安装：" >&2
    echo "  macOS:  brew install --cask love   (或从 https://love2d.org 下载)" >&2
    echo "  Linux:  sudo apt install love       (或见 https://love2d.org)" >&2
    exit 1
fi
