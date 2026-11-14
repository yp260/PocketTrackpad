#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成虚拟键盘的按键音 keyclick.wav（机械键盘 click 音色）。

合成思路（总长约 45ms，44100Hz / 单声道 / 16bit）：
  1) 瞬态「咔哒」：白噪声经过 3 抽头滑动平均（去高频毛刺）后按 1.5ms 指数衰减，
     提供按键触发的锐度；
  2) 本体「哒」：210Hz + 430Hz 两个阻尼正弦（衰减常数 8ms / 5ms），
     提供廉价机械键盘的腔体共振感；
  3) 峰值归一化到 0.9，最后整体淡出 2ms，消除尾部爆音。

用法：python scripts/gen_keyclick.py
输出：PocketTrackpad/Resources/keyclick.wav
"""

import math
import os
import random
import struct
import wave

SR = 44100
DURATION = 0.045          # 秒
OUT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "PocketTrackpad", "Resources", "keyclick.wav"
)


def gen_samples():
    n = int(SR * DURATION)
    random.seed(20261114)

    # 1) 噪声瞬态
    raw = [random.uniform(-1.0, 1.0) for _ in range(n)]
    smooth = []
    for i in range(n):
        a = raw[i]
        b = raw[i - 1] if i >= 1 else 0.0
        c = raw[i - 2] if i >= 2 else 0.0
        smooth.append((a + 2.0 * b + c) / 4.0)

    samples = []
    for i in range(n):
        t = i / SR
        # 瞬态噪声
        tick = smooth[i] * math.exp(-t / 0.0015) * 0.55
        # 阻尼共振体
        body = (math.sin(2 * math.pi * 210.0 * t) * math.exp(-t / 0.008) * 0.45 +
                math.sin(2 * math.pi * 430.0 * t) * math.exp(-t / 0.005) * 0.22)
        samples.append(tick + body)

    # 2) 峰值归一化
    peak = max(abs(s) for s in samples) or 1.0
    samples = [s / peak * 0.9 for s in samples]

    # 3) 尾部 2ms 淡出
    fade = int(SR * 0.002)
    for i in range(fade):
        idx = n - fade + i
        samples[idx] *= (1.0 - i / fade)

    return samples


def write_wav(path, samples):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    frames = bytearray()
    for s in samples:
        v = int(max(-1.0, min(1.0, s)) * 32767)
        frames += struct.pack("<h", v)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(bytes(frames))


if __name__ == "__main__":
    s = gen_samples()
    write_wav(OUT_PATH, s)
    rms = math.sqrt(sum(x * x for x in s) / len(s))
    print("written:", OUT_PATH)
    print("samples:", len(s), "duration_ms: %.1f" % (len(s) / SR * 1000))
    print("peak: %.3f  rms: %.4f" % (max(abs(x) for x in s), rms))
