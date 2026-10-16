/// Explicit policy for durable standalone bearer-session metadata.
///
/// Persistence is disabled unless the operator opts in with the exact
/// `KDEDECK_SESSION_PERSISTENCE=required` value. Unknown values fail closed
/// rather than silently changing the security or recovery contract.
enum SessionPersistenceMode { disabled, required }

final class SessionPersistencePolicy {
  const SessionPersistencePolicy(this.mode);

  factory SessionPersistencePolicy.fromEnvironment(
    Map<String, String> environment,
  ) {
    final raw = environment['KDEDECK_SESSION_PERSISTENCE']
        ?.trim()
        .toLowerCase();
    return switch (raw) {
      null || '' || 'disabled' => const SessionPersistencePolicy(
        SessionPersistenceMode.disabled,
      ),
      'required' => const SessionPersistencePolicy(
        SessionPersistenceMode.required,
      ),
      _ => throw ArgumentError.value(
        environment['KDEDECK_SESSION_PERSISTENCE'],
        'KDEDECK_SESSION_PERSISTENCE',
        'must be disabled or required',
      ),
    };
  }

  final SessionPersistenceMode mode;

  bool get isRequired => mode == SessionPersistenceMode.required;
}
