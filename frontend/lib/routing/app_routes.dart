/// Named routes for the whole app. Kept as plain string constants (no
/// external routing package) since the navigation graph is small and
/// linear — see README "Navigation flow" for the full diagram.
class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String dashboard = '/dashboard';
  static const String upload = '/upload';
  static const String processing = '/processing';
  static const String results = '/results';
  static const String userDetail = '/user-detail';
}
