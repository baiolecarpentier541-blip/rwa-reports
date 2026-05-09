#!/bin/bash
echo "[$(date)] Starting retry loop..."
for i in 1 2 3 4 5 6 7 8 9 10; do
    echo "[$(date)] Attempt $i..."
    python3 /Users/sky/.openclaw/skills/coinfound-skill/shared/coinfound_rwa/scripts/fetch_rwa.py --endpoint-key market-overview.main-asset-classes.summary > /Users/sky/github/rwa-reports/.tmp_market_2026-04-26.json 2>&1
    if [ $? -eq 0 ]; then
        echo "[$(date)] Success on attempt $i"
        break
    fi
    echo "[$(date)] Failed, waiting 15s..."
    sleep 15
done
echo "[$(date)] Done retrying, now running generate.sh..."
cd /Users/sky/github/rwa-reports && bash generate.sh
echo "[$(date)] Script finished with exit code $?"
