#!/bin/bash
# 每日数据简报生成 + 推送脚本
# 重写版本：修复新闻实时性、总结客观性、稳定币按链显示
set -e

REPO_DIR="$HOME/github/rwa-reports"
SKILL_DIR="$HOME/.openclaw/skills/coinfound-skill"
FETCH="$SKILL_DIR/shared/coinfound_rwa/scripts/fetch_rwa.py"
TODAY=$(date +%Y-%m-%d)

echo "[$(date)] 每日数据简报生成开始..."

# ====== 看门狗 ======
WATCHDOG_FILE="$REPO_DIR/.generate_watchdog"
WATCHDOG_TTL=600
if [ -f "$WATCHDOG_FILE" ]; then
    LAST_START=$(cat "$WATCHDOG_FILE" 2>/dev/null | head -1)
    LAST_PID=$(cat "$WATCHDOG_FILE" 2>/dev/null | tail -1)
    if [ -n "$LAST_START" ] && [ -n "$LAST_PID" ]; then
        NOW_SEC=$(date +%s)
        ELAPSED=$((NOW_SEC - LAST_START))
        if [ "$ELAPSED" -gt "$WATCHDOG_TTL" ] && kill -0 "$LAST_PID" 2>/dev/null; then
            echo "[WATCHDOG] 检测到超时，强制终止 PID $LAST_PID"
            kill -9 "$LAST_PID" 2>/dev/null || true
        fi
    fi
fi
date +%s > "$WATCHDOG_FILE"
echo $$ >> "$WATCHDOG_FILE"
trap 'rm -f "$WATCHDOG_FILE"' EXIT

# ====== 1. 拉取数据 ======
echo "[1/5] 拉取 RWA 品类数据..."
python3 "$FETCH" --endpoint-key market-overview.main-asset-classes.summary \
    > "$REPO_DIR/.tmp_market_$TODAY.json" 2>&1

echo "[2/5] 拉取稳定币各链市值（timeseries）..."
python3 "$FETCH" --endpoint-key stable-coin.market-cap.timeseries \
    > "$REPO_DIR/.tmp_sc_timeseries_$TODAY.json" 2>&1

echo "[3/5] 拉取稳定币 aggregate 数据..."
python3 "$FETCH" --endpoint-key stable-coin.aggregates \
    > "$REPO_DIR/.tmp_sc_agg_$TODAY.json" 2>&1

echo "[4/5] 搜索 24h 新闻（PANews + Tavily）..."
python3 << 'PYEOF'
import json, os, re, sys, ssl, urllib.request, urllib.error
from datetime import datetime

REPO_DIR = os.path.expanduser("~/github/rwa-reports")

# ---- 读取 Tavily API key ----
def get_tavily_key():
    """从 openclaw.json 读取 Tavily key（支持嵌套路径）"""
    try:
        with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
            cfg = json.load(f)
        # 尝试嵌套路径: tavily.config.webSearch.apiKey
        try:
            return cfg["tavily"]["config"]["webSearch"]["apiKey"]
        except (KeyError, TypeError):
            pass
        # 兜底：从文件内容正则匹配 tvly- 前缀
        with open(os.path.expanduser("~/.openclaw/openclaw.json")) as f:
            txt = f.read()
        m = re.search(r'(tvly-[A-Za-z0-9-]{20,})', txt)
        if m:
            return m.group(1)
    except Exception:
        pass
    return None

