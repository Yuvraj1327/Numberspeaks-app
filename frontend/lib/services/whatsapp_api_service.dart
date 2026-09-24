import '../core/api_client.dart';
import '../models/whatsapp_send_summary.dart';

/// Talks to the /reports/{id}/send-whatsapp endpoint (Step 7 of the
/// backend). No WhatsApp API logic lives here or anywhere in this app —
/// this only calls the existing FastAPI endpoint and parses its response.
class WhatsAppApiService {
  WhatsAppApiService(this._client);

  final ApiClient _client;

  /// POST /api/v1/reports/{report_id}/send-whatsapp?force=..
  Future<WhatsAppSendSummary> sendWhatsAppForReport(
    String reportId, {
    bool force = false,
  }) async {
    final json = await _client.post(
      '/reports/$reportId/send-whatsapp${force ? '?force=true' : ''}',
    );
    return WhatsAppSendSummary.fromJson(json);
  }
}
