// Textos de las notificaciones, localizados SIN BuildContext.
//
// Las notificaciones se disparan también desde un isolate de segundo plano
// (BackgroundListener) donde no hay `BuildContext` ni `AppLocalizations`. Por eso
// no podemos usar gen-l10n aquí: resolvemos el idioma leyendo la misma clave que
// usa la app (`app_locale` de AppLocales) y devolvemos los textos a mano
// (es/en/zh). Mantener en sintonía con lib/l10n cuando cambie el tono.
import 'dart:ui' show PlatformDispatcher;

import 'package:shared_preferences/shared_preferences.dart';

/// Idioma de la copia de notificaciones. Tres estados: la app publica es/en/zh
/// (`AppLocales.all` en `main.dart`) y esta capa no puede usar gen-l10n.
enum NotifLang { es, en, zh }

class NotifL10n {
  final NotifLang lang;

  /// Compatibilidad: `true` = español, `false` = inglés. Para chino, usar
  /// [NotifL10n.zh] (o [NotifL10n.of], que lo resuelve solo).
  const NotifL10n(bool es) : lang = es ? NotifLang.es : NotifLang.en;
  const NotifL10n.zh() : lang = NotifLang.zh;

  bool get es => lang == NotifLang.es;
  bool get zh => lang == NotifLang.zh;

  /// Código de idioma para `lookupStrings`/`Locale` de gen-l10n.
  String get languageCode => switch (lang) {
    NotifLang.es => 'es',
    NotifLang.en => 'en',
    NotifLang.zh => 'zh',
  };

  /// Resuelve el idioma desde SharedPreferences (clave `app_locale`):
  /// 'es'/'en'/'zh' fuerzan; 'system' (o ausente) sigue el idioma del
  /// dispositivo.
  factory NotifL10n.of(SharedPreferences prefs) {
    final id = prefs.getString('app_locale') ?? 'system';
    final code = id == 'system'
        ? PlatformDispatcher.instance.locale.languageCode
        : id;
    return switch (code) {
      'es' => const NotifL10n(true),
      'zh' => const NotifL10n.zh(),
      _ => const NotifL10n(false),
    };
  }

  String _(String es_, String en, String zh_) => switch (lang) {
    NotifLang.es => es_,
    NotifLang.en => en,
    NotifLang.zh => zh_,
  };

  // ── Marca / genéricos ─────────────────────────────────────────────────────
  String get brand => 'Hermes';
  String get privateTitle =>
      _('Nueva actividad en Hermes', 'New Hermes activity', 'Hermes 有新活动');
  String get privateBody => _('Toca para verla', 'Tap to see it', '点按查看');

  /// Resumen del grupo con el número real de avisos activos (más concreto que
  /// "varios" y estable a la vista en la bandeja).
  String groupSummaryCount(int n) => _(
    '$n avisos recientes',
    '$n recent alerts',
    '$n 条新提醒',
  );

  // ── Canales (nombre + descripción) ────────────────────────────────────────
  String get chApprovals => _('Aprobaciones', 'Approvals', '审批');
  String get chApprovalsDesc => _(
    'Permisos que el agente necesita de ti',
    'Permissions the agent needs from you',
    '智能体需要你授予的权限',
  );
  String get chReplies => _('Respuestas', 'Replies', '回复');
  String get chRepliesDesc => _(
    'Cuando el agente termina de responder',
    'When the agent finishes replying',
    '智能体回复完成时',
  );
  String get chRuns => _('Ejecuciones', 'Runs', '运行');
  String get chRunsDesc => _(
    'Estado de las tareas en ejecución',
    'Status of running tasks',
    '正在运行的任务状态',
  );
  String get chTransfers => _('Transferencias', 'Transfers', '传输');
  String get chTransfersDesc => _(
    'Progreso de subidas y descargas SFTP',
    'SFTP upload and download progress',
    'SFTP 上传与下载进度',
  );
  String get chVoice => _('Modo voz', 'Voice mode', '语音模式');
  String get chVoiceDesc => _(
    'Estado del modo voz activo',
    'Active voice mode status',
    '语音模式的当前状态',
  );
  String get chOperations =>
      _('Operaciones locales', 'Local operations', '本地操作');
  String get chOperationsDesc => _(
    'Progreso de operaciones locales que has iniciado',
    'Progress of local operations you started',
    '你发起的本地操作进度',
  );

  // ── Aprobaciones ──────────────────────────────────────────────────────────
  String get approvalTitle => _(
    'Hermes necesita tu atención',
    'Hermes needs your attention',
    'Hermes 需要你的关注',
  );
  String approvalBody(String tool, String where) =>
      _('Toca para responder', 'Tap to answer', '点按以回复');

  // ── Ejecuciones ───────────────────────────────────────────────────────────
  String get runCompleted => _('Terminó', 'Finished', '已完成');
  String get runFailed => _('No pudo terminar', 'Couldn’t finish', '未能完成');

