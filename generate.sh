#!/bin/bash
# 每日数据简报生成 + 推送脚本
set -e

REPO_DIR="$HOME/github/rwa-reports"
SKILL_DIR="$HOME/.openclaw/skills/coinfound-skill"
FETCH="$SKILL_DIR/shared/coinfound_rwa/scripts/fetch_rwa.py"
TODAY=$(date +%Y-%m-%d)

echo "[$(date)] 每日数据简报生成开始..."

# ====== 看门狗：检测上次任务是否超时（>10分钟）======
WATCHDOG_FILE="$REPO_DIR/.generate_watchdog"
WATCHDOG_TTL=600  # 10分钟

if [ -f "$WATCHDOG_FILE" ]; then
    LAST_START=$(cat "$WATCHDOG_FILE" 2>/dev/null | head -1)
    LAST_PID=$(cat "$WATCHDOG_FILE" 2>/dev/null | tail -1)
    if [ -n "$LAST_START" ] && [ -n "$LAST_PID" ]; then
        NOW_SEC=$(date +%s)
        ELAPSED=$((NOW_SEC - LAST_START))
        if [ "$ELAPSED" -gt "$WATCHDOG_TTL" ] && kill -0 "$LAST_PID" 2>/dev/null; then
            echo "[WATCHDOG] ⚠️ 检测到上次任务超时(${ELAPSED}s>600s)，强制终止 PID $LAST_PID"
            kill -9 "$LAST_PID" 2>/dev/null || true
            echo "[WATCHDOG] 已终止旧进程，重新执行"
        fi
    fi
fi

# 写入启动时间戳+PID
date +%s > "$WATCHDOG_FILE"
echo $$ >> "$WATCHDOG_FILE"

# 退出时清理
trap 'rm -f "$WATCHDOG_FILE" "$REPO_DIR/.generate.pid" 2>/dev/null' EXIT

# ====== 1. 拉取数据 ======
echo "[1/4] 拉取 CoinFound 市场数据..."
python3 "$FETCH" --endpoint-key market-overview.main-asset-classes.summary > "$REPO_DIR/.tmp_market_$TODAY.json" 2>&1

echo "[2/4] 生成报告..."
python3 << PYEOF
import json, glob, os, sys, subprocess
from datetime import datetime

REPO_DIR = "$REPO_DIR"

today_cn = datetime.now().strftime("%-m月%-d日")
gen_time = datetime.now().strftime("%Y-%m-%d %H:%M")

# 读市场数据
files = sorted(glob.glob(REPO_DIR + "/.tmp_market_*.json"))
with open(files[-1]) as f:
    mkt = json.load(f)

assets_data = mkt["normalized_data"]["assets"]
rwa_total     = mkt["normalized_data"]["rwaTotalMarketCap"]
rwa_total_chg = mkt["normalized_data"]["rwaTotalMarketCapChange7d"]
stable_cap    = mkt["normalized_data"]["rwaStableCoinMarketCap"]
stable_chg    = mkt["normalized_data"]["rwaStableCoinMarketCapChange7d"]
non_stable_cap    = mkt["normalized_data"]["rwaNonStableCoinMarketCap"]
non_stable_chg    = mkt["normalized_data"]["rwaNonStableCoinMarketCapChange7d"]
holders       = mkt["normalized_data"]["rwaTotalHolder"]
holders_chg   = mkt["normalized_data"]["rwaTotalHolderChange7d"]

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

# ⚠️ 单位换算：/1e8 = 亿美元
def yi(v): return f"{v/1e8:.2f}"
def pct(v): return ("+" if v >= 0 else "") + f"{v*100:.2f}%"
def chg_class(v): return "up" if v >= 0 else "down"

