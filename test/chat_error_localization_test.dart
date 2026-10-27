import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/utils/chat_error_localization.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

Future<Strings> _load(Locale locale) => Strings.delegate.load(locale);

const _recovery =
    'No se pudo recuperar el turno. Inténtalo de nuevo.';
const _incomplete =
    'No se pudo completar la respuesta. Inténtalo de nuevo.';
const _lost =
    'Se perdió la conexión con Hermes. El mensaje no se confirmó; '
    'revisa el borrador y reintenta.';
const _owned =
    'No se puede continuar esta conversación en directo. '
    'El historial se conserva y puedes iniciar un chat nuevo.';
const _kept = 'No se pudo conservar el turno antes de enviarlo.';
const _attachment = 'No se pudo leer un adjunto local.';
const _auth = 'El envío perdió su autorización antes de entregarse.';

const _constants = <String>[
  _recovery,
  _incomplete,
  _lost,
  _owned,
  _kept,
  _attachment,
  _auth,
];

void main() {
  test('las 7 constantes se traducen en zh y en', () async {
    final zh = await _load(const Locale('zh'));
    final en = await _load(const Locale('en'));
    for (final raw in _constants) {
      final zhText = localizedChatError(raw, zh);
      final enText = localizedChatError(raw, en);
      expect(zhText, isNot(raw), reason: 'zh debe traducir: $raw');
      expect(enText, isNot(raw), reason: 'en debe traducir: $raw');
      expect(zhText, isNot(enText), reason: 'zh y en no deben coincidir');
    }
    expect(localizedChatError(_recovery, zh), '无法恢复该回合，请重试。');
    expect(
      localizedChatError(_auth, en),
      'The send lost its authorization before delivery.',
    );
  });

  test('es devuelve el mismo texto (no hay traducción que hacer)', () async {
    final es = await _load(const Locale('es'));
    for (final raw in _constants) {
      expect(localizedChatError(raw, es), raw);
    }
  });

  test('la causa remota se conserva byte a byte tras el prefijo', () async {
    final zh = await _load(const Locale('zh'));
    expect(
      localizedChatError(
        'No se pudo completar la respuesta: upstream 502 Bad Gateway\n',
        zh,
      ),
      '回复未能完成：upstream 502 Bad Gateway\n',
    );
    // Prefijo anidado: sólo se quita el exterior.
    expect(
      localizedChatError(
        'No se pudo completar la respuesta: '
        'No se pudo completar la respuesta: x',
        zh,
      ),
      '回复未能完成：No se pudo completar la respuesta: x',
    );
  });

  test('prefijo sin causa cae al mensaje genérico', () async {
    final zh = await _load(const Locale('zh'));
    expect(
      localizedChatError('No se pudo completar la respuesta: ', zh),
      '回复未能完成，请重试。',
    );
    expect(
      localizedChatError('No se pudo completar la respuesta:', zh),
      'No se pudo completar la respuesta:',
      reason: 'sin espacio no es el prefijo exacto: no se reescribe',
    );
  });

  test('envío y propiedad del gateway también se traducen', () async {
    final zh = await _load(const Locale('zh'));
    expect(
      localizedChatError('No se pudo enviar el mensaje. Inténtalo de nuevo.', zh),
      '消息未能发送，请重试。',
    );
    expect(
      localizedChatError(
        'El gateway está ejecutando un turno en este chat: la entrega no '
        'quedó confirmada. Vuelve a enviarlo cuando termine.',
        zh,
      ),
      '网关正在这个会话里跑一轮，这条消息没有确认送达。等它结束后再发。',
    );
    expect(
      localizedChatError(
        'El gateway no confirmó este mensaje; puede que ya esté en su cola. '
        'Revisa el chat antes de enviarlo otra vez.',
        zh,
      ),
      '网关没有确认这条消息，可能已经排队。先看会话，再决定是否重发。',
    );
  });

  test('ownership 文案按生产原文匹配（含前缀）', () async {
    final zh = await _load(const Locale('zh'));
    expect(
      localizedChatError(
        'No se puede continuar en directo porque esta conversación '
        'pertenece a otro gateway o proceso. El historial se conserva '
        'y puedes iniciar un chat nuevo.',
        zh,
      ),
      '该对话属于另一个网关或进程，无法继续实时会话。历史记录已保留，可新建对话。',
    );
  });

  test('el texto libre o desconocido no se reescribe', () async {
    final zh = await _load(const Locale('zh'));
    const free = 'El servidor rechazó la solicitud.';
    expect(localizedChatError(free, zh), free);
    expect(localizedChatError('  $free  ', zh), '  $free  ');
    expect(localizedChatError('', zh), '');
  });
}
