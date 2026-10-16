import 'package:backend/session_persistence_policy.dart';
import 'package:backend/session_store.dart';
import 'package:test/test.dart';

void main() {
  test('persistence is disabled unless explicitly required', () {
    expect(
      SessionPersistencePolicy.fromEnvironment(const {}).mode,
      SessionPersistenceMode.disabled,
    );
    expect(
      SessionPersistencePolicy.fromEnvironment({
        'KDEDECK_SESSION_PERSISTENCE': 'disabled',
      }).mode,
      SessionPersistenceMode.disabled,
    );
    expect(
      SessionPersistencePolicy.fromEnvironment({
        'KDEDECK_SESSION_PERSISTENCE': ' REQUIRED ',
      }).mode,
      SessionPersistenceMode.required,
    );
  });

  test('unknown persistence policy values fail closed', () {
    expect(
      () => SessionPersistencePolicy.fromEnvironment({
        'KDEDECK_SESSION_PERSISTENCE': 'best-effort',
      }),
      throwsArgumentError,
    );
  });

  test('required policy resolves a private user-config store path', () {
    const environment = {
      'KDEDECK_SESSION_PERSISTENCE': 'required',
      'XDG_CONFIG_HOME': '/tmp/kdedeck-policy-config',
    };
    final policy = SessionPersistencePolicy.fromEnvironment(environment);
    expect(policy.isRequired, isTrue);

    final expected = FileSessionStore.inUserConfigDirectory(
      environment: environment,
    ).filePath;
    expect(expected, '/tmp/kdedeck-policy-config/kdedeck/sessions.json');
  });
}
