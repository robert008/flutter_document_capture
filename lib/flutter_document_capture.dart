import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:ffi/ffi.dart';

import 'flutter_document_capture_bindings_generated.dart';

/// Enhancement mode for OCR optimization
enum EnhanceMode {
  none,          // No enhancement
  whitenBg,      // Background whitening
  contrastStretch, // Contrast stretching
  adaptiveBinarize, // Adaptive binarization
  sauvola,       // Sauvola binarization
}

const String _libName = 'flutter_document_capture';

/// Load the native library
final DynamicLibrary _dylib = () {
  if (Platform.isIOS) {
    // iOS: C++ code is compiled directly into the app via podspec source_files
    // Use process() to access symbols in the main executable
    return DynamicLibrary.process();
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// FFI bindings
final DocumentCaptureBindings _bindings = DocumentCaptureBindings(_dylib);

/// Document Capture Engine
///
/// Provides document detection, quality assessment, and perspective correction.
class DocumentCaptureEngine {
  Pointer<Void>? _engine;
  bool _isInitialized = false;

  /// Create a new capture engine instance
  DocumentCaptureEngine() {
    _engine = _bindings.capture_engine_create();
    _isInitialized = _engine != null && _engine != nullptr;
  }

  /// Check if engine is initialized
  bool get isInitialized => _isInitialized;

  /// Reset engine state (clears stability history)
  void reset() {
    if (_isInitialized && _engine != null) {
      _bindings.capture_engine_reset(_engine!);
    }
  }

  /// Analyze a single frame for document detection and quality assessment
  ///
  /// [imageData] - Raw image bytes
  /// [width] - Image width
  /// [height] - Image height
  /// [format] - 0: BGRA, 1: BGR, 2: RGB
  /// [rotation] - 0: none, 90: clockwise, 180, 270: counter-clockwise
  /// [cropX], [cropY], [cropW], [cropH] - Crop region after rotation (0 for no crop)
  ///
  /// Returns [FrameAnalysisResult] with detection results and quality scores
  FrameAnalysisResult analyzeFrame(
    Uint8List imageData,
    int width,
    int height, {
    int format = 0,
    int rotation = 0,
    int cropX = 0,
    int cropY = 0,
    int cropW = 0,
    int cropH = 0,
  }) {
    if (!_isInitialized || _engine == null) {
      return FrameAnalysisResult.error('Engine not initialized');
    }

    final dataPtr = malloc<Uint8>(imageData.length);
    dataPtr.asTypedList(imageData.length).setAll(0, imageData);

    Pointer<Char>? resultPtr;
    try {
      resultPtr = _bindings.analyze_frame(
        _engine!,
        dataPtr,
        width,
        height,
        format,
        rotation,
        cropX,
        cropY,
        cropW,
        cropH,
      );

      if (resultPtr == null || resultPtr == nullptr) {
        return FrameAnalysisResult.error('Analysis failed');
      }

      final jsonStr = resultPtr.cast<Utf8>().toDartString();
      final json = jsonDecode(jsonStr);
      return FrameAnalysisResult.fromJson(json);
    } finally {
      malloc.free(dataPtr);
      if (resultPtr != null && resultPtr != nullptr) {
        _bindings.free_string(resultPtr);
      }
    }
  }

  /// Enhance captured image with perspective correction
  ///
  /// [imageData] - Raw image bytes
  /// [width] - Image width
  /// [height] - Image height
  /// [corners] - Document corners [x0,y0,x1,y1,x2,y2,x3,y3] (TL,TR,BR,BL)
  /// [format] - 0: BGRA, 1: BGR, 2: RGB
  /// [enhanceMode] - Enhancement mode for OCR optimization
  /// [outputWidth] - Desired output width (0 for auto)
  /// [outputHeight] - Desired output height (0 for auto)
  ///
  /// Returns [EnhancementResult] with corrected image data
  EnhancementResult enhanceImage(
    Uint8List imageData,
    int width,
    int height,
    List<double> corners, {
    int format = 1,
    bool applyPerspective = true,
    bool applyDeskew = false,
    bool applyEnhance = false,
    bool applySharpening = false,
    double sharpeningStrength = 0.5,
    EnhanceMode enhanceMode = EnhanceMode.none,
    int outputWidth = 0,
    int outputHeight = 0,
  }) {
    if (!_isInitialized || _engine == null) {
      return EnhancementResult.error('Engine not initialized');
    }

    if (corners.length != 8) {
      return EnhancementResult.error('Corners must have 8 values');
    }

    final dataPtr = malloc<Uint8>(imageData.length);
    dataPtr.asTypedList(imageData.length).setAll(0, imageData);

    final cornersPtr = malloc<Float>(8);
    for (int i = 0; i < 8; i++) {
      cornersPtr[i] = corners[i];
    }

    Pointer<Void>? resultPtr;
    try {
      resultPtr = _bindings.enhance_image(
        _engine!,
        dataPtr,
        width,
        height,
        format,
        cornersPtr,
        applyPerspective ? 1 : 0,
        applyDeskew ? 1 : 0,
        applyEnhance ? 1 : 0,
        applySharpening ? 1 : 0,
        sharpeningStrength,
        enhanceMode.index,
        outputWidth,
        outputHeight,
      );

      if (resultPtr == null || resultPtr == nullptr) {
        return EnhancementResult.error('Enhancement failed');
      }

      final success = _bindings.get_enhancement_success(resultPtr) == 1;
      if (!success) {
        final errorPtr = _bindings.get_enhancement_error(resultPtr);
        final error = errorPtr.cast<Utf8>().toDartString();
        return EnhancementResult.error(error);
      }

      final resultWidth = _bindings.get_enhancement_width(resultPtr);
      final resultHeight = _bindings.get_enhancement_height(resultPtr);
      final channels = _bindings.get_enhancement_channels(resultPtr);
      final imageDataPtr = _bindings.get_enhancement_image_data(resultPtr);

      final dataSize = resultWidth * resultHeight * channels;
      final resultData = Uint8List.fromList(
        imageDataPtr.asTypedList(dataSize),
      );

      return EnhancementResult(
        success: true,
        imageData: resultData,
        width: resultWidth,
        height: resultHeight,
        channels: channels,
      );
    } finally {
      malloc.free(dataPtr);
      malloc.free(cornersPtr);
      if (resultPtr != null && resultPtr != nullptr) {
        _bindings.free_enhancement_result(resultPtr);
      }
    }
  }

  /// Enhance captured image with guide frame (auto-calculate virtual trapezoid)
  ///
  /// Uses the last analyzeFrame result to automatically calculate perspective
  /// correction. Supports both vertical (front-back tilt) and horizontal
  /// (left-right offset) skew correction.
  ///
  /// [imageData] - Raw image bytes
  /// [width] - Image width
  /// [height] - Image height
  /// [guideLeft] - Guide frame left edge
  /// [guideTop] - Guide frame top edge
  /// [guideRight] - Guide frame right edge
  /// [guideBottom] - Guide frame bottom edge
  /// [format] - 0: BGRA, 1: BGR, 2: RGB
  /// [rotation] - 0: none, 90: clockwise, 180, 270: counter-clockwise
  ///
  /// Returns [EnhancementResult] with corrected image data
  EnhancementResult enhanceImageWithGuideFrame(
    Uint8List imageData,
    int width,
    int height,
    double guideLeft,
    double guideTop,
    double guideRight,
    double guideBottom, {
    int format = 2,
    bool applySharpening = false,
    double sharpeningStrength = 0.5,
    EnhanceMode enhanceMode = EnhanceMode.none,
    int rotation = 0,
  }) {
    if (!_isInitialized || _engine == null) {
      return EnhancementResult.error('Engine not initialized');
    }

    final dataPtr = malloc<Uint8>(imageData.length);
    dataPtr.asTypedList(imageData.length).setAll(0, imageData);

    Pointer<Void>? resultPtr;
    try {
      resultPtr = _bindings.enhance_image_with_guide_frame(
        _engine!,
        dataPtr,
        width,
        height,
        format,
        guideLeft,
        guideTop,
        guideRight,
        guideBottom,
        applySharpening ? 1 : 0,
        sharpeningStrength,
        enhanceMode.index,
        rotation,
      );

      if (resultPtr == null || resultPtr == nullptr) {
        return EnhancementResult.error('Enhancement failed');
      }

      final success = _bindings.get_enhancement_success(resultPtr) == 1;
      if (!success) {
        final errorPtr = _bindings.get_enhancement_error(resultPtr);
        final error = errorPtr.cast<Utf8>().toDartString();
        return EnhancementResult.error(error);
      }

      final resultWidth = _bindings.get_enhancement_width(resultPtr);
      final resultHeight = _bindings.get_enhancement_height(resultPtr);
      final channels = _bindings.get_enhancement_channels(resultPtr);
      final imageDataPtr = _bindings.get_enhancement_image_data(resultPtr);

      final dataSize = resultWidth * resultHeight * channels;
      final resultData = Uint8List.fromList(
        imageDataPtr.asTypedList(dataSize),
      );

      return EnhancementResult(
        success: true,
        imageData: resultData,
        width: resultWidth,
        height: resultHeight,
        channels: channels,
      );
    } finally {
      malloc.free(dataPtr);
      if (resultPtr != null && resultPtr != nullptr) {
        _bindings.free_enhancement_result(resultPtr);
      }
    }
  }

  /// Dispose the engine and free resources
  void dispose() {
    if (_isInitialized && _engine != null) {
      _bindings.capture_engine_destroy(_engine!);
      _engine = null;
      _isInitialized = false;
    }
  }
}

/// Represents a single text region bounds [x, y, width, height]
class TextRegionBounds {
  final double x;
  final double y;
  final double width;
  final double height;

  TextRegionBounds({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  Rect toRect() => Rect.fromLTWH(x, y, width, height);
}

/// Result of frame analysis
class FrameAnalysisResult {
  final bool documentFound;
  final bool tableFound;       // True if table detected (clear rectangular border)
  final bool textRegionFound;  // True if text region detected (fallback)
  final List<double> corners;
  final double cornerConfidence;
  final double blurScore;
  final double brightnessScore;
  final double stabilityScore;
  final double overallScore;
  final bool captureReady;
  final String? error;

  // Table/Trapezoid data
  final bool isTrapezoid;      // True if shape needs perspective correction
  final double skewRatio;      // Overall skew ratio (max of vertical and horizontal)
  final double topWidth;       // Width of top edge
  final double bottomWidth;    // Width of bottom edge
  final double leftHeight;     // Height of left edge
  final double rightHeight;    // Height of right edge
  final double verticalSkew;   // Vertical skew (front-back tilt)
  final double horizontalSkew; // Horizontal skew (left-right offset)

  // Multiple text regions data
  final int textRegionCount;
  final double coverageRatio;
  final List<double> overallBounds;  // [x, y, width, height]
  final List<TextRegionBounds> textRegions;  // Individual regions

  FrameAnalysisResult({
    required this.documentFound,
    this.tableFound = false,
    this.textRegionFound = false,
    required this.corners,
    required this.cornerConfidence,
    required this.blurScore,
    required this.brightnessScore,
    required this.stabilityScore,
    required this.overallScore,
    required this.captureReady,
    this.error,
    this.isTrapezoid = false,
    this.skewRatio = 0,
    this.topWidth = 0,
    this.bottomWidth = 0,
    this.leftHeight = 0,
    this.rightHeight = 0,
    this.verticalSkew = 0,
    this.horizontalSkew = 0,
    this.textRegionCount = 0,
    this.coverageRatio = 0,
    this.overallBounds = const [],
    this.textRegions = const [],
  });

  /// Returns true if either table or text region was found
  bool get hasRegion => tableFound || textRegionFound;

  /// Get overall bounds as Rect (or null if not available)
  Rect? get overallRect {
    if (overallBounds.length == 4) {
      return Rect.fromLTWH(overallBounds[0], overallBounds[1], overallBounds[2], overallBounds[3]);
    }
    return null;
  }

  /// Get skew percentage for display
  int get skewPercent => (skewRatio * 100).round();

  factory FrameAnalysisResult.fromJson(Map<String, dynamic> json) {
    // Parse text regions
    final regionsData = json['text_regions'] as List? ?? [];
    final textRegions = regionsData.map((r) {
      final bounds = (r as List).map((e) => (e as num).toDouble()).toList();
      return TextRegionBounds(
        x: bounds.isNotEmpty ? bounds[0] : 0,
        y: bounds.length > 1 ? bounds[1] : 0,
        width: bounds.length > 2 ? bounds[2] : 0,
        height: bounds.length > 3 ? bounds[3] : 0,
      );
    }).toList();

    return FrameAnalysisResult(
      documentFound: json['document_found'] ?? false,
      tableFound: json['table_found'] ?? false,
      textRegionFound: json['text_region_found'] ?? false,
      corners: (json['corners'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? [],
      cornerConfidence: (json['corner_confidence'] as num?)?.toDouble() ?? 0.0,
      blurScore: (json['blur_score'] as num?)?.toDouble() ?? 0.0,
      brightnessScore: (json['brightness_score'] as num?)?.toDouble() ?? 0.0,
      stabilityScore: (json['stability_score'] as num?)?.toDouble() ?? 0.0,
      overallScore: (json['overall_score'] as num?)?.toDouble() ?? 0.0,
      captureReady: json['capture_ready'] ?? false,
      error: json['error'],
      isTrapezoid: json['is_trapezoid'] ?? false,
      skewRatio: (json['skew_ratio'] as num?)?.toDouble() ?? 0.0,
      topWidth: (json['top_width'] as num?)?.toDouble() ?? 0.0,
      bottomWidth: (json['bottom_width'] as num?)?.toDouble() ?? 0.0,
      leftHeight: (json['left_height'] as num?)?.toDouble() ?? 0.0,
      rightHeight: (json['right_height'] as num?)?.toDouble() ?? 0.0,
      verticalSkew: (json['vertical_skew'] as num?)?.toDouble() ?? 0.0,
      horizontalSkew: (json['horizontal_skew'] as num?)?.toDouble() ?? 0.0,
      textRegionCount: json['text_region_count'] ?? 0,
      coverageRatio: (json['coverage_ratio'] as num?)?.toDouble() ?? 0.0,
      overallBounds: (json['overall_bounds'] as List?)?.map((e) => (e as num).toDouble()).toList() ?? [],
      textRegions: textRegions,
    );
  }

  factory FrameAnalysisResult.error(String message) {
    return FrameAnalysisResult(
      documentFound: false,
      tableFound: false,
      textRegionFound: false,
      corners: [],
      cornerConfidence: 0,
      blurScore: 0,
      brightnessScore: 0,
      stabilityScore: 0,
      overallScore: 0,
      captureReady: false,
      error: message,
    );
  }
}

/// Result of image enhancement
class EnhancementResult {
  final bool success;
  final Uint8List? imageData;
  final int width;
  final int height;
  final int channels;
  final String? error;

  EnhancementResult({
    required this.success,
    this.imageData,
    this.width = 0,
    this.height = 0,
    this.channels = 0,
    this.error,
  });

  factory EnhancementResult.error(String message) {
    return EnhancementResult(
      success: false,
      error: message,
    );
  }
}

/// Get library version
String getVersion() {
  final versionPtr = _bindings.get_version();
  return versionPtr.cast<Utf8>().toDartString();
}
