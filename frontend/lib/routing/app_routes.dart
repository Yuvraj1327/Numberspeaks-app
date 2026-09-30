/// Named routes for the whole app. Kept as plain string constants (no
/// external routing package) since the navigation graph is small — see
/// README "Navigation flow" for the full diagram.
///
/// [home] is [MainShell] — the bottom-nav shell hosting the Dashboard,
/// Reports, Results, Account and Settings tabs. Everything else is pushed
/// on top of it (upload/processing flow, a specific report's results,
/// user detail, terms).
class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String home = '/home';
  static const String upload = '/upload';
  static const String processing = '/processing';
  static const String results = '/results';
  static const String userDetail = '/user-detail';
  static const String terms = '/terms';
}
