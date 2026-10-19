#!/usr/bin/env python3
"""Синтезирует звуки Luna: короткие мягкие тона под теми же именами, что ждёт SoundEngine.
Звуки coucou под лицензией автора и в репозиторий не берутся; эти — свои, их можно заменить
любым файлом с тем же именем в папке «Open sounds folder» настроек.

    python3 apps/macos/scripts/render-sounds.py        # → apps/macos/Resources/sounds/*.wav
"""
import math, os, struct, wave

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "sounds")

# имя: (ноты в герцах по очереди, длительность одной ноты в секундах, громкость)
SOUNDS = {
    "annoyed":  ([330, 294], 0.09, 0.5),
    "approval": ([880, 1175], 0.10, 0.55),
    "approve":  ([784, 1047, 1319], 0.07, 0.55),
    "attach":   ([523, 659], 0.08, 0.5),
    "blip":     ([1047], 0.05, 0.45),
    "close":    ([659, 523], 0.07, 0.45),
    "dizzy":    ([494, 440, 392, 349], 0.09, 0.5),
    "error":    ([294, 247], 0.14, 0.55),
    "finish":   ([659, 784, 1047], 0.09, 0.55),
    "greet":    ([523, 659, 784], 0.08, 0.5),
    "greeting": ([523, 659, 784, 1047], 0.09, 0.5),
    "gulp":     ([392, 294], 0.10, 0.5),
    "hover":    ([1319], 0.04, 0.3),
    "love":     ([784, 988, 1175], 0.10, 0.5),
    "open":     ([523, 659], 0.07, 0.45),
    "peek":     ([988], 0.05, 0.4),
    "pop":      ([880], 0.04, 0.5),
    "proud":    ([659, 784, 988, 1319], 0.08, 0.55),
    "question": ([659, 880], 0.12, 0.55),
    "rate":     ([1047, 1319], 0.06, 0.45),
    "search":   ([880, 988, 1109], 0.06, 0.45),
    "send":     ([784, 1047], 0.07, 0.5),
    "slap":     ([220], 0.06, 0.6),
    "sleep":    ([440, 392, 349], 0.16, 0.4),
    "think":    ([587, 659], 0.10, 0.4),
    "tick":     ([1568], 0.03, 0.35),
    "wink":     ([1175, 1568], 0.05, 0.45),
    "work":     ([523, 587], 0.07, 0.4),
    "yawn":     ([392, 349, 294], 0.18, 0.4),
}


def tone(freq, seconds, volume):
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        # огибающая: быстрый подъём, плавный спад
        env = min(1.0, t / 0.008) * math.exp(-4.5 * t / seconds)
        # основной тон плюс лёгкая вторая гармоника — мягкий «деревянный» тембр
        s = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * freq * 2 * t)
        out.append(volume * env * s / 1.25)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, (notes, dur, vol) in SOUNDS.items():
        samples = []
        for f in notes:
            samples += tone(f, dur, vol)
        samples += [0.0] * int(RATE * 0.05)
        path = os.path.join(OUT, f"{name}.wav")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))
    print(f"{len(SOUNDS)} звуков → {os.path.normpath(OUT)}")


if __name__ == "__main__":
    main()
