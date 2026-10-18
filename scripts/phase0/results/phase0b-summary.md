# Phase 0B – Summary (iPhone 13, iOS 27.0.1)

Part 1 is automatic: launched from the Mac on 17–18 Oct 2026, without the camera. Full reports are in `results/iphone/` (not committed).
Memory = phys_footprint, the metric iOS uses to terminate an app. On this iPhone the per-app limit is about **2,070 MB**.

## 1. Depth – Depth Anything V2 Small F16 (Core ML), 14 photos
| Compute unit | Load | Median | fps | Mac M4 |
|---|---|---|---|---|
| CPU only | 0.5 s | 69.9 ms | 14.3 | 48.9 ms |
| CPU + GPU | 0.4 s | 136.8 ms | 7.3 | 40.5 ms |
| **CPU + Neural Engine** | 10.5 s (first) | **30.3 ms** | **33.0** | 22.5 ms |
| All (.all) | 10.1 s | 30.3 ms | 33.0 | 22.5 ms |

- On the iPhone 13 the Neural Engine is **4.5× faster than the GPU** (1.8× on the Mac). With `.all` Core ML picks the Neural Engine.
- Neural Engine depth maps are **visually identical to the Mac ones** on all 14 photos: no Float16 degradation.
- The first Neural Engine load takes about 10 s: it must happen at app start-up, not when an alert is needed.

## 2. Description – VisionPsy Nano 460M Flash (Q4_K_M) + Bergamot EN→IT
| | iPhone 13 | Mac M4 |
|---|---|---|
| First token (mean) | 3.07 s (1.3 to 6.0 s) | 0.99 s |
| Full description (mean) | 3.79 s | 1.23 s |
| Bergamot translation | 0.16 s | – |
| App memory (peak) | 409 MB | – |
| "Stairs/steps?" answers identical to the Mac | **14/14** | – |

- The measured load (180 s) includes the first download (~410 MB); the load time from local storage is measured by "What is in front of me?" (section 7).
- The darkest photos (09, 10, 12) are the slowest (about 6 s).
- No out-of-memory terminations: VisionPsy fits with a wide margin.

## 3. Reading signs (OCR)
| Engine | Time per sign | App memory (peak) | Text |
|---|---|---|---|
| **Apple Vision** (it-IT) | **0.1–0.5 s** | negligible | perfect, even on the dark sign |
| QVAC OCR, canvasSize 640 | 6.5–6.9 s | 857 MB | correct, lines split; "9.00" instead of "9:00" and "18:00" split on one image |
| QVAC OCR, canvasSize 960 | 14.7 s | 1,417 MB | correct, lines split |
| QVAC OCR, canvasSize 1280 and 2560 (default) | – | > 2,070 MB | **iOS kills the app** |

## 4. Voice – Supertonic 3 (Italian, F1, 5 steps)
- 1.2–1.5 s for 5–7 s sentences (about 0.2× real time); app memory 611 MB.
- Audio identical in duration and format to the version approved on the Mac (44.1 kHz).

## 5. Classification – MobileNetV3-Small
- 136 ms per photo (Mac ~17 ms), JPEG decoding included (45 ms on the smallest photo).
- The weights shipped in the npm package do not end up in the phone bundle: they must be passed explicitly (`modelPath`).

## 6. Live depth (ARKit + Depth Anything) – 18 Oct, launched from the Mac, phone still in the dark (4 lux)
| Unit | Depth fps | Median inference | ARKit fps | Peak memory |
|---|---|---|---|---|
| CPU only | 10.0 | 85.6 ms | 59 | 250 MB |
| CPU + GPU | 6.2 | 145.0 ms | 59 | 285 MB |
| **CPU + Neural Engine** | **15.1** | **48.8 ms** | 59 | 203 MB |
| All (.all) | 15.2 | 48.1 ms | 59 | 203 MB |

- Live inference costs 49 ms instead of the 30 ms measured on photos: camera-frame conversion is added, and ARKit runs at 60 fps at the same time. 15 updates per second are still enough for walking.
- At 4 lux ARKit tracking stayed **0% of the time in the normal state**: in the dark there is no floor plane (needed for distances in metres).
- The user's first 5 runs crashed because of a code bug (a dispatch queue waiting on itself), since fixed.

