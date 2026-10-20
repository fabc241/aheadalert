// MVP step 1.6: how the guide's settings are named on screen and by VoiceOver (shared by home and settings screens).
import type { AlertMode, GuideSettings } from '../../modules/perception';

export const DISTANCES: GuideSettings['alertDistance'][] = [1, 1.5, 2];

export const DISTANCE_TEXT: Record<GuideSettings['alertDistance'], string> = {
  1: '1 metro',
  1.5: '1 metro e mezzo',
  2: '2 metri',
};

export const MODES: AlertMode[] = ['voiceAndVibration', 'vibrationOnly', 'voiceOnly'];

export const MODE_TEXT: Record<AlertMode, string> = {
  voiceAndVibration: 'Voce e vibrazione',
  vibrationOnly: 'Solo vibrazione',
  voiceOnly: 'Solo voce',
};

/** One line, e.g. "Avvisi entro 2 metri, voce e vibrazione". */
export function settingsSummary(s: GuideSettings): string {
  return `Avvisi entro ${DISTANCE_TEXT[s.alertDistance]}, ${MODE_TEXT[s.mode].toLowerCase()}`;
}