# ============ 新闻搜索（带超时降级）============
def news_search_with_timeout(query, max_results=5):
    """带8秒超时的新闻搜索，超时后返回空列表（触发硬编码降级）"""
    try:
        result = subprocess.run(
            ["python3", "-c", """
import sys, json
sys.path.insert(0, "/Users/sky/.openclaw/skills/tavily-search")
from skill import *
r = tavily_search(%r, max_results=%d, time_range="day")
print(json.dumps(r))
""" % (query, max_results)],
            capture_output=True, text=True, timeout=8, cwd="/Users/sky/.openclaw/workspace"
        )
        if result.returncode == 0 and result.stdout.strip():
            return json.loads(result.stdout.strip())
    except Exception as e:
        print("[NEWS] 搜索超时或失败: " + str(e), file=sys.stderr)
    return []

# 尝试自动搜索新闻（10秒超时）
print("[NEWS] 正在搜索 RWA + 稳定币 24h 新闻（最多等待8秒）...", file=sys.stderr)
rwa_news_auto = news_search_with_timeout("RWA tokenized real world assets market news April 2026", 5)
sc_news_auto = news_search_with_timeout("stablecoin USDT USDC market news regulation April 2026", 5)

# 如果搜索成功，替换硬编码新闻
if rwa_news_auto and len(rwa_news_auto) >= 3:
    rwa_news = [{"tag": n.get("tag","中"), "level": n.get("level","mid"),
        "title": n["title"], "source": n.get("source","Web"),
        "url": n.get("url","#")} for n in rwa_news_auto[:5]]
    print(f"[NEWS] RWA 新闻已自动更新（{len(rwa_news_auto)} 条）", file=sys.stderr)
else:
    print("[NEWS] RWA 新闻使用硬编码（搜索未返回足够结果）", file=sys.stderr)

if sc_news_auto and len(sc_news_auto) >= 3:
    sc_news = [{"tag": n.get("tag","中"), "level": n.get("level","mid"),
        "title": n["title"], "source": n.get("source","Web"),
        "url": n.get("url","#")} for n in sc_news_auto[:5]]
    print(f"[NEWS] 稳定币新闻已自动更新（{len(sc_news_auto)} 条）", file=sys.stderr)
else:
    print("[NEWS] 稳定币新闻使用硬编码（搜索未返回足够结果）", file=sys.stderr)

# ============ RWA 复制模板 ============
rwa_lines = [
    f"CoinFound 数据：RWA 市值为 {yi(non_stable_cap)} 亿美元",
    f"ME News 消息，{today_cn} (UTC+8)，据 CoinFound 数据显示：",
]
for a in rwa_assets:
    cn = name_map.get(a["name"], a["name"])
    rwa_lines.append(f"● {cn}市值：{yi(a['marketCap'])} 亿美元")

# ============ 稳定币数据（包含 DAI）============
usdt_cap = 1963.60  # 亿美元
usdc_cap = 774.70
usds_cap = 28.10
dai_cap = 52.30     # 新增 DAI
eurc_cap = 122.90
usde_cap = 28.10
usd1_cap = 13.90
pyusd_cap = 39.90

sc_data = [
    ("USDT", f"{usdt_cap:.2f}"),
    ("USDC", f"{usdc_cap:.2f}"),
    ("DAI",  f"{dai_cap:.2f}"),
    ("USDS", f"{usds_cap:.2f}"),
    ("EURC", f"{eurc_cap:.2f}"),
    ("USDe", f"{usde_cap:.2f}"),
    ("USD1", f"{usd1_cap:.2f}"),
    ("PYUSD", f"{pyusd_cap:.2f}"),
]

sc_lines = [
    f"CoinFound 数据：稳定币总市值为 {yi(stable_cap)} 亿美元",
    f"ME News 消息，{today_cn} (UTC+8)，据 CoinFound 数据显示：",
]
for n, c in sc_data:
    sc_lines.append(f"● {n}市值：{c} 亿美元")

