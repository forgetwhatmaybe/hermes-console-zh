import '../models/desktop_session_snapshot.dart';
import '../utils/assistant_content.dart';
import '../utils/chat_turn.dart';
import 'replay_snapshot_boundary.dart';
import 'session_reconciler.dart';

const Map<String, dynamic> _emptyRow = <String, dynamic>{};

/// The live assistant row of a viewer projection: the newest non-durable
/// assistant row that is still open. Durable rows carry transcript identity and
/// are never the streaming row; cancelled/error rows are terminal.
int? viewerLiveAssistantIndex(List<Map<String, dynamic>> newestFirst) {
  for (var index = 0; index < newestFirst.length; index++) {
    final message = newestFirst[index];
    if (message['role'] != 'assistant') continue;
    if (message['_cancelled'] == true) continue;
    if (canonicalTranscriptMessageId(message) != null) continue;
    if (canonicalTranscriptRowId(message) != null) continue;
    return index;
  }
  return null;
}

/// Public text currently painted in the viewer's live row (empty when there is
/// no live row).
String viewerLiveAssistantPublicText(List<Map<String, dynamic>> newestFirst) {
  final index = viewerLiveAssistantIndex(newestFirst);
  if (index == null) return '';
  return newestFirst[index]['content']?.toString() ?? '';
}

/// Snapshot text a live row would have to show after application.
String viewerSnapshotPublicText(DesktopInflightTurn? inflight) =>
    streamingPublicAssistantText(inflight?.assistant ?? '').trimLeft();

/// Rebuilds the viewer's live row from an `inflight` snapshot.
///
/// A truncated replay may only resume the stream when the snapshot is applied
/// COMPLETELY: the live row becomes the whole `assistant` text AND carries the
/// snapshot's `display_kind`/`display_metadata`; the existing activity trace is
/// kept (the snapshot does not carry the tool steps this client already saw,
/// and dropping them would lose the running tool pill).
///
/// Returns null — the whole snapshot is refused — when there is no live row or
/// when the live text is not a prefix of the snapshot text (a fork or a
/// regression means the live row is not this inflight, so nothing may be
/// claimed as covered).
List<Map<String, dynamic>>? projectViewerTurnSnapshot({
  required List<Map<String, dynamic>> newestFirst,
  required DesktopInflightTurn? inflight,
}) {
  if (inflight == null) return null;
  final index = viewerLiveAssistantIndex(newestFirst);
  if (index == null) return null;
  final live = newestFirst[index];
  final liveText = live['content']?.toString() ?? '';
  final snapshotText = viewerSnapshotPublicText(inflight);
  if (!liveTextIsPrefixOfSnapshot(liveText, snapshotText)) return null;
  final rebuilt = <String, dynamic>{
    ...live,
    'content': snapshotText,
  };
  final displayKind = inflight.displayKind;
  if (displayKind != null) rebuilt['display_kind'] = displayKind;
  final displayMetadata = inflight.displayMetadata;
  if (displayMetadata != null) {
    rebuilt['display_metadata'] = Map<String, dynamic>.unmodifiable(
      displayMetadata,
    );
  }
  final projected = newestFirst.toList(growable: true);
  projected[index] = Map<String, dynamic>.unmodifiable(rebuilt);
  return projected;
}

/// The live row a snapshot would replace, or an empty map.
Map<String, dynamic> viewerLiveAssistantRow(
  List<Map<String, dynamic>> newestFirst,
) {
  final index = viewerLiveAssistantIndex(newestFirst);
  if (index == null) return _emptyRow;
  return newestFirst[index];
}

/// Activity trace of the live row (kept across a snapshot application).
Object? viewerLiveAssistantActivity(List<Map<String, dynamic>> newestFirst) =>
    viewerLiveAssistantRow(newestFirst)[assistantActivityTraceKey];