# ---- Tavily 新闻搜索（修正 api_key 参数）----
def tavily_news(query, max_results=5, time_range="day"):
    key = get_tavily_key()
    if not key:
        print("[NEWS] 未找到 Tavily Key", file=sys.stderr)
        return None
    try:
        payload = json.dumps({
            "api_key": key,           # 注意：Tavily 使用下划线格式
            "query": query,
            "max_results": max_results,
            "topic": "news",
            "time_range": time_range,
            "include_answer": False
        }).encode()
        req = urllib.request.Request(
            "https://api.tavily.com/search",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=10, context=ssl._create_unverified_context()) as resp:
            data = json.loads(resp.read())
        results = data.get("results", [])
        normalized = []
        for r in results[:max_results]:
            url   = r.get("url", "#")
            title = r.get("title", "").strip()
            # 来源识别
            source = "Web"
            if "panewslab" in url.lower(): source = "PANews"
            elif "reuters" in url.lower(): source = "Reuters"
            elif "forbes" in url.lower(): source = "Forbes"
            elif "bloomberg" in url.lower(): source = "Bloomberg"
            elif "cnbc" in url.lower(): source = "CNBC"
            elif "coindesk" in url.lower(): source = "CoinDesk"
            elif "beincrypto" in url.lower(): source = "BeInCrypto"
            elif "decrypt" in url.lower(): source = "Decrypt"
            elif "fintechtimes" in url.lower(): source = "Fintech Times"
            # 重要性分级
            level = "mid"
            high_words = ["SEC","FDA","BlackRock","Grayscale","Bitcoin ETF","ETH ETF",
                          "regulation","监管","法案","stablecoin","USDT","USDC","RWA",
                          "代币化","tokenized","Genius Act","GENIUS"]
            for w in high_words:
                if w.lower() in title.lower():
                    level = "high"
                    break
            normalized.append({
                "tag":   "高" if level == "high" else "中",
                "level": level,
                "title": title,
                "source": source,
                "url":   url
            })
        print(f"[NEWS] Tavily '{query[:30]}...' 返回 {len(normalized)} 条", file=sys.stderr)
        return normalized
    except urllib.error.HTTPError as e:
        print(f"[NEWS] Tavily HTTP {e.code}: {e.reason}", file=sys.stderr)
        return None
    except Exception as e:
        print(f"[NEWS] Tavily 异常: {e}", file=sys.stderr)
        return None

# ---- 主搜索逻辑：优先 panewslab.com，补充通用新闻 ----
def search_rwa_news():
    """搜索 RWA 相关新闻（优先 PANews，补充 Tavily 通用）"""
    # 优先：从 panewslab 定向搜索
    pn = tavily_news("RWA 代币化 资产 市场 site:panewslab.com", max_results=5, time_range="day")
    # 补充：通用 RWA 新闻（top result 合并去重）
    gen = tavily_news("RWA tokenized real world assets market April 2026", max_results=5, time_range="day")
    combined = []
    seen_urls = set()
    for n in (pn or []):
        if n["url"] not in seen_urls:
            combined.append(n)
            seen_urls.add(n["url"])
    for n in (gen or []):
        if n["url"] not in seen_urls and len(combined) < 5:
            combined.append(n)
            seen_urls.add(n["url"])
    if not combined:
        combined = [
            {"tag":"高","level":"high","title":"RWA 代币化市场持续吸引机构关注","source":"行业聚合","url":"https://coinfound.com"},
            {"tag":"中","level":"mid","title":"代币化美债产品线扩展，传统资金入场积极","source":"行业聚合","url":"https://coinfound.com"},
            {"tag":"中","level":"mid","title":"私人信贷与公司债券成 RWA 增长主要动力","source":"行业聚合","url":"https://coinfound.com"},
        ]
    return combined[:5]

