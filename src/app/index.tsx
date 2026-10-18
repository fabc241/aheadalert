// Home screen. MVP features are added here one at a time (plan, phase 1); for now only the technical tests.
import { Redirect, router } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import Perception from '../../modules/perception';
import { BigButton } from '../ui/BigButton';
import { BLACK, WHITE, YELLOW } from '../ui/theme';

export default function HomeScreen() {
  // Launched from the Mac with PHASE0_AUTO: go straight to the tests, which run on their own.
  if (Perception.autoRun) return <Redirect href="/tests" />;

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="light" />
      <View style={styles.content}>
        <Text style={styles.title} accessibilityRole="header">
          Guida Visiva
        </Text>
        <Text style={styles.text}>Le funzioni arriveranno una alla volta.</Text>
        <BigButton
          title="Prove tecniche"
          hint="Apre le prove della Fase 0 su profondità, descrizione, lettura e voce"
          onPress={() => router.push('/tests')}
        />
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: BLACK },
  content: { padding: 16, gap: 20 },
  title: { color: YELLOW, fontSize: 34, fontWeight: '800' },
  text: { color: WHITE, fontSize: 24 },
});
