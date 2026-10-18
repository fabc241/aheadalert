// Fase 0B (iPhone 13): prove QVAC su dispositivo, stessi modelli e impostazioni della Fase 0A sul Mac.
import {
  classify,
  completion,
  loadModel,
  ocr,
  textToSpeech,
  translate,
  unloadModel,
  BERGAMOT_EN_IT,
  MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
  OCR_LATIN,
  TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
  VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
} from '@qvac/sdk';
import Perception from '../../modules/perception';

export type Reporter = {
  /** riga del rapporto (markdown) */
  log: (line: string) => void;
  /** stato corrente, mostrato in grande e letto da VoiceOver */
  status: (text: string) => void;
};

const DOCS = Perception.documentsPath;
const FASE0 = `${DOCS}/fase0`;
export const PHOTOS = Array.from({ length: 14 }, (_, i) => `${FASE0}/immagini-reali/${String(i + 1).padStart(2, '0')}.jpg`);
const SIGNS = [`${FASE0}/immagini/cartello.png`, `${FASE0}/immagini/cartello_buio.png`];

// Stesse richieste della Fase 0A, per confrontare le risposte con il Mac
const PROMPT_DESCR = 'Describe this image in two short sentences.';
const PROMPT_STEPS =
  'Are there any stairs, steps, escalators or curbs in this image? Answer "yes" or "no" first, then say where in one short sentence.';

const s = (ms: number) => (ms / 1000).toFixed(2).replace('.', ',') + ' s';
const mb = (v: number) => `${Math.round(v)} MB`;
const name = (p: string) => p.split('/').pop() ?? p;
const clean = (t: string) => t.trim().replace(/\s+/g, ' ').replace(/\|/g, '/');

function progress(r: Reporter, label: string) {
  let last = -1;
  return (p: { percentage: number; downloaded?: number; total?: number }) => {
    const pct = Math.floor(p.percentage);
    if (pct === last || pct >= 100) return;
    last = pct;
    const size = p.total ? ` di ${mb(p.total / 1e6)}` : '';
    r.status(`Download ${label}: ${pct}%${size}`);
  };
}

/** Esegue `fn` misurando il picco di memoria (phys_footprint) di tutta l'app, worker QVAC compreso. */
async function withPeak<T>(fn: () => Promise<T>): Promise<{ value: T; peakMB: number }> {
  Perception.startMemorySampler();
  try {
    const value = await fn();
    return { value, peakMB: Perception.stopMemorySampler() };
  } catch (e) {
    Perception.stopMemorySampler();
    throw e;
  }
}

function memLine(label: string) {
  const m = Perception.memory();
  return `${label}: memoria app ${mb(m.footprintMB)}, ancora disponibile ${mb(m.availableMB)}, temperatura ${m.thermal}`;
}

export function checkFiles(): string[] {
  return [...PHOTOS, ...SIGNS, `${FASE0}/DepthAnythingV2SmallF16.mlpackage`, `${FASE0}/modelli/mobilenetv3_3class_v3_fp16.gguf`].filter((p) => !Perception.fileExists(p));
}

// --- VisionPsy Flash ---------------------------------------------------------------------------

function loadVisionPsy(r: Reporter) {
  return loadModel({
    modelSrc: VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
    modelConfig: {
      ctx_size: 2048,
      projectionModelSrc: MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
      image_no_upscale: 'on',
    },
    onProgress: progress(r, 'VisionPsy Flash'),
  });
}

function loadBergamot(r: Reporter) {
  return loadModel({
    modelSrc: BERGAMOT_EN_IT,
    modelConfig: { engine: 'Bergamot', from: 'en', to: 'it' },
    onProgress: progress(r, 'Bergamot EN→IT'),
  });
}

