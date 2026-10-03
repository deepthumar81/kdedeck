import 'dart:io';

/// Resolves TLS exclusively from the daemon's local environment. Never put
/// these paths or key contents in board configuration or protocol messages.
SecurityContext? serverTlsContext(
  Map<String, String> environment, {
  required bool requireTls,
}) {
  const certificateVariable = 'KDEDECK_TLS_CERT_FILE';
  const keyVariable = 'KDEDECK_TLS_KEY_FILE';
  final certificate = environment[certificateVariable];
  final key = environment[keyVariable];
  if (certificate == null && key == null) {
    if (requireTls) throw const FormatException('TLS required');
    return null;
  }
  if (certificate == null ||
      certificate.trim().isEmpty ||
      key == null ||
      key.trim().isEmpty) {
    throw const FormatException('Incomplete TLS configuration');
  }

  // Certificate/key parsing happens before opening any network listener.
  final context = SecurityContext(withTrustedRoots: false);
  context.useCertificateChain(certificate);
  context.usePrivateKey(key);
  return context;
}
