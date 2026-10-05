import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// A bounded failure with no filesystem path or credential in diagnostics.
class SessionStoreException implements Exception {
  const SessionStoreException();

  @override
  String toString() => 'SessionStoreException: session persistence unavailable';
}

/// Only fingerprints and non-secret authorization metadata cross this boundary.
class StoredSession {
  const StoredSession(
    this.fingerprint,
    this.role,
    this.issuedAt,
    this.expiresAt,
  );

  final String fingerprint;
  final String role;
  final DateTime issuedAt;
  final DateTime expiresAt;
}

String sessionTokenFingerprint(String token) =>
    sha256.convert(utf8.encode(token)).toString();

/// Synchronous to retain the existing session manager API and ordering.
abstract class SessionStore {
  List<StoredSession> read({required int maxSessions});

  void write(List<StoredSession> sessions, {required int maxSessions});
}

/// Atomic, private-file store owned by one instance at a time.
///
/// The containing directory is restricted to 0700 and files to 0600 on POSIX.
/// A persistent sibling lock file is held from first access until [close].
/// A pending marker prevents an interrupted write from restoring an older
/// snapshot. It must not be removed automatically: recovery requires explicit
/// operator intervention and invalidation of all previously issued tokens.
class FileSessionStore implements SessionStore {
  FileSessionStore(
    this.filePath, {
    void Function()? beforeReplace,
    void Function()? beforePendingCreate,
    void Function()? beforePendingWrite,
    void Function()? beforePendingClear,
  }) : _beforeReplace = beforeReplace,
       _beforePendingCreate = beforePendingCreate,
       _beforePendingWrite = beforePendingWrite,
       _beforePendingClear = beforePendingClear {
    if (!path.isAbsolute(filePath) || path.normalize(filePath) != filePath) {
      throw const SessionStoreException();
    }
  }

