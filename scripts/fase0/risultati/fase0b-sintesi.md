# Fase 0B – Sintesi (iPhone 13, iOS 27.0.1)

Parte 1, automatica: avviata dal Mac il 17–18/10/2026, senza fotocamera. Rapporti completi in `risultati/iphone/` (non versionati).
Memoria = phys_footprint, cioè la misura che iOS usa per chiudere un'app. Su questo iPhone il limite per l'app è circa **2 070 MB**.

## 1. Profondità – Depth Anything V2 Small F16 (Core ML), 14 foto
| Unità di calcolo | Caricamento | Mediana | fps | Mac M4 |
|---|---|---|---|---|
| Solo CPU | 0,5 s | 69,9 ms | 14,3 | 48,9 ms |
| CPU + GPU | 0,4 s | 136,8 ms | 7,3 | 40,5 ms |
| **CPU + Neural Engine** | 10,5 s (primo) | **30,3 ms** | **33,0** | 22,5 ms |
| Tutte (.all) | 10,1 s | 30,3 ms | 33,0 | 22,5 ms |

- Il Neural Engine è **4,5 volte più veloce della GPU** sull'iPhone 13 (sul Mac lo era 1,8 volte). Con `.all` Core ML sceglie il Neural Engine.
- Mappe di profondità del Neural Engine **identiche a occhio a quelle del Mac** su tutte le 14 foto: nessun degrado da Float16.
- Il primo caricamento sul Neural Engine richiede circa 10 s: va fatto all'avvio dell'app, non al momento dell'avviso.

## 2. Descrizione – VisionPsy Nano 460M Flash (Q4_K_M) + Bergamot EN→IT
| | iPhone 13 | Mac M4 |
|---|---|---|
| Primo token (media) | 3,07 s (da 1,3 a 6,0 s) | 0,99 s |
| Descrizione completa (media) | 3,79 s | 1,23 s |
| Traduzione Bergamot | 0,16 s | – |
| Memoria app (picco) | 409 MB | – |
| Risposte "scale/gradini?" uguali al Mac | **14/14** | – |

- Il caricamento misurato (180 s) comprende il primo download (~410 MB): il tempo di caricamento dal telefono si misura con "Cosa ho davanti?".
- Le foto più buie (09, 10, 12) sono le più lente (circa 6 s).
- Nessuna chiusura per memoria: VisionPsy entra con largo margine.

## 3. Lettura cartelli (OCR)
| Motore | Tempo per cartello | Memoria app (picco) | Testo |
|---|---|---|---|
| **Apple Vision** (it-IT) | **0,1–0,5 s** | trascurabile | perfetto, anche sul cartello scuro |
| QVAC OCR, canvasSize 640 | 6,5–6,9 s | 857 MB | corretto, righe spezzate; "9.00" invece di "9:00" e "18:00" spezzato su una foto |
| QVAC OCR, canvasSize 960 | 14,7 s | 1 417 MB | corretto, righe spezzate |
| QVAC OCR, canvasSize 1280 e 2560 (predefinito) | – | > 2 070 MB | **iOS chiude l'app** |

## 4. Voce – Supertonic 3 (italiano, F1, 5 passi)
- 1,2–1,5 s per frasi da 5–7 s di audio (circa 0,2 volte il tempo reale); memoria app 611 MB.
- Audio identico per durata e formato a quello approvato sul Mac (44,1 kHz).

## 5. Classificazione – MobileNetV3-Small
- 136 ms per foto (Mac ~17 ms), decodifica del JPEG compresa (45 ms sulla foto più piccola).
- I pesi inclusi nel pacchetto npm non finiscono nel pacchetto per il telefono: vanno indicati a mano (`modelPath`).

## 6. Profondità dal vivo (ARKit + Depth Anything) – 18/10, avvio dal Mac, telefono fermo al buio (4 lux)
| Unità | fps profondità | Inferenza mediana | fps ARKit | Picco memoria |
|---|---|---|---|---|
| Solo CPU | 10,0 | 85,6 ms | 59 | 250 MB |
| CPU + GPU | 6,2 | 145,0 ms | 59 | 285 MB |
| **CPU + Neural Engine** | **15,1** | **48,8 ms** | 59 | 203 MB |
| Tutte (.all) | 15,2 | 48,1 ms | 59 | 203 MB |

- Dal vivo l'inferenza costa 49 ms invece dei 30 ms misurati sulle foto: si aggiungono la conversione del fotogramma della fotocamera e ARKit, che lavora a 60 fps nello stesso momento. 15 avvisi al secondo bastano comunque per camminare.
- Con 4 lux il tracciamento ARKit è rimasto **allo 0% in stato normale**: al buio manca il piano del pavimento (che serve per le distanze in metri). Va verificato con una luce reale.
- Le prime 5 prove dell'utente si sono chiuse per un errore nel codice (attesa di una coda su sé stessa), poi corretto.

## 7. "Cosa ho davanti?" – percorso completo (scatto → VisionPsy → Bergamot → Supertonic)
- **9,3–13,5 s** dalla richiesta all'inizio della voce (10 prove). Ripartizione tipica: scatto 1,6 s, caricamento VisionPsy dal telefono 2,0 s, descrizione 2,4 s, traduzione con caricamento 1,1 s, voce con caricamento 2,9–6 s.
- Con 4–10 lux i fotogrammi ARKit sono neri (luminosità media 0–1 su 255): VisionPsy risponde correttamente "nessun oggetto visibile", senza inventare. Schiarendo un fotogramma a 96 lux compaiono porta e letto.
- Con 965 lux (corridoio verso la cucina) la descrizione è plausibile: tavolo, sedie, finestra, pianta.
- ⚠️ Memoria: a ogni richiesta restano occupati circa 30–100 MB (da 151 a 520 MB dopo 4 richieste, picchi fino a 1 415 MB in 6 richieste). Da sistemare nell'MVP: riusare sessione ARKit e contesto immagine, verificare lo scaricamento dei modelli.
- Margini di miglioramento: tenere caricati traduttore e voce (sono piccoli), voce in streaming, scatto senza attesa di 1,5 s → stima, da verificare: 5–7 s.

