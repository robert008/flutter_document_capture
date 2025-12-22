import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_ocr_kit/flutter_ocr_kit.dart';
import 'package:flutter_document_capture/flutter_document_capture.dart';

import '../utils/score_calculator.dart';
import '../services/layout_service.dart';

/// Top-level function for compute() - encodes image to JPEG in isolate
Uint8List _encodeJpgInIsolate(Map<String, dynamic> params) {
  final int width = params['width'] as int;
  final int height = params['height'] as int;
  final int quality = params['quality'] as int;
  final Uint8List pixels = params['pixels'] as Uint8List;
  final int channels = params['channels'] as int;

  // Reconstruct image from raw pixels
  final image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final i = (y * width + x) * channels;
      if (channels >= 3) {
        image.setPixelRgb(x, y, pixels[i], pixels[i + 1], pixels[i + 2]);
      }
    }
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

/// Result holder for A/B comparison with voting mechanism
class ComparisonResult {
  ExtractionScore? score;
  int frameCount = 0;
  Duration totalTime = Duration.zero;

  // Voting maps: value -> count
  final Map<String, int> _numVotes = {};
  final Map<String, int> _dateVotes = {};
  final Map<String, int> _customerVotes = {};
  final Map<String, int> _orderVotes = {};
  final Map<int, int> _subtotalVotes = {};
  final Map<int, int> _taxVotes = {};
  final Map<int, int> _totalVotes = {};

  // Keep best items list (with most valid items)
  List<QuotationItem> _bestItems = [];

  // Confidence threshold for voting
  static const double _minConfidence = 0.3;

  ComparisonResult();

  // Get the most voted value from a map
  T? _getMostVoted<T>(Map<T, int> votes) {
    if (votes.isEmpty) return null;
    return votes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }

  // Get current best result based on votes
  QuotationInfo? get quotationInfo {
    final num = _getMostVoted(_numVotes);
    final subtotal = _getMostVoted(_subtotalVotes);
    final tax = _getMostVoted(_taxVotes);
    final total = _getMostVoted(_totalVotes);

    if (num == null && subtotal == null && tax == null && total == null) {
      return null;
    }

    return QuotationInfo(
      quotationNumber: num,
      quotationDate: _getMostVoted(_dateVotes),
      customerName: _getMostVoted(_customerVotes),
      orderNumber: _getMostVoted(_orderVotes),
      subtotal: subtotal,
      tax: tax,
      total: total,
      items: _bestItems,
      confidence: 0,
    );
  }

  void updateFrom(QuotationInfo info) {
    frameCount++;

    // Only count votes from high confidence results
    if (info.confidence < _minConfidence) {
      debugPrint('[ComparisonResult] Frame $frameCount skipped (low confidence: ${info.confidence.toStringAsFixed(2)})');
      return;
    }

    // Vote for each non-null field
    if (info.quotationNumber != null) {
      _numVotes[info.quotationNumber!] = (_numVotes[info.quotationNumber!] ?? 0) + 1;
    }
    if (info.quotationDate != null) {
      _dateVotes[info.quotationDate!] = (_dateVotes[info.quotationDate!] ?? 0) + 1;
    }
    if (info.customerName != null) {
      _customerVotes[info.customerName!] = (_customerVotes[info.customerName!] ?? 0) + 1;
    }
    if (info.orderNumber != null) {
      _orderVotes[info.orderNumber!] = (_orderVotes[info.orderNumber!] ?? 0) + 1;
    }
    if (info.subtotal != null) {
      _subtotalVotes[info.subtotal!] = (_subtotalVotes[info.subtotal!] ?? 0) + 1;
    }
    if (info.tax != null) {
      _taxVotes[info.tax!] = (_taxVotes[info.tax!] ?? 0) + 1;
    }
    if (info.total != null) {
      _totalVotes[info.total!] = (_totalVotes[info.total!] ?? 0) + 1;
    }

    // Keep best items list (most valid items with amount > 0)
    final validItems = info.items.where((item) => item.amount > 0).length;
    final currentValid = _bestItems.where((item) => item.amount > 0).length;
    if (validItems > currentValid) {
      _bestItems = List.from(info.items);
    }

    // Debug: show current votes
    debugPrint('[ComparisonResult] Frame $frameCount votes: num=${_numVotes}, subtotal=${_subtotalVotes}, tax=${_taxVotes}, total=${_totalVotes}');

    // Update score
    final current = quotationInfo;
    if (current != null) {
      score = ScoreCalculator.calculateBasic(current);
    }
  }

