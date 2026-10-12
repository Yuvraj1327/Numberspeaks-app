import 'package:flutter/material.dart';

import '../routing/app_routes.dart';

/// What action makes sense for a report given its last known `status`
/// (exactly the backend's own state-machine value, never guessed). Shared
/// by the Dashboard and Reports tabs so a report card behaves identically
/// wherever it's shown.
enum ReportNextActionKind { reviewAndCalculate, viewResults }

class ReportNextAction {
  final ReportNextActionKind kind;
  final String label;
  final IconData icon;

  const ReportNextAction({required this.kind, required this.label, required this.icon});

  /// The route this action pushes to, given the report id.
  String get route =>
      kind == ReportNextActionKind.viewResults ? AppRoutes.results : AppRoutes.review;
}

ReportNextAction resolveNextAction(String? status) {
  switch (status) {
    case 'completed':
      return const ReportNextAction(
        kind: ReportNextActionKind.viewResults,
        label: 'View Results',
        icon: Icons.list_alt_outlined,
      );
    default:
      // uploaded / processing / validated / failed: the admin reviews the
      // extracted rows, then confirms the calculation.
      return const ReportNextAction(
        kind: ReportNextActionKind.reviewAndCalculate,
        label: 'Review & Calculate',
        icon: Icons.fact_check_outlined,
      );
  }
}
