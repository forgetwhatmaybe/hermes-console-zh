import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/companion/data/companion_error_codes.dart';
import 'package:hermes_android/core/companion/hatch/hatch_provider.dart';
import 'package:hermes_android/core/companion/hatch/hermes_hatch_provider.dart';
import 'package:hermes_android/core/companion/hatch/mock_hatch_provider.dart';

void main() {
  group('MockHatchProvider', () {
    test('disponible y sin consentimiento de privacidad', () async {
      const p = MockHatchProvider();
      final a = await p.availability();
      expect(a.available, isTrue);
      expect(a.requiresPrivacyConsent, isFalse);
    });

    test('puede forzarse no disponible', () async {
      const p = MockHatchProvider(unavailableReason: 'sin gateway');
      final a = await p.availability();
      expect(a.available, isFalse);
      expect(a.reason, 'sin gateway');
    });

    test('generate produce bytes de imagen', () async {
      const p = MockHatchProvider();
      final r = await p.generate(const HatchRequest('gato'));
      expect(r.imageBytes, isNotEmpty);
    });
  });

  group('HermesHatchProvider (probe inyectado, sin red)', () {
    test(
      'probe true → disponible y EXIGE consentimiento de privacidad',
      () async {
        final p = HermesHatchProvider(
          probe: () async => true,
          call: (_) async => Uint8List.fromList([1, 2, 3]),
        );
        final a = await p.availability();
        expect(a.available, isTrue);
        expect(a.requiresPrivacyConsent, isTrue); // el prompt sale al gateway
      },
    );

    test('probe false → no disponible con razón', () async {
      final p = HermesHatchProvider(
        probe: () async => false,
        call: (_) async => Uint8List.fromList([1]),
      );
      final a = await p.availability();
      expect(a.available, isFalse);
      // El motivo es un código estable; la pantalla lo localiza al pintar.
      expect(a.code, CompanionErrorCode.hatchGatewayUnsupported);
    });

    test('probe que lanza → degrada a no disponible (no rompe)', () async {
      final p = HermesHatchProvider(
        probe: () async => throw Exception('boom'),
        call: (_) async => Uint8List.fromList([1]),
      );
      final a = await p.availability();
      expect(a.available, isFalse);
    });

    test('generate envuelve fallos del gateway en HatchException', () async {
      final p = HermesHatchProvider(
        probe: () async => true,
        call: (_) async => throw Exception('timeout'),
      );
      expect(
        () => p.generate(const HatchRequest('x')),
        throwsA(isA<HatchException>()),
      );
    });
  });
}