async function ask(modelId: string, image: string, prompt: string) {
  const t = Date.now();
  let first = 0;
  let text = '';
  const res = completion({
    modelId,
    history: [{ role: 'user', content: prompt, attachments: [{ path: image }] }],
    stream: true,
  });
  for await (const tok of res.tokenStream) {
    if (!first) first = Date.now() - t;
    text += tok;
  }
  return { text: clean(text), ms: Date.now() - t, first };
}

async function toItalian(modelId: string, en: string) {
  const t = Date.now();
  let it = '';
  for await (const x of translate({ modelId, text: [en], modelType: 'nmtcpp-translation', stream: true }).tokenStream)
    it += x;
  return { it: clean(it), ms: Date.now() - t };
}

/** VisionPsy Flash sulle 14 foto (stesse richieste del Mac) + traduzione Bergamot. */
export async function testVisionPsy(r: Reporter) {
  r.log('\n## VisionPsy Nano 460M Flash (Q4_K_M) + Bergamot EN→IT – 14 foto');
  r.log(memLine('Prima'));
  const rows: { img: string; d: Awaited<ReturnType<typeof ask>>; st: Awaited<ReturnType<typeof ask>>; it?: string; trMs?: number }[] = [];

  const { value: loadMs, peakMB } = await withPeak(async () => {
    let t = Date.now();
    r.status('Carico VisionPsy Flash…');
    const vlm = await loadVisionPsy(r);
    const loadMs = Date.now() - t;
    r.log(`Caricamento: ${s(loadMs)} — ${memLine('dopo il caricamento')}`);
    for (const [i, img] of PHOTOS.entries()) {
      r.status(`VisionPsy: foto ${i + 1} di ${PHOTOS.length}`);
      const d = await ask(vlm, img, PROMPT_DESCR);
      const st = await ask(vlm, img, PROMPT_STEPS);
      rows.push({ img: name(img), d, st });
    }
    r.log(memLine('Fine descrizioni'));
    await unloadModel({ modelId: vlm, clearStorage: false });
    t = Date.now();
    r.status('Carico Bergamot…');
    const tr = await loadBergamot(r);
    r.log(`Bergamot caricato in ${s(Date.now() - t)}`);
    for (const row of rows) {
      const x = await toItalian(tr, row.d.text);
      row.it = x.it;
      row.trMs = x.ms;
    }
    await unloadModel({ modelId: tr, clearStorage: false });
    return loadMs;
  });

  const avg = (f: (x: (typeof rows)[number]) => number) => rows.reduce((a, x) => a + f(x), 0) / rows.length;
  r.log(
    `Picco memoria app durante la prova: ${mb(peakMB)}. Caricamento ${s(loadMs)}. ` +
      `Media descrizione: primo token ${s(avg((x) => x.d.first))}, totale ${s(avg((x) => x.d.ms))}; ` +
      `domanda scale ${s(avg((x) => x.st.ms))}; traduzione ${s(avg((x) => x.trMs ?? 0))}.`,
  );
  r.log(`(Mac M4, Fase 0A: primo token 0,99 s, descrizione 1,23 s)`);
  r.log('\n| Foto | Primo token | Totale | Descrizione (IT) | Scale/gradini? (EN) |');
  r.log('|---|---|---|---|---|');
  for (const x of rows) r.log(`| ${x.img} | ${s(x.d.first)} | ${s(x.d.ms)} | ${x.it} | ${x.st.text} |`);
  r.log('\nTesto originale inglese:');
  for (const x of rows) r.log(`- **${x.img}**: ${x.d.text}`);
  r.log(memLine('Dopo lo scaricamento dei modelli'));
}

// --- Sintesi vocale ---------------------------------------------------------------------------

function loadSupertonic(r: Reporter) {
  return loadModel({
    modelSrc: TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
    modelConfig: { ttsEngine: 'supertonic', language: 'it', voice: 'F1', ttsSpeed: 1.0, ttsNumInferenceSteps: 5 },
    onProgress: progress(r, 'Supertonic 3'),
  });
}

