Pod::Spec.new do |s|
  s.name             = 'flutter_document_capture'
  s.version          = '1.0.0'
  s.summary          = 'Document capture and preprocessing plugin for Flutter'
  s.description      = <<-DESC
Flutter plugin for document capture preprocessing using OpenCV.
Features: document detection, perspective correction, quality assessment.
                       DESC
  s.homepage         = 'https://github.com/anthropics/flutter_document_capture'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Author' => 'email@example.com' }
  s.source           = { :path => '.' }

  # Only Objective-C source files for plugin registration and symbol retention
  s.source_files = 'Classes/**/*.{h,m}'
  s.preserve_paths = 'download_frameworks.sh'

  # Download frameworks before build
  s.prepare_command = <<-CMD
    ./download_frameworks.sh
  CMD

  # Pre-compiled static library containing C++ code
  s.vendored_libraries = 'libflutter_document_capture.a'

  # OpenCV framework (same version as flutter_ocr_kit 4.10.0)
  # Note: When used with flutter_ocr_kit, OpenCV is shared from that plugin.
  # When used standalone, uncomment the line below:
  # s.vendored_frameworks = 'Frameworks/opencv2.framework'

  s.ios.deployment_target = '12.0'
  s.static_framework = true

  # Build settings
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-force_load $(PODS_TARGET_SRCROOT)/libflutter_document_capture.a -lc++',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'DEFINES_MODULE' => 'YES',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }

  # Required system frameworks for OpenCV
  s.frameworks = 'Foundation', 'CoreVideo', 'CoreMedia', 'AVFoundation', 'Accelerate', 'CoreGraphics', 'QuartzCore'
  s.libraries = 'z', 'c++'

  s.dependency 'Flutter'
end
