import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/api_client.dart';
import 'package:numberspeaks_app/core/app_theme.dart';
import 'package:numberspeaks_app/models/bonus_result.dart';
import 'package:numberspeaks_app/repositories/auth_repository.dart';
import 'package:numberspeaks_app/repositories/report_repository.dart';
import 'package:numberspeaks_app/routing/app_router.dart';
import 'package:numberspeaks_app/routing/app_routes.dart';
import 'package:numberspeaks_app/screens/login_screen.dart';
import 'package:numberspeaks_app/screens/main_shell.dart';
import 'package:numberspeaks_app/screens/user_detail_screen.dart';
import 'package:numberspeaks_app/services/bonus_api_service.dart';
import 'package:numberspeaks_app/services/referrals_api_service.dart';
import 'package:numberspeaks_app/services/reports_api_service.dart';
import 'package:numberspeaks_app/services/settings_api_service.dart';
import 'package:numberspeaks_app/services/users_api_service.dart';
import 'package:numberspeaks_app/services/whatsapp_api_service.dart';
import 'package:provider/provider.dart';

/// Layout audit: every screen is rendered with realistic (long names, large
/// amounts) data at phone, small-phone, tablet and desktop sizes and at an
/// enlarged system font; any RenderFlex overflow or other layout exception
/// fails the test.
class _FakeAuth extends ChangeNotifier implements AuthRepository {
  @override
  bool isLoading = false;
  @override
  String? lastError;
  @override
  bool get isLoggedIn => true;
  @override
  String? get userEmail => 'a.very.long.administrator.email.address@example-company.com';
  @override
  String? get userId => '11111111-2222-3333-4444-555555555555';
  @override
  DateTime? get sessionExpiresAt => DateTime(2030, 1, 1);
  @override
  Future<bool> login({required String email, required String password}) async => true;
  @override
  Future<void> logout() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Map<String, dynamic> _row(int i) => {
      'bonus_result_id': 'b$i',
      'report_id': 'r1',
      'user_id': 'u$i',
      'user_name': i == 0 ? 'A_very_long_user_identifier_number_$i' : 'user$i',
      'whatsapp_number': i.isEven ? '919876543210' : null,
      'level': '3',
      'casino_pts': 1234567.5,
      'sport_pts': 98765.25,
      'third_party_pts': 0,
      'profit_loss': i.isEven ? -1234567.89 : 4567.8,
      'ptype': 'Agent',
      'calculation_status': 'calculated',
      'personal_adjustment': 37037.04,
      'referral_adjustment': -1234.5,
      'previous_balance': -99999.99,
      'final_balance': 35802.54,
      'payable_bonus': i.isEven ? 35802.54 : 0,
      'carry_forward_balance': i.isEven ? 0 : -500.5,
      'whatsapp_status': 'not_sent',
      'whatsapp_initiated_count': 0,
    };

class _Backend implements HttpClientAdapter {
  dynamic _body(RequestOptions o) {
    final p = o.path;
    if (RegExp(r'/reports/[^/]+/results/[^/]+$').hasMatch(p)) return _row(0);
    if (p.endsWith('/results')) return [for (var i = 0; i < 6; i++) _row(i)];
    if (p.endsWith('/referrals')) {
      return [
        {
          'entry_id': 'e1', 'report_id': 'r1', 'referrer_user_id': 'u0', 'referrer_name': 'A_very_long_user_identifier_number_0',
          'referred_user_id': 'u1', 'referred_name': 'user1', 'rate': 0.1, 'amount': 1234.5, 'adjustment': 123.45,
        }
      ];
    }
    if (p.endsWith('/history')) {
      return {
        'user': {'user_id': 'u0', 'name': 'A_very_long_user_identifier_number_0', 'level': '3', 'whatsapp_number': '919876543210', 'carry_forward_balance': -500.5},
        'history': [
          {
            'history_id': 'h1', 'run_id': 'x', 'report_id': 'r1', 'report_file_name': 'Party Profit Loss (1) - long file name.pdf',
            'calculated_at': '2026-10-02T10:00:05+00:00', 'profit_loss': -1234567.89, 'personal_rate': 0.03,
            'personal_adjustment': 37037.04, 'referral_adjustment': 0, 'previous_balance': -99999.99,
            'final_balance': 35802.54, 'payable_bonus': 35802.54, 'carry_forward_balance': 0,
          }
        ],
      };
    }
    if (RegExp(r'/users/[^/]+$').hasMatch(p)) return {'user_id': 'u0', 'name': 'A_very_long_user_identifier_number_0', 'level': '3', 'whatsapp_number': '919876543210'};
    if (p.endsWith('/users')) {
      return [
        for (var i = 0; i < 4; i++)
          {'user_id': 'u$i', 'name': i == 0 ? 'A_very_long_user_identifier_number_0' : 'user$i', 'level': '3', 'whatsapp_number': i.isEven ? '919876543210' : null, 'carry_forward_balance': -500.5}
      ];
    }
    if (p.endsWith('/settings')) return {'personal_rate': 0.03, 'referral_rate': 0.1};
    if (RegExp(r'/reports/[^/]+$').hasMatch(p)) return _report('r1', 'completed');
    if (p.endsWith('/reports')) {
      return [_report('r1', 'completed'), _report('r2', 'processing'), _report('r3', 'failed'), _report('r4', 'validated')];
    }
    return {};
  }

