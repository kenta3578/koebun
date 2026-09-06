#!/usr/bin/env python3
"""録音開始音・停止音の候補を波形合成して ~/koebun/sounds/ に書き出す（Issue #71）。

外部サービス・追加ライブラリ不要（標準ライブラリだけ）。短くて主張しすぎない音を狙う。

    python3 scripts/make-sounds.py            # 全候補を生成
    python3 scripts/make-sounds.py --list     # 候補名を表示
    python3 scripts/make-sounds.py --gain 0.5 # 音量（既定 0.35。1.0 でフルスケール）

生成した音は設定 →「録音開始音」「録音停止音」の「自分の音」に出る。
気に入らなければ下の PRESETS の周波数・長さを変えて作り直す。
"""
import argparse, math, os, struct, wave

RATE = 44100

def tone(freq, seconds, *, wave_fn="sine", attack=0.004, decay=None, level=1.0):
    """1 音。decay は指数減衰の時定数（秒）。None なら台形エンベロープ。"""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        if wave_fn == "sine":
            v = math.sin(2 * math.pi * freq * t)
        elif wave_fn == "triangle":
            v = 2 * abs(2 * ((t * freq) % 1) - 1) - 1
        elif wave_fn == "marimba":
            # 基音＋ 4 倍音（木琴は 4 倍音が強い）。倍音は速く減衰する。
            v = math.sin(2 * math.pi * freq * t) + 0.35 * math.sin(2 * math.pi * freq * 4 * t) * math.exp(-t * 30)
        else:
            raise ValueError(wave_fn)
        env = min(1.0, t / attack) if attack > 0 else 1.0
        if decay is not None:
            env *= math.exp(-t / decay)
        else:
            release = 0.02
            env *= min(1.0, (seconds - t) / release)
        out.append(v * env * level)
    return out

def glide(f0, f1, seconds, *, decay, level=1.0, attack=0.001):
    """周波数が f0 → f1 へ指数的に滑る減衰音（泡がはじける「ポッ」の芯）。"""
    n = int(RATE * seconds)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        f = f0 * (f1 / f0) ** (t / seconds)
        phase += 2 * math.pi * f / RATE
        env = min(1.0, t / attack) * math.exp(-t / decay)
        out.append(math.sin(phase) * env * level)
    return out

def purr_burst(freqs, seconds, *, mod_hz, decay, level=1.0):
    """(周波数, 重み) の正弦波を重ね、mod_hz で振幅変調した短い「ブルッ」。"""
    n = int(RATE * seconds)
    total = sum(w for _, w in freqs)
    out = []
    for i in range(n):
        t = i / RATE
        v = sum(w * math.sin(2 * math.pi * f * t) for f, w in freqs) / total
        am = 0.55 + 0.45 * math.sin(2 * math.pi * mod_hz * t)
        env = min(1.0, t / 0.003) * math.exp(-t / decay)
        out.append(v * am * env * level)
    return out

def knock(seconds=0.09, *, body=190.0, sub=45.0, level=1.0, seed=1):
    """木を軽く叩いた「コツッ」。短い雑音のアタック＋ body Hz の胴鳴り＋ sub Hz の低い響き。"""
    import random
    rnd = random.Random(seed)
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        click = (rnd.random() * 2 - 1) * math.exp(-t / 0.002) * 0.35
        tone_ = math.sin(2 * math.pi * body * t) * math.exp(-t / 0.02)
        low = math.sin(2 * math.pi * sub * t) * math.exp(-t / 0.026) * 1.2
        env = min(1.0, t / 0.0015)
        out.append((click + tone_ + low) * env * level)
    return out

def beep(freq, seconds, *, attack=0.005, release=0.015, level=1.0):
    """一定音量のビープ（台形エンベロープ）。"""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = min(1.0, t / attack, (seconds - t) / release)
        out.append(math.sin(2 * math.pi * freq * t) * max(0.0, env) * level)
    return out

def mix(*segments, gap=0.0):
    """音を順に並べる（gap 秒の無音を挟む）。"""
    silence = [0.0] * int(RATE * gap)
    out = []
    for i, seg in enumerate(segments):
        if i: out += silence
        out += seg
    return out

def overlay(a, b, offset=0.0):
    """b を a の offset 秒後に重ねる。"""
    start = int(RATE * offset)
    n = max(len(a), start + len(b))
    out = [0.0] * n
    for i, v in enumerate(a): out[i] += v
    for i, v in enumerate(b): out[start + i] += v
    return out

