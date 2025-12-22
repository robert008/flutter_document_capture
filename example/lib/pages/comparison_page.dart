import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

import 'package:flutter_ocr_kit/flutter_ocr_kit.dart';
import 'package:flutter_document_capture/flutter_document_capture.dart';

import 'realtime_comparison_page.dart';
import '../utils/score_calculator.dart';
import '../services/layout_service.dart';

/// Single side result (original or processed)
class SideResult {
  final Uint8List? imageBytes;
  final int? width;
  final int? height;

  // OCR results
  final String? documentNumber;
  final int? subtotal;
  final int? tax;
  final int? total;
  final double? ocrConfidence;    // Apple Vision confidence
  final ExtractionScore? score;   // Custom extraction score

  final Duration? processingTime;
  final String? error;

  SideResult({
    this.imageBytes,
    this.width,
    this.height,
    this.documentNumber,
    this.subtotal,
    this.tax,
    this.total,
    this.ocrConfidence,
    this.score,
    this.processingTime,
    this.error,
  });
}

/// A/B Test Page
class ComparisonPage extends StatefulWidget {
  const ComparisonPage({super.key});

  @override
  State<ComparisonPage> createState() => _ComparisonPageState();
}

class _ComparisonPageState extends State<ComparisonPage> {
  // Layout model
  bool _isLayoutInitialized = false;

  // Document Capture
  DocumentCaptureEngine? _captureEngine;

  // State
  bool _isProcessing = false;
  String _status = 'Initializing...';

  // Results
  SideResult? _originalResult;
  SideResult? _processedResult;

  // Extractors
  final QuotationExtractor _extractor = QuotationExtractor();

  // Guide rectangle padding (must match CameraCapturePage)
  final double _guidePaddingH = 0.10;  // 10% horizontal
  final double _guidePaddingV = 0.25;  // 25% vertical (more square)

  // Enhancement mode selection
  bool _enableEnhance = true;
  EnhanceMode _selectedEnhanceMode = EnhanceMode.contrastStretch;
  bool _enableSharpening = true;
  double _sharpeningStrength = 0.5;

