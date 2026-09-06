#!/usr/bin/env bash
# 北極星（ai_docs/north-star.md）のゴール KPI「平日 1 日あたりの挿入回数」を履歴から集計する。
#
#   ./scripts/kpi.sh            # 直近 14 日の日別表と、転換条件の進捗
#   ./scripts/kpi.sh --days 30  # 期間を変える
#
# 読むのは ~/koebun/history/<timestamp>/meta.json だけ（アプリ側には触らない）。
# 生テキスト 10 文字未満は「テスト入力」として KPI から除く。
set -euo pipefail

exec python3 - "$@" <<'PY'
import glob, json, os, sys, datetime, statistics, collections

days = 14
args = sys.argv[1:]
if "--days" in args:
    days = int(args[args.index("--days") + 1])

MIN_CHARS = 10          # これ未満はテスト入力（「あいうえお」級）として除外
TARGET_PER_DAY = 10     # 転換条件: 平日 1 日 10 回以上
TARGET_DAYS = 14        # が 14 日（平日）続く

root = os.path.expanduser("~/koebun/history")
files = sorted(glob.glob(os.path.join(root, "*", "meta.json")))

per_day = collections.defaultdict(lambda: {"all": 0, "kpi": 0, "lens": []})
for f in files:
    try:
        m = json.load(open(f))
    except Exception:
        continue
    created = m.get("createdAt") or os.path.basename(os.path.dirname(f))
    try:
        # createdAt は ISO8601（UTC）。ローカル日付に直して日別に数える。
        ts = datetime.datetime.fromisoformat(created.replace("Z", "+00:00")).astimezone()
    except Exception:
        try:
            ts = datetime.datetime.strptime(os.path.basename(os.path.dirname(f))[:15], "%Y%m%dT%H%M%S").replace(tzinfo=datetime.timezone.utc).astimezone()
        except Exception:
            continue
    day = ts.date()
    n = len(m.get("rawText") or "")
    per_day[day]["all"] += 1
    if n >= MIN_CHARS:
        per_day[day]["kpi"] += 1
        per_day[day]["lens"].append(n)

today = datetime.date.today()
start = today - datetime.timedelta(days=days - 1)

print(f"KPI: 平日 1 日あたりの挿入回数（{MIN_CHARS} 文字未満は除外） 期間: {start} 〜 {today}")
print()
print(f"{'日付':<12}{'曜':<3}{'全件':>5}{'KPI':>5}{'中央値':>7}  達成")
print("-" * 44)
weekday_names = "月火水木金土日"
achieved = 0
weekday_count = 0
for i in range(days):
    d = start + datetime.timedelta(days=i)
    rec = per_day.get(d, {"all": 0, "kpi": 0, "lens": []})
    is_weekday = d.weekday() < 5
    med = int(statistics.median(rec["lens"])) if rec["lens"] else 0
    ok = is_weekday and rec["kpi"] >= TARGET_PER_DAY
    if is_weekday:
        weekday_count += 1
        achieved += 1 if ok else 0
    mark = "✓" if ok else ("" if is_weekday else "休")
    print(f"{d.isoformat():<12}{weekday_names[d.weekday()]:<3}{rec['all']:>5}{rec['kpi']:>5}{med:>7}  {mark}")

print("-" * 44)
total_kpi = sum(v["kpi"] for d, v in per_day.items() if start <= d <= today)
total_all = sum(v["all"] for d, v in per_day.items() if start <= d <= today)
print(f"合計: 全件 {total_all} / KPI {total_kpi}")
print()
print(f"転換条件: 平日 {TARGET_PER_DAY} 回以上 × {TARGET_DAYS} 日 → 達成 {achieved} / 平日 {weekday_count} 日（直近 {days} 日）")
if total_all == 0:
    print("履歴がありません（~/koebun/history が空）。")
PY
