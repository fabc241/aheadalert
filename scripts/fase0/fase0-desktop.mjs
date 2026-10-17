// Fase 0 (desktop): verifica funzionale di QVAC in italiano sul Mac.
// Misura tempi indicativi (NON rappresentativi dell'iPhone 13) e salva i risultati.
// Uso: node scripts/fase0/fase0-desktop.mjs   (dalla cartella mobile/)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  classify,
  close,
  completion,
  loadModel,
  ocr,
  textToSpeech,
  unloadModel,
  MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0,
  OCR_LATIN,
  SMOLVLM2_500M_MULTIMODAL_Q8_0,
  TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
} from '@qvac/sdk';
import { createWav } from '../../node_modules/@qvac/sdk/dist/examples/tts/utils.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const imgDir = path.join(here, 'immagini');
const outDir = path.join(here, 'risultati');
fs.mkdirSync(outDir, { recursive: true });

const images = fs
  .readdirSync(imgDir)
  .filter((f) => /\.(png|jpe?g)$/i.test(f))
  .map((f) => path.join(imgDir, f));

const PROMPT_IT =
  'Descrivi brevemente in italiano cosa si vede, segnalando ostacoli, gradini, scale o scritte.';

const report = [];
const log = (line) => {
  console.log(line);
  report.push(line);
};
const secs = (ms) => (ms / 1000).toFixed(2) + ' s';
const progress = (label) => (p) => {
  if (p.percentage >= 100) return;
  process.stderr.write(`\r▸ ${label}: download ${p.percentage.toFixed(0)}%   `);
};

log(`# Fase 0 desktop – ${new Date().toISOString()}`);
log(`Immagini: ${images.map((i) => path.basename(i)).join(', ')}`);

// 1. Descrizione scena (SmolVLM2 500M)
try {
  let t = Date.now();
  const vlm = await loadModel({
    modelSrc: SMOLVLM2_500M_MULTIMODAL_Q8_0,
    modelConfig: { ctx_size: 2048, projectionModelSrc: MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0 },
    onProgress: progress('SmolVLM2'),
  });
  log(`\n## Descrizione scena (SmolVLM2 500M)\nCaricamento: ${secs(Date.now() - t)}`);
  for (const img of images) {
    for (const [lang, prompt] of [
      ['IT', PROMPT_IT],
      ['EN', 'Briefly describe what you see, pointing out obstacles, steps, stairs or text.'],
    ]) {
      t = Date.now();
      let first = 0;
      let text = '';
      const res = completion({
        modelId: vlm,
        history: [{ role: 'user', content: prompt, attachments: [{ path: img }] }],
        stream: true,
      });
      for await (const tok of res.tokenStream) {
        if (!first) first = Date.now() - t;
        text += tok;
      }
      const stats = await res.stats;
      log(
        `\n**${path.basename(img)} [prompt ${lang}]** – primo token ${secs(first)}, totale ${secs(Date.now() - t)}\n> ${text.trim()}\nstats: ${JSON.stringify(stats)}`,
      );
    }
  }
  await unloadModel({ modelId: vlm, clearStorage: false });
} catch (e) {
  log(`\n## Descrizione scena: ERRORE\n${e?.stack ?? e}`);
}

// 2. OCR (EasyOCR latin_g2, italiano)
try {
  let t = Date.now();
  let langUsed = ['it'];
  let ocrModel;
  try {
    ocrModel = await loadModel({ modelSrc: OCR_LATIN, modelConfig: { langList: langUsed }, onProgress: progress('OCR') });
  } catch (e) {
    log(`\nOCR con langList ['it'] rifiutato: ${e?.message ?? e} → riprovo con ['en']`);
    langUsed = ['en'];
    ocrModel = await loadModel({ modelSrc: OCR_LATIN, modelConfig: { langList: langUsed }, onProgress: progress('OCR') });
  }
  log(`\n## OCR (OCR_LATIN, langList ${JSON.stringify(langUsed)})\nCaricamento: ${secs(Date.now() - t)}`);
  for (const img of images) {
    t = Date.now();
    const blocks = await ocr({ modelId: ocrModel, image: img, options: { paragraph: false } }).blocks;
    log(
      `\n**${path.basename(img)}** – ${secs(Date.now() - t)}\n` +
        blocks.map((b) => `- "${b.text}" (confidenza ${b.confidence?.toFixed?.(2) ?? '?'})`).join('\n'),
    );
  }
  await unloadModel({ modelId: ocrModel, clearStorage: false });
} catch (e) {
  log(`\n## OCR: ERRORE\n${e?.stack ?? e}`);
}

// 3. Classificazione (MobileNetV3-Small incluso) – solo tempi
try {
  let t = Date.now();
  const cls = await loadModel({ modelType: 'ggml-classification' });
  log(`\n## Classificazione (MobileNetV3-Small)\nCaricamento: ${secs(Date.now() - t)}`);
  for (const img of images) {
    const buf = fs.readFileSync(img);
    const times = [];
    let last;
    for (let i = 0; i < 10; i++) {
      t = performance.now();
      last = await classify({ modelId: cls, image: buf });
      times.push(performance.now() - t);
    }
    times.sort((a, b) => a - b);
    log(`- ${path.basename(img)}: mediana ${times[5].toFixed(1)} ms su 10 run → ${JSON.stringify(last)}`);
  }
  await unloadModel({ modelId: cls });
} catch (e) {
  log(`\n## Classificazione: ERRORE\n${e?.stack ?? e}`);
}

// 4. Sintesi vocale italiana (Supertonic 3)
try {
  let t = Date.now();
  const tts = await loadModel({
    modelSrc: TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
    modelConfig: { ttsEngine: 'supertonic', language: 'it', voice: 'F1', ttsSpeed: 1.0, ttsNumInferenceSteps: 5 },
    onProgress: progress('Supertonic 3'),
  });
  log(`\n## Sintesi vocale (Supertonic 3, italiano)\nCaricamento: ${secs(Date.now() - t)}`);
  const frasi = [
    'Attenzione: gradino in discesa a un metro, sulla sinistra.',
    'Davanti a te c’è un corridoio con una porta aperta a destra e una sedia vicino al muro.',
  ];
  for (const [i, frase] of frasi.entries()) {
    t = Date.now();
    const res = textToSpeech({ modelId: tts, text: frase, inputType: 'text', stream: false });
    const audio = await res.buffer;
    const rate = (await res.sampleRate) ?? 44100;
    const ms = Date.now() - t;
    const file = path.join(outDir, `voce-${i + 1}.wav`);
    createWav(audio, rate, file);
    log(`- "${frase}" → ${secs(ms)} per ${(audio.length / rate).toFixed(2)} s di audio (${path.basename(file)})`);
  }
  await unloadModel({ modelId: tts });
} catch (e) {
  log(`\n## Sintesi vocale: ERRORE\n${e?.stack ?? e}`);
}

fs.writeFileSync(path.join(outDir, 'fase0-desktop.md'), report.join('\n') + '\n');
console.log(`\nRisultati salvati in ${path.join(outDir, 'fase0-desktop.md')}`);
await close();
process.exit(0);
