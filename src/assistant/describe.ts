// MVP step 1.8: "Cosa ho davanti?" – photo → VisionPsy (English) → Bergamot (Italian) → system voice.
// Agreed: from the tap to the start of the voice ≤ 7 s (Phase 0B: 9.3–13.5 s). What changed since Phase 0B:
// - the two models are loaded once in the background when the app opens and stay loaded (Phase 0B loaded and
//   unloaded them at each request: 2 s + 1 s);
// - the photo comes from the guide's camera when it runs, otherwise from a short camera session (native side);
// - only the first two sentences are written (the prompt asks for two, the model often writes three or four);
// - the system voice, as the guide's alerts, starts at once. The Supertonic voice (option A1) was measured on 20/10:
//   5.1–6.4 s with a plain scene but 7.7–25 s with a richer one (first sentence 2.3–3.9 s, up to 17 s), so the
//   fallback agreed with the user (A2) is used; it also frees about 400 MB.
// Same model, prompt and photo size as Phase 0, so that accuracy does not change.
// The guide's alerts go first: one played while the description is spoken ends it (native side).
// Log: Documents/describe/describe-log.csv (fetched with scripts/guide/fetch-logs.sh).
// Spoken and on-screen texts are in Italian.
import { cancel, completion, translate, unloadModel } from '@qvac/sdk';
import Perception, { type DescriptionEnd } from '../../modules/perception';
import { loadBergamot, loadVisionPsy, PHOTO_MAX_SIDE, PROMPT_DESCR } from './models';

/** ARKit light (lumens) below which the guide is suspended (step 1.2): the photo is black, nothing to describe. */
const DARK_LIGHT = 20;
/**
 * Mean brightness of the photo (0–255) below which it is black all the same: on 20/10 ARKit said 50 for photos the
 * model described as "a completely black image" (phone face down or covered). Phase 0B black shots: 0–1.
 */
const DARK_PHOTO = 10;

export const LOG = `${Perception.documentsPath}/describe/describe-log.csv`;
const LOG_HEAD =
  'time,photo_from,light,brightness,models_wait_ms,photo_ms,describe_ms,first_token_ms,translate_ms,first_voice_ms,to_voice_ms,' +
  'total_ms,end,memory_before_mb,memory_after_mb,english,italian\n';

type Models = { vlm: string; tr: string };
let models: Models | null = null;
let preparing: Promise<Models> | null = null;

/** Loads the two models once (translator first: small; then VisionPsy). Safe to call many times. */
export function prepareModels(): Promise<Models> {
  if (models) return Promise.resolve(models);
  if (!preparing) {
    preparing = (async () => {
      const tr = await loadBergamot();
      const vlm = await loadVisionPsy();
      models = { vlm, tr };
      return models;
    })().finally(() => {
      preparing = null;
    });
  }
  return preparing;
}

/** Frees the memory (before the technical tests, which load their own models). */
export async function releaseModels() {
  const m = models ?? (preparing ? await preparing.catch(() => null) : null);
  models = null;
  if (!m) return;
  for (const id of [m.vlm, m.tr]) await unloadModel({ modelId: id, clearStorage: false }).catch(() => {});
}

export type DescribePhase = 'photo' | 'thinking' | 'speaking';
export type DescribeResult = {
  end: DescriptionEnd | 'dark' | 'error';
  italian: string;
  /** From the request to the start of the voice; undefined when nothing was spoken. */
  toVoiceMs?: number;
  error?: string;
};

let running = false;

/** "Ferma descrizione". */
export function stopDescribe() {
  return Perception.describeStop();
}

const clean = (t: string) => t.trim().replace(/\s+/g, ' ');
/** The first two sentences of a text being written, once the second is complete (its full stop and a space). */
const twoSentences = (t: string) => t.match(/^\s*([^.!?]*[.!?]+\s+[^.!?]*[.!?]+)\s/)?.[1];
const csv = (v: unknown) => (typeof v === 'string' ? `"${v.replace(/"/g, '""')}"` : v === undefined ? '' : String(v));

/**
 * One description, spoken. `onPhase` follows its progress for the screen. Ends when the voice has finished, or when
 * it is stopped (alert, user).
 */
