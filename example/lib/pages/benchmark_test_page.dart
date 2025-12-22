import 'package:flutter/material.dart';

import 'benchmark_scan_page.dart';
import '../services/layout_service.dart';

/// Batch Test Page - Single Result Display
class BenchmarkTestPage extends StatefulWidget {
  const BenchmarkTestPage({super.key});

  @override
  State<BenchmarkTestPage> createState() => _BenchmarkTestPageState();
}

class _BenchmarkTestPageState extends State<BenchmarkTestPage> {
  static const int targetCount = 5;

  // Model initialization
  bool _isModelInitialized = false;
  String _status = 'Loading model...';

  // Current result
  BenchmarkResult? _result;

  // Current test mode
  bool _preprocessEnabled = true;

  @override
  void initState() {
    super.initState();
    _initModel();
  }

  Future<void> _initModel() async {
    try {
      await LayoutService.instance.init();
      setState(() {
        _isModelInitialized = true;
        _status = 'Ready. Press START to begin.';
      });
    } catch (e) {
      setState(() => _status = 'Model init failed: $e');
    }
  }

  Future<void> _startBenchmark() async {
    final result = await Navigator.push<BenchmarkResult>(
      context,
      MaterialPageRoute(
        builder: (context) => BenchmarkScanPage(
          preprocessEnabled: _preprocessEnabled,
          targetCount: targetCount,
        ),
      ),
    );

    if (result != null) {
      setState(() => _result = result);
    }
  }

  void _reset() {
    setState(() => _result = null);
  }

  @override
  Widget build(BuildContext context) {
    final color = _preprocessEnabled ? Colors.green : Colors.orange;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Batch Test'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          if (_result != null)
            IconButton(
              onPressed: _reset,
              icon: const Icon(Icons.refresh),
              tooltip: 'Reset',
            ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: _isModelInitialized ? Colors.indigo.shade50 : Colors.orange.shade100,
            child: Row(
              children: [
                if (!_isModelInitialized)
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

          // Mode selector & Start button
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey.shade100,
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Preprocess:', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 12),
                    ChoiceChip(
                      label: const Text('ON'),
                      selected: _preprocessEnabled,
                      onSelected: _isModelInitialized ? (v) => setState(() => _preprocessEnabled = true) : null,
                      selectedColor: Colors.green.shade200,
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('OFF'),
                      selected: !_preprocessEnabled,
                      onSelected: _isModelInitialized ? (v) => setState(() => _preprocessEnabled = false) : null,
                      selectedColor: Colors.orange.shade200,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isModelInitialized ? _startBenchmark : null,
                    icon: Icon(_isModelInitialized ? Icons.play_arrow : Icons.hourglass_empty),
                    label: Text(_isModelInitialized
                        ? 'Start (${_preprocessEnabled ? "ON" : "OFF"})'
                        : 'Loading...'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Result
          Expanded(
            child: _result != null
                ? _buildResultPanel(_result!)
                : _buildEmptyState(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.speed, size: 64, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          Text(
            'No test result yet',
            style: TextStyle(fontSize: 16, color: Colors.grey.shade500),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap "Start" to begin\nScan 3 different documents to reach $targetCount successful scans',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
          ),
        ],
      ),
    );
  }

  Widget _buildResultPanel(BenchmarkResult result) {
    final color = result.preprocessEnabled ? Colors.green : Colors.orange;
    final title = 'Preprocess ${result.preprocessEnabled ? "ON" : "OFF"}';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              Icon(Icons.check_circle, color: color),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Main stats
          _buildStatRow('Success', '${result.successCount}/${result.totalAttempts}', color),
          _buildStatRow('Avg Score', '${result.avgScore.toStringAsFixed(1)}%', color),
          _buildStatRow('Success Rate', '${(result.successRate * 100).toStringAsFixed(1)}%', color),
          _buildStatRow('Documents', '${result.documents.length}', color),

          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),

          // Detected documents
          const Text(
            'Detected Documents:',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: result.documents.map((doc) {
              return Chip(
                label: Text(doc, style: const TextStyle(fontSize: 11)),
                backgroundColor: color.withValues(alpha: 0.1),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              );
            }).toList(),
          ),

          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 8),

          // Recent scans
          Row(
            children: [
              const Text(
                'Recent Scans:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => _showAllScans(result),
                child: const Text('View All'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...result.scans.reversed.take(5).map((scan) => _buildScanTile(scan, color)),
        ],
      ),
    );
  }

  Widget _buildStatRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanTile(ScanRecord scan, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: scan.success ? Colors.green.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: scan.success ? Colors.green.shade200 : Colors.red.shade200,
        ),
      ),
      child: Row(
        children: [
          Text(
            '#${scan.index}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              scan.documentNumber ?? '-',
              style: const TextStyle(fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: scan.success ? Colors.green : Colors.red,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${scan.score}%',
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${scan.processingTime.inMilliseconds}ms',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }

  void _showAllScans(BenchmarkResult result) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: result.preprocessEnabled ? Colors.green : Colors.orange,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.list, color: Colors.white),
                  const SizedBox(width: 8),
                  Text(
                    'All Scans (${result.scans.length})',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Stats summary
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.grey.shade100,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildMiniStat('Success', '${result.successCount}', Colors.green),
                  _buildMiniStat('Failed', '${result.totalAttempts - result.successCount}', Colors.red),
                  _buildMiniStat('Avg Score', '${result.avgScore.toStringAsFixed(0)}%', Colors.blue),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: result.scans.length,
                itemBuilder: (context, index) {
                  final scan = result.scans[result.scans.length - 1 - index];
                  return _buildDetailedScanTile(scan);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: color),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Widget _buildDetailedScanTile(ScanRecord scan) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scan.success ? Colors.green.shade50 : Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: scan.success ? Colors.green.shade200 : Colors.red.shade200,
        ),
      ),
      child: Row(
        children: [
          // Index
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: scan.success ? Colors.green : Colors.red,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Center(
              child: Text(
                '${scan.index}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  scan.documentNumber ?? 'Unknown',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  'Total: ${scan.total ?? "-"} | Time: ${scan.processingTime.inMilliseconds}ms',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),
          // Score
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: scan.success ? Colors.green : Colors.red,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${scan.score}%',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
