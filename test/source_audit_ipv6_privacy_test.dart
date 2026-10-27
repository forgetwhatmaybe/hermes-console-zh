import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/origin_bound_http_client.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/tui_gateway_client.dart';
import 'package:hermes_android/core/utils/transport_privacy.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'source_audit_request_cancel_recovery_test.dart' show AuditDashboard;

void main() {
  test(
    'public IPv6 gateway connect rejects before socket construction',
    () async {
      var sockets = 0;
      TuiGatewayClient? client;
      Object? rejection;
      try {
        client = TuiGatewayClient(
          SavedConnection(
            id: 'ipv6-audit',
            label: 'IPv6 audit',
            host: '127.0.0.1',
            port: 8642,
            apiKey: 'synthetic-placeholder',
            dashboardUrl: 'http://[2606:4700:4700::1111]:8642',
          ),
          dashboard: AuditDashboard(),
          channelFactory: (_, _) {
            sockets++;
            throw StateError('socket must not be constructed');
          },
        );
        await client.connect();
      } catch (error) {
        rejection = error;
      } finally {
        await client?.close();
      }
      expect(rejection, isArgumentError);
      expect(sockets, 0);
    },
  );
  const privateHosts = [
    '::1',
    '0:0:0:0:0:0:0:1',
    'fc00::1',
    'fdff:ffff::1',
    'fd7a:115c:a1e0::1',
    'fe80::1',
    'febf:ffff::1',
    '::ffff:127.0.0.1',
    '::ffff:10.0.0.1',
    '::ffff:192.168.1.1',
    '::ffff:100.64.0.1',
    '0:0:0:0:0:ffff:c0a8:0101',
  ];
  const publicHosts = [
    '2606:4700:4700::1111',
    '2001:4860:4860:0:0:0:0:8888',
    '::',
    '0:0:0:0:0:0:0:0',
    'ff02::1',
    'fec0::1',
    'fe7f::1',
    'fbff::1',
    '::ffff:8.8.8.8',
    '::ffff:0808:0808',
    '::ffff:172.32.0.1',
    '::ffff:100.128.0.1',
    '::192.168.1.1',
  ];
  for (final scheme in ['http', 'ws']) {
    for (final host in privateHosts) {
      test('$scheme permits supported IPv6 $host', () {
        final url = '$scheme://[$host]:8642';
        expect(
          TransportPrivacy.classify(url),
          TransportPrivacyClass.privateCleartext,
        );
        expect(TransportPrivacy.requireAllowed(url), url);
      });
    }
    for (final host in publicHosts) {
      test('$scheme rejects unsupported IPv6 $host', () {
        final url = '$scheme://[$host]:8642';
        expect(
          TransportPrivacy.classify(url),
          TransportPrivacyClass.publicCleartext,
        );
        expect(() => TransportPrivacy.requireAllowed(url), throwsArgumentError);
      });
    }
  }
  test('scheme-free IPv6 uses the same literal policy', () {
    expect(
      TransportPrivacy.classify('2606:4700:4700::1111'),
      TransportPrivacyClass.publicCleartext,
    );
    expect(
      TransportPrivacy.classify('[fc00::1]:8642'),
      TransportPrivacyClass.privateCleartext,
    );
  });
  for (final scheme in ['https', 'wss']) {
    test('$scheme retains secure IPv6 handling', () {
      for (final host in [...privateHosts, ...publicHosts]) {
        expect(
          TransportPrivacy.classify('$scheme://[$host]:8642'),
          TransportPrivacyClass.secure,
        );
      }
    });
  }
  test('local names and public IPv4 retain their existing policies', () {
    for (final host in [
      'desktop',
      'localhost',
      'desktop.local',
      'node.ts.net',
      'fixture.test',
      'fixture.example',
    ]) {
      expect(
        TransportPrivacy.classify('http://$host'),
        TransportPrivacyClass.privateCleartext,
      );
    }
    expect(
      TransportPrivacy.classify('http://8.8.8.8'),
      TransportPrivacyClass.publicCleartext,
    );
  });
  test('public IPv6 HTTP never reaches the inner transport', () async {
    var requests = 0;
    final client = OriginBoundHttpClient(
      MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.get(Uri.parse('http://[2606:4700:4700::1111]:8642/api/status')),
      throwsArgumentError,
    );
    expect(requests, 0);
  });
}
