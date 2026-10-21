// MVP step 1.8, criteria 1 and 3: "Cosa ho davanti?" as in the app (src/assistant/describe.ts), 10 requests in a row
// with the guide stopped: time to the voice and memory after each one. Report lines are in Italian (shown in the app).
import Perception from '../../modules/perception';
import { describe, LOG, prepareModels } from '../assistant/describe';
import type { Reporter } from './qvacTests';

const s = (ms?: number) => (ms === undefined ? '–' : (ms / 1000).toFixed(2).replace('.', ',') + ' s');
const mb = (v: number) => `${Math.round(v)} MB`;

export async function testDescribeRepeated(r: Reporter) {
  r.log('\n## Passo 1.8 – "Cosa ho davanti?" 10 volte di fila (guida spenta)');
  r.status('Carico i modelli…');
  let t = Date.now();
  await prepareModels();
  r.log(`Caricamento dei modelli: ${s(Date.now() - t)} — memoria app ${mb(Perception.memory().footprintMB)}`);
  r.log('\n| # | Alla voce | Fine | Memoria dopo | Descrizione |');
  r.log('|---|---|---|---|---|');
  const times: number[] = [];
  const mem: number[] = [];
  for (let i = 1; i <= 10; i++) {
    r.status(`Richiesta ${i} di 10`);
    t = Date.now();
    const x = await describe(() => {});
    const m = Perception.memory().footprintMB;
    mem.push(m);
    if (x.toVoiceMs !== undefined) times.push(x.toVoiceMs);
    r.log(`| ${i} | ${s(x.toVoiceMs)} | ${x.end}${x.error ? `: ${x.error}` : ''} | ${mb(m)} | ${x.italian} |`);
    await new Promise((res) => setTimeout(res, 2000));
  }
  const ok = times.filter((x) => x <= 7000).length;
  r.log(`\nEntro 7 s: **${ok}/10** (min ${s(Math.min(...times))}, max ${s(Math.max(...times))}).`);
  r.log(`Memoria: dopo la 1ª ${mb(mem[0])}, dopo la 10ª ${mb(mem[9])} (**${mem[9] - mem[0] >= 0 ? '+' : ''}${mb(mem[9] - mem[0])}**; criterio ≤ +50 MB).`);
  r.log(`Dettaglio dei tempi: ${LOG.replace(Perception.documentsPath, 'Documents')}`);
}
