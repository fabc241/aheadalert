// MVP step 1.3: learn the guide's vibrations and sounds standing still, then check that they are told apart
// (acceptance criteria 2 and 3: the right side at least 9 times out of 10). Reached from "Prove tecniche".
// Step 1.4 adds the light-passage signal (three quick taps), in the list and in the vibration quiz.
// Step 1.5 adds the step signal (a strong tap and a long buzz), in the list and in the vibration quiz.
// Step 1.7: renamed "Impara i segnali" and reached from the settings; one answer per row with larger iOS text.
// Each series of 10 is saved to Documents/guide/feedback-quiz-<time>.csv (fetched with scripts/guide/fetch-logs.sh).
import { router } from 'expo-router';
import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Pressable, StyleSheet, Text, useWindowDimensions, View } from 'react-native';
import Perception, { type FeedbackKind } from '../../modules/perception';
import { BigButton } from '../ui/BigButton';
import { Screen } from '../ui/Screen';
import { BLACK, MAX_FONT_SCALE, WHITE, YELLOW } from '../ui/theme';

const NAME: Record<FeedbackKind, string> = {
  left: 'Sinistra',
  ahead: 'Davanti',
  right: 'Destra',
  suspended: 'Guida sospesa',
  light: 'Cambio di luce',
  step: 'Gradino',
};

const LEARN: { title: string; hint: string; kind: FeedbackKind; low?: boolean }[] = [
  { title: 'Sinistra', hint: 'Un colpo breve; con le cuffie un suono a sinistra', kind: 'left' },
  { title: 'Davanti', hint: 'Una vibrazione lunga; con le cuffie un suono davanti', kind: 'ahead' },
  { title: 'Destra', hint: 'Due colpi brevi; con le cuffie un suono a destra', kind: 'right' },
  { title: 'Davanti, basso', hint: 'Come davanti; con le cuffie il suono è più grave', kind: 'ahead', low: true },
  { title: 'Guida sospesa', hint: 'Due vibrazioni lunghe, senza suono', kind: 'suspended' },
  { title: 'Cambio di luce', hint: 'Tre colpi brevi e rapidi, senza suono: zona buia o luminosa davanti', kind: 'light' },
  { title: 'Gradino', hint: 'Un colpo forte e una vibrazione lunga, per gradino su o giù; con le cuffie il suono grave davanti', kind: 'step' },
];

type Mode = 'haptic' | 'sound' | 'both';
const MODE_NAME: Record<Mode, string> = { haptic: 'Solo vibrazione', sound: 'Solo suono', both: 'Vibrazione e suono' };
const ROUNDS = 10;
const DISTANCE = ['', 'mezzo metro', 'un metro', 'un metro e mezzo', 'due metri'];

type Round = { kind: FeedbackKind; step: number; low: boolean; answer?: FeedbackKind };

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));
const pick = <T,>(xs: readonly T[]) => xs[Math.floor(Math.random() * xs.length)];