  factory FileSessionStore.inUserConfigDirectory({
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final base = env['XDG_CONFIG_HOME']?.trim();
    final home = env['HOME']?.trim();
    if (base != null && base.isNotEmpty && path.isAbsolute(base)) {
      return FileSessionStore(path.join(base, 'kdedeck', 'sessions.json'));
    }
    if (home == null || home.isEmpty || !path.isAbsolute(home)) {
      throw const SessionStoreException();
    }
    return FileSessionStore(
      path.join(home, '.config', 'kdedeck', 'sessions.json'),
    );
  }

  final String filePath;
  final void Function()? _beforeReplace;
  final void Function()? _beforePendingCreate;
  final void Function()? _beforePendingWrite;
  final void Function()? _beforePendingClear;
  String get _pendingPath => '$filePath.pending';
  String get _lockPath => '$filePath.lock';
  static final Set<String> _ownedPaths = <String>{};
  RandomAccessFile? _lockHandle;
  bool _closed = false;
  static const _maxFileBytes = 1024 * 1024;
  static final _fingerprintPattern = RegExp(r'^[0-9a-f]{64}$');

  /// Release ownership explicitly; a closed store cannot be reopened.
  void close() {
    if (_closed) return;
    _closed = true;
    final handle = _lockHandle;
    if (handle == null) return;
    // Keep the registry entry on a failed unlock/close: another instance in
    // this process must not take over while the OS handle may still be live.
    try {
      handle.unlockSync();
      handle.closeSync();
      _lockHandle = null;
      _ownedPaths.remove(filePath);
    } catch (_) {
      throw const SessionStoreException();
    }
  }

  void _ensureOwner() {
    if (_closed) throw const SessionStoreException();
    if (_lockHandle != null) return;
    if (_ownedPaths.contains(filePath)) throw const SessionStoreException();
    _prepareDirectory();
    final lockType = FileSystemEntity.typeSync(_lockPath, followLinks: false);
    if (lockType != FileSystemEntityType.notFound &&
        lockType != FileSystemEntityType.file) {
      throw const SessionStoreException();
    }
    // append does not truncate the persistent inode; the file is never
    // removed, since unlinking a locked inode would allow split ownership.
    final handle = File(_lockPath).openSync(mode: FileMode.append);
    try {
      if (FileSystemEntity.typeSync(_lockPath, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const SessionStoreException();
      }
      // FileLock.exclusive is the nonblocking variant (blockingExclusive is
      // deliberately not used); contention must fail promptly.
      handle.lockSync(FileLock.exclusive);
      _restrict(_lockPath, '600');
      _lockHandle = handle;
      _ownedPaths.add(filePath);
    } catch (_) {
      handle.closeSync();
      throw const SessionStoreException();
    }
  }

  @override
  List<StoredSession> read({required int maxSessions}) {
    try {
      _ensureOwner();
      // A marker of any kind (including a symlink or malformed file) means
      // that the snapshot may predate a failed revocation. Never restore it.
      if (FileSystemEntity.typeSync(_pendingPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const SessionStoreException();
      }
      final file = File(filePath);
      final type = FileSystemEntity.typeSync(filePath, followLinks: false);
      if (type == FileSystemEntityType.notFound) return const [];
      if (type != FileSystemEntityType.file ||
          file.lengthSync() > _maxFileBytes) {
        throw const SessionStoreException();
      }
      _restrict(filePath, '600');
      final data = jsonDecode(file.readAsStringSync());
      if (data is! Map<String, dynamic> ||
          data.length != 2 ||
          data['version'] != 1 ||
          data['sessions'] is! List) {
        throw const SessionStoreException();
      }
      final entries = data['sessions'] as List;
      if (entries.length > maxSessions) throw const SessionStoreException();
      final seen = <String>{};
      return entries
          .map((entry) {
            if (entry is! Map<String, dynamic> || entry.length != 4) {
              throw const SessionStoreException();
            }
            final fingerprint = entry['fingerprint'];
            final role = entry['role'];
            final issued = entry['issuedAt'];
            final expires = entry['expiresAt'];
            if (fingerprint is! String ||
                !_fingerprintPattern.hasMatch(fingerprint) ||
                !seen.add(fingerprint) ||
                role is! String ||
                !const ['viewer', 'control', 'configAdmin'].contains(role) ||
                issued is! int ||
                expires is! int ||
                issued >= expires) {
              throw const SessionStoreException();
            }
            return StoredSession(
              fingerprint,
              role,
              DateTime.fromMillisecondsSinceEpoch(issued, isUtc: true),
              DateTime.fromMillisecondsSinceEpoch(expires, isUtc: true),
            );
          })
          .toList(growable: false);
    } catch (_) {
      throw const SessionStoreException();
    }
  }

  @override
  void write(List<StoredSession> sessions, {required int maxSessions}) {
    String? temporaryPath;
    try {
      _ensureOwner();
      if (sessions.length > maxSessions) throw const SessionStoreException();
      final existing = FileSystemEntity.typeSync(filePath, followLinks: false);
      if (existing != FileSystemEntityType.notFound &&
          existing != FileSystemEntityType.file) {
        throw const SessionStoreException();
      }
      final seen = <String>{};
      final entries = sessions
          .map((session) {
            if (!_fingerprintPattern.hasMatch(session.fingerprint) ||
                !seen.add(session.fingerprint) ||
                !const [
                  'viewer',
                  'control',
                  'configAdmin',
                ].contains(session.role) ||
                !session.issuedAt.isBefore(session.expiresAt)) {
              throw const SessionStoreException();
            }
            return {
              'fingerprint': session.fingerprint,
              'role': session.role,
              'issuedAt': session.issuedAt.toUtc().millisecondsSinceEpoch,
              'expiresAt': session.expiresAt.toUtc().millisecondsSinceEpoch,
            };
          })
          .toList(growable: false);
      final bytes = utf8.encode(
        jsonEncode({'version': 1, 'sessions': entries}),
      );
      if (bytes.length > _maxFileBytes) throw const SessionStoreException();
      if (FileSystemEntity.typeSync(_pendingPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const SessionStoreException();
      }
      _beforePendingCreate?.call();
      // Exclusive creation rejects a pre-existing marker, including symlinks.
      // Once created, preserve it on *every* failure, including failed flushes
      // and failure to clear it after the primary replacement.
      final pending = File(_pendingPath)..createSync(exclusive: true);
      _restrict(_pendingPath, '600');
      final pendingSink = pending.openSync(mode: FileMode.writeOnly);
      try {
        _beforePendingWrite?.call();
        pendingSink.writeFromSync(utf8.encode('pending\n'));
        // Flush the file before touching the primary. dart:io does not expose
        // directory fsync, so sudden power loss is not covered by this barrier.
        pendingSink.flushSync();
      } finally {
        pendingSink.closeSync();
      }
      final random = Random.secure();
      // Exclusive creation prevents another writer from overwriting our temp file.
      temporaryPath =
          '$filePath.${random.nextInt(1 << 32).toRadixString(16)}.tmp';
      final temporary = File(temporaryPath)..createSync(exclusive: true);
      _restrict(temporaryPath, '600');
      final sink = temporary.openSync(mode: FileMode.writeOnly);
      try {
        sink.writeFromSync(bytes);
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
      _beforeReplace?.call();
      temporary.renameSync(filePath);
      temporaryPath = null;
      // A failed removal leaves the store unusable rather than allowing a
      // possibly stale snapshot to be accepted at the next startup.
      pending.deleteSync();
    } catch (_) {
      throw const SessionStoreException();
    } finally {
      if (temporaryPath != null) {
        try {
          File(temporaryPath).deleteSync();
        } catch (_) {
          // The failed operation is already reported without exposing a path.
        }
      }
    }
  }

  /// Offline recovery only: invalidate every stored token, including when a
  /// corrupt snapshot or interrupted write prevents normal reads and writes.
  /// The caller must stop the daemon first; a live owner prevents this reset.
  void resetSessions() {
    String? temporaryPath;
    try {
      _ensureOwner();
      final primaryType = FileSystemEntity.typeSync(
        filePath,
        followLinks: false,
      );
      if (primaryType != FileSystemEntityType.notFound &&
          primaryType != FileSystemEntityType.file) {
        throw const SessionStoreException();
      }
      final markerType = FileSystemEntity.typeSync(
        _pendingPath,
        followLinks: false,
      );
      if (markerType != FileSystemEntityType.notFound &&
          markerType != FileSystemEntityType.file) {
        throw const SessionStoreException();
      }
      if (markerType == FileSystemEntityType.notFound) {
        // Establish the blocking marker before replacing a possibly live
        // snapshot. A failed replacement must never expose old tokens again.
        _beforePendingCreate?.call();
        File(_pendingPath).createSync(exclusive: true);
        _restrict(_pendingPath, '600');
        final sink = File(_pendingPath).openSync(mode: FileMode.writeOnly);
        try {
          _beforePendingWrite?.call();
          sink.writeFromSync(utf8.encode('pending\n'));
          sink.flushSync();
        } finally {
          sink.closeSync();
        }
      } else {
        // Even a malformed marker blocks reads. Its contents need not be
        // trusted; it can only be removed after the empty snapshot commits.
        _restrict(_pendingPath, '600');
      }

      temporaryPath =
          '$filePath.${Random.secure().nextInt(1 << 32).toRadixString(16)}.tmp';
      final temporary = File(temporaryPath)..createSync(exclusive: true);
      _restrict(temporaryPath, '600');
      final sink = temporary.openSync(mode: FileMode.writeOnly);
      try {
        sink.writeFromSync(utf8.encode('{"version":1,"sessions":[]}'));
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
      _beforeReplace?.call();
      temporary.renameSync(filePath);
      temporaryPath = null;
      _beforePendingClear?.call();
      File(_pendingPath).deleteSync();
    } catch (_) {
      throw const SessionStoreException();
    } finally {
      if (temporaryPath != null) {
        try {
          File(temporaryPath).deleteSync();
        } catch (_) {
          // Preserve the bounded error; the pending marker still blocks reads.
        }
      }
    }
  }

  void _prepareDirectory() {
    final directoryPath = path.dirname(filePath);
    // Check every existing parent component, not just the immediate parent.
    // A symlink in XDG_CONFIG_HOME or HOME must not redirect a reset.
    var current = path.rootPrefix(directoryPath);
    for (final component in path.split(path.normalize(directoryPath))) {
      if (component == current || component == path.separator) continue;
      current = path.join(current, component);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw const SessionStoreException();
      }
    }
    final directory = Directory(directoryPath);
    // A symlink at the store's immediate parent is not a safe storage boundary.
    final type = FileSystemEntity.typeSync(directoryPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      directory.createSync(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const SessionStoreException();
    }
    _restrict(directoryPath, '700');
  }

  static void _restrict(String target, String mode) {
    if (Platform.isWindows) return;
    final result = Process.runSync('chmod', [mode, target]);
    if (result.exitCode != 0) throw const SessionStoreException();
  }
}
