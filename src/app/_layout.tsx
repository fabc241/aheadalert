// Root navigator. No native header: every screen has its own large title and buttons.
// Step 1.8: the models of "Cosa ho davanti?" are loaded in the background as soon as the app opens.
import { Stack } from 'expo-router';
import { useEffect } from 'react';
import Perception from '../../modules/perception';
import { prepareModels } from '../assistant/describe';
import { BLACK } from '../ui/theme';

export default function RootLayout() {
  useEffect(() => {
    // Not when the tests are launched from the Mac: they load their own models.
    if (!Perception.autoRun) prepareModels().catch(() => {});  // retried at the first request
  }, []);

  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: BLACK } }}>
      {/* No swipe back during the tests: leaving mid-test would stop the camera without closing the report. */}
      <Stack.Screen name="tests" options={{ gestureEnabled: false }} />
    </Stack>
  );
}
