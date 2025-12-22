import 'package:flutter_ocr_kit/flutter_ocr_kit.dart';

/// Ground truth for test document HD-2024120015
class GroundTruth {
  static const String quotationNumber = 'HD-2024120015';
  static const String quotationDate = '2024/12/12';
  static const String customerName = '智慧電子有限公司';
  static const String orderNumber = 'PO-20241210-007';
  static const int subtotal = 8370;
  static const int tax = 419;
  static const int total = 8789;
  static const int itemCount = 5;

  static const List<Map<String, dynamic>> items = [
    {'name': '微控制器 MCU-32', 'quantity': 30, 'unitPrice': 185, 'amount': 5550},
    {'name': '繼電器 RELAY-5V', 'quantity': 40, 'unitPrice': 28, 'amount': 1120},
    {'name': '蜂鳴器 BUZZ-12', 'quantity': 50, 'unitPrice': 15, 'amount': 750},
    {'name': '按鍵開關 SW-6x6', 'quantity': 200, 'unitPrice': 2, 'amount': 400},
    {'name': '七段顯示器 7SEG', 'quantity': 25, 'unitPrice': 22, 'amount': 550},
  ];
}

/// Extraction score result
class ExtractionScore {
  final double score;              // 0.0 - 1.0
  final Map<String, bool> fields;  // Field extraction status
  final bool mathValid;            // subtotal + tax == total
  final int itemCount;             // Number of items extracted
  final int itemsMatched;          // Number of items matching ground truth
  final String summary;

  ExtractionScore({
    required this.score,
    required this.fields,
    required this.mathValid,
    required this.itemCount,
    required this.itemsMatched,
    required this.summary,
  });

  int get percentage => (score * 100).round();
}

/// Calculator for quotation extraction success rate
class ScoreCalculator {

  /// Calculate score against ground truth (HD-2024120015)
  /// Weights: quotationNumber 30%, total 20%, subtotal 10%, tax 10%, itemCount 10%, itemsContent 20%
  static ExtractionScore calculate(QuotationInfo info) {
    final fields = <String, bool>{};
    double earnedWeight = 0;

    // 1. Quotation Number (30%)
    const numberWeight = 0.30;
    final numberMatch = info.quotationNumber == GroundTruth.quotationNumber;
    fields['quotationNumber'] = numberMatch;
    if (numberMatch) earnedWeight += numberWeight;

    // 2. Total (20%)
    const totalWeight = 0.20;
    final totalMatch = info.total == GroundTruth.total;
    fields['total'] = totalMatch;
    if (totalMatch) earnedWeight += totalWeight;

    // 3. Subtotal (10%)
    const subtotalWeight = 0.10;
    final subtotalMatch = info.subtotal == GroundTruth.subtotal;
    fields['subtotal'] = subtotalMatch;
    if (subtotalMatch) earnedWeight += subtotalWeight;

    // 4. Tax (10%)
    const taxWeight = 0.10;
    final taxMatch = info.tax == GroundTruth.tax;
    fields['tax'] = taxMatch;
    if (taxMatch) earnedWeight += taxWeight;

    // 5. Math validation (not scored, just for display)
    bool mathValid = false;
    if (info.subtotal != null && info.tax != null && info.total != null) {
      mathValid = (info.subtotal! + info.tax!) == info.total!;
    }
    fields['mathValid'] = mathValid;

    // 6. Item count match (10%)
    const itemCountWeight = 0.10;
    final itemCountMatch = info.items.length == GroundTruth.itemCount;
    fields['itemCount'] = itemCountMatch;
    if (itemCountMatch) earnedWeight += itemCountWeight;

    // 7. Items content validation (20%)
    const itemsContentWeight = 0.20;
    int itemsMatched = 0;
    for (final gtItem in GroundTruth.items) {
      final gtAmount = gtItem['amount'] as int;
      final gtQuantity = gtItem['quantity'] as int;

      // Find matching item by amount + quantity
      final found = info.items.any((item) =>
        item.amount == gtAmount && item.quantity == gtQuantity
      );
      if (found) itemsMatched++;
    }

    final itemsFullMatch = itemsMatched == GroundTruth.items.length;
    fields['itemsContent'] = itemsFullMatch;
    if (itemsFullMatch) earnedWeight += itemsContentWeight;

    final score = earnedWeight;
    final matchedCount = fields.values.where((v) => v).length;
    final summary = '$matchedCount/${fields.length} (${itemsMatched}/${GroundTruth.itemCount}items)';

    return ExtractionScore(
      score: score,
      fields: fields,
      mathValid: mathValid,
      itemCount: info.items.length,
      itemsMatched: itemsMatched,
      summary: summary,
    );
  }

  /// Calculate score based on extraction completeness
  /// - No quotation number = 0
  /// - With quotation number: base 40 + total 25 + items 25 + subtotal 10 = 100
  static ExtractionScore calculateBasic(QuotationInfo info) {
    final fields = <String, bool>{};

    // Quotation number pattern (XX-digits)
    final numberPattern = RegExp(r'^[A-Z]{2}-\d{6,}$');

    // 1. Check quotation number first - no number = 0 score
    final hasValidNumber = info.quotationNumber != null &&
        info.quotationNumber!.isNotEmpty &&
        numberPattern.hasMatch(info.quotationNumber!);
    fields['quotationNumber'] = hasValidNumber;

    if (!hasValidNumber) {
      // No quotation number = 0 score
      return ExtractionScore(
        score: 0.0,
        fields: fields,
        mathValid: false,
        itemCount: info.items.length,
        itemsMatched: 0,
        summary: 'No quotation number',
      );
    }

    // Has quotation number, start with base 40 points
    int points = 40;

    // 2. Total: +25 if recognized and > 100
    final hasValidTotal = info.total != null && info.total! > 100;
    fields['total'] = hasValidTotal;
    if (hasValidTotal) points += 25;

    // 3. Items: base 10 + 3 per valid item (max 25 total)
    final validItems = info.items.where((item) => item.amount > 0).length;
    final hasItems = info.items.isNotEmpty;
    fields['items'] = hasItems;
    if (hasItems) {
      points += 10; // Base for having items
      points += (validItems * 3).clamp(0, 15); // +3 per item, max 15
    }

    // 4. Subtotal: +10 if recognized and > 100
    final hasValidSubtotal = info.subtotal != null && info.subtotal! > 100;
    fields['subtotal'] = hasValidSubtotal;
    if (hasValidSubtotal) points += 10;

    // Math validation (not scored, just for display)
    bool mathValid = false;
    if (info.subtotal != null && info.tax != null && info.total != null) {
      mathValid = (info.subtotal! + info.tax!) == info.total!;
    }
    fields['mathValid'] = mathValid;

    final score = points / 100.0;
    final summary = '$points/100';

    return ExtractionScore(
      score: score,
      fields: fields,
      mathValid: mathValid,
      itemCount: info.items.length,
      itemsMatched: validItems,
      summary: summary,
    );
  }
}
