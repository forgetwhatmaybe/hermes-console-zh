import 'server_paths.dart';

/// Compact display form of a server path for small screens.
///
/// `/home/<user>/code/app` → `~/code/app`; deep paths keep their last two
/// segments (`…/apps/console`). The full path stays available elsewhere
/// (selectable text / copy) — this is only a label.
String shortServerPath(String path) {
  final normalized = ServerPath.normalize(path);
  if (ServerPath.looksWindows(normalized)) {
    final parts = normalized
        .split(RegExp(r'[\\/]'))
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length <= 4) return normalized;
    return '…\\${parts[parts.length - 2]}\\${parts.last}';
  }
  var value = normalized;
  if (value.isEmpty) return '';
  final home = RegExp(r'^(/home/[^/]+|/Users/[^/]+|/root)(?=/|$)');
  value = value.replaceFirst(home, '~');
  final trailing = value.endsWith('/') && value.length > 1;
  if (trailing) value = value.substring(0, value.length - 1);
  final parts = value.split('/');
  final meaningful = parts.where((part) => part.isNotEmpty).toList();
  if (meaningful.length <= 3) return value;
  return '…/${meaningful[meaningful.length - 2]}/${meaningful.last}';
}
