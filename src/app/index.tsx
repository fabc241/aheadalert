// Home screen. MVP features are added here one at a time (plan, phase 1).
// Step 1.1: obstacle guide (start/stop); the native module speaks the alerts itself.
// Step 1.2: reliability line (the native module speaks its changes too; VoiceOver reads it on touch only).
// Step 1.3: the native module also vibrates (and plays a directional sound with headphones) with each alert.
import { Redirect, router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { AccessibilityInfo, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Perception, { type GuideStatus, type Reliability, type ReliabilityReason } from '../../modules/perception';
import { BigButton } from '../ui/BigButton';
import { BLACK, WHITE, YELLOW } from '../ui/theme';

const STATE_TEXT: Record<GuideStatus['state'] | 'loading', string> = {
  loading: 'Preparo la guida…',
  starting: 'Avvio la fotocamera…',
  tracking: 'Fotocamera non ancora pronta: muovi piano il telefono.',
  searchingFloor: 'Cerco il pavimento: inclina il telefono verso il basso.',
  upright: 'Inclina il telefono verso il basso.',
  active: 'Guida attiva.',
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

export default function HomeScreen() {
  const [state, setState] = useState<keyof typeof STATE_TEXT>('stopped');
  const [lastAlert, setLastAlert] = useState('');
  const [reliability, setReliability] = useState<ReliabilityState>(null);
  const [error, setError] = useState('');
  const on = state !== 'stopped';

  useEffect(() => {
    const sub = Perception.addListener('onGuideStatus', (s) => {
      setState(s.state);
      if (s.lastAlert) setLastAlert(s.lastAlert);
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

  async function openTests() {
    // The tests use the camera too: only one of them at a time.
    if (on) {
      await Perception.stopGuide();
      setState('stopped');
    }
    router.push('/tests');
  }

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <View style={styles.content}>
        <Text style={styles.title} accessibilityRole="header">
          Guida Visiva
        </Text>
        <BigButton
          title={on ? 'Ferma guida' : 'Avvia guida'}
          hint={
            on
              ? 'Ferma gli avvisi e la fotocamera'
              : 'Avvisa con voce e vibrazione degli ostacoli davanti e ai lati, entro 2 metri. Con le cuffie anche un suono dal lato dell’ostacolo. Tieni il telefono al petto, inclinato verso il basso'
          }
          disabled={state === 'loading'}
          onPress={toggleGuide}
        />
        <View style={[styles.statusBox, suspended && styles.statusBoxSuspended]} accessible>
          {shownReliability ? (
            <Text style={[styles.status, suspended && styles.suspendedText]}>
              {RELIABILITY_TEXT[shownReliability.level]}
              {reason ? `: ${reason}.` : '.'}
            </Text>
          ) : null}
          {!suspended ? <Text style={styles.status}>{error ? `Errore: ${error}` : STATE_TEXT[state]}</Text> : null}
          {on && lastAlert && !suspended ? <Text style={styles.text}>Ultimo avviso: {lastAlert}</Text> : null}
        </View>
        <BigButton
          title="Prove tecniche"
          hint="Apre le prove della Fase 0 su profondità, descrizione, lettura e voce"
          onPress={openTests}
        />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: BLACK },
  content: { padding: 16, gap: 20 },
  title: { color: YELLOW, fontSize: 34, fontWeight: '800' },
  statusBox: { borderColor: YELLOW, borderWidth: 3, borderRadius: 12, padding: 14, minHeight: 90, gap: 8 },
  // Suspended guide: solid yellow, visible at the edge of the field of view.
  statusBoxSuspended: { backgroundColor: YELLOW },
  suspendedText: { color: BLACK, fontSize: 28, fontWeight: '800' },
  status: { color: WHITE, fontSize: 24, fontWeight: '700' },
  text: { color: WHITE, fontSize: 22 },
});
