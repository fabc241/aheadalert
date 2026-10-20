// MVP step 1.6: basic settings of the guide (alert distance, alert type, sound with headphones). Reached from the
// home screen. Each choice is saved on the phone at once and applies at once, also while the guide runs.
import { router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Perception, { type AlertMode, type GuideSettings } from '../../modules/perception';
import { BigButton } from '../ui/BigButton';
import { DISTANCE_TEXT, DISTANCES, MODE_TEXT, MODES } from '../ui/guideSettings';
import { BLACK, WHITE, YELLOW } from '../ui/theme';

const MODE_HINT: Record<AlertMode, string> = {
  voiceAndVibration: 'Ogni avviso con la voce e la vibrazione',
  vibrationOnly: 'Avvisi solo con la vibrazione. I messaggi sulla guida sospesa o la visione ridotta restano a voce',
  voiceOnly: 'Avvisi solo con la voce, senza vibrazione né suono',
};

export default function SettingsScreen() {
  const [settings, setSettings] = useState<GuideSettings>(() => Perception.guideSettings());

  function change(patch: Partial<GuideSettings>) {
    setSettings(Perception.setGuideSettings({ ...settings, ...patch }));
  }

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <ScrollView contentContainerStyle={styles.content}>
        <BigButton title="Indietro" hint="Torna alla schermata principale" onPress={() => (router.canGoBack() ? router.back() : router.replace('/'))} />
        <Text style={styles.title} accessibilityRole="header">
          Impostazioni
        </Text>
        <Text style={styles.text}>Ogni scelta è salvata subito e vale anche con la guida accesa.</Text>

        <Text style={styles.section} accessibilityRole="header">
          Distanza degli avvisi
        </Text>
        <Text style={styles.text}>Ostacoli e gradini più lontani non vengono annunciati.</Text>
        {DISTANCES.map((d) => (
          <Choice
            key={d}
            title={DISTANCE_TEXT[d]}
            hint={`Avvisi entro ${DISTANCE_TEXT[d]}`}
            selected={settings.alertDistance === d}
            onPress={() => change({ alertDistance: d })}
          />
        ))}

        <Text style={styles.section} accessibilityRole="header">
          Tipo di avviso
        </Text>
        {MODES.map((m) => (
          <Choice key={m} title={MODE_TEXT[m]} hint={MODE_HINT[m]} selected={settings.mode === m} onPress={() => change({ mode: m })} />
        ))}

        <Text style={styles.section} accessibilityRole="header">
          Suono con le cuffie
        </Text>
        <Text style={styles.text}>Un breve suono dal lato dell’ostacolo, solo con le cuffie collegate.</Text>
        <Choice
          title="Sì"
          hint="Suono con le cuffie acceso"
          selected={settings.headphoneSound}
          disabled={settings.mode === 'voiceOnly'}
          onPress={() => change({ headphoneSound: true })}
        />
        <Choice
          title="No"
          hint="Suono con le cuffie spento"
          selected={!settings.headphoneSound}
          disabled={settings.mode === 'voiceOnly'}
          onPress={() => change({ headphoneSound: false })}
        />
        {settings.mode === 'voiceOnly' ? <Text style={styles.text}>Con “Solo voce” il suono è sempre spento.</Text> : null}
      </ScrollView>
    </SafeAreaView>
  );
}

function Choice({ title, hint, selected, disabled, onPress }: { title: string; hint: string; selected: boolean; disabled?: boolean; onPress: () => void }) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityHint={hint}
      accessibilityState={{ selected, disabled: !!disabled }}
      style={({ pressed }) => [styles.choice, selected && styles.choiceSelected, disabled && styles.disabled, pressed && styles.pressed]}
    >
      <Text style={[styles.choiceText, selected && styles.choiceTextSelected]}>
        {selected ? '✓ ' : ''}
        {title}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: BLACK },
  content: { padding: 16, gap: 14, paddingBottom: 48 },
  title: { color: YELLOW, fontSize: 30, fontWeight: '800' },
  section: { color: YELLOW, fontSize: 26, fontWeight: '800', marginTop: 12 },
  text: { color: WHITE, fontSize: 20 },
  choice: { borderColor: YELLOW, borderWidth: 3, borderRadius: 14, padding: 16, minHeight: 72, justifyContent: 'center' },
  choiceSelected: { backgroundColor: YELLOW },
  choiceText: { color: YELLOW, fontSize: 24, fontWeight: '800' },
  choiceTextSelected: { color: BLACK },
  disabled: { opacity: 0.35 },
  pressed: { backgroundColor: '#333' },
});
