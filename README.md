# Flutter Document Capture

A Flutter FFI plugin for real-time document capture preprocessing. Uses OpenCV for image processing on mobile devices (Edge AI) to optimize input quality for downstream OCR and layout detection.

## Features

- **Document Detection** - OpenCV-based corner detection using Canny + findContours
- **Quality Assessment** - Blur, brightness, and stability scoring
- **Perspective Correction** - Transform skewed documents to rectangular
- **Image Enhancement** - Multiple enhancement modes for OCR optimization
- **Auto-capture Trigger** - Automatic capture when quality thresholds are met

## Screenshot

### A/B Test Comparison
<img src="https://github.com/robert008/flutter_document_capture/releases/download/v0.0.1/compare.PNG" width="400">

### Preprocessing Results

| Processed OFF | Processed ON |
|:-------------:|:------------:|
| ![OFF](https://github.com/robert008/flutter_document_capture/releases/download/v0.0.1/processed_off.PNG) | ![ON](https://github.com/robert008/flutter_document_capture/releases/download/v0.0.1/processed_on.PNG) |

## Why Use This Package?

| Benefit | Description |
|---------|-------------|
| **Higher Accuracy** | Preprocessing improves OCR recognition rate |
| **Better Stability** | Multi-frame buffering selects the best result |
| **Faster Valid Results** | Reduces time to obtain valid recognition |

> **Note:** Single-frame processing time is not faster (due to preprocessing + multi-frame buffer), but overall time to get valid results is reduced.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_document_capture:
    git:
      url: https://github.com/robert008/flutter_document_capture.git
```

## Usage

### Basic Setup

```dart
import 'package:flutter_document_capture/flutter_document_capture.dart';

// Initialize engine
final engine = DocumentCaptureEngine();

// Analyze frame quality
final analysis = engine.analyzeFrame(
  imageBytes,
  width,
  height,
  format: 2, // RGB
);

// Check if ready for capture
if (analysis.captureReady) {
  // Capture and enhance
  final result = engine.enhanceImageWithGuideFrame(
    imageBytes,
    width,
    height,
    guideLeft,
    guideTop,
    guideRight,
    guideBottom,
    enhanceMode: EnhanceMode.contrastStretch,
  );
}

// Cleanup
engine.dispose();
```

### Enhancement Modes

```dart
enum EnhanceMode {
  none,              // No enhancement
  whitenBg,          // Background whitening
  contrastStretch,   // Contrast stretching (recommended)
  adaptiveBinarize,  // Adaptive binarization
  sauvola,           // Sauvola binarization
}
```

### Frame Analysis Result

```dart
class FrameAnalysisResult {
  bool documentFound;      // Document corners detected
  bool tableFound;         // Table region detected
  bool textRegionFound;    // Text regions detected
  double blurScore;        // 0.0 - 1.0 (higher = sharper)
  double brightnessScore;  // 0.0 - 1.0
  double stabilityScore;   // 0.0 - 1.0
  double cornerConfidence; // 0.0 - 1.0
  bool captureReady;       // All thresholds met
  List<double> corners;    // 8 values: [x0,y0,x1,y1,x2,y2,x3,y3]
}
```

## Requirements

- Flutter 3.0+
- iOS 12.0+ / Android API 21+
- OpenCV (bundled)

## Related Projects

- [flutter_ocr_kit](https://github.com/robert008/flutter_ocr_kit) - OCR + Layout Detection

## License

MIT License - see [LICENSE](LICENSE) for details.
