// Large, high-contrast button used across the app. VoiceOver reads the title, then the hint.
import { Pressable, StyleSheet, Text } from 'react-native';
import { MAX_FONT_SCALE, WHITE, YELLOW } from './theme';

type Props = { title: string; hint?: string; disabled?: boolean; onPress: () => void };

export function BigButton({ title, hint, disabled, onPress }: Props) {
  return (
    <Pressable
      onPress={onPress}
      disabled={disabled}
      accessibilityRole="button"
      accessibilityLabel={title}
      accessibilityHint={hint}
      accessibilityState={{ disabled: !!disabled }}
      style={({ pressed }) => [styles.button, disabled && styles.disabled, pressed && styles.pressed]}
    >
      <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.title}>{title}</Text>
      {hint ? <Text maxFontSizeMultiplier={MAX_FONT_SCALE} style={styles.hint}>{hint}</Text> : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  button: { borderColor: YELLOW, borderWidth: 3, borderRadius: 14, padding: 18, minHeight: 88, justifyContent: 'center' },
  disabled: { opacity: 0.35 },
  pressed: { backgroundColor: '#333' },
  title: { color: YELLOW, fontSize: 26, fontWeight: '800' },
  hint: { color: WHITE, fontSize: 18, marginTop: 4 },
});
