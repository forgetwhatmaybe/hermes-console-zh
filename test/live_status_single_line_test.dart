// Una sola línea de estado por pantalla, en el orden
// texto de la respuesta → línea de estado → pie de tokens → compositor. Antes
// había dos copias de más (el dock bajo el compositor y el título vivo dentro
// de la cabecera de la burbuja).
//
// El harness copia el de test/chat_screen_test.dart: ChatScreen resuelve
// `HermesAppState` en didChangeDependencies, así que no se puede montar aislado.
// Se monta el HermesApp real con los canales de plugin mockeados y la sesión
// pre-adjuntada al ActiveChatService, de modo que el chat reusa ese ActiveChat y
// no hay red real.
//
// No se usa `pumpAndSettle` (quedan futuros y timers vivos): se avanza con
// `pump()` de duración fija.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/active_chat_service.dart';
import 'package:hermes_android/core/services/app_lock.dart';
import 'package:hermes_android/core/services/approval_policy.dart';
import 'package:hermes_android/core/services/chat_draft_store.dart';
import 'package:hermes_android/core/services/compression_restore_store.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/font_size_service.dart';
import 'package:hermes_android/core/services/notifications/notification_delivery_store.dart';
import 'package:hermes_android/core/services/notifications/notification_service.dart';
import 'package:hermes_android/core/services/secure_storage.dart';
import 'package:hermes_android/core/services/sftp_transfer_service.dart';
import 'package:hermes_android/core/services/ssh_manager.dart';
import 'package:hermes_android/core/services/ssh_session_service.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/widgets/chat/chat_markdown_body.dart';
import 'package:hermes_android/core/widgets/chat_event_cards.dart';
import 'package:hermes_android/core/widgets/chat_turn_activity.dart';
import 'package:hermes_android/main.dart';

