// Fase 0c (desktop): SmolVLM2 su foto reali.
// A) descrizione neutra in inglese + traduzione IT (Bergamot)
// B) domanda diretta "ci sono scale/gradini/cordoli?" per misurare errori e invenzioni.
// Uso: node scripts/fase0/fase0c-foto-reali.mjs   (dalla cartella mobile/)
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  close,
  completion,
  loadModel,
  translate,
  unloadModel,
  BERGAMOT_EN_IT,
  MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0,
  SMOLVLM2_500M_MULTIMODAL_Q8_0,
} from '@qvac/sdk';

const here = path.dirname(fileURLToPath(import.meta.url));
const imgDir = path.join(here, 'immagini-reali');
const outDir = path.join(here, 'risultati');
fs.mkdirSync(outDir, { recursive: true });
const images = fs.readdirSync(imgDir).filter((f) => /\.jpe?g$/i.test(f)).sort();

const PROMPT_DESCR = 'Describe this image in two short sentences.';
const PROMPT_STEPS =
  'Are there any stairs, steps, escalators or curbs in this image? Answer "yes" or "no" first, then say where in one short sentence.';

async function ask(modelId, img, prompt) {
  const t = Date.now();
  let text = '';
  const res = completion({
    modelId,
    history: [{ role: 'user', content: prompt, attachments: [{ path: path.join(imgDir, img) }] }],
    stream: true,
  });
  for await (const tok of res.tokenStream) text += tok;
  return { text: text.trim().replace(/\s+/g, ' '), ms: Date.now() - t };
}

const rows = [];
const vlm = await loadModel({
  modelSrc: SMOLVLM2_500M_MULTIMODAL_Q8_0,
  modelConfig: { ctx_size: 2048, projectionModelSrc: MMPROJ_SMOLVLM2_500M_MULTIMODAL_Q8_0 },
});
for (const img of images) {
  const d = await ask(vlm, img, PROMPT_DESCR);
  const s = await ask(vlm, img, PROMPT_STEPS);
  rows.push({ img, d, s });
  console.log(`${img}: ${d.text}\n   scale? ${s.text}`);
}
await unloadModel({ modelId: vlm, clearStorage: false });

const tr = await loadModel({ modelSrc: BERGAMOT_EN_IT, modelConfig: { engine: 'Bergamot', from: 'en', to: 'it' } });
for (const r of rows) {
  let it = '';
  for await (const x of translate({ modelId: tr, text: [r.d.text], modelType: 'nmtcpp-translation', stream: true })
    .tokenStream)
    it += x;
  r.it = it.trim();
}
await unloadModel({ modelId: tr });

const md = [
  `# Fase 0c – SmolVLM2 su foto reali – ${new Date().toISOString()}`,
  '',
  '| Foto | Descrizione (IT, tradotta) | Scale/gradini? (EN) | Tempo descr. |',
  '|---|---|---|---|',
  ...rows.map(
    (r) => `| ${r.img} | ${r.it.replace(/\|/g, '/')} | ${r.s.text.replace(/\|/g, '/')} | ${(r.d.ms / 1000).toFixed(1)} s |`,
  ),
  '',
  '## Testo originale inglese',
  ...rows.map((r) => `- **${r.img}**: ${r.d.text}`),
];
fs.writeFileSync(path.join(outDir, 'fase0c-foto-reali.md'), md.join('\n') + '\n');
await close();
process.exit(0);