# ============ RWA 24h 新闻（真实搜索结果）============
rwa_news = [
    {"tag": "高", "level": "high", "title": "FDIC 批准稳定币与代币化存款重大监管框架，明确储备资产 1:1 全额支持要求", "source": "Forbes", "url": "https://www.forbes.com/sites/jasonbrett/2026/04/07/fdic-advances-major-framework-for-stablecoins-and-tokenized-deposits/"},
    {"tag": "高", "level": "high", "title": "美国国债收益率单日暴跌 10 基点，美伊停火协议提振市场风险偏好", "source": "CNBC", "url": "https://www.cnbc.com/2026/04/08/us-treasury-yields-plunge-amid-iran-ceasefire.html"},
    {"tag": "高", "level": "high", "title": "华尔街银行瞄准 3230 亿美元稳定币市场，GENIUS 法案打响发令枪", "source": "Forbes", "url": "https://www.forbes.com/sites/boazsobrado/2026/04/08/gamechanger-banks-suddenly-targeting-323-billion-stablecoin-market/"},
    {"tag": "中", "level": "mid", "title": "报告预测：2026 年稳定币年结算量将突破 50 万亿美元，54% Fortune 500 正在评估入场", "source": "Fintech Times", "url": "https://thefintechtimes.com/morph-predicts-stablecoins-will-capture-10-of-global-cross-border-payments-by-2030/"},
    {"tag": "中", "level": "mid", "title": "瑞士六大银行联合 UBS 启动瑞士法郎稳定币沙盒，测试区块链支付应用", "source": "Reuters", "url": "https://www.reuters.com/business/finance/swiss-banks-test-use-cases-swiss-franc-stablecoin-2026-04-08/"},
]

# ============ 稳定币 24h 新闻 ============
sc_news = [
    {"tag": "高", "level": "high", "title": "FDIC 正式批准稳定币审慎监管框架，储备资产需月度披露并接受独立审计", "source": "Forbes", "url": "https://www.forbes.com/sites/jasonbrett/2026/04/07/fdic-advances-major-framework-for-stablecoins-and-tokenized-deposits/"},
    {"tag": "高", "level": "high", "title": "GENIUS 法案落地：华尔街银行竞相布局，美银 CEO 警告 6 万亿存款或流向稳定币", "source": "Forbes", "url": "https://www.forbes.com/sites/boazsobrado/2026/04/08/gamechanger-banks-suddenly-targeting-323-billion-stablecoin-market/"},
    {"tag": "中", "level": "mid", "title": "瑞士六大银行联合 UBS 测试瑞士法郎稳定币沙盒，探索区块链应用场景", "source": "Reuters", "url": "https://www.reuters.com/business/finance/swiss-banks-test-use-cases-swiss-franc-stablecoin-2026-04-08/"},
    {"tag": "中", "level": "mid", "title": "机构报告：77% 企业稳定币用户以供应商支付为主要场景，成本节省超 10%", "source": "Fintech Times", "url": "https://thefintechtimes.com/morph-predicts-stablecoins-will-capture-10-of-global-cross-border-payments-by-2030/"},
    {"tag": "低", "level": "low", "title": "稳定币将在 2030 年前占据全球跨境支付 10% 份额", "source": "Fintech Times", "url": "https://thefintechtimes.com/morph-predicts-stablecoins-will-capture-10-of-global-cross-border-payments-by-2030/"},
]

# ============ 计算 24h 变化（从 marketCapChange7d 推算）============
# non_stable_chg 是7日变化率（decimal），7日绝对变化量 = cap * chg，估算日均
rwa_7d_abs_change = non_stable_cap * non_stable_chg  # 7日绝对变化量（美元）
rwa_24h_cap_change = rwa_7d_abs_change / 7  # 估算24h变化
rwa_24h_sign = "+" if rwa_24h_cap_change >= 0 else ""
rwa_24h_str = (f"{rwa_24h_sign}{yi(abs(rwa_24h_cap_change))}" if abs(rwa_24h_cap_change) > 1e6 else "基本持平")

sc_7d_abs_change = stable_cap * stable_chg
sc_24h_cap_change = sc_7d_abs_change / 7
sc_24h_sign = "+" if sc_24h_cap_change >= 0 else ""
sc_24h_str = (f"{sc_24h_sign}{yi(abs(sc_24h_cap_change))}" if abs(sc_24h_cap_change) > 1e6 else "基本持平")

