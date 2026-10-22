import '../utils/server_paths.dart';
import 'dart:typed_data';

import '../models/session_artifact.dart';
import 'artifact_export_service.dart';
import 'connection_manager.dart';

enum SessionArtifactDownloadFailure {
  unavailable,
  expired,
  unsupportedReference,
  accessDenied,
  tooLarge,
  notFound,
  server,
}

final class SessionArtifactDownloadException implements Exception {
  final SessionArtifactDownloadFailure failure;

  const SessionArtifactDownloadException(this.failure);

  @override
  String toString() => 'session_artifact_download_${failure.name}';
}

final class SessionArtifactDownload {
  final Uint8List bytes;
  final String fileName;
  final String mimeType;

  const SessionArtifactDownload({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
  });
}

typedef SessionArtifactDashboardFactory =
    DashboardClient Function(SavedConnection connection);

/// Descarga únicamente referencias que ya cruzaron el índice estructurado y
/// que se pueden traducir a la ruta oficial autenticada de Hermes Desktop.
/// Nunca abre `file://`, URLs firmadas, hosts externos ni rutas relativas.
final class SessionArtifactDownloadService {
  static const int maximumBytes = 25 * 1024 * 1024;

  final SavedConnection connection;
  final SessionArtifactDashboardFactory _dashboardFactory;

  SessionArtifactDownloadService({
    required this.connection,
    SessionArtifactDashboardFactory? dashboardFactory,
  }) : _dashboardFactory = dashboardFactory ?? DashboardClient.lazy;

  bool canDownload(SessionArtifact artifact) {
    if (artifact.availability == SessionArtifactAvailability.missing ||
        artifact.availability == SessionArtifactAvailability.expired ||
        (artifact.sizeBytes ?? 0) > maximumBytes) {
      return false;
    }
    return _downloadEndpoint(artifact.managedReference) != null;
  }

  Future<SessionArtifactDownload> download(SessionArtifact artifact) async {
    if (artifact.availability == SessionArtifactAvailability.expired) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.expired,
      );
    }
    if (artifact.availability == SessionArtifactAvailability.missing) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.unavailable,
      );
    }
    if ((artifact.sizeBytes ?? 0) > maximumBytes) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.tooLarge,
      );
    }
    final endpoint = _downloadEndpoint(artifact.managedReference);
    if (endpoint == null) {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.unsupportedReference,
      );
    }

    final dashboard = _dashboardFactory(connection);
    try {
      final response = await dashboard.apiDownload(
        endpoint,
        maxBytes: maximumBytes,
      );
      if (response.bytes.isEmpty) {
        throw const SessionArtifactDownloadException(
          SessionArtifactDownloadFailure.unavailable,
        );
      }
      final contentType = response.contentType
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      return SessionArtifactDownload(
        bytes: response.bytes,
        fileName: PlatformArtifactExportActions.sanitizeFileName(
          artifact.displayName,
        ),
        mimeType: contentType?.isNotEmpty == true
            ? contentType!
            : artifact.mimeType ?? 'application/octet-stream',
      );
    } on DashboardHttpException catch (error) {
      throw SessionArtifactDownloadException(switch (error.statusCode) {
        401 || 403 => SessionArtifactDownloadFailure.accessDenied,
        404 => SessionArtifactDownloadFailure.notFound,
        410 => SessionArtifactDownloadFailure.expired,
        413 => SessionArtifactDownloadFailure.tooLarge,
        _ => SessionArtifactDownloadFailure.server,
      });
    } on StateError {
      throw const SessionArtifactDownloadException(
        SessionArtifactDownloadFailure.tooLarge,
      );
    } finally {
      dashboard.close();
    }
  }

  Future<ArtifactSaveResult> downloadAndSave(
    SessionArtifact artifact,
    ArtifactExportActions exporter,
  ) async {
    final result = await download(artifact);
    return exporter.saveBytes(fileName: result.fileName, bytes: result.bytes);
  }

  String? _downloadEndpoint(String? rawReference) {
    final reference = rawReference?.trim() ?? '';
    if (reference.isEmpty ||
        reference.length > 2048 ||
        _hasControl(reference)) {
      return null;
    }

    if (reference.startsWith('/')) {
      return _managedPathEndpoint(reference);
    }

    final uri = Uri.tryParse(reference);
    if (uri == null ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        uri.path != '/api/files/download') {
      return null;
    }
    final query = uri.queryParametersAll;
    final pathValues = query['path'];
    final dashboard = Uri.parse(
      '${connection.dashboardUseHttps ? 'https' : 'http'}://'
      '${connection.dashboardHost}:${connection.dashboardPort}',
    );
    if (uri.scheme.toLowerCase() != dashboard.scheme ||
        uri.host.toLowerCase() != dashboard.host.toLowerCase() ||
        uri.port != dashboard.port ||
        query.length != 1 ||
        pathValues == null ||
        pathValues.length != 1) {
      return null;
    }
    return _managedPathEndpoint(pathValues.single);
  }

  static String? _managedPathEndpoint(String? rawPath) {
    final path = rawPath?.trim() ?? '';
    if (!_safeManagedPath(path)) return null;
    final query = Uri(queryParameters: {'path': path}).query;
    return 'files/download?$query';
  }

  static bool _safeManagedPath(String path) {
    if (path.isEmpty ||
        path == '/' ||
        path.length > 2048 ||
        !path.startsWith('/') ||
        path.startsWith('//') ||
        path.contains('//') ||
        path.contains(r'\') ||
        _hasControl(path)) {
      return false;
    }
    for (final rawSegment in path.split(RegExp(r'[\\/]')).skip(1)) {
      if (rawSegment.isEmpty) return false;
      late final String decoded;
      try {
        decoded = Uri.decodeComponent(rawSegment);
      } on FormatException {
        return false;
      }
      if (decoded == '.' ||
          decoded == '..' ||
          decoded.contains('/') ||
          decoded.contains(r'\') ||
          _hasControl(decoded)) {
        return false;
      }
    }
    if (ServerPath.looksWindows(path)) return true;
    final uri = Uri.tryParse(path);
    return uri != null &&
        !uri.hasScheme &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        !uri.pathSegments.any((segment) => segment == '.' || segment == '..');
  }

  static bool _hasControl(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);
}
