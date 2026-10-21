// Home screen. MVP features are added here one at a time (plan, phase 1).
// Step 1.1: obstacle guide (start/stop); the native module speaks the alerts itself.
// Step 1.2: reliability line (the native module speaks its changes too; VoiceOver reads it on touch only).
// Step 1.3: the native module also vibrates (and plays a directional sound with headphones) with each alert.
// Step 1.4: it also warns of a passage to a dark (or bright) zone ahead; the last warning is shown here.
// Step 1.5: and of a step down or up ahead (experimental); the last one is shown here.
// Step 1.6: "Impostazioni" (alert distance, alert type, sound with headphones); the current choice is in its hint.
// Step 1.7: final layout, only "Avvia guida" and "Impostazioni" ("Impara i segnali" and "Prove tecniche" are at the
// bottom of the settings).
// Step 1.8: "Cosa ho davanti?" between the two, with the guide on or off (src/assistant/describe.ts); while it speaks
// it becomes "Ferma descrizione", and the description stays written below it.
// Step 1.9: while this screen is shown the app listens for the voice commands (src/assistant/voiceCommands.ts), if on
// in the settings: "Avvia guida", "Ferma guida", "Cosa ho davanti", "Basta" act like the buttons.
import { Redirect, router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, StyleSheet, Text, View } from 'react-native';
import Perception, { type GuideStatus, type Reliability, type ReliabilityReason } from '../../modules/perception';
import { describe, stopDescribe, type DescribePhase, type DescribeResult } from '../assistant/describe';
import { startListening, stopListening, type VoiceCommand } from '../assistant/voiceCommands';
import { BigButton } from '../ui/BigButton';
import { DISTANCE_TEXT, settingsSummary } from '../ui/guideSettings';
import { Screen } from '../ui/Screen';
import { BLACK, MAX_FONT_SCALE, WHITE, YELLOW } from '../ui/theme';

const STATE_TEXT: Record<GuideStatus['state'] | 'loading', string> = {
  loading: 'Preparo la guida…',
  starting: 'Avvio la fotocamera…',
  tracking: 'Fotocamera non ancora pronta: muovi piano il telefono.',
  searchingFloor: 'Cerco il pavimento: inclina il telefono verso il basso.',
  upright: 'Inclina il telefono verso il basso.',
  active: 'Guida attiva.',
  paused: 'Guida in pausa: telefono bloccato o app chiusa. Riprende tornando all’app.',
  stopped: 'Guida ferma.',
};

const RELIABILITY_TEXT: Record<Reliability, string> = {
  good: 'Affidabilità: buona',
  reduced: 'Affidabilità: ridotta',
  unavailable: 'Affidabilità: assente, nessun avviso',
};

const REASON_TEXT: Partial<Record<ReliabilityReason, string>> = {
  lowLight: 'poca luce',
  scale: 'misura delle distanze incerta',
  slow: 'analisi lenta',
  dark: 'troppo buio',
  motion: 'muovi piano il telefono',
  noFloor: 'pavimento non trovato, inclina il telefono verso il basso',
};

type ReliabilityState = { level: Reliability; reason: ReliabilityReason } | null;

const PHASE_TEXT: Record<DescribePhase, string> = {
  photo: 'Scatto la foto…',
  thinking: 'Descrivo…',
  speaking: '',
};

const END_TEXT: Partial<Record<DescribeResult['end'], string>> = {
  dark: 'Troppo buio per descrivere.',
  alert: '(interrotta da un avviso)',
  user: '(fermata)',
};

