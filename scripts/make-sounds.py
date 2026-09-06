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