  Color _getScoreColor(double score) {
    if (score >= 0.8) return Colors.green;
    if (score >= 0.6) return Colors.orange;
    if (score >= 0.4) return Colors.deepOrange;
    return Colors.red;
  }

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    _initCaptureEngine();
    await _initLayoutModel();
  }

  void _initCaptureEngine() {
    try {
      _captureEngine = DocumentCaptureEngine();
      if (_captureEngine!.isInitialized) {
        debugPrint('[Comparison] CaptureEngine initialized successfully');
      } else {
        debugPrint('[Comparison] CaptureEngine failed to initialize');
        _captureEngine = null;
      }
    } catch (e) {
      debugPrint('[Comparison] CaptureEngine error: $e');
      _captureEngine = null;
    }
  }

  Future<void> _initLayoutModel() async {
    setState(() => _status = 'Loading layout model...');

    try {
      // Use singleton LayoutService (shared across app)
      await LayoutService.instance.init();
      debugPrint('[Comparison] LayoutService ready');

      setState(() {
        _isLayoutInitialized = true;
        _status = 'Ready. Press START to begin.';
      });
    } catch (e) {
      setState(() => _status = 'Layout init failed: $e');
    }
  }

  /// Get guide corners in image pixel coordinates
  List<double> _getGuideCorners(int imageWidth, int imageHeight) {
    final left = imageWidth * _guidePaddingH;
    final top = imageHeight * _guidePaddingV;
    final right = imageWidth * (1 - _guidePaddingH);
    final bottom = imageHeight * (1 - _guidePaddingV);

    // Return as [TL_x, TL_y, TR_x, TR_y, BR_x, BR_y, BL_x, BL_y]
    return [
      left, top,     // Top-left
      right, top,    // Top-right
      right, bottom, // Bottom-right
      left, bottom,  // Bottom-left
    ];
  }

  Future<SideResult> _processOneImage(String imagePath, String label) async {
    final startTime = DateTime.now();

    final originalBytes = await File(imagePath).readAsBytes();
    final originalDecoded = img.decodeImage(originalBytes);

    if (originalDecoded == null) {
      return SideResult(error: 'Failed to decode image');
    }

    debugPrint('[Comparison] $label image: ${originalDecoded.width}x${originalDecoded.height}');

    Uint8List processedBytes;
    int processedWidth = originalDecoded.width;
    int processedHeight = originalDecoded.height;

    // Apply crop + enhancement
    if (_captureEngine != null) {
      final rgbBytes = originalDecoded.getBytes(order: img.ChannelOrder.rgb);
      final corners = _getGuideCorners(originalDecoded.width, originalDecoded.height);

      final enhanceResult = _captureEngine!.enhanceImage(
        rgbBytes,
        originalDecoded.width,
        originalDecoded.height,
        corners,
        format: 2, // RGB
        applyPerspective: false,
        applyEnhance: false,
        applySharpening: _enableSharpening,
        sharpeningStrength: _sharpeningStrength,
        enhanceMode: _enableEnhance ? _selectedEnhanceMode : EnhanceMode.none,
      );

      if (enhanceResult.success && enhanceResult.imageData != null) {
        final enhancedImage = img.Image(
          width: enhanceResult.width,
          height: enhanceResult.height,
        );

        final srcData = enhanceResult.imageData!;
        for (int y = 0; y < enhanceResult.height; y++) {
          for (int x = 0; x < enhanceResult.width; x++) {
            final i = (y * enhanceResult.width + x) * enhanceResult.channels;
            if (enhanceResult.channels >= 3) {
              enhancedImage.setPixelRgb(x, y, srcData[i], srcData[i + 1], srcData[i + 2]);
            }
          }
        }

        processedBytes = Uint8List.fromList(img.encodePng(enhancedImage));
        processedWidth = enhanceResult.width;
        processedHeight = enhanceResult.height;
      } else {
        processedBytes = originalBytes;
      }
    } else {
      processedBytes = originalBytes;
    }

    // Save for OCR
    final appDir = await getApplicationDocumentsDirectory();
    final processedFilePath = '${appDir.path}/${label}_${DateTime.now().millisecondsSinceEpoch}.png';
    await File(processedFilePath).writeAsBytes(processedBytes);

    // Layout detection + OCR
    final layoutResult = await LayoutService.instance.detect(processedFilePath);
    final ocrResult = await OcrKit.recognizeNativeIsolate(processedFilePath);
    final quotation = _extractor.extract(ocrResult, layoutResult: layoutResult);

    final duration = DateTime.now().difference(startTime);
    final score = ScoreCalculator.calculateBasic(quotation);

    // Cleanup
    try { await File(processedFilePath).delete(); } catch (_) {}

    return SideResult(
      imageBytes: processedBytes,
      width: processedWidth,
      height: processedHeight,
      documentNumber: quotation.quotationNumber,
      subtotal: quotation.subtotal,
      tax: quotation.tax,
      total: quotation.total,
      ocrConfidence: quotation.confidence,
      score: score,
      processingTime: duration,
    );
  }

  @override
  void dispose() {
    _captureEngine?.dispose();
    OcrKit.releaseLayout();
    debugPrint('[Comparison] Layout model released');
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasResults = _originalResult != null && _processedResult != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('A/B Test'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _isProcessing ? Colors.orange.shade100 : Colors.teal.shade50,
            child: Row(
              children: [
                if (_isProcessing)
                  Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.only(right: 8),
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                Expanded(
                  child: Text(
                    _status,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),

          // Main content
          Expanded(
            child: hasResults
                ? _buildComparisonView()
                : _buildWaitingView(),
          ),

          // Bottom controls
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  if (hasResults)
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _originalResult = null;
                            _processedResult = null;
                            _status = 'Ready. Press START to begin.';
                          });
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reset'),
                      ),
                    ),
                  if (hasResults) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      onPressed: _isLayoutInitialized && !_isProcessing
                          ? () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const RealtimeComparisonPage()),
                              );
                            }
                          : null,
                      icon: Icon(_isProcessing ? Icons.hourglass_empty : Icons.play_arrow),
                      label: Text(_isProcessing ? 'Processing...' : 'START'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.teal,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Enhancement mode options
          Text(
            'Image Processing Options',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 12),
          _buildEnhanceModeCheckbox(EnhanceMode.whitenBg, 'Whiten BG'),
          _buildEnhanceModeCheckbox(EnhanceMode.contrastStretch, 'Contrast'),
          _buildEnhanceModeCheckbox(EnhanceMode.adaptiveBinarize, 'Adaptive'),
          _buildEnhanceModeCheckbox(EnhanceMode.sauvola, 'Sauvola'),
          const SizedBox(height: 16),
          // Sharpening option
          _buildSharpeningOption(),
        ],
      ),
    );
  }

  Widget _buildEnhanceModeCheckbox(EnhanceMode mode, String label) {
    final isSelected = _enableEnhance && _selectedEnhanceMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          if (isSelected) {
            // Deselect - disable enhance
            _enableEnhance = false;
          } else {
            // Select this mode
            _enableEnhance = true;
            _selectedEnhanceMode = mode;
          }
        });
      },
      child: Container(
        width: 200,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          children: [
            Checkbox(
              value: isSelected,
              onChanged: (v) {
                setState(() {
                  if (v == true) {
                    _enableEnhance = true;
                    _selectedEnhanceMode = mode;
                  } else {
                    _enableEnhance = false;
                  }
                });
              },
              visualDensity: VisualDensity.compact,
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isSelected ? Colors.teal : Colors.grey.shade700,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSharpeningOption() {
    return Container(
      width: 240,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Column(
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _enableSharpening = !_enableSharpening);
            },
            child: Row(
              children: [
                Checkbox(
                  value: _enableSharpening,
                  onChanged: (v) {
                    setState(() => _enableSharpening = v ?? false);
                  },
                  visualDensity: VisualDensity.compact,
                ),
                Text(
                  'Sharpening',
                  style: TextStyle(
                    fontSize: 14,
                    color: _enableSharpening ? Colors.teal : Colors.grey.shade700,
                    fontWeight: _enableSharpening ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
          if (_enableSharpening)
            Row(
              children: [
                const SizedBox(width: 32),
                Expanded(
                  child: Slider(
                    value: _sharpeningStrength,
                    min: 0.1,
                    max: 1.5,
                    divisions: 14,
                    onChanged: (v) {
                      setState(() => _sharpeningStrength = v);
                    },
                  ),
                ),
                SizedBox(
                  width: 35,
                  child: Text(
                    _sharpeningStrength.toStringAsFixed(1),
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildComparisonView() {
    return SingleChildScrollView(
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _buildSidePanel(
                  title: 'Instant',
                  subtitle: '(按下即拍)',
                  result: _originalResult!,
                  color: Colors.orange,
                ),
              ),
              Container(width: 2, color: Colors.grey.shade300),
              Expanded(
                child: _buildSidePanel(
                  title: 'Stable',
                  subtitle: '(穩定後拍)',
                  result: _processedResult!,
                  color: Colors.green,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSidePanel({
    required String title,
    required String subtitle,
    required SideResult result,
    required Color color,
  }) {
    return Column(
      children: [
        // Header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          color: color.withOpacity(0.2),
          child: Column(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: color,
                  fontSize: 16,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: color.withOpacity(0.8),
                ),
              ),
            ],
          ),
        ),

        // Image
        if (result.imageBytes != null)
          Container(
            constraints: const BoxConstraints(maxHeight: 250),
            child: Image.memory(
              result.imageBytes!,
              fit: BoxFit.contain,
            ),
          ),

        // OCR Results
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildOcrField('No.', result.documentNumber, 'HD-2024120015'),
              _buildOcrField('Sub', result.subtotal?.toString(), '8370'),
              _buildOcrField('Tax', result.tax?.toString(), '419'),
              _buildOcrField('Total', result.total?.toString(), '8789'),
              const Divider(),
              Row(
                children: [
                  Icon(Icons.timer, size: 12, color: Colors.grey.shade600),
                  const SizedBox(width: 4),
                  Text(
                    '${result.processingTime?.inMilliseconds ?? 0}ms',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  // Custom extraction score
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: _getScoreColor(result.score?.score ?? 0),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'Score: ${result.score?.percentage ?? 0}%',
                      style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Math validation indicator
                  if (result.score != null)
                    Icon(
                      result.score!.mathValid ? Icons.check_circle : Icons.cancel,
                      size: 14,
                      color: result.score!.mathValid ? Colors.green : Colors.red,
                    ),
                  const SizedBox(width: 4),
                  // Items info
                  if (result.score != null)
                    Text(
                      '${result.score!.itemsMatched}/${result.score!.itemCount}items',
                      style: TextStyle(
                        fontSize: 10,
                        color: result.score!.itemsMatched == result.score!.itemCount && result.score!.itemCount > 0
                            ? Colors.green
                            : Colors.grey.shade600,
                      ),
                    ),
                  const Spacer(),
                  // OCR confidence (secondary)
                  Text(
                    'OCR: ${((result.ocrConfidence ?? 0) * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOcrField(String label, String? value, String expected) {
    final isMatch = value != null && value.replaceAll(RegExp(r'[^0-9]'), '') == expected.replaceAll(RegExp(r'[^0-9]'), '');

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
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
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
