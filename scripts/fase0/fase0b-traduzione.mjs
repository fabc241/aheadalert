// Fase 0b (desktop): descrizione in inglese con SmolVLM2 + traduzione offline EN→IT (Bergamot),
// e OCR senza tentativi di rotazione per ridurre i tempi.
// Uso: node scripts/fase0/fase0b-traduzione.mjs   (dalla cartella mobile/)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  close,
  completion,
  loadModel,
  ocr,
  translate,
  unloadModel,
  BERGAMOT_EN_IT,
  MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0,
  OCR_LATIN,
  SMOLVLM2_500M_MULTIMODAL_Q8_0,
} from '@qvac/sdk';

const here = path.dirname(fileURLToPath(import.meta.url));
const imgDir = path.join(here, 'immagini');
const outDir = path.join(here, 'risultati');
fs.mkdirSync(outDir, { recursive: true });
const images = fs
  .readdirSync(imgDir)
  .filter((f) => /\.(png|jpe?g)$/i.test(f))
  .map((f) => path.join(imgDir, f));

const PROMPT_EN =
  'In two short sentences, describe what is in front of the camera for a visually impaired person walking. Mention obstacles, steps, stairs, doors and any written text.';

const report = [];
const log = (line) => {
  console.log(line);
  report.push(line);
};
const secs = (ms) => (ms / 1000).toFixed(2) + ' s';

log(`# Fase 0b desktop – ${new Date().toISOString()}`);

// 1. Descrizioni in inglese
const descrizioni = [];
try {
  const vlm = await loadModel({
    modelSrc: SMOLVLM2_500M_MULTIMODAL_Q8_0,
    modelConfig: { ctx_size: 2048, projectionModelSrc: MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0 },
  });
  for (const img of images) {
    const t = Date.now();
    let text = '';
    const res = completion({
      modelId: vlm,
      history: [{ role: 'user', content: PROMPT_EN, attachments: [{ path: img }] }],
      stream: true,
    });
    for await (const tok of res.tokenStream) text += tok;
    descrizioni.push({ img, en: text.trim(), ms: Date.now() - t });
  }
  await unloadModel({ modelId: vlm, clearStorage: false });
} catch (e) {
  log(`\n## Descrizione: ERRORE\n${e?.stack ?? e}`);
}

// 2. Traduzione EN→IT
try {
  let t = Date.now();
  const tr = await loadModel({
    modelSrc: BERGAMOT_EN_IT,
    modelConfig: { engine: 'Bergamot', from: 'en', to: 'it' },
  });
  log(`\n## Descrizione EN (SmolVLM2) + traduzione IT (Bergamot)\nCaricamento traduttore: ${secs(Date.now() - t)}`);
  for (const d of descrizioni) {
    t = Date.now();
    const res = translate({ modelId: tr, text: [d.en], modelType: 'nmtcpp-translation', stream: true });
    let it = '';
    for await (const x of res.tokenStream) it += x;
    log(
      `\n**${path.basename(d.img)}** – descrizione ${secs(d.ms)}, traduzione ${secs(Date.now() - t)}\n` +
        `EN > ${d.en}\nIT > ${it.trim()}`,
    );
  }
  await unloadModel({ modelId: tr });
} catch (e) {
  log(`\n## Traduzione: ERRORE\n${e?.stack ?? e}`);
}

// 3. OCR senza rotazioni
try {
  const m = await loadModel({
    modelSrc: OCR_LATIN,
    modelConfig: { langList: ['it'], defaultRotationAngles: [], contrastRetry: false, recognizerBatchSize: 8 },
  });
  log(`\n## OCR senza rotazioni (OCR_LATIN, it)`);
  for (const img of images) {
    const t = Date.now();
    const blocks = await ocr({ modelId: m, image: img, options: { paragraph: false } }).blocks;
    log(`- ${path.basename(img)}: ${secs(Date.now() - t)} → ${blocks.map((b) => b.text).join(' | ')}`);
  }
  await unloadModel({ modelId: m, clearStorage: false });
} catch (e) {
  log(`\n## OCR: ERRORE\n${e?.stack ?? e}`);
}

fs.writeFileSync(path.join(outDir, 'fase0b-traduzione.md'), report.join('\n') + '\n');
await close();
process.exit(0);
