import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../companion/render/companion_view.dart';
import '../../companion/state/companion_controller.dart';
import '../../companion/models/companion_mood.dart';

/// Playground del Companion (006 FASE 2): muestra la mascota **equipada a gran
/// tamaño** y permite disparar cada animación para lucirlas. Reutiliza
/// [CompanionView] (que mapea cada [CompanionMood] a su estado de animación),
/// así que funciona igual con la cara del perfil o con un spritesheet
/// importado. No toca voz, runtime ni red.
class CompanionPlaygroundScreen extends StatefulWidget {
  final CompanionController controller;
  const CompanionPlaygroundScreen({required this.controller, super.key});

  @override
  State<CompanionPlaygroundScreen> createState() =>
      _CompanionPlaygroundScreenState();
}

class _CompanionPlaygroundScreenState
    extends State<CompanionPlaygroundScreen> {
  // Animaciones mostrables (mood que la dispara; la etiqueta se localiza al
  // pintar).
  static const List<CompanionMood> _moves = [
    CompanionMood.idle,
    CompanionMood.thinking,
    CompanionMood.waiting,
    CompanionMood.success,
    CompanionMood.jump,
    CompanionMood.error,
  ];

  static String _label(CompanionMood mood, Strings strings) {
    switch (mood) {
      case CompanionMood.idle:
        return strings.petAnimIdle;
      case CompanionMood.thinking:
        return strings.petAnimRun;
      case CompanionMood.waiting:
        return strings.petAnimWait;
      case CompanionMood.success:
        return strings.petAnimGreet;
      case CompanionMood.jump:
        return strings.petAnimJump;
      default:
        return strings.petAnimFail;
    }
  }

  CompanionMood _mood = CompanionMood.idle;

  /// Cambia con cada pulsación para re-disparar animaciones one-shot
  /// (saludar/saltar/fallo) aunque se repita el mismo estado.
  int _replay = 0;

  void _play(CompanionMood mood) {
    setState(() {
      _mood = mood;
      _replay++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final strings = Strings.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(strings.petAnimationsTitle)),
      body: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          return Column(
            children: [
              Expanded(
                child: Center(
                  child: CompanionView(
                    mood: _mood,
                    size: 200,
                    controller: widget.controller,
                    replayToken: _replay,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final mood in _moves)
                      ChoiceChip(
                        label: Text(_label(mood, strings)),
                        selected: _mood == mood,
                        onSelected: (_) => _play(mood),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
