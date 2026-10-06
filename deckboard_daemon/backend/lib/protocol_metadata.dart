/// Immutable protocol metadata advertised by the standalone Dart server.
///
/// Keep the capability names bounded and stable. Adding a capability is
/// additive; changing or removing one requires an explicit compatibility
/// decision.
final class StandaloneProtocolMetadata {
  const StandaloneProtocolMetadata._();

  /// Stable wire-protocol version advertised by the standalone server.
  static const int protocolVersion = 1;

  /// Protocol operations currently supported by the standalone server.
  static const List<String> capabilities = <String>[
    'trigger_action',
    'save_config',
    'get_system_apps',
  ];

  /// Additive fields included in authenticated `init_state` messages.
  static const Map<String, Object> advertisement = <String, Object>{
    'protocol_version': protocolVersion,
    'capabilities': capabilities,
  };
}
