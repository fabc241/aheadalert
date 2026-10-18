# Phase 0A – Summary (Mac M4, 17 Oct 2026)

Mac measurements are indicative. Final timings and the Neural Engine/GPU choice come from the iPhone 13 only (Phase 0B).

## 1. Depth Anything V2 Small F16 – Core ML
| Compute unit | Load | Median | fps |
|---|---|---|---|
| CPU only | 0.3 s | 48.9 ms | 20.5 |
| CPU + GPU | 0.3 s | 40.5 ms | 24.7 |
| **CPU + Neural Engine** | 6.3 s (first compilation) | **22.5 ms** | **44.4** |
| All (.all) | 6.1 s | 22.5 ms | 44.4 |

- Neural Engine ~1.8× faster than the GPU; with `.all` Core ML picks the Neural Engine on its own.
- Model input 518×392.

Visual inspection of the maps (`depth/comparison.jpg`, not committed: derived from personal photos):
- ✅ Ascending steps clearly separated (01, 03); bollards very sharp (02); an open, protruding wardrobe door clearly visible (14); furniture well separated.
- ✅ **Works even on almost black photos** (09 bedroom and 10 bathroom, taken by the user): bed, chair and sanitary fixtures distinct.
- ⚠️ **Descending** stairs (04) and escalator (05): only a continuous gradient, individual steps do not stand out → the level change must come from geometry (floor plane + discontinuities), not from the image alone.
- ⚠️ Curbs and the pavement step (06, 07, 08): visible but faint.
- ⚠️ Mirrors (13): read as "depth" (openings that do not exist).

## 2. VisionPsy Nano 460M (Q4_K_M) vs SmolVLM2 500M (Q8)
| | SmolVLM2 | VisionPsy Flash | VisionPsy Base |
|---|---|---|---|
| Correct answer to "are there stairs/steps/curbs?" | 9/14 (3/8 steps) | **14/14** | 14/14 (wrong step position in 07) |
| First token / mean description (Mac) | – / 0.4–2.3 s | **0.99 s / 1.23 s** | 1.91 s / 2.18 s |
| Stair direction (up/down) | wrong (05) | wrong in 02 and 04 | wrong in 03 and 04 |
| Hallucinated details | rug, backpack, bed | almost none | bathtub (10), snow (11), dog instead of the cat (13) |
| User's dark photos (09, 10) | correct | correct | 10: hallucinated "bathtub" |

Conclusion: **VisionPsy Flash is the best choice** (faster, more accurate, fewer hallucinations). It remains unreliable on stair **direction** → never used for safety alerts.

Bergamot translation: good overall, with some lexical errors ("potted plants" → "piante inciampate" ≈ "tripped plants", "wall sconces" → "appannamenti da parete" ≈ "wall fogging").
