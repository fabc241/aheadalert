// MVP step 1.9: the speech recognition model of the voice commands and its settings, shared by the app
// (src/assistant/voiceCommands.ts) and the Mac test (scripts/voice/whisper-test.mjs).
// Whisper base fine-tuned for Italian (QVAC, 64 MB), with the Silero voice activity detector: Whisper only runs on
// the stretches where someone speaks, and each one is written once a short pause ends it.
import { VAD_SILERO_5_1_2, WHISPER_ITALIAN_BASE_Q8_0 } from '@qvac/sdk';

export const WHISPER_MODEL = WHISPER_ITALIAN_BASE_Q8_0;
export const VAD_MODEL = VAD_SILERO_5_1_2;

/** 16 kHz mono float32 little-endian: what the phone's microphone is converted to. */
export const SAMPLE_RATE = 16000;

export const WHISPER_CONFIG = {
  audio_format: 'f32le',
  strategy: 'greedy',
  n_threads: 4,
  language: 'it',
  no_timestamps: true,
  suppress_blank: true,
  suppress_nst: true,
  temperature: 0.0,
  vad_params: {
    threshold: 0.5,
    min_speech_duration_ms: 200,
    // A command ends with a pause this long: it is the largest part of the time to the action.
    min_silence_duration_ms: 400,
    max_speech_duration_s: 10.0,
    speech_pad_ms: 200,
  },
} as const;