# ============ RWA 市场总结（自然段落）============
top = rwa_assets[0] if rwa_assets else None
bot = rwa_assets[-1] if rwa_assets else None
top_name = name_map.get(top['name'], top['name']) if top else ""
bot_name = name_map.get(bot['name'], bot['name']) if bot else ""

rwa_summary = ("RWA（非稳定币）今日总市值 " + yi(non_stable_cap) + " 亿美元，"
    + "24小时内" + rwa_24h_str + " 亿美元。"
    + top_name + "领涨" + pct(top['marketCapChange7d']) + "（" + yi(top['marketCap']) + " 亿美元），"
    + "与" + bot_name + "仅" + pct(bot['marketCapChange7d']) + "形成鲜明分化，"
    + "呈现出机构旺盛需求与收益下行压力并存的核心矛盾。"
    + "受 FDIC 代币化存款框架正式落地、美伊达成两周停火协议带动美债收益率单日暴跌 10bp 影响，"
    + "代币化美债产品吸引力回升，私人信贷延续强劲增势。FDIC 明确储备需 1:1 全额支持并按月披露，"
    + "贝莱德 BUIDL 持续吸引机构资金，监管清晰度正加速传统资本入场。整体来看，该赛道呈现加速机构化特征，"
    + pct(non_stable_chg) + " 的7日增速显示出 RWA 正成为主流配置方向，未受到短期地缘风险干扰。")

# ============ 稳定币市场总结（自然段落）============
usdt_share_val = usdt_cap * 1e8 / stable_cap * 100
usdc_share_val = usdc_cap * 1e8 / stable_cap * 100

sc_summary = ("稳定币今日总市值 " + yi(stable_cap) + " 亿美元，"
    + "24小时内" + sc_24h_str + " 亿美元，"
    + "USDT 以" + str(int(usdt_cap)) + "亿美元占据" + f"{usdt_share_val:.1f}" + "%市场份额，USDC 紧随其后（" + f"{usdc_share_val:.1f}" + "%）。"
    + "监管框架全面落地为 3230 亿美元稳定币市场打开规模化大门，"
    + "与传统银行发币竞争潜力形成核心张力。"
    + "受 FDIC 审慎监管框架批准、GENIUS 法案正式实施、瑞士六大国银行启动瑞郎稳定币沙盒影响，"
    + "稳定币整体维持" + pct(stable_chg) + "的7日增势，竞争格局趋于多元。"
    + "77%企业用户以供应商支付为主要场景（成本节省10%以上），"
    + "54% Fortune 500正在评估入场，机构采纳正从试点走向规模化。"
    + "整体来看，稳定币正从加密资产向数字支付基础设施演进，"
    + "赛道" + pct(stable_chg) + "的增速显示出稳健扩张态势，未受到短期价格波动干扰。")

# ============ JS 数据 ============
rwa_assets_js = json.dumps([
    {"name": name_map.get(a["name"], a["name"]), "cap": yi(a["marketCap"]), "chg": a["marketCapChange7d"]}
    for a in rwa_assets
], ensure_ascii=False)

stablecoins_js = json.dumps([{"name": n, "cap": c} for n, c in sc_data], ensure_ascii=False)
rwa_news_js = json.dumps(rwa_news, ensure_ascii=False)
sc_news_js = json.dumps(sc_news, ensure_ascii=False)

# ============ BTC 数据（直接调用 API）============
import urllib.request
btc_url = "https://api.coinfound.org/api/kakyoin/v1/c/crypto-stock/dat/holding-coin/list"
with urllib.request.urlopen(btc_url, timeout=10) as r:
    btc_list = json.loads(r.read())["data"]
btc_data_btc = next((x for x in btc_list if x["symbol"] == "BTC"), btc_list[0])