async function speak(modelId: string, text: string, file: string) {
  const t = Date.now();
  const res = textToSpeech({ modelId, text, inputType: 'text', stream: false });
  const audio = await res.buffer;
  const rate = (await res.sampleRate) ?? 44100;
  const ms = Date.now() - t;
  await Perception.writeWav(file, audio, rate);
  return { ms, seconds: audio.length / rate };
}

export async function testTTS(r: Reporter) {
  r.log('\n## Sintesi vocale Supertonic 3 (italiano, voce F1, 5 passi)');
  const frasi = [
    'Attenzione: gradino in discesa a un metro, sulla sinistra.',
    'Davanti a te c’è un corridoio con una porta aperta a destra e una sedia vicino al muro.',
  ];
  const { peakMB } = await withPeak(async () => {
    const t = Date.now();
    r.status('Carico Supertonic…');
    const tts = await loadSupertonic(r);
    r.log(`Caricamento: ${s(Date.now() - t)}`);
    for (const [i, frase] of frasi.entries()) {
      r.status(`Sintesi frase ${i + 1}…`);
      const file = `${FASE0}/risultati/voce-iphone-${i + 1}.wav`;
      const x = await speak(tts, frase, file);
      r.log(`- "${frase}" → ${s(x.ms)} per ${x.seconds.toFixed(1).replace('.', ',')} s di audio (${(x.ms / 1000 / x.seconds).toFixed(2)}× tempo reale)`);
      // In avvio automatico dal Mac non suona: si misura soltanto (l'ascolto lo fa l'utente dal pulsante)
      if (!Perception.autoRun) {
        r.status(`Ascolta la frase ${i + 1}`);
        await Perception.playAudio(file);
      }
    }
    await unloadModel({ modelId: tts, clearStorage: false });
  });
  r.log(`Picco memoria app: ${mb(peakMB)}`);
}

// --- OCR --------------------------------------------------------------------------------------

export async function testOCR(r: Reporter) {
  r.log('\n## Lettura cartelli');
  r.log('Apple Vision (it-IT, accurate):');
  for (const img of SIGNS) {
    const x = await Perception.recognizeText(img);
    r.log(`- ${name(img)}: ${s(x.ms)} → ${x.lines.map((l) => `"${l.text}"`).join(' | ') || '(nessun testo)'}`);
  }
  // Con canvasSize 2560 (predefinito) e 1280 la lettura del primo cartello porta l'app oltre i ~2 GB e iOS la chiude.
  // Dalla più piccola alla più grande: se iOS chiude l'app, nel registro restano le misure già fatte.
  for (const canvasSize of [640, 960]) {
    r.log(`QVAC OCR_LATIN (it, senza rotazioni, magRatio 1, canvasSize ${canvasSize}):`);
    const { peakMB } = await withPeak(async () => {
      let t = Date.now();
      r.status(`Carico OCR QVAC (${canvasSize})…`);
      const m = await loadModel({
        modelSrc: OCR_LATIN,
        modelConfig: {
          langList: ['it'],
          defaultRotationAngles: [],
          contrastRetry: false,
          recognizerBatchSize: 8,
          magRatio: 1,
          canvasSize,
        },
        onProgress: progress(r, 'OCR'),
      });
      r.log(`- caricamento ${s(Date.now() - t)}`);
      for (const img of SIGNS) {
        r.status(`OCR QVAC su ${name(img)}…`);
        t = Date.now();
        const blocks = await ocr({ modelId: m, image: img, options: { paragraph: false } }).blocks;
        r.log(`- ${name(img)}: ${s(Date.now() - t)} → ${blocks.map((b) => `"${b.text}"`).join(' | ') || '(nessun testo)'}`);
      }
      await unloadModel({ modelId: m, clearStorage: false });
    });
    r.log(`- picco memoria app: ${mb(peakMB)}`);
  }
}

// --- Classificazione ----------------------------------------------------------------------------