# 名前 → 波形。開始音は上向き・明るめ、停止音は下向き・落ち着いた音。
PRESETS = {
    # 2 音の上昇ブリップ（開始向き）
    "koebun-up":     lambda: mix(tone(660, 0.07), tone(990, 0.09), gap=0.01),
    # 2 音の下降ブリップ（停止向き）
    "koebun-down":   lambda: mix(tone(990, 0.07), tone(660, 0.09), gap=0.01),
    # 木琴風の 1 打（開始向き。短い減衰）
    "marimba-high":  lambda: tone(880, 0.35, wave_fn="marimba", decay=0.09),
    # 木琴風の低い 1 打（停止向き）
    "marimba-low":   lambda: tone(440, 0.40, wave_fn="marimba", decay=0.12),
    # ごく短いティック（主張しない。どちらにも）
    "tick":          lambda: tone(1400, 0.03, wave_fn="triangle", decay=0.008),
    # 柔らかい 2 音の和音（開始向き）
    "chime-open":    lambda: overlay(tone(523, 0.30, decay=0.10), tone(784, 0.30, decay=0.10), 0.0),
    # 柔らかい下降の和音（停止向き）
    "chime-close":   lambda: overlay(tone(784, 0.30, decay=0.10), tone(523, 0.30, decay=0.10), 0.03),
    # macOS の Pop 風: 700→480Hz を 15ms で急降下する「ポッ」＋ 70ms 後の小さな反響
    # （実物を解析: 本体 5〜15ms・約 600〜700Hz、反響 70ms・135ms）
    "pop-like":      lambda: overlay(
                         overlay(glide(720, 480, 0.06, decay=0.007),
                                 glide(680, 470, 0.06, decay=0.007, level=0.6), 0.068),
                         glide(660, 460, 0.05, decay=0.006, level=0.25), 0.135),
    # macOS の Purr 風: 520Hz の脈 → 790Hz の脈（各 20〜30ms、約 28Hz の振幅変調で「ブルッ」）
    # ＋ 135ms 後の薄い反響（実物を解析: 15〜35ms が 500Hz 台、40〜60ms が 790Hz 台）
    "purr-like":     lambda: overlay(
                         overlay(purr_burst([(520, 1.0), (1040, 0.3)], 0.045, mod_hz=28, decay=0.014),
                                 purr_burst([(790, 1.0), (1580, 0.3)], 0.045, mod_hz=28, decay=0.012, level=1.1), 0.026),
                         purr_burst([(780, 1.0), (1560, 0.3)], 0.04, mod_hz=28, decay=0.012, level=0.28), 0.135),
    # 「クラシック」風の開始音: 木のノック → 100ms 後に C5（522Hz）のビープ 55ms → 薄い残響
    # （実物を解析: ノック 25〜65ms は 190Hz ＋ 40Hz 台、ビープ 150〜210ms、残響 275〜320ms）
    "classic-start": lambda: overlay(
                         overlay(knock(level=1.0),
                                 beep(522, 0.065, attack=0.006, release=0.02, level=0.9), 0.125),
                         beep(522, 0.045, attack=0.01, release=0.03, level=0.18), 0.25),
    # 「クラシック」風の停止音: 木のノックだけ。150ms 後にごく小さな 2 打目
    "classic-stop":  lambda: overlay(knock(level=1.15, seed=2),
                                     knock(0.06, body=250, sub=60, level=0.22, seed=3), 0.125),
}

def write_wav(path, samples, gain):
    peak = max(1e-9, max(abs(v) for v in samples))
    scale = gain / peak * 32767
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-32767, min(32767, v * scale)))) for v in samples))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--gain", type=float, default=0.35, help="ピーク音量（0〜1）")
    ap.add_argument("--out", default=os.path.expanduser("~/koebun/sounds"))
    ap.add_argument("names", nargs="*", help="生成する候補名（省略時は全部）")
    a = ap.parse_args()
    if a.list:
        for k in PRESETS: print(k)
        return
    os.makedirs(a.out, exist_ok=True)
    names = a.names or list(PRESETS)
    for name in names:
        if name not in PRESETS:
            raise SystemExit(f"unknown preset: {name}（--list で一覧）")
        path = os.path.join(a.out, f"{name}.wav")
        write_wav(path, PRESETS[name](), a.gain)
        print("wrote", path)

if __name__ == "__main__":
    main()
