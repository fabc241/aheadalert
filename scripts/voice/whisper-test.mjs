// MVP step 1.9: voice commands on the Mac, with the same model, settings and matching rules as the app.
// Usage (from mobile/): node scripts/voice/whisper-test.mjs <dir made by make-test-audio.py>
// Streams <dir>/stream.f32 in 100 ms chunks, in real time (written faster, audio is lost), and prints for each
// phrase what Whisper wrote, the command found and the time from the end of the phrase to the text.
// The app's own messages are matched as if the app were saying them (they must never give a command).
import fs from 'node:fs';
import path from 'node:path';
import { close, loadModel, transcribeStream, unloadModel } from '@qvac/sdk';
import { matchCommand } from '../../src/assistant/commandMatch.ts';
import * as sdk from '@qvac/sdk';
import { WHISPER_CONFIG, WHISPER_MODEL, VAD_MODEL } from '../../src/assistant/whisperConfig.ts';

// MODEL=WHISPER_SMALL_Q8_0 … to compare another model of the QVAC registry with the same settings.
const model = process.env.MODEL ? sdk[process.env.MODEL] : WHISPER_MODEL;

const dir = process.argv[2];
const audio = fs.readFileSync(path.join(dir, 'stream.f32'));
const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8'));
const CHUNK = 1600 * 4; // 100 ms

let t = Date.now();
const modelId = await loadModel({ modelSrc: model, modelConfig: { vadModelSrc: VAD_MODEL, ...WHISPER_CONFIG } });
console.log(`${model.name} loaded in ${Date.now() - t} ms`);

const session = await transcribeStream({ modelId, metadata: true });
const t0 = Date.now();
(async () => {
  for (let off = 0, i = 0; off < audio.length; off += CHUNK, i++) {
    session.write(audio.subarray(off, off + CHUNK));
    const wait = t0 + (i + 1) * 100 - Date.now();
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  }
  session.end();
})();

const rows = [];
for await (const seg of session) {
  const now = Date.now() - t0;
  const text = seg.text.trim();
  if (!text) continue;
  // Segment times count from the start of each speech stretch, not of the stream: the phrase is found from the
  // arrival time instead (real-time streaming: the phrases that ended in the last 4 s and started before now).
  if (!rows.length) console.log('first segment:', JSON.stringify(seg));
  const phrases = manifest.filter((p) => p.endMs <= now && p.endMs > now - 4000);
  const app = phrases.filter((p) => p.kind === 'app').map((p) => p.text);
  const m = matchCommand(text, app);
  const last = phrases.at(-1);
  const delay = last ? now - last.endMs : NaN;
  rows.push({ seg, text, m, phrases });
  console.log(
    `[${(now / 1000).toFixed(1)} s] +${delay} ms  "${text}"  → ${m.command ?? m.reason}` +
      `   | said: ${phrases.map((p) => `${p.kind}:${p.text || 'noise'}${p.command ? `=${p.command}` : ''}`).join(' / ')}`,
  );
}

// Score per phrase: each command phrase must give its command once; nothing else may give one.
let ok = 0, missed = 0, wrong = 0, falseCmd = 0;
for (const p of manifest) {
  const got = rows.filter((r) => r.phrases.includes(p) && r.m.command).map((r) => r.m.command);
  if (p.command) {
    if (got.includes(p.command)) ok++;
    else if (got.length) wrong++;
    else missed++;
  } else if (got.length && !rows.some((r) => r.phrases.includes(p) && r.phrases.some((q) => q.command))) falseCmd++;
}
const nCmd = manifest.filter((p) => p.command).length;
console.log(`\ncommands: ${ok}/${nCmd} recognised, ${missed} missed, ${wrong} wrong; false commands: ${falseCmd}`);
await unloadModel({ modelId });
await close?.();
process.exit(0);