## 7. "What is in front of me?" – full path (shot → VisionPsy → Bergamot → Supertonic)
- **9.3–13.5 s** from the request to the start of speech (10 runs). Typical breakdown: shot 1.6 s, VisionPsy load from storage 2.0 s, description 2.4 s, translation incl. load 1.1 s, voice incl. load 2.9–6 s.
- At 4–10 lux the ARKit frames are black (mean brightness 0–1 out of 255): VisionPsy correctly answers "no visible objects" without making things up. Brightening a 96 lux frame reveals a door and a bed.
- At 965 lux (hallway towards the kitchen) the description is plausible: table, chairs, window, plant.
- ⚠️ Memory: each request leaves about 30–100 MB allocated (from 151 to 520 MB after 4 requests, peaks up to 1,415 MB over 6 requests). To fix in the MVP: reuse the ARKit session and image context, verify model unloading.
- Room for improvement: keep the translator and the voice loaded (both are small), stream the voice, take the shot without the 1.5 s wait → estimate, to be verified: 5–7 s.

## 8. User verification (18 Oct)
| Shot | ARKit light | Actual scene | App answer | Result |
|---|---|---|---|---|
| 1, 2, 3 | 4–10 lux | completely dark to the user, shutters down; desk with books | "black image, no objects" | honest but useless: black frame (shot 1 is 0 in every pixel although the camera was not covered) |
| 4 | 965 lux | hallway towards the kitchen: table, chairs, red sofa behind the table, plant on the windowsill | table with a white tablecloth and chairs, window, "a red book and a small plant on the table" | ⚠️ two errors: the sofa becomes a "red book", the plant is placed on the table instead of the windowsill |
| 5 | 96 lux | bedroom: bed and window | "dark indistinct shape, lighter wall" | ❌ too vague |
| 6 | 10 lux | bathroom | "dark background with no objects" | ❌ black frame |

- Supertonic voice on the phone: **approved**.
- **Agreed threshold: 7 s** from request to speech, without losing accuracy. Today it is 9.3–13.5 s → the MVP needs the optimisations in section 7, measured again on the phone.
- In the dark the description is unusable with the ARKit frame. To try without turning on any light: a shot from the regular camera with long exposure (like Night mode) and brightening before the description.

## 9. Live depth – user runs at home, walking (18 Oct, about 15 minutes in total)
| Run | Unit | Depth fps | Median inference | Peak memory | Thermal | Tracking normal | Light (min/median) |
|---|---|---|---|---|---|---|---|
| 30 s × 4 (1st series) | Neural Engine | 15.4 | 48.1 ms | 609 MB | nominal | 97% | 792/964 lux |
| | All (.all) | 18.8 | 42.4 ms | 622 MB | nominal | 97% | 730/1015 lux |
| | CPU | 9.8 | 84.9 ms | 654 MB | nominal | 97% | – |
| | GPU | 6.3 | 143.7 ms | 702 MB | nominal | 97% | – |
| **5 minutes** | All (.all) | **16.0** | 47.2 ms | 625 MB | nominal → **fair** | 100% | 560/985 lux |
| 30 s × 4 (2nd series) | Neural Engine | 15.8 | 47.1 ms | 623 MB | fair | 97% | 78/873 lux |
| **5 minutes** | Neural Engine | **15.7** | 48.0 ms | 639 MB | fair → fair | 100% | 31/889 lux |

- Neural Engine and `.all` are equivalent (15–19 fps): the difference between the two series is measurement variability. Speed is stable over 5 minutes, with no drops.
- Thermal: after about 7 minutes of continuous use the phone goes to "fair" (`.fair`) and stays there; never "serious" (`.serious`). Indoors only: to be repeated outdoors and in the sun during the MVP.
- With ARKit tracking the space, memory rises to about 600–700 MB (203 MB in the dark without tracking): well below the limit (~2,070 MB).
- Tracking is normal 95–100% of the time, including passages through darker rooms (moments at 31–78 lux). In complete darkness (4 lux) it is 0%. The evening dim-light test has not been done yet.

## Phase 0B outcome (proposal, awaiting confirmation)
| Feature | Outcome | Reason |
|---|---|---|
| Obstacles with Depth Anything on the **Neural Engine** | ✅ in the MVP | 15–19 fps live, stable, only "fair" after 15 min |
| Distances in metres from the ARKit floor plane | ✅ with light, ⚠️ in the dark | tracking 95–100% with light, 0% at 4 lux → in the dark the app must say "reduced vision, alerts less reliable" (feature 5 of the plan) |
| Reading signs | ✅ **Apple Vision** | 0.1–0.5 s, perfect text; QVAC OCR rejected (6.5 s or out-of-memory termination) |
| Italian voice, Supertonic 3 | ✅ | approved by the user, 1.2–1.5 s per sentence |
| "What is in front of me?" (VisionPsy + Bergamot + Supertonic) | ⚠️ in the MVP only if it reaches **≤ 7 s** | 9.3–13.5 s today; detail errors even with light; unusable in the dark |
| MobileNetV3 classification | postponed to v2 | as planned |

## To do with the user
- Live depth in evening dim light (postponed to the MVP), to find out how low the light can go before ARKit tracking fails.
