import 'package:flutter/material.dart';
import 'package:flutter_document_capture/flutter_document_capture.dart';

import 'pages/benchmark_test_page.dart';
import 'pages/comparison_page.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  DocumentCaptureEngine? _engine;
  String _status = 'Not initialized';
  String _version = '';
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _initEngine();
  }

  void _initEngine() {
    try {
      _engine = DocumentCaptureEngine();
      final version = getVersion();
      setState(() {
        _status = _engine!.isInitialized ? 'Engine initialized' : 'Failed to initialize';
        _version = version;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
      });
    }
  }

  @override
  void dispose() {
    _engine?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.purple),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Document Capture Demo'),
          backgroundColor: Colors.purple,
          foregroundColor: Colors.white,
        ),
        body: IndexedStack(
          index: _currentIndex,
          children: [
            // Tab 0: A/B Test
            const ComparisonPage(),
            // Tab 1: Batch Test
            const BenchmarkTestPage(),
            // Tab 2: Info
            _buildInfoTab(),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) => setState(() => _currentIndex = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.compare),
              label: 'A/B Test',
            ),
            NavigationDestination(
              icon: Icon(Icons.speed),
              label: 'Batch Test',
            ),
            NavigationDestination(
              icon: Icon(Icons.info_outline),
              label: 'Info',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoTab() {
    const textStyle = TextStyle(fontSize: 18);
    const spacer = SizedBox(height: 16);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Flutter Document Capture',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          spacer,
          Text('Status: $_status', style: textStyle),
          if (_version.isNotEmpty)
            Text('Version: $_version', style: textStyle),
          spacer,
          const Divider(),
          spacer,
          const Text(
            'Features:',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          spacer,
          const FeatureItem(
            title: 'Document Detection',
            description: 'OpenCV-based corner detection using Canny + findContours',
          ),
          const FeatureItem(
            title: 'Quality Assessment',
            description: 'Blur, brightness, and stability scoring',
          ),
          const FeatureItem(
            title: 'Perspective Correction',
            description: 'Transform skewed documents to rectangular',
          ),
          spacer,
          const Divider(),
          spacer,
          const Text(
            'Integration Test:',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          spacer,
          const Text('A/B Test: Compare instant vs stable OCR results in realtime.', style: textStyle),
          const Text('Batch Test: Run multiple scans to measure accuracy and performance.', style: textStyle),
        ],
      ),
    );
  }
}

class FeatureItem extends StatelessWidget {
  final String title;
  final String description;

  const FeatureItem({
    super.key,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(description, style: const TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