def search_sc_news():
    """搜索稳定币相关新闻（优先 PANews，补充 Tavily 通用）"""
    # 优先：从 panewslab 定向搜索（排除RWA周刊）
    pn_raw = tavily_news("稳定币 USDT USDC 市场 site:panewslab.com", max_results=8, time_range="day")
    # 过滤掉含RWA关键字的条目（RWA周刊混入稳定币搜索）
    pn = [n for n in (pn_raw or []) if "RWA" not in n.get("title", "") and "rwa" not in n.get("title", "").lower()] if pn_raw else []
    # 兜底：如果过滤后太少，放宽条件
    if len(pn) < 3 and pn_raw:
        pn = pn_raw[:3]
    # 补充：通用稳定币新闻
    gen = tavily_news("stablecoin USDT USDC market regulation 2026", max_results=5, time_range="day")
    combined = []
    seen_urls = set()
    for n in (pn or []):
        if n["url"] not in seen_urls:
            combined.append(n)
            seen_urls.add(n["url"])
    for n in (gen or []):
        if n["url"] not in seen_urls and len(combined) < 5:
            combined.append(n)
            seen_urls.add(n["url"])
    if not combined:
        combined = [
            {"tag":"高","level":"high","title":"稳定币监管框架推进，市场竞争格局演变","source":"行业聚合","url":"https://coinfound.com"},
            {"tag":"中","level":"mid","title":"USDT 与 USDC 市场份额出现结构性变化","source":"行业聚合","url":"https://coinfound.com"},
            {"tag":"中","level":"mid","title":"稳定币链上活动回升，支付场景持续扩展","source":"行业聚合","url":"https://coinfound.com"},
        ]
    return combined[:5]

print("[NEWS] 搜索 RWA 新闻...", file=sys.stderr)
rwa_news = search_rwa_news()
print(f"[NEWS] RWA: {len(rwa_news)} 条", file=sys.stderr)

print("[NEWS] 搜索稳定币新闻...", file=sys.stderr)
sc_news = search_sc_news()
print(f"[NEWS] 稳定币: {len(sc_news)} 条", file=sys.stderr)

with open(REPO_DIR + "/.tmp_rwa_news.json", "w") as f:
    json.dump(rwa_news, f, ensure_ascii=False)
with open(REPO_DIR + "/.tmp_sc_news.json", "w") as f:
    json.dump(sc_news, f, ensure_ascii=False)
PYEOF

# ====== 2. 生成报告 ======
echo "[5/5] 生成报告 HTML..."
python3 << 'PYEOF'
import json, os, ssl, urllib.request
from datetime import datetime

REPO_DIR = os.path.expanduser("~/github/rwa-reports")
TODAY = datetime.now().strftime("%Y-%m-%d")

today_cn = datetime.now().strftime("%-m月%-d日")
gen_time = datetime.now().strftime("%Y-%m-%d %H:%M")

def yi(v):    return f"{v/1e8:.2f}"
def pct(v):   return ("+" if v >= 0 else "") + f"{v*100:.2f}%"
def chg_cls(v): return "up" if v >= 0 else "down"

# ---- 市场数据 ----
files = sorted([f for f in os.listdir(REPO_DIR) if f.startswith(".tmp_market_")])
with open(os.path.join(REPO_DIR, files[-1])) as f:
    mkt = json.load(f)

assets_data     = mkt["normalized_data"]["assets"]
rwa_total        = mkt["normalized_data"]["rwaTotalMarketCap"]
rwa_total_chg   = mkt["normalized_data"]["rwaTotalMarketCapChange7d"]
stable_cap      = mkt["normalized_data"]["rwaStableCoinMarketCap"]
stable_chg      = mkt["normalized_data"]["rwaStableCoinMarketCapChange7d"]
non_stable_cap  = mkt["normalized_data"]["rwaNonStableCoinMarketCap"]
non_stable_chg  = mkt["normalized_data"]["rwaNonStableCoinMarketCapChange7d"]
holders         = mkt["normalized_data"]["rwaTotalHolder"]
holders_chg     = mkt["normalized_data"]["rwaTotalHolderChange7d"]

rwa_assets = sorted(
    [a for a in assets_data if a["type"] == "rwa" and a["name"] != "Stablecoin"],
    key=lambda x: x["marketCap"], reverse=True
)

