#!/bin/bash
# 推送到 GitHub Pages
# 用法: bash push.sh https://github.com/Abobo-win/wechat-adskip.git

set -e
REMOTE="${1:-https://github.com/Abobo-win/wechat-adskip.git}"
cd "$(dirname "$0")"

if [ ! -d .git ]; then
    git init
    git branch -M main
    git remote add origin "$REMOTE"
fi

git add -A
git commit -m "release $(date +%Y-%m-%d\ %H:%M)" || echo "没有改动"
git push -u origin main

echo ""
echo "推送完成。"
echo "等 1-2 分钟后，Sileo 源地址是："
echo "  https://Abobo-win.github.io/wechat-adskip/"
echo ""
echo "记得去仓库 Settings → Pages 里，Source 选 main / root"
