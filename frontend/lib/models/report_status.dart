/// Mirrors the `reports.status` values used by the backend's state machine
/// (see numberspeaks-backend README / reports_service.py). Not invented —
/// these are exactly the values the backend writes:
/// uploaded -> processing -> validated|failed -> completed|failed
enum ReportStatus {
  uploaded,
  processing,
  validated,
  completed,
  failed,
  unknown;

  static ReportStatus fromString(String? value) {
    switch (value) {
      case 'uploaded':
        return ReportStatus.uploaded;
      case 'processing':
        return ReportStatus.processing;
      case 'validated':
        return ReportStatus.validated;
      case 'completed':
        return ReportStatus.completed;
      case 'failed':
        return ReportStatus.failed;
      default:
        return ReportStatus.unknown;
    }
  }

  String get label {
    switch (this) {
      case ReportStatus.uploaded:
        return 'Uploaded';
      case ReportStatus.processing:
        return 'Processing';
      case ReportStatus.validated:
        return 'Validated';
      case ReportStatus.completed:
        return 'Completed';
      case ReportStatus.failed:
        return 'Failed';
      case ReportStatus.unknown:
        return 'Unknown';
    }
  }
}