  void reset() {
    frameCount = 0;
    score = null;
    _numVotes.clear();
    _dateVotes.clear();
    _customerVotes.clear();
    _orderVotes.clear();
    _subtotalVotes.clear();
    _taxVotes.clear();
    _totalVotes.clear();
    _bestItems = [];
  }
}

/// Realtime A/B Test Page
///
/// Compares:
/// - Instant: First frame OCR result (no quality check)
/// - Stable: Accumulated results from quality frames
class RealtimeComparisonPage extends StatefulWidget {
  const RealtimeComparisonPage({super.key});

  @override
  State<RealtimeComparisonPage> createState() => _RealtimeComparisonPageState();
}

class _RealtimeComparisonPageState extends State<RealtimeComparisonPage> {
  // Camera
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  bool _isProcessing = false;
  bool _isScanning = false;

  // Layout detection (singleton - shared across app)
  bool _isLayoutInitialized = false;

  // Document Capture
  DocumentCaptureEngine? _captureEngine;

  // OCR
  final QuotationExtractor _extractor = QuotationExtractor();

  // A/B Results
  final ComparisonResult _instantResult = ComparisonResult();
  final ComparisonResult _stableResult = ComparisonResult();
  bool _instantCaptured = false;

  // Quality thresholds (only blur matters with fixed guide frame)
  static const double _blurThreshold = 0.5;

  // Current frame quality
  double _blurScore = 0.0;
  double _stabilityScore = 0.0;
  bool _isQualityFrame = false;

  // Last analysis result (for drawing text region)
  FrameAnalysisResult? _lastAnalysis;
  Size? _lastImageSize;
  Rect? _lastGuideRect;  // Guide frame in image coordinates

  // Streaming
  CameraImage? _latestFrame;
  bool _isStreaming = false;

  // UI state
  bool _resultsExpanded = false;

  // Status
  String _status = 'Initializing...';
  int _totalFrames = 0;
  int _qualityFrames = 0;
  DateTime? _scanStartTime;

  // Enhancement settings
  EnhanceMode _enhanceMode = EnhanceMode.contrastStretch;
  bool _enableSharpening = true;
  double _sharpeningStrength = 0.5;

