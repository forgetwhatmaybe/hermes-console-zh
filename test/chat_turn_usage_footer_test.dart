import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/theme/app_theme.dart';
import 'package:hermes_android/core/widgets/chat/chat_message_frame.dart';
import 'package:hermes_android/l10n/app_localizations.dart';
import 'package:intl/intl.dart' show NumberFormat;

/// Codex P2/P3：消息页脚（时间 + 本轮用量）在窄屏、大字号下必须
/// 折到下一行，并且千位分隔符要跟随各自语言的约定。
Widget _host(
  Widget child, {
  double width = 320,
  double textScale = 1.3,
  Locale locale = const Locale('es'),
}) => MaterialApp(
  localizationsDelegates: Strings.localizationsDelegates,
  supportedLocales: Strings.supportedLocales,
  locale: locale,
  theme: AppTheme.hermesRedDark,
  home: MediaQuery(
    data: MediaQueryData(
      size: Size(width, 640),
      textScaler: TextScaler.linear(textScale),
    ),
    child: Scaffold(
      body: SizedBox(width: width, child: child),
    ),
  ),
);

/// 与真实页脚一致：10 pt 等宽字体，上边距与时间相同。
Widget _footerUsage() => const Padding(
  padding: EdgeInsets.only(top: 3),
  child: Text(
    '1.234 tokens · 56 tok/s',
    style: TextStyle(fontSize: 10, fontFamily: 'monospace'),
  ),
);

void main() {
  testWidgets('el pie no desborda a 320 dp con texto al 130 %', (tester) async {
    await tester.pumpWidget(
      _host(
        ChatMessageFrame(
          selectable: false,
          time: '23:59',
          trailing: _footerUsage(),
          children: const [Text('respuesta')],
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('23:59'), findsOneWidget);
    expect(find.textContaining('tok/s'), findsOneWidget);
  });

  testWidgets('con sitio, la hora va antes que el uso del turno', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        ChatMessageFrame(
          selectable: false,
          time: '23:59',
          trailing: _footerUsage(),
          children: const [Text('respuesta')],
        ),
        width: 480,
        textScale: 1,
      ),
    );

    expect(tester.takeException(), isNull);
    final time = tester.getTopLeft(find.text('23:59'));
    final usage = tester.getTopLeft(find.textContaining('tok/s'));
    expect(usage.dx, greaterThan(time.dx), reason: 'time=$time usage=$usage');
    expect(usage.dy, time.dy, reason: 'time=$time usage=$usage');
  });

  test('los miles usan el separador de cada idioma', () {
    expect(NumberFormat.decimalPattern('es').format(1234), '1.234');
    expect(NumberFormat.decimalPattern('en').format(1234), '1,234');
    expect(NumberFormat.decimalPattern('zh').format(1234), '1,234');
  });
}