import 'support/recording_desktop_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var secureStore = <String, String>{};
  var draftStoreNamespace = 0;
  var compressionStoreNamespace = 0;
  var foregroundServiceRunning = false;

  SavedConnection conn(String id) => SavedConnection(
    id: id,
    label: 'Test remoto',
    host: '192.168.255.254',
    port: 8642,
    apiKey: 'k',
    // Instancia remota/LAN del fixture, pero cualquier consulta informativa del
    // Dashboard falla de inmediato sin tocar la red pública.
    dashboardUrl: 'http://127.0.0.1:9119',
  );

  Session session() => const Session(
    id: 'sess-test',
    title: 'Conversación de prueba',
    model: 'hermes-agent',
    source: 'mobile',
    messageCount: 0,
    isActive: true,
    preview: '',
    startedAt: 0,
  );

  /// Nunca toca la red real (404 a todo): solo es la red de seguridad.
  ApiClient safeApi() => ApiClient(
    baseUrl: 'http://127.0.0.1:8642',
    apiKey: 'k',
    httpClient: MockClient((_) async => http.Response('not found', 404)),
  );

  void mockChannel(String name) {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(name), (_) async => null);
  }

  setUp(() {
    ChatScreen.resetAssistantRenderPlanCacheForTesting();
    secureStore = <String, String>{};
    foregroundServiceRunning = false;
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (_) async => null);
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args =
                (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
            switch (call.method) {
              case 'write':
                secureStore[args['key'] as String] = args['value'] as String;
                return null;
              case 'read':
                return secureStore[args['key'] as String];
              case 'delete':
                secureStore.remove(args['key'] as String);
                return null;
              case 'readAll':
                return Map<String, String>.from(secureStore);
              case 'containsKey':
                return secureStore.containsKey(args['key'] as String);
            }
            return null;
          },
        );
    mockChannel('dexterous.com/flutter/local_notifications');
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_foreground_task/methods'),
          (call) async {
            switch (call.method) {
              case 'isRunningService':
                return foregroundServiceRunning;
              case 'startService':
              case 'restartService':
                foregroundServiceRunning = true;
                return null;
              case 'stopService':
                foregroundServiceRunning = false;
                return null;
              case 'attachedActivity':
                return true;
            }
            return null;
          },
        );
    mockChannel('flutter_foreground_task/background');
  });

  /// Monta el HermesApp real (saltando onboarding) y empuja ChatScreen sobre su
  /// Navigator con la sesión ya adjunta.
  Future<ActiveChat> pumpChat(
    WidgetTester tester, {
    List<Map<String, dynamic>> messages = const [],
    HermesDesktopGateway? desktopGateway,
    SavedConnection? connection,
    Session? sessionOverride,
  }) async {
    // El test está escrito contra las cadenas i18n en español.
    tester.platformDispatcher.localesTestValue = [const Locale('es')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);

    SharedPreferences.setMockInitialValues({'onboarding_done': true});
    final prefs = await SharedPreferences.getInstance();
    final connManager = await ConnectionManager.create(prefs);
    final draftStore = ChatDraftStore(
      prefs,
      mutationNamespaceForTesting: 'live-status-${++draftStoreNamespace}',
    );
    final sec = SecureStorage();
    final activeChats = ActiveChatService(
      compressionRestoreStore: CompressionRestoreStore(
        storage: FlutterSecureCompressionRestoreStorage(),
        mutationNamespaceForTesting:
            'live-status-compression-${++compressionStoreNamespace}',
      ),
    );
    addTearDown(activeChats.dispose);
    final targetConnection = connection ?? conn('conn-live-status');
    final targetSession = sessionOverride ?? session();

    // Pre-adjunta la sesión ya cargada: ChatScreen reusa este chat y no dispara
    // la recarga de red.
    final chat = activeChats.attach(
      connection: targetConnection,
      sessionId: targetSession.id,
      logicalSessionId: targetSession.logicalId,
      sessionTitle: targetSession.displayTitle,
      sessionProfile: targetSession.profile,
      api: safeApi(),
      desktopGateway: desktopGateway,
      disableForegroundKeepAlive: desktopGateway != null,
      transcriptPageSizeForTesting: 120,
    );
    chat.internalMessagesForTesting = List<Map<String, dynamic>>.from(messages);
    chat.messagesLoaded = true;

    final notifications = NotificationService(
      prefs,
      deliveryStore: NotificationDeliveryStore(),
    );
    await tester.pumpWidget(
      HermesApp(
        connManager: connManager,
        appLock: AppLockService(prefs),
        approvalPolicy: ApprovalPolicyService(prefs),
        fontSize: FontSizeService(prefs),
        sshManager: SshManager(sec, connManager),
        sftpTransfers: SftpTransferService(
          SshManager(sec, connManager),
          NotificationService(prefs),
        ),
        sshSessions: SshSessionService(SshManager(sec, connManager)),
        notifications: notifications,
        activeChats: activeChats,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 500));

    final ctx = tester.element(find.byType(Navigator).first);
    Navigator.of(ctx).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          connection: targetConnection,
          session: targetSession,
          draftStoreOverride: draftStore,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    return chat;
  }

  /// Envía «hola» desde el composer y deja asentar el turno vivo.
  Future<void> sendPrompt(WidgetTester tester) async {
    final composer = find.byType(TextField).last;
    await tester.tap(composer);
    await tester.pump();
    tester.testTextInput.enterText('hola');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send')));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// El revelado gradual escribe el texto token a token: hay que darle frames.
  Future<void> letRevealRun(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets(
    'A: en streaming con cuerpo hay una sola línea de estado, bajo el texto y '
    'sobre el pie de tokens',
    (tester) async {
      final gateway = RecordingDesktopGateway();
      await pumpChat(
        tester,
        connection: conn('live-status-a'),
        desktopGateway: gateway,
      );
      await tester.pump(const Duration(milliseconds: 400));

      await sendPrompt(tester);
      gateway.emit('message.delta', {
        'text': 'Revisando el repositorio y sus pruebas.',
      });
      await tester.pump(const Duration(milliseconds: 200));
      gateway.emit('session.usage', {
        'usage': {'output': 128, 'avg_tps': 42},
      });
      await tester.pump(const Duration(milliseconds: 200));
      await letRevealRun(tester);

      // Una sola línea de estado, y ninguna dentro de la cabecera del mensaje
      // (la tarjeta de actividad ya no la repite).
      expect(find.byType(TurnStatusLine), findsOneWidget);
      expect(find.byType(ThinkingTraceCard), findsWidgets);
      expect(
        find.descendant(
          of: find.byType(ThinkingTraceCard),
          matching: find.byType(TurnStatusLine),
        ),
        findsNothing,
      );

      final body = find.byType(ChatMarkdownBlock);
      final token = find.textContaining(RegExp(r'\d+ tokens'));
      expect(body, findsWidgets);
      expect(token, findsOneWidget);

      final bodyRect = tester.getRect(body.first);
      final statusRect = tester.getRect(find.byType(TurnStatusLine));
      final tokenRect = tester.getRect(token);
      final inputRect = tester.getRect(find.byType(TextField).last);

      expect(
        bodyRect.bottom <= statusRect.top,
        isTrue,
        reason:
            'el texto (${bodyRect.bottom}) va sobre el estado '
            '(${statusRect.top})',
      );
      expect(
        statusRect.bottom <= tokenRect.top,
        isTrue,
        reason:
            'el estado (${statusRect.bottom}) va sobre el pie de tokens '
            '(${tokenRect.top})',
      );
      expect(
        tokenRect.bottom <= inputRect.top,
        isTrue,
        reason:
            'el pie de tokens (${tokenRect.bottom}) va sobre la entrada '
            '(${inputRect.top})',
      );

      // Cierra el turno para que los timers del estado vivo se apaguen.
      gateway.emit('message.complete', {'text': 'Listo.'});
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'B: antes del primer token hay una sola línea de estado, sobre el '
    'compositor',
    (tester) async {
      final gateway = RecordingDesktopGateway();
      await pumpChat(
        tester,
        connection: conn('live-status-b'),
        desktopGateway: gateway,
      );
      await tester.pump(const Duration(milliseconds: 400));

      await sendPrompt(tester);

      // Todavía no hay respuesta que medir: el estado es lo único vivo.
      expect(find.byType(ChatMarkdownBlock), findsNothing);
      expect(find.byType(TurnStatusLine), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ThinkingTraceCard),
          matching: find.byType(TurnStatusLine),
        ),
        findsNothing,
      );

      final statusRect = tester.getRect(find.byType(TurnStatusLine));
      final inputRect = tester.getRect(find.byType(TextField).last);
      expect(
        statusRect.bottom <= inputRect.top,
        isTrue,
        reason:
            'el estado (${statusRect.bottom}) va sobre la entrada '
            '(${inputRect.top})',
      );

      gateway.emit('message.complete', {'text': 'Listo.'});
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'C: sin pie de tokens sigue habiendo una sola línea de estado, bajo el '
    'texto',
    (tester) async {
      final gateway = RecordingDesktopGateway();
      await pumpChat(
        tester,
        connection: conn('live-status-c'),
        desktopGateway: gateway,
      );
      await tester.pump(const Duration(milliseconds: 400));

      await sendPrompt(tester);
      // Sin tick de uso: esta corrida no tiene pie de tokens.
      gateway.emit('message.delta', {'text': 'Preparando el resumen.'});
      await tester.pump(const Duration(milliseconds: 200));
      await letRevealRun(tester);

      expect(find.textContaining(RegExp(r'\d+ tokens')), findsNothing);
      expect(find.byType(TurnStatusLine), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ThinkingTraceCard),
          matching: find.byType(TurnStatusLine),
        ),
        findsNothing,
      );

      final bodyRect = tester.getRect(find.byType(ChatMarkdownBlock).first);
      final statusRect = tester.getRect(find.byType(TurnStatusLine));
      final inputRect = tester.getRect(find.byType(TextField).last);
      expect(
        bodyRect.bottom <= statusRect.top,
        isTrue,
        reason:
            'el texto (${bodyRect.bottom}) va sobre el estado '
            '(${statusRect.top})',
      );
      expect(
        statusRect.bottom <= inputRect.top,
        isTrue,
        reason:
            'el estado (${statusRect.bottom}) va sobre la entrada '
            '(${inputRect.top})',
      );

      gateway.emit('message.complete', {'text': 'Listo.'});
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
    },
  );
}