export async function describe(onPhase: (p: DescribePhase, text?: string) => void): Promise<DescribeResult> {
  if (running) return { end: 'error', italian: '', error: 'descrizione già in corso' };
  running = true;
  const t0 = Date.now();
  const memBefore = Perception.memory().footprintMB;
  const row: Record<string, unknown> = {};
  let stopped: DescriptionEnd | null = null;
  let requestId: string | null = null;
  const sub = Perception.addListener('onDescriptionStopped', ({ reason }) => {
    stopped = reason;
    if (requestId) cancel({ requestId }).catch(() => {});
  });
  const result: DescribeResult = { end: 'error', italian: '' };
  try {
    await Perception.describeBegin();
    onPhase('photo');
    if (!models) Perception.describeSay('Un momento, preparo la descrizione');
    // The photo is taken at once (the scene the user asked about), while the models may still be loading.
    const [shot, m] = await Promise.all([
      Perception.describeShot(PHOTO_MAX_SIDE),
      prepareModels().then((x) => ((row.models_wait_ms = Date.now() - t0), x)),
    ]);
    row.photo_from = shot.source;
    row.photo_ms = Math.round(shot.ms);
    row.light = shot.light === undefined ? undefined : Math.round(shot.light);
    if (stopped) return Object.assign(result, { end: stopped });
    row.brightness = Math.round(shot.brightness);
    if ((shot.light !== undefined && shot.light < DARK_LIGHT) || shot.brightness < DARK_PHOTO) {
      await Perception.describeSay('Troppo buio per descrivere');
      result.end = 'dark';
      return result;
    }

    // One step after the other. Translating and speaking the first sentence while VisionPsy was still writing was
    // tried on 20/10: the voice then took 14–25 s instead of 1.3–2.8 s (the models slow each other down).
    onPhase('thinking');
    let t = Date.now();
    const run = completion({
      modelId: m.vlm,
      history: [{ role: 'user', content: PROMPT_DESCR, attachments: [{ path: shot.path }] }],
      stream: true,
    });
    requestId = run.requestId;
    let english = '';
    for await (const tok of run.tokenStream) {
      if (!english) row.first_token_ms = Date.now() - t;
      english += tok;
      const two = twoSentences(english);
      if (two) {
        english = two;
        cancel({ requestId: run.requestId }).catch(() => {});
        break;
      }
    }
    requestId = null;
    row.describe_ms = Date.now() - t;
    row.english = clean(english);
    if (stopped) return Object.assign(result, { end: stopped });

    t = Date.now();
    let italian = '';
    for await (const x of translate({ modelId: m.tr, text: [clean(english)], modelType: 'nmtcpp-translation', stream: true }).tokenStream)
      italian += x;
    italian = clean(italian);
    row.translate_ms = Date.now() - t;
    row.italian = italian;
    result.italian = italian;
    onPhase('thinking', italian);
    if (stopped) return Object.assign(result, { end: stopped });

    t = Date.now();
    if (!stopped && (await Perception.describeSpeak(italian))) {
      row.first_voice_ms = Date.now() - t;
      result.toVoiceMs = row.to_voice_ms = Date.now() - t0;
      onPhase('speaking', italian);
    }
    result.end = stopped ?? (await Perception.describeFinish());
    return result;
  } catch (e) {
    result.end = 'error';
    result.error = e instanceof Error ? e.message : String(e);
    if (requestId) cancel({ requestId }).catch(() => {});
    await Perception.describeStop().catch(() => {});
    return result;
  } finally {
    sub.remove();
    // A description ended early (dark, stop, error) must not stay "in progress" natively.
    if (result.end !== 'done') await Perception.describeFinish().catch(() => {});
    running = false;
    row.total_ms = Date.now() - t0;
    row.end = result.error ? `error: ${result.error}` : result.end;
    row.memory_before_mb = Math.round(memBefore);
    row.memory_after_mb = Math.round(Perception.memory().footprintMB);
    const time = new Date().toLocaleTimeString('it-IT');
    const line = [time, ...LOG_HEAD.trim().split(',').slice(1).map((k) => row[k])].map(csv).join(',') + '\n';
    const head = Perception.fileExists(LOG) ? '' : LOG_HEAD;
    await Perception.appendText(LOG, head + line).catch(() => {});
  }
}
