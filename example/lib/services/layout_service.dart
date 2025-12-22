import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_ocr_kit/flutter_ocr_kit.dart';
import 'package:path_provider/path_provider.dart';

/// Message types for isolate communication
enum _MessageType { init, detect, release }

/// Request message to isolate
class _IsolateRequest {
  final _MessageType type;
  final Map<String, String>? params;
  final SendPort replyPort;

  _IsolateRequest(this.type, this.params, this.replyPort);
}

/// Singleton service for layout detection
/// - Model loads once for the entire app
/// - All pages share the same isolate
/// - Call dispose() only when app closes
class LayoutService {
  // Singleton instance
  static final LayoutService _instance = LayoutService._internal();
  static LayoutService get instance => _instance;

  LayoutService._internal();

  // Isolate state
  Isolate? _isolate;
  SendPort? _sendPort;
  bool _isInitialized = false;
  bool _isInitializing = false;
  Completer<void>? _initCompleter;

  bool get isInitialized => _isInitialized;

  /// Initialize the service (safe to call multiple times)
  Future<void> init() async {
    // Already initialized
    if (_isInitialized) return;

    // Currently initializing - wait for it
    if (_isInitializing && _initCompleter != null) {
      return _initCompleter!.future;
    }

    _isInitializing = true;
    _initCompleter = Completer<void>();

    try {
      // Copy model from assets to documents
      final data = await rootBundle.load('assets/pp_doclayout_l.onnx');
      final modelBytes = data.buffer.asUint8List();

      final appDir = await getApplicationDocumentsDirectory();
      final modelPath = '${appDir.path}/pp_doclayout_l.onnx';

      final modelFile = File(modelPath);
      if (!await modelFile.exists()) {
        await modelFile.writeAsBytes(modelBytes);
      }

      // Warmup image
      final warmupData = await rootBundle.load('assets/test_1.jpg');
      final warmupBytes = warmupData.buffer.asUint8List();
      final warmupPath = '${appDir.path}/warmup_layout.jpg';
      await File(warmupPath).writeAsBytes(warmupBytes);

      // Spawn persistent isolate
      final receivePort = ReceivePort();
      _isolate = await Isolate.spawn(_isolateEntryPoint, receivePort.sendPort);
      _sendPort = await receivePort.first as SendPort;

      // Initialize model in isolate
      final responsePort = ReceivePort();
      _sendPort!.send(_IsolateRequest(
        _MessageType.init,
        {'modelPath': modelPath, 'warmupPath': warmupPath},
        responsePort.sendPort,
      ));

      final result = await responsePort.first;
      responsePort.close();

      // Cleanup warmup image
      try {
        await File(warmupPath).delete();
      } catch (_) {}

      if (result is int) {
        debugPrint('[LayoutService] Initialized, warmup: ${result}ms');
        _isInitialized = true;
        _initCompleter!.complete();
      } else if (result is String) {
        throw Exception(result);
      }
    } catch (e) {
      _initCompleter!.completeError(e);
      rethrow;
    } finally {
      _isInitializing = false;
    }
  }

  /// Detect layout in an image
  Future<LayoutResult> detect(String imagePath) async {
    if (!_isInitialized) {
      throw StateError('LayoutService not initialized. Call init() first.');
    }

    final responsePort = ReceivePort();
    _sendPort!.send(_IsolateRequest(
      _MessageType.detect,
      {'imagePath': imagePath},
      responsePort.sendPort,
    ));

    final result = await responsePort.first;
    responsePort.close();

    if (result is Map<String, dynamic>) {
      return LayoutResult.fromJson(result);
    } else if (result is String) {
      throw Exception(result);
    }

    throw Exception('Unexpected response from isolate');
  }

  /// Dispose the service (call when app closes)
  void dispose() {
    if (_isolate != null) {
      _isolate!.kill(priority: Isolate.immediate);
      _isolate = null;
      _sendPort = null;
      _isInitialized = false;
      _isInitializing = false;
      _initCompleter = null;
      debugPrint('[LayoutService] Disposed');
    }
  }
}

/// Entry point for the persistent isolate
void _isolateEntryPoint(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  bool modelLoaded = false;

  receivePort.listen((message) {
    if (message is _IsolateRequest) {
      switch (message.type) {
        case _MessageType.init:
          try {
            final modelPath = message.params!['modelPath']!;
            final warmupPath = message.params!['warmupPath']!;

            OcrKit.init(modelPath);
            modelLoaded = true;

            final warmupStart = DateTime.now();
            OcrKit.detectLayout(warmupPath);
            final warmupTime = DateTime.now().difference(warmupStart).inMilliseconds;

            message.replyPort.send(warmupTime);
          } catch (e) {
            message.replyPort.send('Init error: $e');
          }
          break;

        case _MessageType.detect:
          try {
            if (!modelLoaded) {
              message.replyPort.send('Model not initialized');
              return;
            }

            final imagePath = message.params!['imagePath']!;
            final result = OcrKit.detectLayout(imagePath);
            message.replyPort.send(result.toJson());
          } catch (e) {
            message.replyPort.send('Detect error: $e');
          }
          break;

        case _MessageType.release:
          try {
            OcrKit.releaseLayout();
            modelLoaded = false;
            message.replyPort.send('OK');
          } catch (e) {
            message.replyPort.send('Release error: $e');
          }
          break;
      }
    }
  });
}