export default function FeedbackTestScreen() {
  const [status, setStatus] = useState('Preparo vibrazione e suono…');
  const [headphones, setHeadphones] = useState(false);
  const [mode, setMode] = useState<Mode>('haptic');
  const [rounds, setRounds] = useState<Round[]>([]);
  const [busy, setBusy] = useState(false);
  const startedAt = useRef(new Date());
  // Two answers per row; one with larger iOS text, or the words would be split across lines.
  const wide = useWindowDimensions().fontScale > 1.15;

  useEffect(() => {
    Perception.startFeedbackTest()
      .then((r) => {
        setHeadphones(r.headphones);
        say(
          (r.haptics ? '' : 'Questo telefono non vibra. ') +
            (r.headphones ? 'Cuffie collegate.' : 'Cuffie non collegate: solo vibrazione.'),
        );
      })
      .catch((e) => say(`Errore: ${e instanceof Error ? e.message : String(e)}`));
    return () => {
      Perception.stopFeedbackTest().catch(() => {});
    };
  }, []);

  function say(text: string) {
    setStatus(text);
    AccessibilityInfo.announceForAccessibility(text);
  }

  async function play(kind: FeedbackKind, step: number, low: boolean, m: Mode) {
    const r = await Perception.playFeedback(kind, step, low, m !== 'sound', m !== 'haptic');
    setHeadphones(r.headphones);
    return r;
  }

  async function learn(item: (typeof LEARN)[number]) {
    const r = await play(item.kind, 2, !!item.low, 'both');
    setStatus(`${item.title}: ${r.haptic ? 'vibrazione' : 'nessuna vibrazione'}${r.sound ? ' e suono' : ''}.`);
  }

  async function approach() {
    // Ahead, from two metres to half a metre: the vibration gets stronger.
    setBusy(true);
    for (let step = 4; step >= 1; step--) {
      setStatus(`Davanti, ${DISTANCE[step]}`);
      await play('ahead', step, false, 'both');
      await wait(1200);
    }
    setBusy(false);
  }

  const current = rounds[rounds.length - 1];
  const waiting = !!current && !current.answer;
  const done = rounds.filter((r) => r.answer).length;
  const right = rounds.filter((r) => r.answer === r.kind).length;
  const choices: FeedbackKind[] =
    mode === 'sound' ? ['left', 'ahead', 'right'] : ['left', 'ahead', 'right', 'suspended', 'light', 'step'];

  function chooseMode(m: Mode) {
    setMode(m);
    setRounds([]);
    startedAt.current = new Date();
    say(`${MODE_NAME[m]}. Premi "Segnale a caso".`);
  }

  async function nextSignal() {
    if (mode !== 'haptic' && !headphones) return say('Per il suono servono le cuffie.');
    // The same signal again if it was not answered yet: it may have been missed.
    const round = waiting ? current : { kind: pick(choices), step: 1 + Math.floor(Math.random() * 4), low: Math.random() < 0.3 };
    if (!waiting) setRounds((rs) => [...rs, round]);
    setStatus(`Segnale ${done + 1} di ${ROUNDS}: quale hai sentito?`);
    await play(round.kind, round.step, round.low, mode);
  }

  async function answer(kind: FeedbackKind) {
    if (!waiting) return say('Prima premi "Segnale a caso".');
    const all = rounds.map((r, i) => (i === rounds.length - 1 ? { ...r, answer: kind } : r));
    setRounds(all);
    const ok = kind === current.kind;
    const n = all.filter((r) => r.answer).length;
    let text = ok ? 'Giusto.' : `Sbagliato: era ${NAME[current.kind]}.`;
    if (n === ROUNDS) {
      const score = all.filter((r) => r.answer === r.kind).length;
      text += ` Serie finita: ${score} giuste su ${ROUNDS}.`;
      await save(all);
    }
    say(text);
  }

  async function save(all: Round[]) {
    const t = startedAt.current;
    const stamp = `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}-` +
      `${String(t.getHours()).padStart(2, '0')}-${String(t.getMinutes()).padStart(2, '0')}-${String(t.getSeconds()).padStart(2, '0')}`;
    const rows = all.map((r, i) => [i + 1, mode, r.kind, r.step, r.low ? 1 : 0, r.answer, r.answer === r.kind ? 1 : 0].join(','));
    const csv = ['round,mode,signal,step,low,answer,correct', ...rows].join('\n') + '\n';
    await Perception.writeText(`${Perception.documentsPath}/guide/feedback-quiz-${stamp}.csv`, csv).catch(() => {});
    setRounds([]);
    startedAt.current = new Date();
  }

  const back = () => (router.canGoBack() ? router.back() : router.replace('/settings'));

  return (
    <Screen>
      <BigButton title="Indietro" hint="Torna alle impostazioni" onPress={back} />
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.title} accessibilityRole="header">
        Impara i segnali
      </Text>
      <View style={styles.statusBox} accessible>
        <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.status}>{status}</Text>
        <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
          Cuffie: {headphones ? 'collegate' : 'non collegate'}
        </Text>
      </View>

      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.section} accessibilityRole="header">
        I segnali
      </Text>
      {LEARN.map((item) => (
        <BigButton key={item.title} title={item.title} hint={item.hint} disabled={busy} onPress={() => learn(item)} />
      ))}
      <BigButton
        title="Avvicinamento"
        hint="Davanti, da due metri a mezzo metro: la vibrazione diventa più forte"
        disabled={busy}
        onPress={approach}
      />

      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.section} accessibilityRole="header">
        Indovina il segnale
      </Text>
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
        Scegli il modo, premi “Segnale a caso”, poi rispondi. Serie di {ROUNDS}.
      </Text>
      <View style={styles.row}>
        {(Object.keys(MODE_NAME) as Mode[]).map((m) => (
          <Choice key={m} title={MODE_NAME[m]} wide={wide} selected={mode === m} onPress={() => chooseMode(m)} />
        ))}
      </View>
      <BigButton
        title="Segnale a caso"
        hint={waiting ? 'Ripete lo stesso segnale' : 'Fa sentire un segnale scelto a caso'}
        disabled={busy}
        onPress={nextSignal}
      />
      <View style={styles.row}>
        {choices.map((k) => (
          <Choice key={k} title={NAME[k]} wide={wide} disabled={!waiting} onPress={() => answer(k)} />
        ))}
      </View>
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
        Risposte: {done} di {ROUNDS}, giuste {right}
      </Text>
    </Screen>
  );
}

type ChoiceProps = { title: string; wide: boolean; selected?: boolean; disabled?: boolean; onPress: () => void };

function Choice({ title, wide, selected, disabled, onPress }: ChoiceProps) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityState={{ selected: !!selected, disabled: !!disabled }}
      style={({ pressed }) => [
        styles.choice,
        wide && styles.choiceWide,
        selected && styles.choiceSelected,
        disabled && styles.disabled,
        pressed && styles.pressed,
      ]}
    >
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={[styles.choiceText, selected && styles.choiceTextSelected]}>{title}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  title: { color: YELLOW, fontSize: 30, fontWeight: '800' },
  statusBox: { borderColor: YELLOW, borderWidth: 3, borderRadius: 12, padding: 14, minHeight: 90, gap: 6 },
  status: { color: WHITE, fontSize: 24, fontWeight: '700' },
  section: { color: YELLOW, fontSize: 26, fontWeight: '800', marginTop: 12 },
  text: { color: WHITE, fontSize: 20 },
  row: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  choice: { borderColor: YELLOW, borderWidth: 3, borderRadius: 14, padding: 14, minHeight: 72, minWidth: '47%', flexGrow: 1, justifyContent: 'center' },
  choiceWide: { minWidth: '100%' },
  choiceSelected: { backgroundColor: YELLOW },
  choiceText: { color: YELLOW, fontSize: 22, fontWeight: '800', textAlign: 'center' },
  choiceTextSelected: { color: BLACK },
  disabled: { opacity: 0.35 },
  pressed: { backgroundColor: '#333' },
});
