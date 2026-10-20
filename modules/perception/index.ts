import { NativeModule, requireNativeModule } from 'expo';

export type LiveProgress = {
  elapsedS: number;
  inferences: number;
  depthFps: number;
  arFps: number;
  medianMs: number;
  p90Ms: number;
  postMedianMs: number;
  footprintMB: number;
  thermal: string;
  zones: number[];
};

export type LiveResult = LiveProgress & {
  units: string;
  label: string;
  loadMs: number;
  peakFootprintMB: number;
  thermalStart: string;
  thermalEnd: string;
  trackingNormalPct: number;
  lightMin?: number;
  lightMedian?: number;
  lightMax?: number;
};

export type PhotoBenchRow = {
  units: string;
  label: string;
  loadMs: number;
  medianMs: number;
  p90Ms: number;
  fps: number;
  input: string;
  thermal: string;
  footprintMB: number;
};

export type Memory = { footprintMB: number; availableMB: number; thermal: string };

export type DeviceInfo = Memory & {
  model: string;
  system: string;
  physicalMemoryMB: number;
  lidar: boolean;
  arkit: boolean;
};

export type DepthUnits = 'cpu' | 'gpu' | 'ane' | 'all';

/** Obstacle guide state (MVP step 1.1), sent about once a second while it runs. */
export type GuideState = 'starting' | 'tracking' | 'searchingFloor' | 'upright' | 'active' | 'stopped';
/** How far the alerts can be trusted (MVP step 1.2); "unavailable" means no alerts at all. */
export type Reliability = 'good' | 'reduced' | 'unavailable';
export type ReliabilityReason = 'none' | 'starting' | 'lowLight' | 'scale' | 'slow' | 'dark' | 'motion' | 'noFloor';
export type GuideStatus = {
  state: GuideState;
  fps?: number;
  lastAlert?: string;
  thermal?: string;
  reliability?: Reliability;
  reliabilityReason?: ReliabilityReason;
  /** ARKit ambientIntensity (lumens, 1000 = neutral light; not lux). */
  light?: number;
  /** MVP step 1.4: last light-passage warning spoken ("Zona buia davanti" / "Zona luminosa davanti"), or "". */
  lastLight?: string;
  /** MVP step 1.5: last step announced, without "Gradino" ("giù, un metro" / "su, mezzo metro"), or "". */
  lastStep?: string;
};

/**
 * MVP step 1.3: the guide's signals. left = one tap, right = two taps, ahead = long buzz, suspended = two long buzzes.
 * Step 1.4: light = three quick taps (light passage ahead), without sound.
 * Step 1.5: step = one strong tap and a long buzz (step down or up ahead); with headphones the low click ahead.
 */
export type FeedbackKind = 'left' | 'ahead' | 'right' | 'suspended' | 'light' | 'step';
/** What was actually played: no sound without headphones, no vibration if the phone has none. */
export type FeedbackPlayed = { haptic: boolean; sound: boolean; headphones: boolean };

type Events = { onLiveProgress: (p: LiveProgress) => void; onGuideStatus: (s: GuideStatus) => void };

declare class PerceptionNativeModule extends NativeModule<Events> {
  readonly documentsPath: string;
  readonly autoRun: string;
  startGuide(): Promise<{ logPath: string }>;
  stopGuide(): Promise<void>;
  startFeedbackTest(): Promise<{ haptics: boolean; headphones: boolean }>;
  /** step: distance step as spoken, 1 = half a metre … 4 = two metres (stronger when closer). */
  playFeedback(kind: FeedbackKind, step: number, low: boolean, haptic: boolean, sound: boolean): Promise<FeedbackPlayed>;
  stopFeedbackTest(): Promise<void>;
  deviceInfo(): DeviceInfo;
  memory(): Memory;
  startMemorySampler(): void;
  stopMemorySampler(): number;
  setKeepAwake(on: boolean): void;
  fileExists(path: string): boolean;
  writeText(path: string, text: string): Promise<void>;
  readFile(path: string): Promise<Uint8Array>;
  prepareDepthModel(): Promise<{ compiled: boolean; compileMs: number }>;
  benchDepthPhotos(): Promise<PhotoBenchRow[]>;
  benchDepthLive(units: DepthUnits, seconds: number): Promise<LiveResult>;
  captureFrame(maxSide: number): Promise<{ path: string; width: number; height: number; light?: number }>;
  recognizeText(path: string): Promise<{ ms: number; lines: { text: string; confidence: number }[] }>;
  writeWav(path: string, samples: number[], sampleRate: number): Promise<void>;
  playAudio(path: string): Promise<void>;
}

export default requireNativeModule<PerceptionNativeModule>('Perception');