  // ── Actividad en otra superficie (Desktop / otra Console / TUI) ──────────
  String get sessionActivityFinishedTitle => _(
    'Terminó en otro dispositivo',
    'Finished on another device',
    '已在另一台设备完成',
  );
  String get sessionActivityFailedTitle => _(
    'Falló en otro dispositivo',
    'Failed on another device',
    '在另一台设备失败',
  );
  String get sessionActivityInterruptedTitle => _(
    'Se detuvo en otro dispositivo',
    'Stopped on another device',
    '在另一台设备已停止',
  );
  String get sessionActivityBody =>
      _('Toca para ver el resultado', 'Tap to see the result', '点按查看结果');

  // ── Tarea en segundo plano (prompt.background / background.complete) ─────
  String get backgroundTaskFinishedTitle => _(
    'Terminó una tarea en segundo plano',
    'A background task finished',
    '后台任务已完成',
  );
  String get backgroundTaskFailedTitle => _(
    'Falló una tarea en segundo plano',
    'A background task failed',
    '后台任务失败',
  );
  String get backgroundTaskBody =>
      _('Toca para ver el resultado', 'Tap to see the result', '点按查看结果');
  String get cronCompleted => _(
    'Tarea programada terminada',
    'Scheduled task finished',
    '定时任务已完成',
  );
  String get cronFailed =>
      _('Falló una tarea programada', 'Scheduled task failed', '定时任务失败');
  String get kanbanCompleted => _('Tarea terminada', 'Task done', '任务已完成');
  String get kanbanBlocked => _('Tarea bloqueada', 'Task blocked', '任务受阻');
  String get kanbanNeedsAttention =>
      _('Una tarea te necesita', 'A task needs you', '有任务需要你');
  String get kanbanUpdated => _('Tarea actualizada', 'Task updated', '任务已更新');
  String get kanbanCrashed => _(
    'Una tarea falló y se va a reintentar',
    'A task failed and will be retried',
    '任务失败，将自动重试',
  );
  String get kanbanTimedOut => _(
    'Una tarea tardó demasiado y se va a reintentar',
    'A task took too long and will be retried',
    '任务超时，将自动重试',
  );
  String get kanbanGaveUp => _('Tarea detenida', 'Task stopped', '任务已停止');
  String get kanbanBlockLoop => _(
    'Una tarea necesita que decidas',
    'A task needs your decision',
    '有任务需要你决定',
  );

  // ── Standing goals ────────────────────────────────────────────────────────
  String get goalDone => _('Objetivo cumplido', 'Goal reached', '目标已达成');
  String get goalPaused => _('Objetivo en pausa', 'Goal paused', '目标已暂停');
  String get goalBlocked => _('Objetivo bloqueado', 'Goal blocked', '目标受阻');
  String get goalWaiting => _('Objetivo en espera', 'Goal waiting', '目标等待中');
  String goalBody(String title) =>
      title.isEmpty ? _('Sin título', 'Untitled', '无标题') : title;

