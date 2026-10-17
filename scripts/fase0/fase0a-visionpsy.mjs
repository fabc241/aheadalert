// Fase 0A (Mac): VisionPsy Nano 460M (Flash e Base, Q4_K_M) sulle foto reali.
// Stesse due richieste usate per SmolVLM2 (fase0c) per un confronto diretto:
// A) descrizione neutra in inglese + traduzione IT (Bergamot)
// B) domanda diretta su scale/gradini/scale mobili/cordoli.
// Uso: node scripts/fase0/fase0a-visionpsy.mjs   (dalla cartella mobile/)
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
  MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
  MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0_1,
  VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
  VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M_1,
} from '@qvac/sdk';

const here = path.dirname(fileURLToPath(import.meta.url));
const imgDir = path.join(here, 'immagini-reali');
const outDir = path.join(here, 'risultati');
fs.mkdirSync(outDir, { recursive: true });
const images = fs.readdirSync(imgDir).filter((f) => /\.jpe?g$/i.test(f)).sort();

const PROMPT_DESCR = 'Describe this image in two short sentences.';
const PROMPT_STEPS =
  'Are there any stairs, steps, escalators or curbs in this image? Answer "yes" or "no" first, then say where in one short sentence.';

// Flash: constants without suffix, image_no_upscale 'on'. Base: "_1" constants, flag unset.
const VARIANTS = [
  {
    name: 'Flash',
    modelSrc: VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
    projectionModelSrc: MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
    extra: { image_no_upscale: 'on' },
  },
  {
    name: 'Base',
    modelSrc: VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M_1,
    projectionModelSrc: MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0_1,
    extra: {},
  },
];

async function ask(modelId, img, prompt) {
  const t = Date.now();
  let first = 0;
  let text = '';
  const res = completion({
    modelId,
    history: [{ role: 'user', content: prompt, attachments: [{ path: path.join(imgDir, img) }] }],
    stream: true,
  });
  for await (const tok of res.tokenStream) {
    if (!first) first = Date.now() - t;
    text += tok;
  }
  return { text: text.trim().replace(/\s+/g, ' '), ms: Date.now() - t, first };
}

const results = {};
for (const v of VARIANTS) {
  const t = Date.now();
  const modelId = await loadModel({
    modelSrc: v.modelSrc,
    modelConfig: { ctx_size: 2048, projectionModelSrc: v.projectionModelSrc, ...v.extra },
    onProgress: (p) => p.percentage < 100 && process.stderr.write(`\r▸ ${v.name}: ${p.percentage.toFixed(0)}%  `),
  });
  console.log(`\n${v.name} caricato in ${((Date.now() - t) / 1000).toFixed(1)} s`);
  results[v.name] = [];
  for (const img of images) {
    const d = await ask(modelId, img, PROMPT_DESCR);
    const s = await ask(modelId, img, PROMPT_STEPS);
    results[v.name].push({ img, d, s });
    console.log(`[${v.name}] ${img}: ${d.text}\n   scale? ${s.text}`);
  }
  await unloadModel({ modelId, clearStorage: false });
}

const tr = await loadModel({ modelSrc: BERGAMOT_EN_IT, modelConfig: { engine: 'Bergamot', from: 'en', to: 'it' } });
for (const rows of Object.values(results)) {
  for (const r of rows) {
    let it = '';
    for await (const x of translate({ modelId: tr, text: [r.d.text], modelType: 'nmtcpp-translation', stream: true })
      .tokenStream)
      it += x;
    r.it = it.trim();
  }
}
await unloadModel({ modelId: tr });

const esc = (s) => s.replace(/\|/g, '/');
const md = [`# Fase 0A – VisionPsy Nano 460M su foto reali – ${new Date().toISOString()}`];
for (const [name, rows] of Object.entries(results)) {
  const avg = (k) => (rows.reduce((a, r) => a + r.d[k], 0) / rows.length / 1000).toFixed(2);
  md.push(
    '',
    `## ${name} (Q4_K_M) – primo token medio ${avg('first')} s, descrizione media ${avg('ms')} s (Mac M4)`,
    '',
    '| Foto | Descrizione (IT, tradotta) | Scale/gradini? (EN) |',
    '|---|---|---|',
    ...rows.map((r) => `| ${r.img} | ${esc(r.it)} | ${esc(r.s.text)} |`),
    '',
    `### Testo originale inglese (${name})`,
    ...rows.map((r) => `- **${r.img}**: ${r.d.text}`),
  );
}
fs.writeFileSync(path.join(outDir, 'fase0a-visionpsy.md'), md.join('\n') + '\n');
await close();
process.exit(0);
