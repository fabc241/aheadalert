// Phase 0 (desktop): functional check of QVAC in Italian on the Mac.
// Timings are indicative (NOT representative of the iPhone 13); results are saved to results/.
// Usage: node scripts/phase0/phase0-desktop.mjs   (from mobile/)
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
const imgDir = path.join(here, 'images');
const outDir = path.join(here, 'results');
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

log(`# Phase 0 desktop – ${new Date().toISOString()}`);
log(`Images: ${images.map((i) => path.basename(i)).join(', ')}`);

// 1. Scene description (SmolVLM2 500M)
try {
  let t = Date.now();
  const vlm = await loadModel({
    modelSrc: SMOLVLM2_500M_MULTIMODAL_Q8_0,
    modelConfig: { ctx_size: 2048, projectionModelSrc: MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0 },
    onProgress: progress('SmolVLM2'),
  });
  log(`\n## Scene description (SmolVLM2 500M)\nLoad: ${secs(Date.now() - t)}`);
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
  log(`\n## Scene description: ERROR\n${e?.stack ?? e}`);
}

// 2. OCR (EasyOCR latin_g2, Italian)
try {
  let t = Date.now();
  let langUsed = ['it'];
  let ocrModel;
  try {
    ocrModel = await loadModel({ modelSrc: OCR_LATIN, modelConfig: { langList: langUsed }, onProgress: progress('OCR') });
  } catch (e) {
    log(`\nOCR with langList ['it'] rejected: ${e?.message ?? e} → retrying with ['en']`);
    langUsed = ['en'];
    ocrModel = await loadModel({ modelSrc: OCR_LATIN, modelConfig: { langList: langUsed }, onProgress: progress('OCR') });
  }
  log(`\n## OCR (OCR_LATIN, langList ${JSON.stringify(langUsed)})\nLoad: ${secs(Date.now() - t)}`);
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
  log(`\n## OCR: ERROR\n${e?.stack ?? e}`);
}

// 3. Classification (bundled MobileNetV3-Small) – timing only
try {
  let t = Date.now();
  const cls = await loadModel({ modelType: 'ggml-classification' });
  log(`\n## Classification (MobileNetV3-Small)\nLoad: ${secs(Date.now() - t)}`);
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
    log(`- ${path.basename(img)}: median ${times[5].toFixed(1)} ms over 10 runs → ${JSON.stringify(last)}`);
  }
  await unloadModel({ modelId: cls });
} catch (e) {
  log(`\n## Classification: ERROR\n${e?.stack ?? e}`);
}

// 4. Italian text to speech (Supertonic 3)
try {
  let t = Date.now();
  const tts = await loadModel({
    modelSrc: TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
    modelConfig: { ttsEngine: 'supertonic', language: 'it', voice: 'F1', ttsSpeed: 1.0, ttsNumInferenceSteps: 5 },
    onProgress: progress('Supertonic 3'),
  });
  log(`\n## Text to speech (Supertonic 3, Italian)\nLoad: ${secs(Date.now() - t)}`);
  const phrases = [
    'Attenzione: gradino in discesa a un metro, sulla sinistra.',
    'Davanti a te c’è un corridoio con una porta aperta a destra e una sedia vicino al muro.',
  ];
  for (const [i, phrase] of phrases.entries()) {
    t = Date.now();
    const res = textToSpeech({ modelId: tts, text: phrase, inputType: 'text', stream: false });
    const audio = await res.buffer;
    const rate = (await res.sampleRate) ?? 44100;
    const ms = Date.now() - t;
    const file = path.join(outDir, `voice-${i + 1}.wav`);
    createWav(audio, rate, file);
    log(`- "${phrase}" → ${secs(ms)} for ${(audio.length / rate).toFixed(2)} s of audio (${path.basename(file)})`);
  }
  await unloadModel({ modelId: tts });
} catch (e) {
  log(`\n## Text to speech: ERROR\n${e?.stack ?? e}`);
}

fs.writeFileSync(path.join(outDir, 'phase0-desktop.md'), report.join('\n') + '\n');
console.log(`\nResults saved to ${path.join(outDir, 'phase0-desktop.md')}`);
await close();
process.exit(0);
