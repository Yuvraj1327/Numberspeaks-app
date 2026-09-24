/// Mirrors the backend's `ExtractedRecord` (app/schemas/report.py) exactly —
/// same field names, same nullability. One row from the report PDF, before
/// or after validation, as extracted (never modified client-side).
class ExtractedRecord {
  final int? no;
  final String userName;
  final String? level;
  final double casinoPts;
  final double sportPts;
  final double thirdPartyPts;
  final double profitLoss;
  final String? ptype;
  final int? sourcePage;

  const ExtractedRecord({
    required this.no,
    required this.userName,
    required this.level,
    required this.casinoPts,
    required this.sportPts,
    required this.thirdPartyPts,
    required this.profitLoss,
    required this.ptype,
    required this.sourcePage,
  });

  factory ExtractedRecord.fromJson(Map<String, dynamic> json) {
    return ExtractedRecord(
      no: json['no'] as int?,
      userName: json['user_name'] as String? ?? '',
      level: json['level'] as String?,
      casinoPts: _toDouble(json['casino_pts']),
      sportPts: _toDouble(json['sport_pts']),
      thirdPartyPts: _toDouble(json['third_party_pts']),
      profitLoss: _toDouble(json['profit_loss']),
      ptype: json['ptype'] as String?,
      sourcePage: json['source_page'] as int?,
    );
  }
}

double _toDouble(dynamic value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}
