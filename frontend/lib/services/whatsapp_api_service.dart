import '../core/api_client.dart';

/// What the backend answers after a send attempt.
class WhatsAppSendResult {
  final String status; // 'sent' | 'failed' | 'sending'
  final String? error;
  final String? sentAt;

  const WhatsAppSendResult({required this.status, required this.error, required this.sentAt});

  factory WhatsAppSendResult.fromJson(Map<String, dynamic> json) => WhatsAppSendResult(
        status: json['send_status'] as String? ?? 'failed',
        error: json['send_error'] as String?,
        sentAt: json['sent_at'] as String?,
      );
}

class BulkSkipped {
  final String? userName;
  final String reason;
  const BulkSkipped({required this.userName, required this.reason});
}

class BulkFailure {
  final String? userName;
  final String status; // 'failed' | 'unknown'
  final String? error;
  const BulkFailure({required this.userName, required this.status, required this.error});
}

/// Progress of a bulk run, as recorded by the backend.
class BulkProgress {
  final String batchId;
  final String status; // 'running' | 'completed' | 'interrupted'
  final int totalSelected;
  final int queued;
  final int providerQueued;
  final int sent;
  final int failed;
  final int unknown;
  final int pending;
  final List<BulkSkipped> skipped;
  final List<BulkFailure> problems;

  const BulkProgress({
    required this.batchId,
    required this.status,
    required this.totalSelected,
    required this.queued,
    required this.providerQueued,
    required this.sent,
    required this.failed,
    required this.unknown,
    required this.pending,
    required this.skipped,
    required this.problems,
  });

  bool get isRunning => status == 'running';
  int get done => providerQueued + sent + failed + unknown;

  factory BulkProgress.fromJson(Map<String, dynamic> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return BulkProgress(
      batchId: j['batch_id'] as String? ?? '',
      status: j['status'] as String? ?? 'running',
      totalSelected: n('total_selected'),
      queued: n('queued'),
      providerQueued: n('provider_queued'),
      sent: n('sent'),
      failed: n('failed'),
      unknown: n('unknown'),
      pending: n('pending'),
      skipped: [
        for (final s in (j['skipped'] as List? ?? const []))
          BulkSkipped(userName: (s as Map)['user_name'] as String?, reason: s['reason'] as String? ?? ''),
      ],
      problems: [
        for (final i in (j['items'] as List? ?? const []))
          BulkFailure(
            userName: (i as Map)['user_name'] as String?,
            status: i['send_status'] as String? ?? 'failed',
            error: i['send_error'] as String?,
          ),
      ],
    );
  }
}

/// Sends a bonus message through the backend's No1API integration. The app
/// sends only the (reviewed) message text: the backend looks up the saved
/// number itself and holds every credential, so nothing secret is in Flutter.
class WhatsAppApiService {
  WhatsAppApiService(this._client);

  final ApiClient _client;

  /// POST /api/v1/reports/{report_id}/results/{bonus_result_id}/whatsapp-send
  Future<WhatsAppSendResult> send({
    required String reportId,
    required String bonusResultId,
    required String message,
    bool acknowledgeUnknown = false,
  }) async {
    final json = await _client.post(
      '/reports/$reportId/results/$bonusResultId/whatsapp-send',
      body: {'message': message, if (acknowledgeUnknown) 'acknowledge_unknown': true},
      // The provider call happens inside this request.
      receiveTimeout: const Duration(seconds: 60),
    );
    return WhatsAppSendResult.fromJson(json);
  }

  /// POST /api/v1/reports/{id}/whatsapp-bulk — starts a confirmed background run.
  Future<BulkProgress> startBulk({
    required String reportId,
    required List<({String bonusResultId, String message})> items,
  }) async {
    final json = await _client.post(
      '/reports/$reportId/whatsapp-bulk',
      body: {
        'confirmed': true,
        'items': [
          for (final i in items) {'bonus_result_id': i.bonusResultId, 'message': i.message},
        ],
      },
    );
    return BulkProgress.fromJson(json);
  }

  Future<BulkProgress> bulkProgress(String reportId, String batchId) async {
    return BulkProgress.fromJson(await _client.get('/reports/$reportId/whatsapp-bulk/$batchId'));
  }

  /// Whether a test message was already accepted (required before bulk).
  Future<bool> testPassed() async {
    final json = await _client.get('/whatsapp/test-status');
    return json['tested'] == true;
  }

  /// Sends one message to an authorized test number. Returns (status, error).
  Future<(String, String?)> sendTest({required String number, required String message}) async {
    final json = await _client.post(
      '/whatsapp/test-send',
      body: {'whatsapp_number': number, 'message': message, 'authorized': true},
      receiveTimeout: const Duration(seconds: 60),
    );
    return (json['status'] as String? ?? 'failed', json['error'] as String?);
  }
}
