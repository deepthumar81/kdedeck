import 'package:backend/release_metadata.dart';
import 'package:test/test.dart';

void main() {
  test('exposes a stable daemon artifact identity and release build', () {
    expect(StandaloneReleaseMetadata.artifactName, 'kdedeck_daemon');
    expect(StandaloneReleaseMetadata.version, '1.0.0');
    expect(StandaloneReleaseMetadata.build, 1);
    expect(StandaloneReleaseMetadata.displayVersion, '1.0.0+1');
    expect(StandaloneReleaseMetadata.displayName, 'kdedeck_daemon 1.0.0+1');
  });
}
