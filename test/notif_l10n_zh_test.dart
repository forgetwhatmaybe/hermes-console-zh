// La copia de notificaciones se resuelve sin BuildContext (también desde el
// isolate del servicio en primer plano), así que su chino no pasa por gen-l10n:
// se comprueba aquí, en las tres clases de texto que la componen.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/services/notifications/live_turn_notifications.dart';
import 'package:hermes_android/core/services/notifications/notification_strings.dart';
import 'package:hermes_android/core/services/notifications/rich_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ¿Hay algún carácter CJK? Sirve para probar que un texto salió en chino sin
/// fijar cada traducción palabra por palabra.
bool _hasHan(String text) => RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const zh = NotifL10n.zh();
  const es = NotifL10n(true);
  const en = NotifL10n(false);

  group('NotifL10n.of resuelve el chino', () {
    test('app_locale = zh devuelve chino', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'zh'});
      final t = NotifL10n.of(await SharedPreferences.getInstance());
      expect(t.zh, isTrue);
      expect(t.es, isFalse);
      expect(t.languageCode, 'zh');
      expect(t.approvalTitle, 'Hermes 需要你的关注');
    });

    test('es y en siguen resolviéndose igual', () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'es'});
      expect(NotifL10n.of(await SharedPreferences.getInstance()).es, isTrue);
      SharedPreferences.setMockInitialValues({'app_locale': 'en'});
      final t = NotifL10n.of(await SharedPreferences.getInstance());
      expect(t.es, isFalse);
      expect(t.zh, isFalse);
      expect(t.languageCode, 'en');
    });
  });

  group('NotifL10n en chino: título, cuerpo y botones', () {
    test('privacidad y resumen del grupo', () {
      expect(zh.privateTitle, 'Hermes 有新活动');
      expect(zh.privateBody, '点按查看');
      expect(zh.groupSummaryCount(3), '3 条新提醒');
    });

    test('canales de notificación', () {
      expect(zh.chApprovals, '审批');
      expect(zh.chApprovalsDesc, '智能体需要你授予的权限');
      expect(zh.chReplies, '回复');
      expect(zh.chRuns, '运行');
      expect(zh.chTransfersDesc, 'SFTP 上传与下载进度');
      expect(zh.chVoice, '语音模式');
      expect(zh.chOperationsDesc, '你发起的本地操作进度');
    });

    test('aprobaciones, ejecuciones y actividad en otra superficie', () {
      expect(zh.approvalTitle, 'Hermes 需要你的关注');
      expect(zh.approvalBody('bash', 'casa'), '点按以回复');
      expect(zh.runCompleted, '已完成');
      expect(zh.runFailed, '未能完成');
      expect(zh.sessionActivityFinishedTitle, '已在另一台设备完成');
      expect(zh.sessionActivityInterruptedTitle, '在另一台设备已停止');
      expect(zh.sessionActivityBody, '点按查看结果');
    });

    test('tarea en segundo plano, cron, kanban y objetivos', () {
      expect(zh.backgroundTaskFinishedTitle, '后台任务已完成');
      expect(zh.backgroundTaskFailedTitle, '后台任务失败');
      expect(zh.cronCompleted, '定时任务已完成');
      expect(zh.cronFailed, '定时任务失败');
      expect(zh.kanbanCrashed, '任务失败，将自动重试');
      expect(zh.kanbanTimedOut, '任务超时，将自动重试');
      expect(zh.kanbanBlockLoop, '有任务需要你决定');
      expect(zh.goalDone, '目标已达成');
      expect(zh.goalBody(''), '无标题');
    });

    test('respuestas: título con y sin sesión, y fallo', () {
      expect(zh.replyTitle('Backup'), 'Hermes 在 Backup 中回复');
      expect(zh.replyTitle(null), 'Hermes 已回复');
      expect(zh.replyReadyBody, '回复已就绪。点按打开。');
      expect(zh.replyFailedTitle('Backup'), 'Backup 出现问题');
      expect(zh.replyFailedBody, '智能体未能完成任务。');
    });

    test('agente local, prueba y acciones', () {
      expect(zh.localInstalled, '本地 Hermes 已安装');
      expect(zh.localInstalledBody, '本地 Hermes 智能体已安装到本设备。');
      expect(zh.localRemoveErrorBody, '部分文件无法移除。');
      expect(zh.testBody, '通知正常。Hermes 完成或需要你时，我会告诉你。');
      expect(zh.actOpen, '打开');
    });

    test('servicio en segundo plano', () {
      expect(zh.bgChannel, '后台服务');
      expect(zh.bgChannelDesc, '应用关闭后保持 Hermes 运行');
      expect(zh.bgActive, '后台运行中');
      expect(zh.bgConnected, '已连接到 Hermes');
      expect(zh.bgStop, '停止');
    });

    test('modo voz y lectura en voz alta', () {
      expect(zh.voiceTitle, '语音模式');
      expect(zh.vListening, '正在聆听…');
      expect(zh.vWaitingApproval, '需要审批');
      expect(zh.voiceActive, '你可以继续说 · 点按打开 Hermes');
      expect(zh.voicePaused, '对话已暂停 · 点按“继续”或打开 Hermes');
      expect(zh.voiceReviewApproval, '查看');
      expect(zh.voiceCardMicActive, '麦克风已开启');
      expect(zh.voiceCardOrbDescription, 'Hermes 语音状态');
      expect(zh.readAloudPlaying, '正在朗读回复');
      expect(zh.readAloudPaused, '朗读已暂停');
    });
  });

  group('BotNotificationCopy en chino: tarjetas ricas', () {
    test('tarjeta de aprobación y de pregunta', () {
      expect(zh.approvalNeedsOk('rm -rf /', null), '允许「rm -rf /」？');
      expect(zh.approvalNeedsOk(null, 'red'), '请求许可 · red');
      expect(zh.approvalNeedsOk(null, null), '请求许可');
      expect(zh.asksYou, '有问题要问你');
      expect(zh.actApprove, '允许');
      expect(zh.actDeny, '拒绝');
      expect(zh.actAlways, '始终');
    });

    test('sala: ronda, miembros y fallo', () {
      expect(zh.roundDone(const []), '本轮结束');
      expect(zh.roundDone(const ['Atlas']), '本轮结束 · Atlas 已回复');
      expect(zh.roundDone(const ['Atlas', 'Nova']), '本轮结束 · Atlas 和 Nova 已回复');
      // 三人与去重：rest 是未列出的人数，不是总人数。
      expect(
        zh.roundDone(const ['Atlas', 'Nova', 'Echo']),
        '本轮结束 · Atlas, Nova 和另外 1 个 已回复',
      );
      expect(
        zh.roundDone(const ['Atlas', 'Atlas', 'Nova', 'Echo', 'Echo']),
        '本轮结束 · Atlas, Nova 和另外 1 个 已回复',
      );
      expect(zh.roomBlocked, '房间内有一条回复失败 · 打开查看');
      expect(zh.isWorking('Atlas'), 'Atlas 正在工作…');
      expect(zh.roomsWorking(2), '2 个房间正在工作');
      expect(zh.inlineNeedsYou('Atlas'), 'Atlas 需要你');
      expect(zh.rowReplied('00:41'), '已回复 · 00:41');
    });

    test('bot y chat: resultado y acciones', () {
      expect(zh.botFinished('Atlas', ''), 'Atlas 已完成');
      expect(zh.botFinished('Atlas', 'listo'), 'Atlas 已完成 · listo');
      expect(zh.needsYou('Atlas'), 'Atlas 需要你');
      expect(zh.actMarkRead, '标记为已读');
      expect(zh.resultFailedLine, '未能完成');
      expect(zh.confirmMaybeSent, '已发送 · 打开 Hermes 查看');
      expect(zh.actMute, '静音');
      expect(zh.confirmMuted, '已静音');
    });

    test('filas de tarea y de trabajo programado', () {
      expect(zh.kanbanHead('done'), '已完成');
      expect(
        zh.kanbanHead('blocked', eventKinds: const {'gave_up'}),
        '已停止',
      );
      expect(zh.kanbanHead('done', retry: 'crashed'), '失败；将自动重试');
      expect(zh.cronHead(false), '失败');
      expect(zh.senderScheduled, '定时任务');
      expect(zh.senderTasks, '任务');
      expect(zh.summaryState(RichAccent.failed), '失败');
      expect(zh.routineDone('backup', ''), '「backup」已完成');
    });

    test('estado público (pantalla bloqueada)', () {
      expect(zh.publicDone, '已完成');
      expect(zh.publicFailed, '未能完成');
      expect(zh.publicNeedsYou, '需要你');
    });
  });

  group('LiveTurnCopy en chino: fila de turno en curso', () {
    test('fase, chip, contadores y título', () {
      expect(zh.livePhase(LiveTurnPhase.thinking), '正在思考');
      expect(zh.livePhase(LiveTurnPhase.waitingForApproval), '等待你的批准');
      expect(zh.liveChip(LiveTurnPhase.waitingForApproval), '待批准');
      expect(zh.liveTasks(2, 3), '任务 2/3');
      expect(zh.liveTools(1), '1 个工具');
      expect(zh.liveTools(4), '4 个工具');
      expect(zh.liveWorkingTitle('Atlas'), 'Atlas 正在工作');
    });

    test('la línea de herramienta pasa por gen-l10n con locale zh', () {
      final zhLine = liveToolLine(zh, 'bash');
      expect(_hasHan(zhLine), isTrue, reason: 'zh: $zhLine');
      expect(zhLine, isNot(liveToolLine(en, 'bash')));
    });
  });

  group('es/en no cambian (regresión)', () {
    test('español intacto', () {
      expect(es.privateTitle, 'Nueva actividad en Hermes');
      expect(es.approvalTitle, 'Hermes necesita tu atención');
      expect(es.runCompleted, 'Terminó');
      expect(es.cronCompleted, 'Tarea programada terminada');
      expect(es.replyTitle('Backup'), 'Hermes respondió en Backup');
      expect(es.replyReadyBody, 'Respuesta lista. Toca para abrir.');
      expect(es.actOpen, 'Abrir');
      expect(es.voiceCardListening, 'Escuchando');
      expect(es.approvalNeedsOk('rm -rf /', null), '¿Permitir «rm -rf /»?');
      expect(es.roundDone(const ['Atlas']), 'Ronda terminada · Atlas respondió');
      expect(es.publicFailed, 'No pudo terminar');
      expect(es.kanbanHead('done'), 'Terminada');
      expect(es.liveChip(LiveTurnPhase.waitingForApproval), 'Permiso');
    });

    test('inglés intacto', () {
      expect(en.privateBody, 'Tap to see it');
      expect(en.approvalTitle, 'Hermes needs your attention');
      expect(en.runCompleted, 'Finished');
      expect(en.cronFailed, 'Scheduled task failed');
      expect(en.replyReadyBody, 'Reply ready. Tap to open.');
      expect(en.actOpen, 'Open');
      expect(en.voiceCardMicPaused, 'Microphone paused');
      expect(en.approvalNeedsOk('rm -rf /', null), 'Allow “rm -rf /”?');
      expect(en.roundDone(const ['Atlas']), 'Round done · Atlas replied');
      expect(en.kanbanHead('done'), 'Done');
      expect(en.livePhase(LiveTurnPhase.thinking), 'Thinking');
      expect(en.groupSummaryCount(3), '3 recent alerts');
    });

    test('ningún texto chino se filtra a es/en', () {
      for (final t in [es, en]) {
        for (final text in [
          t.privateTitle,
          t.approvalTitle,
          t.runCompleted,
          t.replyReadyBody,
          t.actOpen,
          t.bgChannel,
          t.vListening,
          t.actApprove,
          t.publicDone,
          t.livePhase(LiveTurnPhase.thinking),
        ]) {
          expect(_hasHan(text), isFalse, reason: text);
        }
      }
    });

    test('el chino no repite el español ni el inglés', () {
      expect(zh.approvalTitle, isNot(es.approvalTitle));
      expect(zh.approvalTitle, isNot(en.approvalTitle));
      expect(zh.actApprove, isNot(es.actApprove));
      expect(zh.actApprove, isNot(en.actApprove));
      expect(zh.liveWorkingTitle('Atlas'), isNot(en.liveWorkingTitle('Atlas')));
    });
  });
}