export default function HomeScreen() {
  const [state, setState] = useState<keyof typeof STATE_TEXT>('stopped');
  const [lastAlert, setLastAlert] = useState('');
  const [lastLight, setLastLight] = useState('');
  const [lastStep, setLastStep] = useState('');
  const [reliability, setReliability] = useState<ReliabilityState>(null);
  const [error, setError] = useState('');
  const [settings, setSettings] = useState(() => Perception.guideSettings());
  const [describing, setDescribing] = useState(false);
  const [description, setDescription] = useState('');  // Italian text, or what is happening
  const [descriptionNote, setDescriptionNote] = useState('');
  const [voiceError, setVoiceError] = useState('');
  const onVoiceRef = useRef<(c: VoiceCommand) => void>(() => {});  // the latest onVoice (state changes)
  const on = state !== 'stopped';

  // Back from the settings screen: show the new choice. Step 1.9: listen while this screen is shown.
  useFocusEffect(
    useCallback(() => {
      const s = Perception.guideSettings();
      setSettings(s);
      if (!s.voiceCommands || Perception.autoRun) return;
      startListening((c) => onVoiceRef.current(c))
        .then(() => setVoiceError(''))
        .catch((e) => {
          const msg = e instanceof Error ? e.message : String(e);
          setVoiceError(msg);
          AccessibilityInfo.announceForAccessibility(`Comandi vocali non disponibili: ${msg}`);
        });
      return () => {
        stopListening().catch(() => {});
      };
    }, []),
  );

  useEffect(() => {
    const sub = Perception.addListener('onGuideStatus', (s) => {
      setState(s.state);
      if (s.lastAlert) setLastAlert(s.lastAlert);
      if (s.lastLight) setLastLight(s.lastLight);
      if (s.lastStep) setLastStep(s.lastStep);
      // Shown once the start is over: before that the state line says what is happening.
      setReliability(
        s.reliability && s.reliabilityReason && s.reliabilityReason !== 'starting'
          ? { level: s.reliability, reason: s.reliabilityReason }
          : null,
      );
    });
    return () => sub.remove();
  }, []);

  // Launched from the Mac with PHASE0_AUTO: go straight to the tests, which run on their own.
  if (Perception.autoRun) return <Redirect href="/tests" />;

  const shownReliability = on ? reliability : null;
  const suspended = shownReliability?.level === 'unavailable';
  const reason = shownReliability && REASON_TEXT[shownReliability.reason];

  async function toggleGuide() {
    setError('');
    if (on) {
      await Perception.stopGuide();
      setState('stopped');
      return;
    }
    setState('loading');
    setLastAlert('');
    setLastLight('');
    setLastStep('');
    setReliability(null);
    try {
      await Perception.startGuide();
      setState((s) => (s === 'loading' ? 'starting' : s));
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setState('stopped');
      setError(msg);
      AccessibilityInfo.announceForAccessibility(`Errore: ${msg}`);
    }
  }

  // Step 1.9: a command does what its button does; when there is nothing to do, a short answer says so.
  function onVoice(c: VoiceCommand) {
    if (c === 'startGuide') {
      if (state === 'loading') return;
      if (on) Perception.describeSay('Guida già attiva');
      else toggleGuide();
    } else if (c === 'stopGuide') {
      if (state === 'loading') return;
      if (on) toggleGuide();
      else Perception.describeSay('Guida già ferma');
    } else if (c === 'describe') {
      if (!describing) toggleDescription();
    } else if (describing) {
      stopDescribe();
    }
  }
  onVoiceRef.current = onVoice;

  async function toggleDescription() {
    if (describing) {
      await stopDescribe();
      return;
    }
    setDescribing(true);
    setDescriptionNote('');
    const r = await describe((phase, text) => {
      setDescription(text || PHASE_TEXT[phase]);
    });
    setDescribing(false);
    if (r.end === 'error') {
      setDescription(`Descrizione non riuscita: ${r.error}`);
      Perception.describeSay('Descrizione non riuscita');
    } else if (r.end === 'dark') {
      setDescription(END_TEXT.dark ?? '');
    } else {
      if (!r.italian) setDescription('');
      setDescriptionNote(END_TEXT[r.end] ?? '');
    }
  }

  return (
    <Screen>
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.title} accessibilityRole="header" accessibilityLabel="Ahead Alert">
        AheadAlert
      </Text>
      {settings.voiceCommands ? (
        <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
          {voiceError ? `Comandi vocali non disponibili: ${voiceError}` : 'Comandi vocali: puoi dire “Avvia guida”, “Ferma guida”, “Cosa ho davanti”, “Basta”.'}
        </Text>
      ) : null}
      <BigButton
        title={on ? 'Ferma guida' : 'Avvia guida'}
        hint={
          on
            ? 'Ferma gli avvisi e la fotocamera'
            : `Ostacoli, gradini e cambi di luce entro ${DISTANCE_TEXT[settings.alertDistance]}. Telefono al petto, inclinato verso il basso`
        }
        disabled={state === 'loading'}
        onPress={toggleGuide}
      />
      <View style={[styles.statusBox, suspended && styles.statusBoxSuspended]} accessible>
        {shownReliability ? (
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={[styles.status, suspended && styles.suspendedText]}>
            {RELIABILITY_TEXT[shownReliability.level]}
            {reason ? `: ${reason}.` : '.'}
          </Text>
        ) : null}
        {!suspended ? (
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.status}>
            {error ? `Errore: ${error}` : STATE_TEXT[state]}
          </Text>
        ) : null}
        {on && lastAlert && !suspended ? (
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
            Ultimo avviso: {lastAlert}
          </Text>
        ) : null}
        {on && lastStep && !suspended ? (
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
            Gradino: {lastStep}
          </Text>
        ) : null}
        {on && lastLight ? (
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={[styles.text, suspended && styles.suspendedLight]}>
            Luce: {lastLight}
          </Text>
        ) : null}
      </View>
      <BigButton
        title={describing ? 'Ferma descrizione' : 'Cosa ho davanti?'}
        hint={describing ? 'Zittisce la descrizione' : 'Descrizione indicativa, non per la sicurezza'}
        onPress={toggleDescription}
      />
      {description ? (
        <View style={styles.descriptionBox} accessible>
          <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.status}>
            {description}
          </Text>
          {descriptionNote ? (
            <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.text}>
              {descriptionNote}
            </Text>
          ) : null}
        </View>
      ) : null}
      <BigButton
        title="Impostazioni"
        hint={`${settingsSummary(settings)}. Cambia distanza e tipo degli avvisi, impara i segnali`}
        onPress={() => router.push('/settings')}
      />
    </Screen>
  );
}

const styles = StyleSheet.create({
  title: { color: YELLOW, fontSize: 34, fontWeight: '800' },
  statusBox: { borderColor: YELLOW, borderWidth: 3, borderRadius: 12, padding: 14, minHeight: 90, gap: 8 },
  // Suspended guide: solid yellow, visible at the edge of the field of view.
  statusBoxSuspended: { backgroundColor: YELLOW },
  suspendedText: { color: BLACK, fontSize: 28, fontWeight: '800' },
  suspendedLight: { color: BLACK, fontWeight: '700' },
  descriptionBox: { borderColor: WHITE, borderWidth: 2, borderRadius: 12, padding: 14, gap: 8 },
  status: { color: WHITE, fontSize: 24, fontWeight: '700' },
  text: { color: WHITE, fontSize: 22 },
});
