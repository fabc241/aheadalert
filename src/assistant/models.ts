// QVAC models for "Cosa ho davanti?" (MVP step 1.8), with the settings validated in Phase 0 (0A on the Mac, 0B on the
// iPhone 13). Also used by the Phase 0 tests, so that both measure the same thing.
import {
  loadModel,
  BERGAMOT_EN_IT,
  MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
  TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
  VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
} from '@qvac/sdk';

type Progress = (p: { percentage: number; downloaded?: number; total?: number }) => void;

/** The model is mainly English: asked in English, answer translated with Bergamot. Same prompt as Phase 0. */
export const PROMPT_DESCR = 'Describe this image in two short sentences.';

/** Long side of the photo given to VisionPsy, as in Phase 0B. */
export const PHOTO_MAX_SIDE = 1024;

/** VisionPsy Nano 460M Flash (Q4_K_M), the variant meant for phones; no upscaling of small images (QVAC docs). */
export function loadVisionPsy(onProgress?: Progress) {
  return loadModel({
    modelSrc: VISIONPSY_NANO_460M_MULTIMODAL_Q4_K_M,
    modelConfig: {
      ctx_size: 2048,
      projectionModelSrc: MMPROJ_VISIONPSY_NANO_460M_MULTIMODAL_Q8_0,
      image_no_upscale: 'on',
    },
    onProgress,
  });
}

export function loadBergamot(onProgress?: Progress) {
  return loadModel({
    modelSrc: BERGAMOT_EN_IT,
    modelConfig: { engine: 'Bergamot', from: 'en', to: 'it' },
    onProgress,
  });
}

/** Supertonic 3, Italian voice F1, 5 steps: the voice the user approved in Phase 0B. */
export function loadSupertonic(onProgress?: Progress) {
  return loadModel({
    modelSrc: TTS_MULTILINGUAL_SUPERTONIC3_Q8_0,
    modelConfig: { ttsEngine: 'supertonic', language: 'it', voice: 'F1', ttsSpeed: 1.0, ttsNumInferenceSteps: 5 },
    onProgress,
  });
}
