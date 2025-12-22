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

/// Single scan record
class ScanRecord {
  final int index;
  final DateTime timestamp;
  final String? documentNumber;
  final int? total;
  final int score;
  final bool success;
  final Duration processingTime;

  ScanRecord({
    required this.index,
    required this.timestamp,
    this.documentNumber,
    this.total,
    required this.score,
    required this.success,
    required this.processingTime,
  });
}

/// Benchmark result returned to parent page
class BenchmarkResult {
  final bool preprocessEnabled;
  final int successCount;
  final int totalAttempts;
  final Duration totalTime;
  final Set<String> documents;
  final List<ScanRecord> scans;

  BenchmarkResult({
    required this.preprocessEnabled,
    required this.successCount,
    required this.totalAttempts,
    required this.totalTime,
    required this.documents,
    required this.scans,
  });

  double get successRate => totalAttempts > 0 ? successCount / totalAttempts : 0;
  Duration get avgTimePerFrame => totalAttempts > 0
      ? Duration(milliseconds: totalTime.inMilliseconds ~/ totalAttempts)
      : Duration.zero;
  double get avgScore => scans.isNotEmpty
      ? scans.map((s) => s.score).reduce((a, b) => a + b) / scans.length
      : 0;
}

/// Benchmark Scan Page - manual capture with auto-capture trigger
class BenchmarkScanPage extends StatefulWidget {
  final bool preprocessEnabled;
  final int targetCount;

  const BenchmarkScanPage({
    super.key,
    required this.preprocessEnabled,
    this.targetCount = 15,
  });

  @override
  State<BenchmarkScanPage> createState() => _BenchmarkScanPageState();
}

class _BenchmarkScanPageState extends State<BenchmarkScanPage> {
  // Camera
  CameraController? _cameraController;
  bool _isCameraInitialized = false;
  CameraImage? _latestFrame;
  bool _isStreaming = false;

  // Layout detection (singleton - shared across app)
  bool _isLayoutInitialized = false;

  // Document Capture
  DocumentCaptureEngine? _captureEngine;

  // Benchmark state
  final List<ScanRecord> _scans = [];
  final Set<String> _detectedDocuments = {};
  bool _isProcessing = false;
  String _status = 'Initializing...';
  DateTime? _startTime;

  // Auto-capture state
  bool _waitingForCapture = false;
  int _consecutiveReadyFrames = 0;
  DateTime? _lastCaptureTime;
  static const int _requiredConsecutiveFrames = 5;
  static const Duration _captureCooldown = Duration(seconds: 1);

  // Current scan info
  String? _currentDocNumber;
  int _currentScore = 0;
  FrameAnalysisResult? _lastAnalysisResult;

  // Extractors
  final QuotationExtractor _extractor = QuotationExtractor();

  // Guide frame padding
  final double _guidePaddingH = 0.10;
  final double _guidePaddingV = 0.25;

