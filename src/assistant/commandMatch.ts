// MVP step 1.9: which voice command, if any, a transcribed phrase is. Pure functions, also run on the Mac
// (scripts/voice/whisper-test.mjs), so that both test the same rules.
// Agreed (21/10): four commands, said on their own; anything else is ignored in silence.
// Whisper writes short phrases out of context in many ways: on the Mac test of 21/10 "Avvia la guida" became
// "A via la guida", "La via guida", "Avia la luida"; "Ferma guida" "Fermaguida", "Fero a guida"; "Cosa ho davanti"
// "Cos'ho davanti", "Cose o davanti". So the whole phrase (fillers aside) is compared letter by letter with each
// accepted form, without spaces and double letters, and a few letters may differ (about one in five).
// The app's own voice reaches the microphone (echo cancellation removes most of it): a command that is part of
// what the app is saying is its own voice; while it speaks, a command at the start or at the end of the phrase
// counts (the user speaking over it).

export type VoiceCommand = 'startGuide' | 'stopGuide' | 'describe' | 'enough';

const FORMS: Record<VoiceCommand, string[]> = {
  startGuide: ['avvia guida', 'avvia la guida'],
  stopGuide: ['ferma guida', 'ferma la guida'],
  describe: ['cosa ho davanti', 'che cosa ho davanti', 'cosa c e davanti'],
  enough: ['basta', 'basta cosi'],
};

/** Words that may come with a command without making it a different phrase. */
const FILLERS = new Set(['ok', 'okay', 'eh', 'ehm', 'allora', 'per', 'favore', 'adesso', 'ora', 'dai']);

/** Lower case, no accents or punctuation: "Cos'ho davanti?" → ["cos", "ho", "davanti"]. */
export function words(text: string): string[] {
  return text
    .toLowerCase()
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .split(' ')
    .filter(Boolean);
}

/** Letters only, without silent h and double letters: "Avvia la guida" → "avialaguida". */
export function letters(w: string[]): string {
  return w.join('').replace(/h/g, '').replace(/(.)\1+/g, '$1');
}

function distance(a: string, b: string): number {
  let prev = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    const cur = [i];
    for (let j = 1; j <= b.length; j++)
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    prev = cur;
  }
  return prev[b.length];
}

/** Letters that may differ: one in five ("basta": 1, "fermaguida": 2, "cosaodavanti": 2). */
const tolerance = (form: string) => Math.max(1, Math.floor(form.length / 5));

const FORM_LETTERS = (Object.entries(FORMS) as [VoiceCommand, string[]][]).flatMap(([command, forms]) =>
  forms.map((form) => ({ command, form, l: letters(words(form)) })),
);

/** The command these words are, if close enough to one of its forms; the closest form wins. */
function closest(w: string[]): { command: VoiceCommand; form: string; d: number } | null {
  const l = letters(w.filter((x) => !FILLERS.has(x)));
  if (!l) return null;
  let best: { command: VoiceCommand; form: string; d: number } | null = null;
  for (const f of FORM_LETTERS) {
    const d = distance(l, f.l);
    if (d <= tolerance(f.l) && (!best || d < best.d)) best = { command: f.command, form: f.form, d };
  }
  return best;
}

export type Match =
  | { command: VoiceCommand; form: string; distance: number }
  | { command: null; reason: 'noCommand' | 'appVoice' };

/**
 * appSpeech: what the app said while the phrase was being spoken (guide messages, description), or [].
 */
export function matchCommand(text: string, appSpeech: string[] = []): Match {
  const w = words(text);
  let found = closest(w);
  // The user spoke over the app: the command is at the start or at the end of what was heard.
  if (!found && appSpeech.length)
    for (let n = 1; n <= Math.min(5, w.length - 1) && !found; n++) found = closest(w.slice(-n)) ?? closest(w.slice(0, n));
  if (!found) return { command: null, reason: 'noCommand' };
  const formLetters = letters(words(found.form));
  if (appSpeech.some((a) => letters(words(a)).includes(formLetters))) return { command: null, reason: 'appVoice' };
  return { command: found.command, form: found.form, distance: found.d };
}
