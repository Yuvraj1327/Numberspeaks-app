/// Mirrors `WhatsAppMessageResult` (app/schemas/whatsapp.py). `status` is one
/// of exactly: "sent" | "failed" | "skipped_already_sent" | "skipped_no_number"
/// | "skipped_no_bonus" — taken verbatim from the backend, never re-derived
/// client-side.
class WhatsAppMessageResult {
  final String bonusResultId;
  final String userId;
  final String userName;
  final String? whatsappNumber;
  final String status;
  final String? message;
  final String? providerMessageId;
  final String? error;

  const WhatsAppMessageResult({
    required this.bonusResultId,
    required this.userId,
    required this.userName,
    required this.whatsappNumber,
    required this.status,
    required this.message,
    required this.providerMessageId,
    required this.error,
  });

  bool get isSent => status == 'sent';
  bool get isAlreadySent => status == 'skipped_already_sent';
  bool get isFailed => status == 'failed';
  bool get isSkippedNoNumber => status == 'skipped_no_number';
  bool get isSkippedNoBonus => status == 'skipped_no_bonus';

  factory WhatsAppMessageResult.fromJson(Map<String, dynamic> json) {
    return WhatsAppMessageResult(
      bonusResultId: json['bonus_result_id'] as String? ?? '',
      userId: json['user_id'] as String? ?? '',
      userName: json['user_name'] as String? ?? '',
      whatsappNumber: json['whatsapp_number'] as String?,
      status: json['status'] as String? ?? '',
      message: json['message'] as String?,
      providerMessageId: json['provider_message_id'] as String?,
      error: json['error'] as String?,
    );
  }
}

/// Mirrors `WhatsAppSendSummary` (app/schemas/whatsapp.py) — the response of
/// POST /api/v1/reports/{report_id}/send-whatsapp.
class WhatsAppSendSummary {
  final String reportId;
  final int totalEligible;
  final int sentCount;
  final int failedCount;
  final int skippedCount;
  final List<WhatsAppMessageResult> results;

  const WhatsAppSendSummary({
    required this.reportId,
    required this.totalEligible,
    required this.sentCount,
    required this.failedCount,
    required this.skippedCount,
    required this.results,
  });

  factory WhatsAppSendSummary.fromJson(Map<String, dynamic> json) {
    return WhatsAppSendSummary(
      reportId: json['report_id'] as String? ?? '',
      totalEligible: json['total_eligible'] as int? ?? 0,
      sentCount: json['sent_count'] as int? ?? 0,
      failedCount: json['failed_count'] as int? ?? 0,
      skippedCount: json['skipped_count'] as int? ?? 0,
      results: (json['results'] as List<dynamic>? ?? [])
          .map((e) => WhatsAppMessageResult.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
