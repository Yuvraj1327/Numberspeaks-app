import '../core/api_client.dart';
import '../models/bonus_calculation_summary.dart';
import '../models/bonus_result.dart';

/// Talks to the /reports/{id}/calculate-bonus and /results endpoints
/// (Steps 5-6 of the backend). The bonus formula itself never runs here —
/// this only calls the backend and parses what it returns.
class BonusApiService {
  BonusApiService(this._client);

  final ApiClient _client;

  /// POST /api/v1/reports/{report_id}/calculate-bonus
  Future<BonusCalculationSummary> calculateBonus(String reportId) async {
    final json = await _client.post('/reports/$reportId/calculate-bonus');
    return BonusCalculationSummary.fromJson(json);
  }

  /// GET /api/v1/reports/{report_id}/results
  Future<List<BonusResult>> getResults(String reportId) async {
    final list = await _client.getList('/reports/$reportId/results');
    return list.map((e) => BonusResult.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// GET /api/v1/reports/{report_id}/results/{user_id}
  Future<BonusResult> getUserResult(String reportId, String userId) async {
    final json = await _client.get('/reports/$reportId/results/$userId');
    return BonusResult.fromJson(json);
  }
}
