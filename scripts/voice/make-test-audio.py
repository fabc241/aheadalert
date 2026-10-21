#!/usr/bin/env python3
"""MVP step 1.9: a synthetic test stream for the voice commands, made with the Mac's Italian voices.

Usage: python3 scripts/voice/make-test-audio.py <out_dir>
Writes <out_dir>/stream.f32 (16 kHz mono float32 little-endian, what the app sends to Whisper) and
<out_dir>/manifest.json (each phrase: start/end in ms, text, expected command or null, kind).
Phrases: the four commands in several voices, everyday phrases with similar words, the app's own messages, and
noise. Silence between phrases, as when a person speaks and pauses.
"""
import json, os, random, struct, subprocess, sys, tempfile, wave

RATE = 16000
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
random.seed(7)

COMMANDS = [("Avvia guida", "startGuide"), ("Ferma guida", "stopGuide"),
            ("Cosa ho davanti?", "describe"), ("Basta", "enough"),
            ("Avvia la guida", "startGuide"), ("Basta così", "enough")]
VOICES = ["Alice", "Eddy (Italiano (Italia))", "Reed (Italiano (Italia))", "Sandy (Italiano (Italia))",
          "Flo (Italiano (Italia))", "Grandpa (Italiano (Italia))"]
OTHER = ["Ciao, come stai?", "Andiamo a fare la spesa più tardi", "La guida turistica era molto brava",
         "Basta con questa storia, non ne posso più", "Cosa hai detto?", "Davanti alla porta c'è un tavolo",
         "Ferma l'autobus alla prossima", "Hai visto cosa c'è in televisione stasera?"]
APP = ["Guida avviata", "Davanti, un metro", "Sinistra, basso, mezzo metro", "Guida sospesa",
       "Avvisi di nuovo affidabili", "Zona buia davanti", "Gradino giù, un metro", "Guida fermata",
       "Un tavolo di legno davanti a una finestra. Sulla destra c'è una sedia."]

def say(text, voice, rate):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "x.wav")
        subprocess.run(["say", "-v", voice, "-r", str(rate), "--file-format=WAVE",
                        f"--data-format=LEI16@{RATE}", "-o", p, text], check=True)
        with wave.open(p) as w:
            n = w.getnframes()
            data = struct.unpack(f"<{n}h", w.readframes(n))
    return [s / 32768 for s in data]

items = []
for text, cmd in COMMANDS:
    for v in random.sample(VOICES, 3):
        items.append((text, cmd, "command", v))
for text in OTHER:
    items.append((text, None, "other", random.choice(VOICES)))
for text in APP:
    items.append((text, None, "app", "Alice"))
items.append(("", None, "noise", None))
items.append(("", None, "noise", None))
random.shuffle(items)

samples, manifest = [0.0] * RATE, []
for text, cmd, kind, voice in items:
    start = len(samples)
    if kind == "noise":
        amp = random.choice([0.02, 0.05])
        samples += [random.uniform(-amp, amp) for _ in range(3 * RATE)]
    else:
        rate = random.choice([160, 180, 200])
        samples += say(text, voice, rate)
    manifest.append({"startMs": start * 1000 // RATE, "endMs": len(samples) * 1000 // RATE, "text": text,
                     "command": cmd, "kind": kind, "voice": voice})
    samples += [random.uniform(-0.001, 0.001) for _ in range(int(RATE * random.uniform(1.5, 2.5)))]

with open(os.path.join(out, "stream.f32"), "wb") as f:
    f.write(struct.pack(f"<{len(samples)}f", *samples))
json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), ensure_ascii=False, indent=1)
print(f"{len(manifest)} phrases, {len(samples) / RATE:.0f} s")