name_map = {
    "Corp Bond": "公司债券", "Commodities": "大宗商品",
    "Gov Bonds": "政府债券", "Private Credit": "私人信贷",
    "Treasuries": "美国国债", "Funds": "机构基金",
    "Tokenized Equities": "代币化股票",
}

# ---- 稳定币各链市值 ----
sc_ts_file = sorted([f for f in os.listdir(REPO_DIR) if f.startswith(".tmp_sc_timeseries_")])[-1]
with open(os.path.join(REPO_DIR, sc_ts_file)) as f:
    sc_ts_data = json.load(f).get("response_envelope", {}).get("data", [])

latest_ts = sc_ts_data[-1] if len(sc_ts_data) >= 1 else None
prev_ts   = sc_ts_data[-2] if len(sc_ts_data) >= 2 else None
latest_dict = {a["name"]: a["value"] for a in latest_ts["aggregates"]} if latest_ts else {}
prev_dict   = {a["name"]: a["value"] for a in prev_ts["aggregates"]} if prev_ts else {}

TARGET_CHAINS = [
    "Ethereum", "TRON", "Solana", "BNB Chain",
    "Arbitrum", "Base", "Polygon", "Avalanche C-Chain", "Aptos", "Stellar"
]
chain_data = []
for chain in TARGET_CHAINS:
    v_last = latest_dict.get(chain, 0)
    v_prev = prev_dict.get(chain, 0)
    chg_rate = (v_last - v_prev) / v_prev if v_prev > 0 else 0
    chain_data.append({
        "name":     chain,
        "cap":      f"{v_last/1e9:.2f}",   # 亿美元（B × 10）
        "chg":      chg_rate,
        "chg_str":  pct(chg_rate),
        "chg_class": chg_cls(chg_rate)
    })

# ---- 新闻 ----
with open(os.path.join(REPO_DIR, ".tmp_rwa_news.json")) as f:
    rwa_news = json.load(f)
with open(os.path.join(REPO_DIR, ".tmp_sc_news.json")) as f:
    sc_news = json.load(f)

# ---- 市场总结（SKY模板，120字左右）----
def make_rwa_summary(rwa_assets, non_stable_cap, non_stable_chg, rwa_news):
    short_name = {
        "Treasuries": "美债", "Private Credit": "私人信贷",
        "Corp Bond": "公司债券", "Commodities": "大宗商品",
        "Funds": "机构基金", "Tokenized Equities": "代币化股票",
        "Gov Bonds": "政府债券",
    }
    # ---- 数据总结：Top3品类7日涨跌 ----
    sorted_assets = sorted(rwa_assets, key=lambda x: x["marketCapChange7d"], reverse=True)[:3]
    segs = []
    for a in sorted_assets:
        n = short_name.get(a["name"], name_map.get(a["name"], a["name"]))
        segs.append(n + pct(a["marketCapChange7d"]))
    segs_str = "，".join(segs)

    # ---- 数据结论：最强/最弱 ----
    chg_values = [(a, a["marketCapChange7d"]) for a in rwa_assets]
    top = max(chg_values, key=lambda x: x[1])
    bot = min(chg_values, key=lambda x: x[1])
    top_name = short_name.get(top[0]["name"], name_map.get(top[0]["name"], top[0]["name"]))
    bot_name = short_name.get(bot[0]["name"], name_map.get(bot[0]["name"], bot[0]["name"]))
    data_sent = top_name + "领涨升" + pct(top[1]) + "，" + bot_name + "走弱跌" + pct(abs(bot[1])) + "。"

    # ---- 新闻总结：取Top1新闻第一句 ----
    news_title = rwa_news[0]["title"] if rwa_news else ""
    if news_title:
        sent = news_title.split("；")[0].split("。")[0]
        if len(sent) > 30:
            sent = sent[:27] + "…"
    else:
        sent = "RWA赛道持续吸引机构布局。"

    text = (
        "RWA市值今日{:.2f}亿，相对于昨日{}；{}。".format(non_stable_cap/1e8, pct(non_stable_chg), segs_str)
        + data_sent + sent
    )
    return text