  static Map<String, dynamic> _report(String id, String status) => {
        'report_id': id,
        'file_name': 'Party Profit Loss (1) - a rather long report file name for a phone.pdf',
        'status': status,
        'user_count': 1234,
        'payable_user_count': 1000,
        'total_payable': 98765432.1,
        'uploaded_at': '2026-10-02T10:00:00+00:00',
        'calculated_at': '2026-10-02T10:00:05+00:00',
      };

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? r, Future<void>? c) async =>
      ResponseBody.fromString(jsonEncode(_body(o)), 200, headers: {Headers.contentTypeHeader: ['application/json']});

  @override
  void close({bool force = false}) {}
}

const _sizes = <String, Size>{
  'small phone 320x568': Size(320, 568),
  'phone 360x740': Size(360, 740),
  'phone 390x844': Size(390, 844),
  'large phone 430x932': Size(430, 932),
  'tablet 768x1024': Size(768, 1024),
  'desktop 1280x800': Size(1280, 800),
};

void main() {
  late ReportRepository repo;

  setUp(() {
    dotenv.testLoad(fileInput: '');
    final api = ApiClient(dio: Dio(BaseOptions(baseUrl: 'http://fake/api/v1'))..httpClientAdapter = _Backend());
    repo = ReportRepository(
      reportsApi: ReportsApiService(api),
      bonusApi: BonusApiService(api),
      referralsApi: ReferralsApiService(api),
      usersApi: UsersApiService(api),
      settingsApi: SettingsApiService(api),
      whatsappApi: WhatsAppApiService(api),
    );
  });

  final screens = <String, Widget Function()>{
    'login': () => const LoginScreen(),
    'shell (dashboard)': () => const MainShell(),
  };

  final routes = <String, RouteSettings>{
    'upload': const RouteSettings(name: AppRoutes.upload),
    'review': const RouteSettings(name: AppRoutes.review, arguments: 'r1'),
    'processing': const RouteSettings(name: AppRoutes.processing, arguments: 'r1'),
    'results': const RouteSettings(name: AppRoutes.results, arguments: 'r1'),
    'referrals': const RouteSettings(name: AppRoutes.referrals, arguments: 'r1'),
    'users': const RouteSettings(name: AppRoutes.users),
    'rates': const RouteSettings(name: AppRoutes.rates),
    'terms': const RouteSettings(name: AppRoutes.terms),
    'user detail': RouteSettings(
      name: AppRoutes.userDetail,
      arguments: UserDetailArgs(
        userId: 'u0',
        userName: 'A_very_long_user_identifier_number_0',
        reportId: 'r1',
        initialResult: BonusResult.fromJson(_row(0)),
      ),
    ),
  };

  Future<List<String>> audit(WidgetTester tester, Size size, double textScale, Future<void> Function() act) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString();
      final where = RegExp(r'lib/[\w/]+\.dart:\d+').firstMatch(text)?.group(0) ?? '?';
      errors.add('${details.exceptionAsString().split('\n').first} [$where]'); 
    };
    try {
      await act();
    } finally {
      FlutterError.onError = previous;
    }
    return errors;
  }

  Widget host(Widget child, double textScale) => MultiProvider(
        providers: [
          ChangeNotifierProvider<ReportRepository>.value(value: repo),
          ChangeNotifierProvider<AuthRepository>.value(value: _FakeAuth()),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          builder: (context, c) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: c!,
          ),
          home: child,
        ),
      );

  for (final scale in [1.0, 1.4]) {
    for (final size in _sizes.entries) {
      for (final s in screens.entries) {
        testWidgets('${s.key} @ ${size.key} x$scale', (tester) async {
          final errors = await audit(tester, size.value, scale, () async {
            await tester.pumpWidget(host(s.value(), scale));
            await tester.pumpAndSettle();
          });
          expect(errors, isEmpty);
        });
      }
      for (final r in routes.entries) {
        testWidgets('${r.key} @ ${size.key} x$scale', (tester) async {
          final errors = await audit(tester, size.value, scale, () async {
            await tester.pumpWidget(host(
              Builder(builder: (context) => Navigator(onGenerateRoute: (_) => AppRouter.onGenerateRoute(r.value))),
              scale,
            ));
            await tester.pumpAndSettle();
          });
          expect(errors, isEmpty);
        });
      }
    }
  }

  // Sheets and dialogs: small phone, large font, on-screen keyboard open.
  for (final scale in [1.0, 1.4]) {
    for (final size in const [Size(320, 568), Size(390, 844)]) {
      Future<List<String>> withKeyboard(WidgetTester tester, Widget screen, Future<void> Function() open) =>
          audit(tester, size, scale, () async {
            addTearDown(tester.view.resetViewInsets);
            await tester.pumpWidget(host(screen, scale));
            await tester.pumpAndSettle();
            await open();
            await tester.pumpAndSettle();
            // The keyboard comes up once the sheet / dialog is open.
            tester.view.viewInsets = const FakeViewPadding(bottom: 280);
            await tester.pumpAndSettle();
          });

      testWidgets('review edit sheet + keyboard @ ${size.width}x${size.height} x$scale', (tester) async {
        final errors = await withKeyboard(
          tester,
          const Navigator(onGenerateRoute: _reviewRoute),
          () async {
            await tester.tap(find.byTooltip('Correct this row').first);
          },
        );
        expect(errors, isEmpty);
        expect(find.text('Save'), findsOneWidget);
      });

      testWidgets('whatsapp number dialog + keyboard @ ${size.width}x${size.height} x$scale', (tester) async {
        final errors = await withKeyboard(
          tester,
          const Navigator(onGenerateRoute: _resultsRoute),
          () async {
            await tester.ensureVisible(find.byTooltip('Edit number').first);
            await tester.tap(find.byTooltip('Edit number').first);
          },
        );
        expect(errors, isEmpty);
      });
    }
  }
}

Route<dynamic> _reviewRoute(RouteSettings _) =>
    AppRouter.onGenerateRoute(const RouteSettings(name: AppRoutes.review, arguments: 'r1'));
Route<dynamic> _resultsRoute(RouteSettings _) =>
    AppRouter.onGenerateRoute(const RouteSettings(name: AppRoutes.results, arguments: 'r1'));
