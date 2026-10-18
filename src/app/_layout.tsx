// Root navigator. No native header: every screen has its own large title and buttons.
import { Stack } from 'expo-router';
import { BLACK } from '../ui/theme';

export default function RootLayout() {
  return (
    <Stack screenOptions={{ headerShown: false, contentStyle: { backgroundColor: BLACK } }}>
      {/* No swipe back during the tests: leaving mid-test would stop the camera without closing the report. */}
      <Stack.Screen name="tests" options={{ gestureEnabled: false }} />
    </Stack>
  );
}