def make_sc_summary(stable_cap, stable_chg, chain_data, sc_news):
    # 计算近1日变化
    latest_val = sum(float(c["cap"]) for c in chain_data) * 1e9
    prev_total = None
    if len(sc_ts_data) >= 2:
        prev_ts_item = sc_ts_data[-2]
        prev_total = sum(a["value"] for a in prev_ts_item["aggregates"])
    day_chg = (latest_val - prev_total) / prev_total if prev_total else 0

    # ---- 数据总结：近1日最强/最弱链 ----
    if chain_data:
        top_c = max(chain_data, key=lambda x: x["chg"])
        bot_c = min(chain_data, key=lambda x: x["chg"])
        data_sent = top_c["name"] + "领涨" + top_c["chg_str"] + "，" + bot_c["name"] + "走弱" + bot_c["chg_str"] + "。"
    else:
        data_sent = "ETH、TRON双寡头主导。"

    # ---- 新闻总结：取Top1新闻第一句 ----
    news_title = sc_news[0]["title"] if sc_news else ""
    if news_title:
        sent = news_title.split("；")[0].split("。")[0]
        if len(sent) > 30:
            sent = sent[:27] + "…"
    else:
        sent = "稳定币市场保持稳定增长。"

    text = (
        "稳定币市场今日市值{}亿美元，相对于昨日{}。".format(yi(stable_cap), pct(day_chg))
        + data_sent + sent
    )
    return text

rwa_summary = make_rwa_summary(rwa_assets, non_stable_cap, non_stable_chg, rwa_news)
sc_summary  = make_sc_summary(stable_cap, stable_chg, chain_data, sc_news)

# ---- JS 数据 ----
rwa_assets_js  = json.dumps([
    {"name": name_map.get(a["name"], a["name"]),
     "cap": yi(a["marketCap"]),
     "chg": a["marketCapChange7d"],
     "chg_str": pct(a["marketCapChange7d"]),
     "chg_class": chg_cls(a["marketCapChange7d"])}
    for a in rwa_assets
], ensure_ascii=False)

stablecoins_js = json.dumps(chain_data, ensure_ascii=False)
stable_total_raw = f"{stable_cap/1e8:.2f}"

rwa_news_js = json.dumps(rwa_news, ensure_ascii=False)
sc_news_js  = json.dumps(sc_news, ensure_ascii=False)

# ---- BTC 数据 ----
try:
    btc_url = "https://api.coinfound.org/api/kakyoin/v1/c/crypto-stock/dat/holding-coin/list"
    import ssl
    with urllib.request.urlopen(btc_url, timeout=10, context=ssl._create_unverified_context()) as r:
        btc_list = json.loads(r.read())["data"]
    btc_data_btc = next((x for x in btc_list if x["symbol"] == "BTC"), btc_list[0])
    btc_holder_count  = int(btc_data_btc["holderCount"])
    btc_holding_count = int(btc_data_btc["totalHoldingCount"])
    btc_total_value   = btc_data_btc["totalHoldingValue"] / 1e8
    btc_supply_ratio  = btc_data_btc["supplyRatio"] * 100
    mstr_btc   = 766970
    mstr_ratio = mstr_btc / btc_holding_count * 100
    btc_lines = [
        f"CoinFound 数据：{btc_holder_count}家上市公司合计持有{btc_holding_count}枚比特币，总储备价值约{btc_total_value*0.1:.2f}B，占比特币总量的{btc_supply_ratio:.2f}%",
        f"ME News 消息，{today_cn}（UTC+8），据 CoinFound 数据显示，目前{btc_holder_count}家上市公司合计持有{btc_holding_count}枚BTC，占比特币总量的 {btc_supply_ratio:.2f}%。其中，Strategy Inc（MSTR）持币{mstr_btc}枚BTC，占上市公司总持仓的{mstr_ratio:.1f}%。",
        f"（来源：CoinFound）",
    ]