  // ── Respuestas ────────────────────────────────────────────────────────────
  String replyTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) return _('Hermes respondió', 'Hermes replied', 'Hermes 已回复');
    return _(
      'Hermes respondió en $s',
      'Hermes replied in $s',
      'Hermes 在 $s 中回复',
    );
  }

  String get replyReadyBody => _(
    'Respuesta lista. Toca para abrir.',
    'Reply ready. Tap to open.',
    '回复已就绪。点按打开。',
  );

  String replyFailedTitle(String? session) {
    final s = session?.trim() ?? '';
    if (s.isEmpty) {
      return _(
        'Hermes encontró un problema',
        'Hermes hit a problem',
        'Hermes 遇到问题',
      );
    }
    return _('Problema en $s', 'Problem in $s', '$s 出现问题');
  }

  String get replyFailedBody => _(
    'El agente no pudo completar la tarea.',
    'The agent could not complete the task.',
    '智能体未能完成任务。',
  );

  // ── Agente local ──────────────────────────────────────────────────────────
  String get localInstalled =>
      _('Hermes local instalado', 'Local Hermes installed', '本地 Hermes 已安装');
  String get localInstallError => _(
    'Error al instalar Hermes local',
    'Error installing local Hermes',
    '安装本地 Hermes 失败',
  );
  String get localInstalledBody => _(
    'El agente Hermes local se instaló en el dispositivo.',
    'The local Hermes agent was installed on the device.',
    '本地 Hermes 智能体已安装到本设备。',
  );
  String get localInstallErrorBody => _(
    'No se pudo completar la instalación.',
    'Could not complete installation.',
    '无法完成安装。',
  );
  String get localRemoved =>
      _('Hermes local eliminado', 'Local Hermes removed', '本地 Hermes 已移除');
  String get localRemoveError => _(
    'Error al eliminar Hermes local',
    'Error removing local Hermes',
    '移除本地 Hermes 失败',
  );
  String get localRemovedBody => _(
    'El agente Hermes local se eliminó del dispositivo.',
    'The local Hermes agent was removed from the device.',
    '本地 Hermes 智能体已从本设备移除。',
  );
  String get localRemoveErrorBody => _(
    'No se pudieron eliminar algunos archivos.',
    'Some files could not be removed.',
    '部分文件无法移除。',
  );

  // ── Prueba ────────────────────────────────────────────────────────────────
  String get testTitle => 'Console';
  String get testBody => _(
    'Las notificaciones funcionan. Te avisaré cuando Hermes termine o te necesite.',
    'Notifications work. I’ll tell you when Hermes finishes or needs you.',
    '通知正常。Hermes 完成或需要你时，我会告诉你。',
  );

  // ── Acciones ──────────────────────────────────────────────────────────────
  String get actOpen => _('Abrir', 'Open', '打开');

  // ── Servicio en segundo plano (foreground service) ────────────────────────
  String get bgChannel =>
      _('Servicio en segundo plano', 'Background service', '后台服务');
  String get bgChannelDesc => _(
    'Mantiene a Hermes activo con la app cerrada',
    'Keeps Hermes active while the app is closed',
    '应用关闭后保持 Hermes 运行',
  );
  String get bgActive =>
      _('Activo en segundo plano', 'Active in the background', '后台运行中');

  /// The fixed card while Console stays connected with the app closed.
  String get bgConnected =>
      _('Conectado a Hermes', 'Connected to Hermes', '已连接到 Hermes');
  String get bgStop => _('Detener', 'Stop', '停止');

  // ── Modo voz (estados) ────────────────────────────────────────────────────
  String get voiceTitle => _('Modo voz', 'Voice mode', '语音模式');
  String get vListening => _('Escuchando…', 'Listening…', '正在聆听…');
  String get vTranscribing => _('Transcribiendo…', 'Transcribing…', '正在转写…');
  String get vThinking => _('Pensando…', 'Thinking…', '正在思考…');
  String get vTool => _(
    'Ejecutando una herramienta…',
    'Running a tool…',
    '正在运行工具…',
  );
  String get vWaitingApproval =>
      _('Necesita aprobación', 'Needs approval', '需要审批');
  String get vSpeaking => _('Hablando…', 'Speaking…', '正在说话…');
  String get vError => _('Error en modo voz', 'Voice mode error', '语音模式出错');
  String get voiceActive => _(
    'Puedes seguir hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
    '你可以继续说 · 点按打开 Hermes',
  );
  String get voicePaused => _(
    'Conversación en pausa · pulsa Continuar o abre Hermes',
    'Conversation paused · tap Continue or open Hermes',
    '对话已暂停 · 点按“继续”或打开 Hermes',
  );
  String get voiceWaitingApproval => _(
    'Hermes necesita aprobación · pulsa Revisar',
    'Hermes needs approval · tap Review',
    'Hermes 需要审批 · 点按“查看”',
  );
  String get voiceOpenHintActive => _(
    'Sigue hablando · toca para abrir Hermes',
    'Keep talking · tap to open Hermes',
    '继续说 · 点按打开 Hermes',
  );
  String get voiceOpenHintPaused => _(
    'Pulsa Continuar o toca para abrir Hermes',
    'Tap Continue or tap to open Hermes',
    '点按“继续”或点按打开 Hermes',
  );
  String get voiceOpenHintApproval => _(
    'Pulsa Revisar para aprobar en Hermes',
    'Tap Review to approve in Hermes',
    '点按“查看”在 Hermes 中批准',
  );
  String get voiceCardListening => _('Escuchando', 'Listening', '聆听中');
  String get voiceCardPaused => _('En pausa', 'Paused', '已暂停');
  String get voiceCardWaitingApproval =>
      _('Necesita aprobación', 'Needs approval', '需要审批');
  String get voiceCardMicActive =>
      _('Micrófono activo', 'Microphone active', '麦克风已开启');
  String get voiceCardMicPaused =>
      _('Micrófono pausado', 'Microphone paused', '麦克风已暂停');
  String get voiceCardOrbDescription =>
      _('Estado de voz de Hermes', 'Hermes voice status', 'Hermes 语音状态');
  String get voiceCardDurationDescription => _(
    'Duración de la conversación',
    'Conversation duration',
    '对话时长',
  );
  String get voicePause => _('Pausar', 'Pause', '暂停');
  String get voiceContinue => _('Continuar', 'Continue', '继续');
  String get voiceReviewApproval => _('Revisar', 'Review', '查看');
  String get voiceEnd => _('Terminar', 'End', '结束');
  String get voiceEndConversation =>
      _('Terminar conversación', 'End conversation', '结束对话');
  String get readAloudPlaying =>
      _('Leyendo respuesta', 'Reading response', '正在朗读回复');
  String get readAloudPaused =>
      _('Lectura en pausa', 'Reading paused', '朗读已暂停');
}
