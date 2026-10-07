/// Release identity for the standalone KDE Deck daemon.
///
/// Keep the release version and build number monotonic across published
/// artifacts. The package version in `pubspec.yaml` must remain aligned with
/// these values until release automation becomes authoritative.
final class StandaloneReleaseMetadata {
  const StandaloneReleaseMetadata._();

  static const String artifactName = 'kdedeck_daemon';
  static const String version = '1.0.0';
  static const int build = 1;
  static const String displayVersion = '$version+$build';
  static const String displayName = '$artifactName $displayVersion';
}
