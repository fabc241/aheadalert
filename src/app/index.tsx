// Home screen. MVP features are added here one at a time (plan, phase 1).
// Step 1.1: obstacle guide (start/stop); the native module speaks the alerts itself.
import { Redirect, router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useEffect, useState } from 'react';
import { AccessibilityInfo, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Perception, { type GuideStatus } from '../../modules/perception';
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

export default function HomeScreen() {
  const [state, setState] = useState<keyof typeof STATE_TEXT>('stopped');
  const [lastAlert, setLastAlert] = useState('');
  const [error, setError] = useState('');
  const on = state !== 'stopped';

  useEffect(() => {
    const sub = Perception.addListener('onGuideStatus', (s) => {
      setState(s.state);
      if (s.lastAlert) setLastAlert(s.lastAlert);
    });
    return () => sub.remove();
  }, []);

  // Launched from the Mac with PHASE0_AUTO: go straight to the tests, which run on their own.
  if (Perception.autoRun) return <Redirect href="/tests" />;

  async function toggleGuide() {
    setError('');
    if (on) {
      await Perception.stopGuide();
      setState('stopped');
      return;
    }
    setState('loading');
    setLastAlert('');
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
              : 'Avvisa a voce degli ostacoli davanti e ai lati, entro 2 metri. Tieni il telefono al petto, inclinato verso il basso'
          }
          disabled={state === 'loading'}
          onPress={toggleGuide}
        />
        <View style={styles.statusBox} accessible>
          <Text style={styles.status}>{error ? `Errore: ${error}` : STATE_TEXT[state]}</Text>
          {on && lastAlert ? <Text style={styles.text}>Ultimo avviso: {lastAlert}</Text> : null}
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
  status: { color: WHITE, fontSize: 24, fontWeight: '700' },
  text: { color: WHITE, fontSize: 22 },
});
