// MVP step 1.9: checks of the command rules (src/assistant/commandMatch.ts) on phrases as Whisper writes them.
// Usage (from mobile/): node scripts/voice/match-test.mjs
import { matchCommand } from '../../src/assistant/commandMatch.ts';

const DESCRIPTION = 'Un tavolo di legno davanti a una finestra. Sulla destra c\'è una sedia.';
const cases = [
  // Commands, also as Whisper misheard them in the Mac test of 21/10.
  ['Avvia guida.', [], 'startGuide'],
  ['A via la guida.', [], 'startGuide'],
  ['Avvia a guida.', [], 'startGuide'],
  ['La via guida.', [], 'startGuide'],
  ['Ok, avvia la guida per favore', [], 'startGuide'],
  ['Ferma guida.', [], 'stopGuide'],
  ['Fermaguida.', [], 'stopGuide'],
  ['Fero a guida!', [], 'stopGuide'],
  ["Cos'ho davanti?", [], 'describe'],
  ['Cose o davanti?', [], 'describe'],
  ["Che cosa c'è davanti?", [], 'describe'],
  ['Basta!', [], 'enough'],
  ['Basta così.', [], 'enough'],
  // The user speaking over the description: the end (or start) of what was heard.
  ['Un tavolo di legno davanti a una finestra sulla destra basta', [DESCRIPTION], 'enough'],
  ['Basta, un tavolo di legno', [DESCRIPTION], 'enough'],
  // Everyday phrases: never a command.
  ['La guida turistica era molto brava.', [], null],
  ['Basta con questa storia, non ne posso più.', [], null],
  ['Davanti alla porta c\'è un tavolo.', [], null],
  ['Ferma l\'autobus alla prossima.', [], null],
  ['Cosa hai detto?', [], null],
  ['Avanti.', [], null],
  ['Guarda davanti.', [], null],
  ['La guida.', [], null],
  ['Grazie per la visione.', [], null],
  ['Sottotitoli creati dalla comunità Amara.org', [], null],
  // The app's own messages, heard back: never a command.
  ['Guida avviata.', ['Guida avviata'], null],
  ['Guida fermata.', ['Guida fermata'], null],
  ['Guida già attiva.', ['Guida già attiva'], null],
  ['Davanti, un metro.', ['Davanti, un metro'], null],
  ['Zona buia davanti.', ['Zona buia davanti'], null],
  ['Basta guardare a destra.', ['Basta guardare a destra, c\'è una porta.'], null],
  [DESCRIPTION, [DESCRIPTION], null],
];

let fails = 0;
for (const [text, app, want] of cases) {
  const m = matchCommand(text, app);
  const ok = m.command === want;
  if (!ok) fails++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${JSON.stringify(text)} → ${m.command ?? m.reason}${ok ? '' : ` (expected ${want})`}`);
}
console.log(`\n${cases.length - fails}/${cases.length} ok`);
process.exit(fails ? 1 : 0);
