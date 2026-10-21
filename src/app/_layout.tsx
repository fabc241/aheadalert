// Root navigator. No native header: every screen has its own large title and buttons.
// Step 1.8: the models of "Cosa ho davanti?" are loaded in the background as soon as the app opens.
// Step 1.9: and Whisper for the voice commands, when they are on.
import { Stack } from 'expo-router';
import { useEffect } from 'react';
import Perception from '../../modules/perception';
import { prepareModels } from '../assistant/describe';
import { prepareVoice } from '../assistant/voiceCommands';
import { BLACK } from '../ui/theme';

export default function RootLayout() {
  useEffect(() => {
    // Not when the tests are launched from the Mac: they load their own models.
    if (Perception.autoRun) return;
    // Whisper first: small (64 MB), and the home screen starts listening at once.
    const voice = Perception.guideSettings().voiceCommands ? prepareVoice().catch(() => {}) : Promise.resolve();
    voice.then(() => prepareModels()).catch(() => {});  // retried at the first request
  }, []);

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: BLACK } }}>
      {/* No swipe back during the tests: leaving mid-test would stop the camera without closing the report. */}
      <Stack.Screen name="tests" options={{ gestureEnabled: false }} />
    </Stack>
  );
}
