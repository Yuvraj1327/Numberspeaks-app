import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:numberspeaks_app/core/app_theme.dart';
import 'package:numberspeaks_app/widgets/figures.dart';
import 'package:numberspeaks_app/widgets/user_whatsapp_button.dart';

Color? colorOf(WidgetTester t, String text) => t.widget<Text>(find.text(text)).style?.color;

void main() {
  testWidgets('profit/loss and bonus figures are formatted and colour coded', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [
        Figure.profitLoss(12500),
        Figure.profitLoss(-2000),
        Figure.profitLoss(0),
        Figure.signed(30),
        Figure.signed(-300),
        Figure.signed(null),
        Figure.payable(1250.5),
        Figure.payable(0),
      ]),
    ));
    expect(colorOf(tester, '+12,500'), AppTheme.success);
    expect(colorOf(tester, '-2,000'), AppTheme.danger);
    expect(colorOf(tester, '0'), Colors.black54);
    expect(colorOf(tester, '+30.00'), AppTheme.success);
    expect(colorOf(tester, '-300.00'), AppTheme.danger);
    expect(find.text('—'), findsOneWidget);
    expect(colorOf(tester, '₹1,250.50'), AppTheme.success);
    expect(colorOf(tester, '₹0.00'), Colors.black45);
  });

  testWidgets("this week's win/loss is bold and colour coded; legacy null is a dash", (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [Figure.signedBig(-10), Figure.signedBig(50), Figure.signedBig(null)]),
    ));
    expect(colorOf(tester, '-10.00'), AppTheme.danger);
    expect(colorOf(tester, '+50.00'), AppTheme.success);
    expect(tester.widget<Text>(find.text('+50.00')).style?.fontWeight, FontWeight.w900);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('one WhatsApp button offers exactly Auto Send and Manual Send', (tester) async {
    WhatsAppMode? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: WhatsAppMenuButton(onSelected: (m) => picked = m)),
    ));
    expect(find.text('WhatsApp'), findsOneWidget);
    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();
    expect(find.text('Auto Send'), findsOneWidget);
    expect(find.text('Manual Send'), findsOneWidget);
    await tester.tap(find.text('Manual Send'));
    await tester.pumpAndSettle();
    expect(picked, WhatsAppMode.manual);
  });

  testWidgets('disabled WhatsApp button opens no menu', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: WhatsAppMenuButton(enabled: false, onSelected: (_) {})),
    ));
    await tester.tap(find.text('WhatsApp'));
    await tester.pumpAndSettle();
    expect(find.text('Auto Send'), findsNothing);
  });
}
