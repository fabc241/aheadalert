// Phase 0B (iPhone 13): Depth Anything V2 Small on Core ML, per compute unit.
// Report lines are in Italian: they are shown in the app.
import Perception, { type DepthUnits, type LiveResult } from '../../modules/perception';
import type { Reporter } from './qvacTests';

const n = (v: number, d = 1) => v.toFixed(d).replace('.', ',');

export async function testDepthPhotos(r: Reporter) {
  r.log('\n## Depth Anything V2 Small F16 – 14 foto (stesso protocollo del Mac: 3 di riscaldamento + 30)');
  r.status('Preparo il modello di profondità…');
  const prep = await Perception.prepareDepthModel();
  if (prep.compiled) r.log(`Compilazione del modello sul telefono: ${n(prep.compileMs / 1000)} s (solo la prima volta)`);
  r.status('Misuro le quattro unità di calcolo, circa un minuto…');
  const rows = await Perception.benchDepthPhotos();
  r.log('\n| Unità di calcolo | Caricamento | Mediana | 90° percentile | fps | Temperatura |');
  r.log('|---|---|---|---|---|---|');
  for (const x of rows)
    r.log(`| ${x.label} | ${Math.round(x.loadMs)} ms | ${n(x.medianMs)} ms | ${n(x.p90Ms)} ms | ${n(x.fps)} | ${x.thermal} |`);
  r.log(`Input ${rows[0]?.input}. Mac M4: Neural Engine 22,5 ms, GPU 40,5 ms, CPU 48,9 ms.`);
  r.log('Mappe del Neural Engine salvate in results/depth-iphone (confronto a occhio con il Mac).');
}

function liveTable(r: Reporter, rows: LiveResult[]) {
  r.log('\n| Unità | Durata | fps profondità | Inferenza mediana | 90° perc. | Post-elab. | fps ARKit | Picco memoria | Temperatura inizio → fine | Tracking normale | Luce ARKit min/med/max |');
  r.log('|---|---|---|---|---|---|---|---|---|---|---|');
  for (const x of rows)
    r.log(
      `| ${x.label} | ${Math.round(x.elapsedS)} s | ${n(x.depthFps)} | ${n(x.medianMs)} ms | ${n(x.p90Ms)} ms | ${n(x.postMedianMs)} ms | ` +
        `${n(x.arFps)} | ${Math.round(x.peakFootprintMB)} MB | ${x.thermalStart} → ${x.thermalEnd} | ${Math.round(x.trackingNormalPct)}% | ` +
        `${Math.round(x.lightMin ?? 0)}/${Math.round(x.lightMedian ?? 0)}/${Math.round(x.lightMax ?? 0)} lm |`,
    );
}

/** Live ARKit frames, one or more units in sequence. Returns the fastest unit. */
export async function testDepthLive(r: Reporter, units: DepthUnits[], seconds: number): Promise<DepthUnits | undefined> {
  r.log(`\n## Profondità dal vivo su fotogrammi ARKit – ${seconds} s per unità`);
  r.log('Fotocamera ARKit 1920×1440 → Vision (ridimensionamento a 518×392) → Depth Anything → zone sx/centro/dx.');
  await Perception.prepareDepthModel();
  const rows: LiveResult[] = [];
  for (const u of units) {
    r.status(`Profondità dal vivo, ${u}: cammina o muovi il telefono per ${seconds} secondi`);
    const res = await Perception.benchDepthLive(u, seconds);
    rows.push(res);
  }
  liveTable(r, rows);
  const best = [...rows].sort((a, b) => b.depthFps - a.depthFps)[0];
  if (best) r.log(`Più veloce in questa prova: **${best.label}** (${n(best.depthFps)} fps).`);
  return best?.units as DepthUnits | undefined;
}