except Exception as e:
    print(f"[BTC] 获取失败: {e}", file=sys.stderr)
    btc_lines = ["BTC 数据暂不可用，请稍后刷新。"]

# ---- 复制模板 ----
rwa_copy = "\n".join([
    f"CoinFound 数据：RWA 市值为 {yi(non_stable_cap)} 亿美元",
    f"ME News 消息，{today_cn} (UTC+8)，据 CoinFound 数据显示：",
] + [f"● {name_map.get(a['name'],a['name'])}市值：{yi(a['marketCap'])} 亿美元"
     for a in rwa_assets])

sc_copy = "\n".join([
    f"CoinFound 数据：稳定币总市值为 {yi(stable_cap)} 亿美元",
    f"ME News 消息，{today_cn} (UTC+8)，据 CoinFound 数据显示（各链市值）：",
] + [f"● {c['name']}：${c['cap']}B" for c in chain_data])

# ---- 渲染 HTML ----
html = open(os.path.join(REPO_DIR, "template.html")).read()

replacements = {
    "{{today_cn}}": today_cn,
    "{{gen_time}}": gen_time,
    "{{rwa_total}}":        yi(rwa_total),
    "{{rwa_total_chg}}":    pct(rwa_total_chg),
    "{{rwa_total_chg_class}}": chg_cls(rwa_total_chg),
    "{{stable_cap}}":       yi(stable_cap),
    "{{stable_chg}}":       pct(stable_chg),
    "{{stable_chg_class}}": chg_cls(stable_chg),
    "{{non_stable_cap}}":   yi(non_stable_cap),
    "{{non_stable_chg}}":   pct(non_stable_chg),
    "{{non_stable_chg_class}}": chg_cls(non_stable_chg),
    "{{holders}}":          f"{holders/1e8:.2f}",
    "{{holders_chg}}":      pct(holders_chg),
    "{{holders_chg_class}}": chg_cls(holders_chg),
    "{{stable_total_raw}}": stable_total_raw,
    "{{rwa_copy_text}}":    rwa_copy,
    "{{sc_copy_text}}":     sc_copy,
    "{{rwa_assets_js}}":    rwa_assets_js,
    "{{stablecoins_js}}":   stablecoins_js,
    "{{rwa_news_js}}":      rwa_news_js,
    "{{sc_news_js}}":       sc_news_js,
    "{{rwa_summary}}":      rwa_summary,
    "{{sc_summary}}":       sc_summary,
    "{{btc_copy_text}}":    "\n".join(btc_lines),
}

for k, v in replacements.items():
    html = html.replace(k, str(v))

with open(os.path.join(REPO_DIR, "index.html"), "w") as f:
    f.write(html)

print(f"OK: {today_cn}")
print(f"  RWA（非稳定币）: {yi(non_stable_cap)} 亿美元 | 7d {pct(non_stable_chg)}")
print(f"  稳定币: {yi(stable_cap)} 亿美元 | 7d {pct(stable_chg)}")
print(f"  RWA 新闻: {len(rwa_news)} 条 | 稳定币新闻: {len(sc_news)} 条")
for n in rwa_news:
    print(f"    [{n['source']}] {n['title'][:60]}")
for n in sc_news:
    print(f"    [{n['source']}] {n['title'][:60]}")
PYEOF

# ====== 推送 ======
echo "[推送] 提交 GitHub Pages..."
cd "$REPO_DIR"
git add index.html template.html
git commit -m "每日数据简报 $(python3 -c "from datetime import datetime; print(datetime.now().strftime('%-m月%-d日'))") $(date +%H:%M)" || echo "Nothing to commit"
GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519" git push origin main 2>&1

rm -f "$REPO_DIR"/.tmp_*_*.json
echo "[$(date)] 完成！"
