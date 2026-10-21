// MVP step 1.9: hands-free voice commands. Agreed (21/10, "A1, B1"): with the app open on the home screen the
// microphone always listens, and four commands said on their own act like the buttons: "Avvia guida", "Ferma guida",
// "Cosa ho davanti", "Basta" (stops the description). Anything else is ignored in silence.
// - Offline and the same on iOS and Android: QVAC Whisper (Italian base, 64 MB) with the Silero voice detector,
//   fed with the phone's microphone (native side, echo-cancelled) about every 100 ms. Not Siri nor Voice Control.
// - Which command a phrase is: src/assistant/commandMatch.ts (tested on the Mac: scripts/voice/whisper-test.mjs).
// - The app's own voice: echo cancellation removes most of it; what is left and matches what the app is saying is
//   not taken for a command.
// A wake word ("Lux", proposed by the user) was not adopted for now: Whisper would still have to transcribe
// everything to find it, the app's voice is already filtered, and a short non-Italian word is often misheard. To be
// added if the false-command criterion fails.
// Log: Documents/voice/voice-log.csv (every phrase heard, what it was taken for, the times).
import { loadModel, transcribeStream, unloadModel } from '@qvac/sdk';
import Perception from '../../modules/perception';
import { matchCommand, type VoiceCommand } from './commandMatch';
import { VAD_MODEL, WHISPER_CONFIG, WHISPER_MODEL } from './whisperConfig';

export type { VoiceCommand } from './commandMatch';

export const VOICE_LOG = `${Perception.documentsPath}/voice/voice-log.csv`;
const LOG_HEAD = 'time,event,text,command,form,distance,reason,speech_end_ms,app_speech,memory_mb\n';

/** The microphone is read this often. */
const READ_EVERY_MS = 100;
/** A session long without speech is closed and opened again (a long session should not hold memory). */
const RENEW_AFTER_MS = 5 * 60_000;
const MEMORY_EVERY_MS = 60_000;
/**
 * Diagnostics: audio received, its loudest level and the voice detector's reports, this often (every 5 s during the
 * first tests of 21/10, when the microphone gave no audio).
 */
const LEVEL_EVERY_MS = 60_000;

let modelId: string | null = null;
let preparing: Promise<string> | null = null;

/** Loads Whisper once. Safe to call many times. */
export function prepareVoice(): Promise<string> {
  if (modelId) return Promise.resolve(modelId);
  if (!preparing) {
    preparing = loadModel({ modelSrc: WHISPER_MODEL, modelConfig: { vadModelSrc: VAD_MODEL, ...WHISPER_CONFIG } })
      .then((id) => (modelId = id))
      .finally(() => {
        preparing = null;
      });
  }
  return preparing;
}

/** Frees the memory (before the technical tests). */
export async function releaseVoice() {
  await stopListening();
  const id = modelId ?? (preparing ? await preparing.catch(() => null) : null);
  modelId = null;
  if (id) await unloadModel({ modelId: id, clearStorage: false }).catch(() => {});
}

const csv = (v: unknown) => (typeof v === 'string' ? `"${v.replace(/"/g, '""')}"` : v === undefined ? '' : String(v));

function log(row: Record<string, unknown>) {
  const time = new Date().toLocaleTimeString('it-IT');
  const line = [time, ...LOG_HEAD.trim().split(',').slice(1).map((k) => row[k])].map(csv).join(',') + '\n';
  const head = Perception.fileExists(VOICE_LOG) ? '' : LOG_HEAD;
  Perception.appendText(VOICE_LOG, head + line).catch(() => {});
}

type Handler = (command: VoiceCommand) => void;
let handler: Handler | null = null;
/** Bumped by every start and stop: a start overtaken by a stop gives up. */
let generation = 0;
let active: { stop: () => Promise<void> } | null = null;
let starting: Promise<void> | null = null;

/**
 * Starts listening (the first time iOS asks for the microphone). The handler can be replaced by calling again.
 * Rejects when the microphone is refused or the model cannot be loaded.
 */
export function startListening(onCommand: Handler): Promise<void> {
  handler = onCommand;
  if (active) return Promise.resolve();
  if (!starting) starting = listen().finally(() => (starting = null));
  return starting;
}

