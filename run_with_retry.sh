#!/bin/bash
# 重试拉取 + 执行生成脚本
REPO_DIR="$HOME/github/rwa-reports"
FETCH="$HOME/.openclaw/skills/coinfound-skill/shared/coinfound_rwa/scripts/fetch_rwa.py"
TODAY=$(date +%Y-%m-%d)

for i in 1 2 3 4 5; do
    echo "[Retry $i] 尝试拉取数据..."
    python3 "$FETCH" --endpoint-key market-overview.main-asset-classes.summary > "$REPO_DIR/.tmp_market_$TODAY.json" 2>&1
    if [ $? -eq 0 ]; then
        echo "[Retry $i] 数据拉取成功"
        break
    fi
    echo "[Retry $i] 失败，10秒后重试..."
    sleep 10
done

# 继续执行生成脚本其余部分（简化版：直接执行 generate.sh）
cd "$REPO_DIR" && bash generate.sh
