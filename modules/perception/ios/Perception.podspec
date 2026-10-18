Pod::Spec.new do |s|
  s.name           = 'Perception'
  s.version        = '0.1.0'
  s.summary        = 'Perception module (ARKit + Core ML) – Phase 0B'
  s.description    = 'On-device measurements: depth, memory, thermal state, ARKit frames, audio.'
  s.author         = ''
  s.homepage       = 'https://example.invalid'
  s.platforms      = { :ios => '17.0' }
  s.source         = { git: '' }
  s.static_framework = true
  s.swift_version  = '5.9'

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'ARKit', 'CoreML', 'Vision', 'AVFoundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }

  s.source_files = "**/*.{h,m,mm,swift}"
end