export async function testClassify(r: Reporter) {
  r.log('\n## Classificazione MobileNetV3-Small (inclusa) – mediana su 10 esecuzioni');
  const t = Date.now();
  r.status('Carico classificatore…');
  // I pesi inclusi nel pacchetto npm non entrano nel bundle mobile: li copia scripts/fase0/copia-su-iphone.sh
  const cls = await loadModel({
    modelType: 'ggml-classification',
    modelConfig: { modelPath: `${FASE0}/modelli/mobilenetv3_3class_v3_fp16.gguf` },
  });
  r.log(`Caricamento: ${s(Date.now() - t)}`);
  const all: number[] = [];
  for (const [i, img] of PHOTOS.entries()) {
    r.status(`Classificazione foto ${i + 1} di ${PHOTOS.length}`);
    const bytes = await Perception.readFile(img);
    const times: number[] = [];
    let last: unknown;
    for (let k = 0; k < 10; k++) {
      const t0 = performance.now();
      last = await classify({ modelId: cls, image: bytes });
      times.push(performance.now() - t0);
    }
    times.sort((a, b) => a - b);
    all.push(times[5]);
    const top = Array.isArray(last) ? (last[0] as { label?: string; score?: number } | undefined) : undefined;
    r.log(`- ${name(img)}: ${times[5].toFixed(1)} ms${top?.label ? ` → ${top.label}` : ''}`);
  }
  all.sort((a, b) => a - b);
  r.log(`Mediana complessiva: ${all[Math.floor(all.length / 2)].toFixed(1)} ms (Mac: ~17 ms)`);
  await unloadModel({ modelId: cls });
}

// --- "Cosa ho davanti?" dal vivo -------------------------------------------------------------

/**
 * Percorso completo come nell'MVP, a freddo: fotogramma ARKit → VisionPsy (caricato e poi scaricato)
 * → Bergamot → Supertonic → riproduzione. Misura il tempo percepito dall'utente.
 */
export async function testCosaHoDavanti(r: Reporter) {
  r.log('\n## "Cosa ho davanti?" – percorso completo a freddo su fotogramma reale');
  const t0 = Date.now();
  const steps: string[] = [];
  const step = (label: string, since: number) => {
    steps.push(`${label} ${s(Date.now() - since)}`);
    return Date.now();
  };
  r.log(memLine('Prima'));
  const { peakMB } = await withPeak(async () => {
    r.status('Inquadra davanti a te: scatto tra un secondo e mezzo');
    let t = Date.now();
    const shot = await Perception.captureFrame(1024);
    t = step('scatto', t);
    r.status('Carico VisionPsy…');
    const vlm = await loadVisionPsy(r);
    t = step('caricamento VisionPsy', t);
    r.status('Descrivo…');
    const d = await ask(vlm, shot.path, PROMPT_DESCR);
    t = step(`descrizione (primo token ${s(d.first)})`, t);
    await unloadModel({ modelId: vlm, clearStorage: false });
    const tr = await loadBergamot(r);
    const it = await toItalian(tr, d.text);
    await unloadModel({ modelId: tr, clearStorage: false });
    t = step('traduzione (con caricamento)', t);
    const tts = await loadSupertonic(r);
    const file = `${FASE0}/risultati/cosa-ho-davanti.wav`;
    await speak(tts, it.it, file);
    await unloadModel({ modelId: tts, clearStorage: false });
    t = step('voce (con caricamento)', t);
    const total = Date.now() - t0;
    r.log(`Scatto: ${name(shot.path)} (${shot.width}×${shot.height}, luce ARKit ${Math.round(shot.light ?? -1)} lm)`);
    r.log(`EN: ${d.text}`);
    r.log(`IT: ${it.it}`);
    r.log(`Tempi: ${steps.join(' · ')}`);
    r.log(`**Dalla richiesta all'inizio della voce: ${s(total)}**`);
    r.status(it.it);
    if (!Perception.autoRun) await Perception.playAudio(file);
  });
  r.log(`Picco memoria app: ${mb(peakMB)} — ${memLine('dopo')}`);
}
