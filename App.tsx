// Phase 0B: test screen for the iPhone 13. Large buttons, high contrast, status announced by VoiceOver.
// The UI is in Italian (the target user is Italian). Results go to Documents/phase0/results/phase0b-<date>.md
// (fetched to the Mac with scripts/phase0/fetch-from-iphone.sh).
import { StatusBar } from 'expo-status-bar';
import { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaProvider, SafeAreaView } from 'react-native-safe-area-context';
import Perception, { type DepthUnits } from './modules/perception';
import { testDepthLive, testDepthPhotos } from './src/phase0/depthTests';
import {
  checkFiles,
  testClassify,
  testWhatIsAhead,
  testOCR,
  testTTS,
  testVisionPsy,
  type Reporter,
} from './src/phase0/qvacTests';

const REPORT = `${Perception.documentsPath}/phase0/results/phase0b-${new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-')}.md`;

type Test = { id: string; title: string; hint: string; run: (r: Reporter) => Promise<unknown> };

export default function App() {
  const [busy, setBusy] = useState<string | null>(null);
  const [status, setStatus] = useState('Pronta. Scegli una prova.');
  const [lines, setLines] = useState<string[]>([]);
  const report = useRef<string[]>([]);
  const bestUnit = useRef<DepthUnits>('ane');

  useEffect(() => {
    const info = Perception.deviceInfo();
    const head = [
      `# Fase 0B – iPhone – ${new Date().toLocaleString('it-IT')}`,
      `Dispositivo ${info.model}, ${info.system}, RAM ${Math.round(info.physicalMemoryMB)} MB, LiDAR ${info.lidar ? 'sì' : 'no'}, ` +
        `memoria disponibile all'app ${Math.round(info.availableMB)} MB, temperatura ${info.thermal}`,
    ];
    const missing = checkFiles();
    if (missing.length) head.push(`⚠️ File mancanti (${missing.length}): eseguire scripts/phase0/copy-to-iphone.sh sul Mac`);
    report.current = head;
    setLines(head);
    const sub = Perception.addListener('onLiveProgress', (p) =>
      setStatus(
        `${Math.round(p.elapsedS)} s · ${p.depthFps.toFixed(1)} fps · ${Math.round(p.medianMs)} ms · ` +
          `${Math.round(p.footprintMB)} MB · ${p.thermal}`,
      ),
    );
    return () => sub.remove();
  }, []);

  const reporter: Reporter = {
    log: (line) => {
      report.current.push(line);
      setLines((l) => [...l.slice(-60), line]);
      // saved right away: if iOS kills the app, the report up to that point is kept
      Perception.writeText(REPORT, report.current.join('\n') + '\n').catch(() => {});
    },
    status: setStatus,
  };

  async function run(t: Test) {
    if (busy) return;
    setBusy(t.title);
    setStatus(`${t.title}: avvio…`);
    AccessibilityInfo.announceForAccessibility(`${t.title} avviata`);
    Perception.setKeepAwake(true);
    const start = Date.now();
    try {
      await t.run(reporter);
      const msg = `${t.title}: finita in ${Math.round((Date.now() - start) / 1000)} secondi.`;
      setStatus(msg);
      AccessibilityInfo.announceForAccessibility(msg);
    } catch (e) {
      const err = e instanceof Error ? e.message : String(e);
      reporter.log(`\n**ERRORE in ${t.title}**: ${err}`);
      setStatus(`Errore: ${err}`);
      AccessibilityInfo.announceForAccessibility(`Errore in ${t.title}`);
    } finally {
      Perception.setKeepAwake(false);
      await Perception.writeText(REPORT, report.current.join('\n') + '\n').catch(() => {});
      setBusy(null);
    }
  }

  const tests: Test[] = [
    { id: 'depth-photos', title: 'Profondità su foto', hint: '4 unità di calcolo, circa 1 minuto', run: testDepthPhotos },
    {
      id: 'depth-live',
      title: 'Profondità dal vivo',
      hint: 'Fotocamera: 4 unità × 30 secondi. Tieni il telefono davanti a te e muovilo',
      run: async (r) => {
        bestUnit.current = (await testDepthLive(r, ['cpu', 'gpu', 'ane', 'all'], 30)) ?? 'ane';
      },
    },
    {
      id: 'depth-long',
      title: 'Profondità prova lunga',
      hint: '5 minuti con l’unità più veloce: temperatura e stabilità',
      run: (r) => testDepthLive(r, [bestUnit.current], 300),
    },
    { id: 'what-is-ahead', title: 'Cosa ho davanti?', hint: 'Scatta, descrive, traduce e legge ad alta voce', run: testWhatIsAhead },
    { id: 'descriptions', title: 'Descrizioni 14 foto', hint: 'VisionPsy Flash + traduzione, alcuni minuti', run: testVisionPsy },
    { id: 'ocr', title: 'Lettura cartelli', hint: 'OCR sui due cartelli di prova', run: testOCR },
    { id: 'voice', title: 'Voce italiana', hint: 'Supertonic 3, due frasi da ascoltare', run: testTTS },
    { id: 'classification', title: 'Classificazione', hint: 'MobileNetV3, solo tempi', run: testClassify },
  ];

  // Auto-run from the Mac (PHASE0_AUTO=depth-photos,descriptions,…): one test after another.
  useEffect(() => {
    const ids = Perception.autoRun.split(',').map((x) => x.trim()).filter(Boolean);
    if (!ids.length) return;
    (async () => {
      for (const id of ids) {
        const t = tests.find((x) => x.id === id);
        if (t) await run(t);
        else reporter.log(`Prova sconosciuta: ${id}`);
      }
      reporter.log('\nAVVIO AUTOMATICO COMPLETATO');
      await Perception.writeText(REPORT, report.current.join('\n') + '\n');
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <SafeAreaProvider>
      <SafeAreaView style={styles.root}>
        <StatusBar style="light" />
        <ScrollView contentContainerStyle={styles.content}>
          <Text style={styles.title} accessibilityRole="header">
            Guida Visiva – Fase 0B
          </Text>
          <View style={styles.statusBox} accessibilityLiveRegion="polite">
            <Text style={styles.status}>{status}</Text>
          </View>
          {tests.map((t) => {
            const disabled = !!busy && busy !== t.title;
            return (
              <Pressable
                key={t.id}
                onPress={() => run(t)}
                disabled={!!busy}
                accessibilityRole="button"
                accessibilityLabel={t.title}
                accessibilityHint={t.hint}
                accessibilityState={{ disabled: !!busy, busy: busy === t.title }}
                style={({ pressed }) => [
                  styles.button,
                  busy === t.title && styles.buttonActive,
                  disabled && styles.buttonDisabled,
                  pressed && styles.buttonPressed,
                ]}
              >
                <Text style={[styles.buttonText, busy === t.title && styles.buttonTextActive]}>{t.title}</Text>
                <Text style={[styles.hint, busy === t.title && styles.buttonTextActive]}>{t.hint}</Text>
              </Pressable>
            );
          })}
          <Text style={styles.section} accessibilityRole="header">
            Registro
          </Text>
          {lines.map((l, i) => (
            <Text key={i} style={styles.log}>
              {l}
            </Text>
          ))}
        </ScrollView>
      </SafeAreaView>
    </SafeAreaProvider>
  );
}

const YELLOW = '#FFD600';
const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  content: { padding: 16, gap: 14, paddingBottom: 48 },
  title: { color: YELLOW, fontSize: 30, fontWeight: '800' },
  statusBox: { borderColor: YELLOW, borderWidth: 3, borderRadius: 12, padding: 14, minHeight: 90 },
  status: { color: '#FFF', fontSize: 24, fontWeight: '700' },
  button: { borderColor: YELLOW, borderWidth: 3, borderRadius: 14, padding: 18, minHeight: 88 },
  buttonActive: { backgroundColor: YELLOW },
  buttonDisabled: { opacity: 0.35 },
  buttonPressed: { backgroundColor: '#333' },
  buttonText: { color: YELLOW, fontSize: 26, fontWeight: '800' },
  buttonTextActive: { color: '#000' },
  hint: { color: '#FFF', fontSize: 18, marginTop: 4 },
  section: { color: YELLOW, fontSize: 24, fontWeight: '800', marginTop: 12 },
  log: { color: '#FFF', fontSize: 16 },
});