  // Guide rectangle padding (smaller = bigger frame)
  final double _guidePaddingH = 0.05;  // 5% each side = 90% width
  final double _guidePaddingV = 0.10;  // 10% each side = 80% height

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    _initCaptureEngine();
    await _initLayoutModel();
    await _initCamera();
  }

  void _initCaptureEngine() {
    try {
      _captureEngine = DocumentCaptureEngine();
      if (!_captureEngine!.isInitialized) {
        _captureEngine = null;
      }
    } catch (e) {
      debugPrint('[RealtimeComparison] CaptureEngine error: $e');
      _captureEngine = null;
    }
  }

  Future<void> _initLayoutModel() async {
    setState(() => _status = 'Loading layout model...');

    try {
      // Use singleton - model loads once for entire app
      await LayoutService.instance.init();
      debugPrint('[RealtimeComparison] Layout service ready');
      setState(() {
        _isLayoutInitialized = true;
        _status = 'Ready - Press START';
      });
    } catch (e) {
      setState(() => _status = 'Layout init failed: $e');
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _status = 'No camera available');
        return;
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();

      if (mounted) {
        setState(() => _isCameraInitialized = true);
      }
    } catch (e) {
      setState(() => _status = 'Camera init failed: $e');
    }
  }

  void _startScanning() {
    if (!_isLayoutInitialized || !_isCameraInitialized) return;

    setState(() {
      _isScanning = true;
      _instantCaptured = false;
      _totalFrames = 0;
      _qualityFrames = 0;
      _scanStartTime = DateTime.now();
      _status = 'Scanning...';

      // Reset results
      _instantResult.reset();
      _stableResult.reset();
    });

    _captureEngine?.reset();

    // Start image stream
    if (!_isStreaming) {
      _isStreaming = true;
      _cameraController!.startImageStream((CameraImage image) {
        _latestFrame = image;
        // Trigger processing if not already processing
        if (!_isProcessing && _isScanning) {
          _processNextFrame();
        }
      });
    }
  }

  void _stopScanning() {
    setState(() {
      _isScanning = false;
      _status = 'Stopped';
    });

    // Stop image stream
    if (_isStreaming) {
      _isStreaming = false;
      _cameraController?.stopImageStream();
      _latestFrame = null;
    }
  }

  Future<void> _processNextFrame() async {
    if (!_isScanning) return;
    if (!_isCameraInitialized || _cameraController == null) return;
    if (_isProcessing) return;  // Skip if already processing
    if (_latestFrame == null) return;  // No frame available

    _isProcessing = true;
    String? tempFilePath;
    final stopwatch = Stopwatch();
    final timings = <String, int>{};

    try {
      // Get frame from stream (no capture delay!)
      stopwatch.start();
      final frame = _latestFrame!;
      _totalFrames++;

      // Convert CameraImage to img.Image
      final int origWidth = frame.width;
      final int origHeight = frame.height;
      late img.Image decodedImage;

      // For Android, rotation will be done in C++ (SIMD optimized)
      // Calculate effective dimensions after rotation
      final bool needsRotation = Platform.isAndroid;
      final int rotation = needsRotation ? 90 : 0;
      final int effectiveWidth = needsRotation ? origHeight : origWidth;
      final int effectiveHeight = needsRotation ? origWidth : origHeight;

      if (Platform.isIOS) {
        // iOS: BGRA format
        final plane = frame.planes[0];
        decodedImage = img.Image(width: origWidth, height: origHeight);
        final bytes = plane.bytes;
        final rowStride = plane.bytesPerRow;

        for (int y = 0; y < origHeight; y++) {
          for (int x = 0; x < origWidth; x++) {
            final idx = y * rowStride + x * 4;
            if (idx + 3 < bytes.length) {
              final b = bytes[idx];
              final g = bytes[idx + 1];
              final r = bytes[idx + 2];
              decodedImage.setPixelRgb(x, y, r, g, b);
            }
          }
        }
      } else {
        // Android: YUV420 format - convert to RGB (no rotation here!)
        final yPlane = frame.planes[0];
        final uPlane = frame.planes[1];
        final vPlane = frame.planes[2];

        decodedImage = img.Image(width: origWidth, height: origHeight);

        for (int y = 0; y < origHeight; y++) {
          for (int x = 0; x < origWidth; x++) {
            final yIndex = y * yPlane.bytesPerRow + x;
            final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2);

            final yValue = yPlane.bytes[yIndex];
            final uValue = uPlane.bytes[uvIndex];
            final vValue = vPlane.bytes[uvIndex];

            // YUV to RGB conversion
            int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
            int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).round().clamp(0, 255);
            int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);

            decodedImage.setPixelRgb(x, y, r, g, b);
          }
        }
        // Rotation moved to C++ layer (OpenCV SIMD optimized)
      }
      timings['convert'] = stopwatch.elapsedMilliseconds;

      // Calculate guide frame based on EFFECTIVE (rotated) dimensions
      final guideLeft = (effectiveWidth * _guidePaddingH).round();
      final guideTop = (effectiveHeight * _guidePaddingV).round();
      final guideWidth = (effectiveWidth * (1 - 2 * _guidePaddingH)).round();
      final guideHeight = (effectiveHeight * (1 - 2 * _guidePaddingV)).round();
      final guideRect = Rect.fromLTWH(
        guideLeft.toDouble(),
        guideTop.toDouble(),
        guideWidth.toDouble(),
        guideHeight.toDouble(),
      );

      // Analyze with crop (C++ rotates first, then crops to guide frame)
      bool isQualityFrame = true;
      if (_captureEngine != null) {
        stopwatch.reset();
        final rgbBytes = decodedImage.getBytes(order: img.ChannelOrder.rgb);
        timings['getBytes1'] = stopwatch.elapsedMilliseconds;
        stopwatch.reset();
        final analysis = _captureEngine!.analyzeFrame(
          rgbBytes,
          origWidth,  // Original dimensions - C++ will rotate first
          origHeight,
          format: 2,  // RGB
          rotation: rotation,  // C++ handles rotation (SIMD optimized)
          cropX: guideLeft,    // Crop region in rotated coordinates
          cropY: guideTop,
          cropW: guideWidth,
          cropH: guideHeight,
        );
        timings['analyzeFrame'] = stopwatch.elapsedMilliseconds;

        _blurScore = analysis.blurScore;
        _stabilityScore = analysis.stabilityScore;
        isQualityFrame = _blurScore >= _blurThreshold;
        _isQualityFrame = isQualityFrame;

        // Store for drawing - corners are in cropped image coordinates
        // imageSize = cropped size, guideRect = offset to map back to full image
        _lastAnalysis = analysis;
        _lastImageSize = Size(guideWidth.toDouble(), guideHeight.toDouble());  // Cropped size
        _lastGuideRect = guideRect;  // Guide frame offset for overlay drawing

        // Debug: show raw detection flags
        debugPrint('[RealtimeComparison] docFound=${analysis.documentFound}, tableFound=${analysis.tableFound}, textFound=${analysis.textRegionFound}, conf=${analysis.cornerConfidence.toStringAsFixed(2)}, corners=${analysis.corners.length}');

        if (analysis.tableFound) {
          debugPrint('[RealtimeComparison] TABLE: trapezoid=${analysis.isTrapezoid}, skew=${analysis.skewPercent}%, blur=${_blurScore.toStringAsFixed(2)}, stability=${_stabilityScore.toStringAsFixed(2)}');
          // Debug: check if corners exceed crop region
          final c = analysis.corners;
          final maxX = [c[0], c[2], c[4], c[6]].reduce((a, b) => a > b ? a : b);
          final maxY = [c[1], c[3], c[5], c[7]].reduce((a, b) => a > b ? a : b);
          debugPrint('[DEBUG] cropSize=${guideWidth}x$guideHeight, corners maxX=$maxX maxY=$maxY, exceed=${maxX > guideWidth || maxY > guideHeight}');
        } else if (analysis.textRegionFound) {
          debugPrint('[RealtimeComparison] TEXT: regions=${analysis.textRegionCount}, cov=${(analysis.coverageRatio * 100).toInt()}%, blur=${_blurScore.toStringAsFixed(2)}');
        } else {
          debugPrint('[RealtimeComparison] NO REGION: blur=${_blurScore.toStringAsFixed(2)}');
        }

        if (isQualityFrame) {
          _qualityFrames++;
        }
      }

      // Apply enhancement (crop + enhance)
      // Need to save to file for OCR
      final appDir = await getApplicationDocumentsDirectory();
      final basePath = '${appDir.path}/frame_$_totalFrames';
      String imagePathForOcr = '$basePath.jpg';

      if (_captureEngine != null) {
        stopwatch.reset();
        final rgbBytes = decodedImage.getBytes(order: img.ChannelOrder.rgb);
        timings['getBytes2'] = stopwatch.elapsedMilliseconds;

        // Calculate guide frame bounds using EFFECTIVE (rotated) dimensions
        final enhanceGuideLeft = effectiveWidth * _guidePaddingH;
        final enhanceGuideTop = effectiveHeight * _guidePaddingV;
        final enhanceGuideRight = effectiveWidth * (1 - _guidePaddingH);
        final enhanceGuideBottom = effectiveHeight * (1 - _guidePaddingV);

        // Log perspective correction info
        if (_lastAnalysis?.tableFound == true && _lastAnalysis?.isTrapezoid == true) {
          debugPrint('[RealtimeComparison] Applying perspective correction (skew=${_lastAnalysis!.skewPercent}%, vSkew=${(_lastAnalysis!.verticalSkew * 100).toInt()}%, hSkew=${(_lastAnalysis!.horizontalSkew * 100).toInt()}%)');
        }

        // Use new API - C++ handles rotation + virtual trapezoid calculation
        stopwatch.reset();
        final enhanceResult = _captureEngine!.enhanceImageWithGuideFrame(
          rgbBytes,
          origWidth,   // Original dimensions - C++ will rotate
          origHeight,
          enhanceGuideLeft,   // Guide coords in rotated space
          enhanceGuideTop,
          enhanceGuideRight,
          enhanceGuideBottom,
          applySharpening: _enableSharpening,
          sharpeningStrength: _sharpeningStrength,
          enhanceMode: _enhanceMode,
          rotation: rotation,  // C++ handles rotation (SIMD optimized)
        );
        timings['enhance'] = stopwatch.elapsedMilliseconds;

        if (enhanceResult.success && enhanceResult.imageData != null) {
          // Encode JPEG in isolate to avoid blocking main thread
          stopwatch.reset();
          final jpgBytes = await compute(_encodeJpgInIsolate, {
            'width': enhanceResult.width,
            'height': enhanceResult.height,
            'quality': 95,
            'pixels': enhanceResult.imageData!,
            'channels': enhanceResult.channels,
          });
          timings['saveJpg'] = stopwatch.elapsedMilliseconds;

          stopwatch.reset();
          final enhancedPath = '${basePath}_enhanced.jpg';
          await File(enhancedPath).writeAsBytes(jpgBytes);
          timings['writeFile'] = stopwatch.elapsedMilliseconds;
          imagePathForOcr = enhancedPath;
          tempFilePath = enhancedPath;
        }
      }

      // Layout + OCR in parallel (both run in isolates)
      // Layout uses singleton service (model shared across app)
      stopwatch.reset();
      final futures = await Future.wait([
        LayoutService.instance.detect(imagePathForOcr),
        OcrKit.recognizeNativeIsolate(imagePathForOcr),
      ]);
      final layoutResult = futures[0] as LayoutResult;
      final ocrResult = futures[1] as OcrResult;
      timings['layout+ocr'] = stopwatch.elapsedMilliseconds;

      // Debug: Log Layout Detection results
      final tables = layoutResult.detections.where((d) => d.className.toLowerCase() == 'table').toList();
      final allClasses = layoutResult.detections.map((d) => d.className).toSet().toList();
      debugPrint('[LayoutDetection] Found ${layoutResult.detections.length} regions: ${allClasses.join(", ")}');
      if (tables.isNotEmpty) {
        tables.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
        final mainTable = tables.first;
        debugPrint('[LayoutDetection] Table: (${mainTable.x1.toInt()},${mainTable.y1.toInt()})-(${mainTable.x2.toInt()},${mainTable.y2.toInt()}) size=${mainTable.width.toInt()}x${mainTable.height.toInt()} score=${mainTable.score.toStringAsFixed(2)}');
      } else {
        debugPrint('[LayoutDetection] NO TABLE FOUND');
      }

      stopwatch.reset();
      final quotationInfo = _extractor.extract(ocrResult, layoutResult: layoutResult);
      timings['extract'] = stopwatch.elapsedMilliseconds;

      // Print timing summary
      final total = timings.values.fold(0, (a, b) => a + b);
      debugPrint('[TIMING] Total: ${total}ms | ${timings.entries.map((e) => "${e.key}:${e.value}").join(" | ")}');

      // Log OCR result
      debugPrint('[RealtimeComparison] OCR: num=${quotationInfo.quotationNumber}, subtotal=${quotationInfo.subtotal}, tax=${quotationInfo.tax}, total=${quotationInfo.total}, items=${quotationInfo.items.length}');

      // Update results - accept any frame with some data
      final hasData = quotationInfo.quotationNumber != null ||
          quotationInfo.subtotal != null ||
          quotationInfo.tax != null ||
          quotationInfo.total != null ||
          quotationInfo.items.isNotEmpty;

      if (hasData) {
        // First frame -> Instant result (only once)
        if (!_instantCaptured) {
          _instantResult.updateFrom(quotationInfo);
          _instantCaptured = true;
          debugPrint('[RealtimeComparison] Instant captured');
        }

        // Quality frames -> Stable result (accumulate)
        if (isQualityFrame) {
          _stableResult.updateFrom(quotationInfo);
          debugPrint('[RealtimeComparison] Stable frame #${_stableResult.frameCount} accumulated');
        }
      } else {
        debugPrint('[RealtimeComparison] No data extracted from frame');
      }

      // Update UI
      if (mounted) {
        final elapsed = DateTime.now().difference(_scanStartTime!).inSeconds;
        setState(() {
          _status = 'Frame $_totalFrames | Quality $_qualityFrames | ${elapsed}s';
        });
      }

    } catch (e) {
      debugPrint('[RealtimeComparison] Error: $e');
    } finally {
      _isProcessing = false;

      // Cleanup temp file
      if (tempFilePath != null) {
        try { await File(tempFilePath).delete(); } catch (_) {}
      }

      // Continue scanning
      if (_isScanning && mounted) {
        Future.microtask(() => _processNextFrame());
      }
    }
  }

  @override
  void dispose() {
    _isScanning = false;
    _cameraController?.dispose();
    _captureEngine?.dispose();
    // Note: LayoutService is singleton, don't dispose here
    super.dispose();
  }

  Color _getScoreColor(double score) {
    if (score >= 0.8) return Colors.green;
    if (score >= 0.6) return Colors.orange;
    if (score >= 0.4) return Colors.deepOrange;
    return Colors.red;
  }

  Widget _buildScoreBadge(String label, int? percentage, Color color) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: percentage != null ? _getScoreColor(percentage / 100) : Colors.grey,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  percentage != null ? '$percentage%' : '-',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('A/B Test - Realtime'),
        backgroundColor: Colors.deepPurple,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _isScanning ? Colors.green.shade100 : Colors.grey.shade200,
            child: Row(
              children: [
                if (_isScanning)
                  Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: _isQualityFrame ? Colors.green : Colors.orange,
                      shape: BoxShape.circle,
                    ),
                  ),
                Expanded(
                  child: Text(
                    _status,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (_isScanning) ...[
                  Text('Blur: ${(_blurScore * 100).toInt()}%',
                    style: TextStyle(fontSize: 11, color: _blurScore >= _blurThreshold ? Colors.green : Colors.red)),
                  const SizedBox(width: 8),
                  Text(_isQualityFrame ? 'QUALITY' : 'waiting...',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _isQualityFrame ? Colors.green : Colors.orange)),
                ],
              ],
            ),
          ),

          // Camera preview
          Expanded(
            flex: 2,
            child: _isCameraInitialized
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.center,
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox(
                              width: _cameraController!.value.previewSize!.height,
                              height: _cameraController!.value.previewSize!.width,
                              child: CameraPreview(_cameraController!),
                            ),
                          ),
                        ),
                      ),
                      CustomPaint(
                        painter: _GuidePainter(
                          paddingH: _guidePaddingH,
                          paddingV: _guidePaddingV,
                          isQuality: _isQualityFrame,
                          analysis: _lastAnalysis,
                          imageSize: _lastImageSize,
                          guideRect: _lastGuideRect,
                        ),
                        size: Size.infinite,
                      ),
                    ],
                  )
                : const Center(child: CircularProgressIndicator()),
          ),

          // Results comparison (collapsible)
          GestureDetector(
            onTap: () => setState(() => _resultsExpanded = !_resultsExpanded),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: _resultsExpanded ? 280 : 80,
              child: Column(
                children: [
                  // Summary bar (always visible)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    color: Colors.grey.shade100,
                    child: Row(
                      children: [
                        // Instant score
                        Expanded(
                          child: _buildScoreBadge(
                            'Instant',
                            _instantResult.score?.percentage,
                            Colors.orange,
                          ),
                        ),
                        // Expand/collapse icon
                        Icon(
                          _resultsExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                          color: Colors.grey,
                        ),
                        // Processed score
                        Expanded(
                          child: _buildScoreBadge(
                            'Processed (${_stableResult.frameCount})',
                            _stableResult.score?.percentage,
                            Colors.green,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Expanded details
                  if (_resultsExpanded)
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildResultPanel(
                              title: 'Instant',
                              subtitle: '(1st frame)',
                              result: _instantResult,
                              color: Colors.orange,
                            ),
                          ),
                          Container(width: 2, color: Colors.grey.shade300),
                          Expanded(
                            child: _buildResultPanel(
                              title: 'Processed',
                              subtitle: '(${_stableResult.frameCount} frames)',
                              result: _stableResult,
                              color: Colors.green,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Controls
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLayoutInitialized && _isCameraInitialized
                        ? (_isScanning ? _stopScanning : _startScanning)
                        : null,
                    icon: Icon(_isScanning ? Icons.stop : Icons.play_arrow),
                    label: Text(_isScanning ? 'STOP' : 'START'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isScanning ? Colors.red : Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel({
    required String title,
    required String subtitle,
    required ComparisonResult result,
    required Color color,
  }) {
    final info = result.quotationInfo;
    final score = result.score;

    return Container(
      color: Colors.grey.shade50,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Column(
                children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: color, fontSize: 16)),
                  Text(subtitle, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8))),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // Score
            if (score != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: _getScoreColor(score.score),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Score: ${score.percentage}%',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ),
            const SizedBox(height: 8),

            // Fields
            _buildField('No.', info?.quotationNumber, 'HD-2024120015'),
            _buildField('Sub', info?.subtotal?.toString(), '8370'),
            _buildField('Tax', info?.tax?.toString(), '419'),
            _buildField('Total', info?.total?.toString(), '8789'),

            const Divider(),
            Text('Items: ${info?.items.length ?? 0}', style: const TextStyle(fontSize: 11)),
            if (score != null)
              Text('Matched: ${score.itemsMatched}/5', style: const TextStyle(fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _buildField(String label, String? value, String expected) {
    final isMatch = value != null &&
        value.replaceAll(RegExp(r'[^0-9]'), '') == expected.replaceAll(RegExp(r'[^0-9]'), '');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            isMatch ? Icons.check_circle : Icons.cancel,
            size: 14,
            color: isMatch ? Colors.green : Colors.red,
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 35,
            child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: Text(
              value ?? '-',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: isMatch ? Colors.green.shade700 : Colors.red.shade700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Guide overlay painter
class _GuidePainter extends CustomPainter {
  final double paddingH;
  final double paddingV;
  final bool isQuality;
  final FrameAnalysisResult? analysis;
  final Size? imageSize;
  final Rect? guideRect;  // Guide frame in image coordinates

  _GuidePainter({
    required this.paddingH,
    required this.paddingV,
    this.isQuality = false,
    this.analysis,
    this.imageSize,
    this.guideRect,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      size.width * paddingH,
      size.height * paddingV,
      size.width * (1 - 2 * paddingH),
      size.height * (1 - 2 * paddingV),
    );

    final guideColor = isQuality ? Colors.greenAccent : Colors.orange;

    final overlayPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(rect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, overlayPaint);

    final borderPaint = Paint()
      ..color = guideColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRect(rect, borderPaint);

    // Draw regions if detected
    // imageSize = cropped image size, map to guide frame on screen
    if (analysis != null && imageSize != null && guideRect != null) {
      // Guide frame position on screen (same as rect above)
      final guideOnScreen = Rect.fromLTWH(
        size.width * paddingH,
        size.height * paddingV,
        size.width * (1 - 2 * paddingH),
        size.height * (1 - 2 * paddingV),
      );
      // Scale from cropped image coords to screen guide frame
      final scaleX = guideOnScreen.width / imageSize!.width;
      final scaleY = guideOnScreen.height / imageSize!.height;
      final offsetX = guideOnScreen.left;
      final offsetY = guideOnScreen.top;

      // Draw individual text regions (yellow boxes)
      if (analysis!.textRegionFound && analysis!.textRegions.isNotEmpty) {
        final regionPaint = Paint()
          ..color = Colors.yellow
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;

        final regionFillPaint = Paint()
          ..color = Colors.yellow.withValues(alpha: 0.1)
          ..style = PaintingStyle.fill;

        for (int i = 0; i < analysis!.textRegions.length; i++) {
          final region = analysis!.textRegions[i];
          final rect = Rect.fromLTWH(
            offsetX + region.x * scaleX,
            offsetY + region.y * scaleY,
            region.width * scaleX,
            region.height * scaleY,
          );
          canvas.drawRect(rect, regionFillPaint);
          canvas.drawRect(rect, regionPaint);

          // Label each region with index
          final indexSpan = TextSpan(
            text: ' ${i + 1} ',
            style: TextStyle(
              color: Colors.black,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              backgroundColor: Colors.yellow.withValues(alpha: 0.8),
            ),
          );
          final indexPainter = TextPainter(
            text: indexSpan,
            textDirection: TextDirection.ltr,
          );
          indexPainter.layout();
          indexPainter.paint(canvas, Offset(rect.left, rect.top));
        }
      }

      // Draw overall bounds (cyan box) - encompasses all regions
      if (analysis!.corners.length == 8) {
        final hasRegion = analysis!.tableFound || analysis!.textRegionFound;

        if (hasRegion) {
          final corners = analysis!.corners;
          final points = [
            Offset(offsetX + corners[0] * scaleX, offsetY + corners[1] * scaleY),
            Offset(offsetX + corners[2] * scaleX, offsetY + corners[3] * scaleY),
            Offset(offsetX + corners[4] * scaleX, offsetY + corners[5] * scaleY),
            Offset(offsetX + corners[6] * scaleX, offsetY + corners[7] * scaleY),
          ];

          // Choose color based on detection type
          final regionColor = analysis!.tableFound ? Colors.cyan : Colors.lightGreenAccent;

          // Draw polygon outline
          final strokePaint = Paint()
            ..color = regionColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round;

          final strokePath = Path()..addPolygon(points, true);
          canvas.drawPath(strokePath, strokePaint);

          // Draw corner circles
          final cornerPaint = Paint()
            ..color = regionColor
            ..style = PaintingStyle.fill;

          for (int i = 0; i < points.length; i++) {
            canvas.drawCircle(points[i], 5, cornerPaint);
          }

          // Draw label - TABLE with trapezoid info or text region count
          String labelText;
          if (analysis!.tableFound) {
            // TABLE detected - show trapezoid info
            if (analysis!.isTrapezoid) {
              labelText = 'TABLE [${analysis!.skewPercent}%]';
            } else {
              labelText = 'TABLE';
            }
          } else {
            // Text region fallback
            labelText = 'TEXT (${analysis!.textRegionCount})';
          }
          final textSpan = TextSpan(
            text: ' $labelText ',
            style: TextStyle(
              color: Colors.black,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              backgroundColor: regionColor,
            ),
          );
          final textPainter = TextPainter(
            text: textSpan,
            textDirection: TextDirection.ltr,
          );
          textPainter.layout();
          final labelY = points[0].dy - 16;
          textPainter.paint(canvas, Offset(points[0].dx, labelY > 0 ? labelY : points[0].dy + 5));

          // Draw trapezoid indicator if perspective correction needed
          if (analysis!.tableFound && analysis!.isTrapezoid) {
            final trapezoidSpan = TextSpan(
              text: ' PERSP ',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.red.withValues(alpha: 0.8),
              ),
            );
            final trapezoidPainter = TextPainter(
              text: trapezoidSpan,
              textDirection: TextDirection.ltr,
            );
            trapezoidPainter.layout();
            trapezoidPainter.paint(canvas, Offset(points[1].dx - trapezoidPainter.width, labelY > 0 ? labelY : points[1].dy + 5));
          }

          // Draw stats at bottom
          String statsText;
          if (analysis!.tableFound) {
            // TABLE: show blur, stability, and skew
            statsText = 'blur:${(analysis!.blurScore * 100).toInt()}% stab:${(analysis!.stabilityScore * 100).toInt()}% skew:${analysis!.skewPercent}%';
          } else {
            statsText = 'blur:${(analysis!.blurScore * 100).toInt()}% stab:${(analysis!.stabilityScore * 100).toInt()}% cov:${(analysis!.coverageRatio * 100).toInt()}%';
          }
          final statsSpan = TextSpan(
            text: ' $statsText ',
            style: TextStyle(
              color: Colors.white,
              fontSize: 9,
              backgroundColor: Colors.black.withValues(alpha: 0.7),
            ),
          );
          final statsPainter = TextPainter(
            text: statsSpan,
            textDirection: TextDirection.ltr,
          );
          statsPainter.layout();
          statsPainter.paint(canvas, Offset(points[3].dx, points[3].dy + 3));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _GuidePainter oldDelegate) {
    return oldDelegate.isQuality != isQuality ||
        oldDelegate.analysis != analysis ||
        oldDelegate.imageSize != imageSize ||
        oldDelegate.guideRect != guideRect;
  }
}
