/// Named routes for the whole app. Kept as plain string constants (no
/// external routing package) since the navigation graph is small — see
/// README "Navigation flow" for the full diagram.
///
/// [home] is [MainShell] — the bottom-nav shell hosting the Dashboard,
/// Reports, Results, Account and Settings tabs. Everything else is pushed
/// on top of it.
///
/// Upload -> [review] (check / correct the extracted rows, add referrals)
/// -> [processing] (the admin confirms; validate + calculate) -> [results].
class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String home = '/home';
  static const String upload = '/upload';
  static const String review = '/review';
  static const String processing = '/processing';
  static const String results = '/results';
  static const String userDetail = '/user-detail';
  static const String referrals = '/referrals';
  static const String users = '/users';
  static const String rates = '/rates';
  static const String terms = '/terms';
}