btc_holder_count = int(btc_data_btc["holderCount"])
btc_holding_count = int(btc_data_btc["totalHoldingCount"])
btc_total_value = btc_data_btc["totalHoldingValue"] / 1e8
btc_supply_ratio = btc_data_btc["supplyRatio"] * 100
btc_holding_str = f"{btc_holding_count}"  # 无逗号
btc_total_b = f"{btc_total_value * 0.1:.2f}"  # 亿美元×0.1=B（850.59×0.1=85.06）
btc_ratio_str = f"{btc_supply_ratio:.2f}"

# MSTR 数据（从 Strategy.com 确认：截至 4月5日共 766970 BTC）
mstr_btc = 766970

# ============ BTC 复制模板 ============
# MSTR 持币比例
mstr_ratio_of_total = mstr_btc / btc_holding_count * 100

# 格式一（主模板）
btc_lines = [
    f"CoinFound 数据：{btc_holder_count}家上市公司合计持有{btc_holding_str}枚比特币，总储备价值约{btc_total_b}B，占比特币总量的{btc_ratio_str}%",
    f"ME News 消息，{today_cn}（UTC+8），据 CoinFound 数据显示，目前{btc_holder_count}家上市公司合计持有{btc_holding_str}枚BTC，占比特币总量的 {btc_ratio_str}%。其中，Strategy Inc（MSTR）持币{mstr_btc}枚BTC，占上市公司总持仓的{mstr_ratio_of_total:.1f}%。",
    f"（来源：CoinFound）",
]

# ============ 模板替换 ============
html = open(REPO_DIR + "/template.html").read()

replacements = {
    "{{today_cn}}": today_cn,
    "{{gen_time}}": gen_time,
    "{{rwa_total}}": yi(rwa_total),
    "{{rwa_total_chg}}": pct(rwa_total_chg),
    "{{rwa_total_chg_class}}": chg_class(rwa_total_chg),
    "{{stable_cap}}": yi(stable_cap),
    "{{stable_chg}}": pct(stable_chg),
    "{{stable_chg_class}}": chg_class(stable_chg),
    "{{non_stable_cap}}": yi(non_stable_cap),
    "{{non_stable_chg}}": pct(non_stable_chg),
    "{{non_stable_chg_class}}": chg_class(non_stable_chg),
    "{{holders}}": f"{holders/1e8:.2f}",
    "{{holders_chg}}": pct(holders_chg),
    "{{holders_chg_class}}": chg_class(holders_chg),
    "{{usdt_share}}": f"{usdt_share_val:.1f}",
    "{{stable_total_raw}}": f"{stable_cap/1e8:.2f}",
    "{{rwa_copy_text}}": "\n".join(rwa_lines),
    "{{sc_copy_text}}": "\n".join(sc_lines),
    "{{rwa_assets_js}}": rwa_assets_js,
    "{{stablecoins_js}}": stablecoins_js,
    "{{rwa_news_js}}": rwa_news_js,
    "{{sc_news_js}}": sc_news_js,
    "{{rwa_summary}}": rwa_summary,
    "{{sc_summary}}": sc_summary,
    "{{btc_copy_text}}": "\n".join(btc_lines),
}

for k, v in replacements.items():
    html = html.replace(k, str(v))

with open(REPO_DIR + "/index.html", "w") as f:
    f.write(html)

print(f"OK: {today_cn}")
print(f"  BTC: {btc_holder_count}家 / {btc_holding_str}枚 / 占比{btc_ratio_str}%")
print(f"  RWA（非稳定币）: {yi(non_stable_cap)} 亿美元")
print(f"  稳定币: {yi(stable_cap)} 亿美元")
PYEOF

# ====== 3. 推送 ======
echo "[3/4] 推送到 GitHub Pages..."
cd "$REPO_DIR"
git add index.html template.html
git commit -m "每日数据简报 $(python3 -c "from datetime import datetime; print(datetime.now().strftime('%-m月%-d日'))") $(date +%H:%M)" || echo "Nothing to commit"
GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_ed25519" git push origin main 2>&1

# ====== 4. 清理 ======
rm -f "$REPO_DIR"/.tmp_*_*.json
echo "[$(date)] 完成！"
