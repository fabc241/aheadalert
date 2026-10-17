# Fase 0A – Sintesi (Mac M4, 17/10/2026)

Misure sul Mac: indicative. Tempi e scelta Neural Engine/GPU definitivi solo sull'iPhone 13 (Fase 0B).

## 1. Depth Anything V2 Small F16 – Core ML
| Unità di calcolo | Caricamento | Mediana | fps |
|---|---|---|---|
| Solo CPU | 0,3 s | 48,9 ms | 20,5 |
| CPU + GPU | 0,3 s | 40,5 ms | 24,7 |
| **CPU + Neural Engine** | 6,3 s (prima compilazione) | **22,5 ms** | **44,4** |
| Tutte (.all) | 6,1 s | 22,5 ms | 44,4 |

- Neural Engine ~1,8× più veloce della GPU; con `.all` Core ML sceglie da solo il Neural Engine.
- Input del modello 518×392.

Ispezione visiva delle mappe (`profondita/confronto.jpg`):
- ✅ Gradini in salita ben separati (01, 03); paletti/dissuasori nettissimi (02); anta di armadio aperta sporgente ben visibile (14); mobili separati.
- ✅ **Funziona anche su foto quasi nere** (09 camera e 10 bagno dell'utente): letto, sedia, sanitari distinti.
- ⚠️ Scale in **discesa** (04) e scala mobile (05): solo una sfumatura continua, i singoli gradini non emergono → il dislivello va ricavato dalla geometria (piano del pavimento + discontinuità), non dalla sola immagine.
- ⚠️ Cordoli e gradino del marciapiede (06, 07, 08): visibili ma deboli.
- ⚠️ Specchi (13): letti come "profondità" (aperture inesistenti).

## 2. VisionPsy Nano 460M (Q4_K_M) vs SmolVLM2 500M (Q8)
| | SmolVLM2 | VisionPsy Flash | VisionPsy Base |
|---|---|---|---|
| Risposta corretta "ci sono scale/gradini/cordoli?" | 9/14 (3/8 gradini) | **14/14** | 14/14 (posizione del gradino errata in 07) |
| Primo token / descrizione media (Mac) | – / 0,4–2,3 s | **0,99 s / 1,23 s** | 1,91 s / 2,18 s |
| Direzione delle scale (su/giù) | sbagliata (05) | sbagliata in 02 e 04 | sbagliata in 03 e 04 |
| Dettagli inventati | tappeto, zaino, letto | quasi nessuno | vasca (10), neve (11), cane al posto del gatto (13) |
| Foto al buio dell'utente (09, 10) | corrette | corrette | 10: "vasca" inventata |

Conclusione: **VisionPsy Flash è la scelta migliore** (più rapido, più preciso, meno invenzioni). Resta inaffidabile sulla **direzione** delle scale → mai usato per avvisi di sicurezza.

Traduzione Bergamot: buona nel complesso, ma alcuni errori di lessico ("potted plants" → "piante inciampate", "wall sconces" → "appannamenti da parete").
