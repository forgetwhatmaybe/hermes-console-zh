/// Path helpers for paths that live on the Hermes host (Linux or Windows).
///
/// The Console UI keeps paths as opaque strings; these helpers only decide
/// separators, parents, basenames and containment, so the same screens work
/// against a POSIX server and a Windows server (C:\Users\...).
class ServerPath {
  ServerPath._();

  static final RegExp _drive = RegExp(r'^[A-Za-z]:[\\/]');
  static final RegExp _sep = RegExp(r'[\\/]+');

  /// Absolute path on either platform ("/x", "C:" + sep, or a UNC "\\server").
  static bool isAbsolute(String path) {
    final p = path.trim();
    return p.startsWith('/') ||
        _drive.hasMatch(p) ||
        p.startsWith('\\');
  }

  /// Windows-style path (drive letter or backslashes).
  static bool looksWindows(String path) =>
      _drive.hasMatch(path) || path.contains('\\');

  static String _sepFor(String path) => looksWindows(path) ? '\\' : '/';

  /// Strips trailing separators, keeping a bare root ("/" or "C:\").
  static String normalize(String path) {
    var p = path.trim();
    if (p.isEmpty) return p;
    if (_drive.hasMatch(p) && p.length <= 3) {
      return p.replaceAll('/', '\\');
    }
    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      if (_drive.hasMatch(p) && p.length <= 3) break;
      p = p.substring(0, p.length - 1);
    }
    if (_drive.hasMatch(p)) {
      return p.replaceAll('/', '\\');
    }
    return p;
  }

  /// Last segment of [path].
  static String basename(String path) {
    final p = normalize(path);
    if (p.isEmpty) return p;
    if (p == '/' || (_drive.hasMatch(p) && p.length <= 3)) return p;
    final parts = p.split(_sep).where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? p : parts.last;
  }

  /// Joins [parent] and [name] with the separator that matches [parent].
  static String join(String parent, String name) {
    if (parent.isEmpty) return name;
    final sep = _sepFor(parent);
    final base = normalize(parent);
    if (base == '/') return '/$name';
    if (_drive.hasMatch(base) && base.length <= 3) {
      return '$base$name';
    }
    return '$base$sep$name';
  }

  /// Parent folder, clamped at the filesystem root ("/" or "C:\").
  static String parent(String path) {
    final p = normalize(path);
    if (p.isEmpty || p == '/') return '/';
    if (_drive.hasMatch(p) && p.length <= 3) return p;
    final sep = _sepFor(p);
    if (_drive.hasMatch(p)) {
      final root = '${p.substring(0, 2)}\\';
      if (p == root) return root;
      final cut = p.lastIndexOf(sep);
      return cut <= 2 ? root : p.substring(0, cut);
    }
    final cut = p.lastIndexOf(sep);
    return cut <= 0 ? '/' : p.substring(0, cut);
  }

  /// True when [folder] is [root] or lives below it.
  static bool isInside(String root, String folder) {
    final r = normalize(root);
    final f = normalize(folder);
    if (r.isEmpty) return false;
    final win = looksWindows(r) || looksWindows(f);
    if (win) {
      final rr = r.toLowerCase();
      final ff = f.toLowerCase();
      if (ff == rr) return true;
      if (rr.endsWith('\\')) return ff.startsWith(rr);
      return ff.startsWith('$rr\\') || ff.startsWith('$rr/');
    }
    if (f == r) return true;
    if (r == '/') return f.startsWith('/');
    return f.startsWith('$r/');
  }

  /// Drive root ("C:\") of [path], or "/" for POSIX paths.
  static String rootOf(String path) {
    final p = normalize(path);
    if (_drive.hasMatch(p)) return '${p.substring(0, 2)}\\';
    return '/';
  }

  /// Segments of [path] below [root], used for breadcrumbs.
  static List<String> partsBelow(String root, String path) {
    final r = normalize(root);
    final p = normalize(path);
    if (!isInside(r, p) || p == r) return const [];
    final rest = r == '/' ? p.substring(1) : p.substring(r.length);
    return rest.split(_sep).where((s) => s.isNotEmpty).toList();
  }
}

/// Which OS the connected Hermes host runs. Auto detects from the paths the
/// file endpoints return; the explicit values exist for hosts where detection
/// is ambiguous (e.g. a Windows box behind a POSIX-looking proxy).
enum ServerOs {
  auto('auto'),
  linux('linux'),
  windows('windows');

  const ServerOs(this.storageKey);
  final String storageKey;

  static ServerOs fromStorage(String? value) => values.firstWhere(
    (o) => o.storageKey == value,
    orElse: () => ServerOs.auto,
  );
}