async function listen(): Promise<void> {
  const gen = ++generation;
  const id = await prepareVoice();
  if (gen !== generation) return;
  await Perception.voiceStart();
  if (gen !== generation) {
    await Perception.voiceStop();
    return;
  }
  const events = Perception.addListener('onVoiceEvent', ({ event }) => log({ event }));
  const open = () => transcribeStream({ modelId: id, emitVadEvents: true });
  let session: Awaited<ReturnType<typeof open>> | null = null;
  let stopped = false;
  let lastSpeech = Date.now();
  let speechStart = 0;
  let speechEnd = 0;
  let speaking = false;
  const level = { bytes: 0, peak: 0, vad: 0, speech: 0, texts: 0, taps: 0, converted: 0, engine: true, kind: '' };

  const consume = async (s: NonNullable<typeof session>) => {
    try {
      for await (const e of s) {
        if (e.type === 'vad') {
          level.vad++;
          if (e.speaking) level.speech++;
          if (e.speaking && !speaking) speechStart = Date.now();
          if (!e.speaking && speaking) speechEnd = Date.now();
          if (e.speaking) lastSpeech = Date.now();
          speaking = e.speaking;
        } else if (e.type === 'text') {
          level.texts++;
          await heard(e.text);
        }
      }
    } catch (err) {
      log({ event: 'session error', reason: err instanceof Error ? err.message : String(err) });
    }
    log({ event: 'session ended' });
  };

  const heard = async (raw: string) => {
    const text = raw.trim();
    if (!text) return;
    // What the app said while this phrase was spoken (the voice detector reports about every 300 ms).
    const appSpeech = await Perception.appSpeechSince((speechStart || Date.now() - 10_000) - 500).catch(() => []);
    const m = matchCommand(text, appSpeech);
    const row: Record<string, unknown> = {
      event: m.command ? 'command' : 'ignored',
      text,
      app_speech: appSpeech.join(' | '),
      speech_end_ms: speechEnd ? Date.now() - speechEnd : undefined,
    };
    if (m.command) Object.assign(row, { command: m.command, form: m.form, distance: m.distance });
    else row.reason = m.reason;
    log(row);
    if (m.command && !stopped) handler?.(m.command);
  };

  const begin = async () => {
    session = await open();
    consume(session);
  };
  await begin();
  log({ event: 'start', memory_mb: Math.round(Perception.memory().footprintMB) });

  let renewing = false;
  const reader = setInterval(() => {
    if (!session || renewing) return;
    const r = Perception.voiceRead();
    level.taps += r.taps;
    level.converted += r.converted;
    level.engine = r.engineRunning;
    level.kind = Object.prototype.toString.call(r.audio);
    if (r.dropped) log({ event: 'dropped', reason: `${r.dropped} samples` });
    if (r.audio.byteLength) {
      const n = r.audio.byteLength >> 2;
      const f = new Float32Array(r.audio.slice(0, n * 4).buffer);
      for (let i = 0; i < n; i += 16) level.peak = Math.max(level.peak, Math.abs(f[i]));
      level.bytes += r.audio.byteLength;
      session.write(r.audio);
    }
    if (!speaking && Date.now() - lastSpeech > RENEW_AFTER_MS) {
      renewing = true;
      const old = session;
      session = null;
      old.end();
      lastSpeech = Date.now();
      begin()
        .then(() => log({ event: 'session renewed', memory_mb: Math.round(Perception.memory().footprintMB) }))
        .catch((err) => log({ event: 'session error', reason: String(err) }))
        .finally(() => (renewing = false));
    }
  }, READ_EVERY_MS);
  const levels = setInterval(() => {
    log({
      event: 'level',
      reason:
        `audio ${(level.bytes / 64000).toFixed(1)} s, peak ${level.peak.toFixed(3)}, vad ${level.vad} (speech ${level.speech}), ` +
        `texts ${level.texts}; mic buffers ${level.taps}, converted ${level.converted}, engine ${level.engine ? 'on' : 'off'}, ${level.kind}`,
    });
    Object.assign(level, { bytes: 0, peak: 0, vad: 0, speech: 0, texts: 0, taps: 0, converted: 0 });
  }, LEVEL_EVERY_MS);
  const memory = setInterval(() => log({ event: 'memory', memory_mb: Math.round(Perception.memory().footprintMB) }), MEMORY_EVERY_MS);

  active = {
    stop: async () => {
      stopped = true;
      clearInterval(reader);
      clearInterval(memory);
      clearInterval(levels);
      session?.end();
      session = null;
      events.remove();
      await Perception.voiceStop();
      log({ event: 'stop', memory_mb: Math.round(Perception.memory().footprintMB) });
    },
  };
}

export async function stopListening(): Promise<void> {
  generation++;
  handler = null;
  const a = active;
  active = null;
  await a?.stop();
}