## 8. Verifica dell'utente (18/10)
| Scatto | Luce ARKit | Scena reale | Risposta dell'app | Esito |
|---|---|---|---|---|
| 1, 2, 3 | 4–10 lux | buio completo per lei, tapparelle abbassate; scrivania con libri | "immagine nera, nessun oggetto" | onesta ma inutile: fotogramma nero (lo scatto 1 vale 0 in ogni pixel anche se la fotocamera non era coperta) |
| 4 | 965 lux | corridoio verso la cucina: tavolo, sedie, divano rosso dietro il tavolo, pianta sulla finestra | tavolo con tovaglia bianca e sedie, finestra, "libro rosso e piccola pianta sul tavolo" | ⚠️ due errori: il divano diventa un "libro rosso", la pianta finisce sul tavolo invece che sulla finestra |
| 5 | 96 lux | camera: letto e finestra | "forma scura indistinta, parete più chiara" | ❌ troppo vaga |
| 6 | 10 lux | bagno | "sfondo scuro senza oggetti" | ❌ fotogramma nero |

- Voce Supertonic sul telefono: **approvata**.
- **Soglia decisa: 7 s** dalla richiesta alla voce, senza perdere accuratezza. Oggi siamo a 9,3–13,5 s → nell'MVP servono le ottimizzazioni del punto 7, misurate di nuovo sul telefono.
- Al buio la descrizione non è utilizzabile con il fotogramma ARKit. Da provare senza accendere luci: scatto con la fotocamera normale a esposizione lunga (come la modalità notte) e schiarimento prima della descrizione.

## 9. Profondità dal vivo – prove dell'utente in casa, camminando (18/10, circa 15 minuti in tutto)
| Prova | Unità | fps profondità | Inferenza mediana | Picco memoria | Temperatura | Tracking normale | Luce (min/mediana) |
|---|---|---|---|---|---|---|---|
| 30 s × 4 (1ª serie) | Neural Engine | 15,4 | 48,1 ms | 609 MB | normale | 97% | 792/964 lux |
| | Tutte (.all) | 18,8 | 42,4 ms | 622 MB | normale | 97% | 730/1015 lux |
| | CPU | 9,8 | 84,9 ms | 654 MB | normale | 97% | – |
| | GPU | 6,3 | 143,7 ms | 702 MB | normale | 97% | – |
| **5 minuti** | Tutte (.all) | **16,0** | 47,2 ms | 625 MB | normale → **tiepido** | 100% | 560/985 lux |
| 30 s × 4 (2ª serie) | Neural Engine | 15,8 | 47,1 ms | 623 MB | tiepido | 97% | 78/873 lux |
| **5 minuti** | Neural Engine | **15,7** | 48,0 ms | 639 MB | tiepido → tiepido | 100% | 31/889 lux |

- Neural Engine e `.all` sono equivalenti (15–19 fps): la differenza tra le due serie è nella variabilità della misura. Velocità stabile per 5 minuti, senza cali.
- Temperatura: dopo circa 7 minuti di uso continuo il telefono passa a "tiepido" (`.fair`) e resta lì; mai "caldo" (`.serious`). In casa: all'aperto e al sole va ripetuta nell'MVP.
- Con ARKit che segue lo spazio la memoria sale a circa 600–700 MB (203 MB al buio senza tracciamento): resta sotto il limite (~2 070 MB) con largo margine.
- Tracciamento normale per il 95–100% del tempo, anche passando in stanze più buie (momenti a 31–78 lux). Al buio completo (4 lux) invece è 0%. La prova in penombra serale non è ancora stata fatta.

## Esito della Fase 0B (proposta da confermare)
| Funzione | Esito | Motivo |
|---|---|---|
| Ostacoli con Depth Anything sul **Neural Engine** | ✅ nell'MVP | 15–19 fps dal vivo, stabile, solo "tiepido" dopo 15 min |
| Distanze in metri dal piano del pavimento ARKit | ✅ con luce, ⚠️ al buio | tracciamento 95–100% con luce, 0% a 4 lux → al buio l'app deve dire "visione ridotta, avvisi meno affidabili" (funzione 5 del piano) |
| Lettura cartelli | ✅ **Apple Vision** | 0,1–0,5 s, testo perfetto; QVAC OCR scartato (6,5 s o chiusura per memoria) |
| Voce italiana Supertonic 3 | ✅ | approvata dall'utente, 1,2–1,5 s per frase |
| "Cosa ho davanti?" (VisionPsy + Bergamot + Supertonic) | ⚠️ nell'MVP solo se si arriva a **≤ 7 s** | oggi 9,3–13,5 s; errori di dettaglio anche con luce; inutilizzabile al buio |
| Classificazione MobileNetV3 | rinviata alla v2 | come da piano |

## Da fare con l'utente
- Profondità dal vivo in penombra serale (rinviata all'MVP), per sapere fino a che luce regge il tracciamento ARKit.
