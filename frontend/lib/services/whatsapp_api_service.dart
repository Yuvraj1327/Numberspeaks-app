import '../core/api_client.dart';

/// What the backend answers after recording that WhatsApp was opened.
class WhatsAppOpenedRecord {
  final String status;
  final String? initiatedAt;
  final int count;

  const WhatsAppOpenedRecord({required this.status, required this.initiatedAt, required this.count});

  factory WhatsAppOpenedRecord.fromJson(Map<String, dynamic> json) {
    final rawCount = json['whatsapp_initiated_count'];
    return WhatsAppOpenedRecord(
      status: json['whatsapp_status'] as String? ?? 'initiated',
      initiatedAt: json['whatsapp_initiated_at'] as String?,
      count: rawCount is num ? rawCount.toInt() : 0,
    );
  }
}

/// No WhatsApp message is ever sent through an API. The app opens a `wa.me`
/// link on the admin's own device, and — only after that link was really
/// opened — tells the backend so it can record "opened/initiated". This is
/// NOT a delivery receipt.
class WhatsAppApiService {
  WhatsAppApiService(this._client);

  final ApiClient _client;

  /// POST /api/v1/reports/{report_id}/results/{bonus_result_id}/whatsapp-initiated
  Future<WhatsAppOpenedRecord> recordOpened({
    required String reportId,
    required String bonusResultId,
    required String whatsappNumber,
    required String message,
  }) async {
    final json = await _client.post(
      '/reports/$reportId/results/$bonusResultId/whatsapp-initiated',
      body: {'whatsapp_number': whatsappNumber, 'message': message},
    );
    return WhatsAppOpenedRecord.fromJson(json);
  }
}