  int get _successCount => _scans.where((s) => s.success).length;

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
    // Always init for analysis (both ON and OFF need frame analysis)
    try {
      _captureEngine = DocumentCaptureEngine();
      if (!_captureEngine!.isInitialized) {
        _captureEngine = null;
      }
    } catch (e) {
      debugPrint('[BenchmarkScan] CaptureEngine error: $e');
      _captureEngine = null;
    }
  }

  Future<void> _initLayoutModel() async {
    setState(() => _status = 'Loading layout model...');

    try {
      await LayoutService.instance.init();
      debugPrint('[BenchmarkScan] Layout service ready');
      setState(() => _isLayoutInitialized = true);
    } catch (e) {
      setState(() => _status = 'Layout init failed: $e');
    }
  }

  Future<void> _initCamera() async {
    setState(() => _status = 'Initializing camera...');

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
        imageFormatGroup: Platform.isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.bgra8888,
      );

      await _cameraController!.initialize();
      _startImageStream();

      setState(() {
        _isCameraInitialized = true;
        _status = 'Ready. Press CAPTURE to start.';
      });
    } catch (e) {
      setState(() => _status = 'Camera init failed: $e');
    }
  }

  void _startImageStream() {
    if (_isStreaming || _cameraController == null) return;

    _isStreaming = true;
    _cameraController!.startImageStream((CameraImage image) {
      _latestFrame = image;
      _analyzeFrameForAutoCapture();
    });
  }

  void _stopImageStream() {
    if (!_isStreaming) return;
    _isStreaming = false;
    _cameraController?.stopImageStream();
    _latestFrame = null;
  }

  void _analyzeFrameForAutoCapture() {
    if (_latestFrame == null || _captureEngine == null) return;
    if (_isProcessing) return;

    // Convert frame for analysis
    final frame = _latestFrame!;
    final int origWidth = frame.width;
    final int origHeight = frame.height;

    Uint8List rgbBytes;
    int rotation = 0;

    if (Platform.isIOS) {
      // iOS: BGRA format
      final plane = frame.planes[0];
      final bytes = plane.bytes;
      final rowStride = plane.bytesPerRow;
      rgbBytes = Uint8List(origWidth * origHeight * 3);

      for (int y = 0; y < origHeight; y++) {
        for (int x = 0; x < origWidth; x++) {
          final srcIdx = y * rowStride + x * 4;
          final dstIdx = (y * origWidth + x) * 3;
          if (srcIdx + 3 < bytes.length) {
            rgbBytes[dstIdx] = bytes[srcIdx + 2];     // R
            rgbBytes[dstIdx + 1] = bytes[srcIdx + 1]; // G
            rgbBytes[dstIdx + 2] = bytes[srcIdx];     // B
          }
        }
      }
    } else {
      // Android: YUV420 format
      rotation = 90;
      final yPlane = frame.planes[0];
      final uPlane = frame.planes[1];
      final vPlane = frame.planes[2];
      rgbBytes = Uint8List(origWidth * origHeight * 3);

      for (int y = 0; y < origHeight; y++) {
        for (int x = 0; x < origWidth; x++) {
          final yIndex = y * yPlane.bytesPerRow + x;
          final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * uPlane.bytesPerPixel!;

          final yValue = yPlane.bytes[yIndex];
          final uValue = uPlane.bytes[uvIndex];
          final vValue = vPlane.bytes[uvIndex];

          int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
          int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).round().clamp(0, 255);
          int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);

          final idx = (y * origWidth + x) * 3;
          rgbBytes[idx] = r;
          rgbBytes[idx + 1] = g;
          rgbBytes[idx + 2] = b;
        }
      }
    }

    // Calculate crop region (guide frame area)
    final effectiveWidth = rotation == 90 ? origHeight : origWidth;
    final effectiveHeight = rotation == 90 ? origWidth : origHeight;
    final cropX = (effectiveWidth * _guidePaddingH).round();
    final cropY = (effectiveHeight * _guidePaddingV).round();
    final cropW = (effectiveWidth * (1 - 2 * _guidePaddingH)).round();
    final cropH = (effectiveHeight * (1 - 2 * _guidePaddingV)).round();

    // Analyze frame
    final analysisResult = _captureEngine!.analyzeFrame(
      rgbBytes,
      origWidth,
      origHeight,
      format: 2, // RGB
      rotation: rotation,
      cropX: cropX,
      cropY: cropY,
      cropW: cropW,
      cropH: cropH,
    );

    setState(() {
      _lastAnalysisResult = analysisResult;
    });

    // Auto-capture logic
    if (_waitingForCapture) {
      // Check cooldown
      if (_lastCaptureTime != null &&
          DateTime.now().difference(_lastCaptureTime!) < _captureCooldown) {
        return;
      }

      if (analysisResult.captureReady) {
        _consecutiveReadyFrames++;
        setState(() {
          _status = 'Quality OK ($_consecutiveReadyFrames/$_requiredConsecutiveFrames)...';
        });

        if (_consecutiveReadyFrames >= _requiredConsecutiveFrames) {
          // Trigger capture!
          _doCapture();
        }
      } else {
        _consecutiveReadyFrames = 0;
        setState(() {
          _status = 'Checking quality...';
        });
      }
    }
  }

  void _onCapturePressed() {
    if (_isProcessing) return;
    if (_scans.length >= widget.targetCount) return;

    _startTime ??= DateTime.now();

    if (widget.preprocessEnabled) {
      // ON: wait for quality before capture
      setState(() {
        _waitingForCapture = true;
        _consecutiveReadyFrames = 0;
        _status = 'Waiting for stable frame...';
      });
    } else {
      // OFF: capture immediately (no quality check)
      _doCapture();
    }
  }

  Future<void> _doCapture() async {
    if (_isProcessing) return;
    if (_latestFrame == null) return;

    _isProcessing = true;
    _waitingForCapture = false;
    _consecutiveReadyFrames = 0;
    _lastCaptureTime = DateTime.now();

    setState(() {
      _status = 'Processing...';
    });

    final scanStart = DateTime.now();
    String? processedFilePath;

    try {
      final frame = _latestFrame!;
      final int origWidth = frame.width;
      final int origHeight = frame.height;

      // Convert frame to image
      late img.Image decodedImage;
      int rotation = 0;

      if (Platform.isIOS) {
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
        // Android: YUV420
        rotation = 90;
        final yPlane = frame.planes[0];
        final uPlane = frame.planes[1];
        final vPlane = frame.planes[2];
        decodedImage = img.Image(width: origWidth, height: origHeight);

        for (int y = 0; y < origHeight; y++) {
          for (int x = 0; x < origWidth; x++) {
            final yIndex = y * yPlane.bytesPerRow + x;
            final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * uPlane.bytesPerPixel!;

            final yValue = yPlane.bytes[yIndex];
            final uValue = uPlane.bytes[uvIndex];
            final vValue = vPlane.bytes[uvIndex];

            int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
            int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).round().clamp(0, 255);
            int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);

            decodedImage.setPixelRgb(x, y, r, g, b);
          }
        }
      }

      // Apply rotation if needed (for Android)
      if (rotation == 90) {
        decodedImage = img.copyRotate(decodedImage, angle: 90);
      }

      final rgbBytes = decodedImage.getBytes(order: img.ChannelOrder.rgb);
      Uint8List processedBytes;

      // Preprocessing (crop + enhance) only when enabled
      if (widget.preprocessEnabled && _captureEngine != null) {
        final corners = _getGuideCorners(decodedImage.width, decodedImage.height);

        final enhanceResult = _captureEngine!.enhanceImage(
          rgbBytes,
          decodedImage.width,
          decodedImage.height,
          corners,
          format: 2,
          applyPerspective: false,
          applySharpening: true,
          sharpeningStrength: 0.5,
          enhanceMode: EnhanceMode.contrastStretch,
        );

        if (enhanceResult.success && enhanceResult.imageData != null) {
          processedBytes = await compute(_encodeJpgInIsolate, {
            'width': enhanceResult.width,
            'height': enhanceResult.height,
            'quality': 90,
            'pixels': enhanceResult.imageData!,
            'channels': enhanceResult.channels,
          });
        } else {
          processedBytes = Uint8List.fromList(img.encodeJpg(decodedImage, quality: 90));
        }
      } else {
        // No preprocessing - use original
        processedBytes = Uint8List.fromList(img.encodeJpg(decodedImage, quality: 90));
      }

      // Save for OCR
      final appDir = await getApplicationDocumentsDirectory();
      processedFilePath = '${appDir.path}/benchmark_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(processedFilePath).writeAsBytes(processedBytes);

      // Layout + OCR
      final futures = await Future.wait([
        LayoutService.instance.detect(processedFilePath),
        OcrKit.recognizeNativeIsolate(processedFilePath),
      ]);
      final layoutResult = futures[0] as LayoutResult;
      final ocrResult = futures[1] as OcrResult;
      final quotation = _extractor.extract(ocrResult, layoutResult: layoutResult);

      // Calculate score
      final extractionScore = ScoreCalculator.calculateBasic(quotation);
      final score = extractionScore.percentage;
      final success = score >= 60;

      // Track detected documents
      if (quotation.quotationNumber != null && quotation.quotationNumber!.isNotEmpty) {
        _detectedDocuments.add(quotation.quotationNumber!);
      }

      final processingTime = DateTime.now().difference(scanStart);

      final record = ScanRecord(
        index: _scans.length + 1,
        timestamp: DateTime.now(),
        documentNumber: quotation.quotationNumber,
        total: quotation.total,
        score: score,
        success: success,
        processingTime: processingTime,
      );

      _scans.add(record);

      setState(() {
        _currentDocNumber = quotation.quotationNumber;
        _currentScore = score;
        _status = 'Captured ${_scans.length}/${widget.targetCount}';
      });

      debugPrint('[BenchmarkScan] #${record.index}: '
          'num=${record.documentNumber}, '
          'score=${record.score}, '
          'time=${record.processingTime.inMilliseconds}ms');

      // Check if complete
      if (_scans.length >= widget.targetCount) {
        _returnResult();
      }
    } catch (e) {
      debugPrint('[BenchmarkScan] Error: $e');
      setState(() => _status = 'Error: $e');
    } finally {
      _isProcessing = false;

      // Cleanup
      if (processedFilePath != null) {
        try { await File(processedFilePath).delete(); } catch (_) {}
      }
    }
  }

  List<double> _getGuideCorners(int imageWidth, int imageHeight) {
    final left = imageWidth * _guidePaddingH;
    final top = imageHeight * _guidePaddingV;
    final right = imageWidth * (1 - _guidePaddingH);
    final bottom = imageHeight * (1 - _guidePaddingV);

    return [left, top, right, top, right, bottom, left, bottom];
  }

  void _returnResult() {
    _stopImageStream();

    final totalTime = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;

    final result = BenchmarkResult(
      preprocessEnabled: widget.preprocessEnabled,
      successCount: _successCount,
      totalAttempts: _scans.length,
      totalTime: totalTime,
      documents: _detectedDocuments,
      scans: _scans,
    );

    Navigator.pop(context, result);
  }

  @override
  void dispose() {
    _stopImageStream();
    _cameraController?.dispose();
    _captureEngine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;

    final isReady = _lastAnalysisResult?.captureReady ?? false;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black87,
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: widget.preprocessEnabled ? Colors.green : Colors.orange,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.preprocessEnabled ? 'Preprocess ON' : 'Preprocess OFF',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () {
                      _stopImageStream();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.close, color: Colors.white),
                  ),
                ],
              ),
            ),

            // Camera preview
            Expanded(
              child: _isCameraInitialized && _cameraController != null
                  ? Stack(
                      fit: StackFit.expand,
                      children: [
                        // Camera
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

                        // Guide frame (only show when preprocessing ON)
                        if (widget.preprocessEnabled)
                          CustomPaint(
                            painter: _GuideFramePainter(
                              paddingH: _guidePaddingH,
                              paddingV: _guidePaddingV,
                              isReady: isReady,
                            ),
                          ),

                        // Progress overlay
                        Positioned(
                          top: 16,
                          left: 16,
                          right: 16,
                          child: Column(
                            children: [
                              // Progress bar
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: _scans.length / widget.targetCount,
                                  backgroundColor: Colors.white24,
                                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                                  minHeight: 8,
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Stats row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  _buildStatChip('Captured', '${_scans.length}/${widget.targetCount}', Colors.green),
                                  _buildStatChip('Success', '$_successCount', Colors.blue),
                                  _buildStatChip('Docs', '${_detectedDocuments.length}', Colors.purple),
                                  if (_startTime != null)
                                    _buildStatChip('Time', '${elapsed.inSeconds}s', Colors.orange),
                                ],
                              ),
                            ],
                          ),
                        ),

                        // Quality indicator
                        Positioned(
                          top: 80,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              decoration: BoxDecoration(
                                color: isReady ? Colors.green.withOpacity(0.8) : Colors.orange.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isReady ? Icons.check_circle : Icons.hourglass_empty,
                                    color: Colors.white,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    isReady ? 'READY' : 'ADJUSTING...',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Current scan info
                        if (_scans.isNotEmpty)
                          Positioned(
                            bottom: 16,
                            left: 16,
                            right: 16,
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _currentDocNumber ?? 'No document',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        Text(
                                          _status,
                                          style: TextStyle(
                                            color: Colors.white.withOpacity(0.7),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _currentScore >= 60 ? Colors.green : Colors.red,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '$_currentScore%',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 18,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        // Processing indicator
                        if (_isProcessing)
                          Container(
                            color: Colors.black54,
                            child: const Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  CircularProgressIndicator(color: Colors.white),
                                  SizedBox(height: 16),
                                  Text(
                                    'Processing...',
                                    style: TextStyle(color: Colors.white, fontSize: 16),
                                  ),
                                ],
                              ),
                            ),
                          ),

                        // Waiting for capture indicator
                        if (_waitingForCapture && !_isProcessing)
                          Positioned(
                            bottom: 100,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(25),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      'Checking... $_consecutiveReadyFrames/$_requiredConsecutiveFrames',
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const CircularProgressIndicator(color: Colors.white),
                          const SizedBox(height: 16),
                          Text(
                            _status,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ],
                      ),
                    ),
            ),

            // Bottom controls
            Container(
              padding: const EdgeInsets.all(16),
              color: Colors.black87,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Cancel button
                  OutlinedButton.icon(
                    onPressed: () {
                      _stopImageStream();
                      Navigator.pop(context);
                    },
                    icon: const Icon(Icons.close, color: Colors.white),
                    label: const Text('Cancel', style: TextStyle(color: Colors.white)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                  ),

                  // Capture button
                  ElevatedButton.icon(
                    onPressed: (_isCameraInitialized &&
                               _isLayoutInitialized &&
                               !_isProcessing &&
                               !_waitingForCapture &&
                               _scans.length < widget.targetCount)
                        ? _onCapturePressed
                        : null,
                    icon: const Icon(Icons.camera_alt, size: 28),
                    label: Text(
                      _waitingForCapture
                          ? 'Waiting...'
                          : 'CAPTURE (${_scans.length}/${widget.targetCount})',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    ),
                  ),

                  // Done button
                  if (_scans.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _returnResult,
                      icon: const Icon(Icons.check, color: Colors.green),
                      label: const Text('Done', style: TextStyle(color: Colors.green)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.green),
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.8),
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

/// Guide frame painter
class _GuideFramePainter extends CustomPainter {
  final double paddingH;
  final double paddingV;
  final bool isReady;

  _GuideFramePainter({
    required this.paddingH,
    required this.paddingV,
    this.isReady = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final left = size.width * paddingH;
    final top = size.height * paddingV;
    final right = size.width * (1 - paddingH);
    final bottom = size.height * (1 - paddingV);

    final rect = Rect.fromLTRB(left, top, right, bottom);

    // Dim outside area
    final paint = Paint()..color = Colors.black.withValues(alpha: 0.5);
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
        Path()..addRect(rect),
      ),
      paint,
    );

    // Border
    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(rect, borderPaint);

    // Corner accents (green when ready, white otherwise)
    const cornerLength = 30.0;
    final accentPaint = Paint()
      ..color = isReady ? Colors.green : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;

    // Top-left
    canvas.drawLine(Offset(left, top), Offset(left + cornerLength, top), accentPaint);
    canvas.drawLine(Offset(left, top), Offset(left, top + cornerLength), accentPaint);

    // Top-right
    canvas.drawLine(Offset(right, top), Offset(right - cornerLength, top), accentPaint);
    canvas.drawLine(Offset(right, top), Offset(right, top + cornerLength), accentPaint);

    // Bottom-left
    canvas.drawLine(Offset(left, bottom), Offset(left + cornerLength, bottom), accentPaint);
    canvas.drawLine(Offset(left, bottom), Offset(left, bottom - cornerLength), accentPaint);

    // Bottom-right
    canvas.drawLine(Offset(right, bottom), Offset(right - cornerLength, bottom), accentPaint);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - cornerLength), accentPaint);
  }

  @override
  bool shouldRepaint(covariant _GuideFramePainter oldDelegate) {
    return oldDelegate.isReady != isReady;
  }
}
