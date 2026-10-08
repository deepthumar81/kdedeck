import 'dart:convert';

import 'approved_application_registry.dart';

const int currentConfigSchemaVersion = 1;

/// Limits applied to a standalone daemon configuration.
///
/// The validator is deliberately independent of persistence and networking so
/// that both can use the same pure decision. Tests can provide smaller limits
/// to exercise every boundary without constructing a server.
class ConfigLimits {
  const ConfigLimits({
    this.maxBoards = 32,
    this.maxItemsPerBoard = 256,
    this.maxIdLength = 128,
    this.maxTitleLength = 256,
    this.maxPayloadLength = 4096,
    this.maxIconLength = 512,
    this.maxIconBase64Length = 8 * 1024 * 1024,
    this.maxSystemIconPathLength = 4096,
    this.maxGridColumns = 64,
    this.maxGridRows = 64,
    this.maxSpan = 64,
    this.maxCoordinate = 64,
    this.maxUnknownStringLength = 4096,
    this.maxUnknownCollectionEntries = 256,
    this.maxNestingDepth = 8,
    this.maxSerializedBytes = 16 * 1024 * 1024,
  });

  final int maxBoards;
  final int maxItemsPerBoard;
  final int maxIdLength;
  final int maxTitleLength;
  final int maxPayloadLength;
  final int maxIconLength;
  final int maxIconBase64Length;
  final int maxSystemIconPathLength;
  final int maxGridColumns;
  final int maxGridRows;
  final int maxSpan;
  final int maxCoordinate;
  final int maxUnknownStringLength;
  final int maxUnknownCollectionEntries;
  final int maxNestingDepth;
  final int maxSerializedBytes;
}

class ConfigValidationResult {
  const ConfigValidationResult.valid(this.config) : errorCode = null;

  const ConfigValidationResult.invalid(this.errorCode) : config = null;

  final Map<String, dynamic>? config;
  final String? errorCode;

  bool get isValid => config != null;
}

/// Pure validation and defensive copying for the standalone config schema.
class ConfigValidator {
  const ConfigValidator({this.limits = const ConfigLimits()});

  final ConfigLimits limits;

  ConfigValidationResult validate(Object? value) {
    try {
      final config = _validateConfig(value);
      final encodedLength = utf8.encode(jsonEncode(config)).length;
      if (encodedLength > limits.maxSerializedBytes) {
        throw const _ConfigValidationException('config_too_large');
      }
      return ConfigValidationResult.valid(config);
    } on _ConfigValidationException catch (error) {
      return ConfigValidationResult.invalid(error.code);
    } catch (_) {
      // Keep callers from receiving parser/runtime details or user data.
      return const ConfigValidationResult.invalid('invalid_config');
    }
  }

  Map<String, dynamic> _validateConfig(Object? value) {
    final input = _map(value, 'config');
    final schemaVersion = input['config_schema_version'];
    if (input.containsKey('config_schema_version') &&
        (schemaVersion is! int ||
            schemaVersion != currentConfigSchemaVersion)) {
      throw const _ConfigValidationException('unsupported_config_version');
    }

    final output = <String, dynamic>{
      'config_schema_version': currentConfigSchemaVersion,
    };
    var hasBoards = false;

    for (final entry in input.entries) {
      final key = _key(entry.key, 'config');
      if (key == 'config_schema_version') {
        continue;
      } else if (key == 'boards') {
        hasBoards = true;
        output[key] = _validateBoards(entry.value);
      } else {
        output[key] = _safeCopy(entry.value, 'config.$key', 1);
      }
    }

    if (!hasBoards) throw const _ConfigValidationException('missing_boards');
    return output;
  }

  List<dynamic> _validateBoards(Object? value) {
    if (value is! List) {
      throw const _ConfigValidationException('boards_not_list');
    }
    if (value.length > limits.maxBoards) {
      throw const _ConfigValidationException('too_many_boards');
    }

    final ids = <String>{};
    return [
      for (var index = 0; index < value.length; index++)
        _validateBoard(value[index], index, ids),
    ];
  }

  Map<String, dynamic> _validateBoard(
    Object? value,
    int index,
    Set<String> ids,
  ) {
    final input = _map(value, 'boards[$index]');
    final output = <String, dynamic>{};
    final id = _requiredString(
      input,
      'id',
      'boards[$index].id',
      limits.maxIdLength,
    );
    _addId(ids, id, 'boards[$index].id');
    output['id'] = id;

    if (input.containsKey('title')) {
      output['title'] = _providedString(
        input['title'],
        'boards[$index].title',
        limits.maxTitleLength,
      );
    }

    final columns = _optionalInteger(
      input,
      'grid_columns',
      'boards[$index].grid_columns',
      4,
      limits.maxGridColumns,
    );
    final rows = _optionalInteger(
      input,
      'grid_rows',
      'boards[$index].grid_rows',
      3,
      limits.maxGridRows,
    );
    output['grid_columns'] = columns;
    output['grid_rows'] = rows;

    final items = input['items'];
    if (items is! List) {
      throw const _ConfigValidationException('items_not_list');
    }
    if (items.length > limits.maxItemsPerBoard) {
      throw const _ConfigValidationException('too_many_items');
    }
    output['items'] = [
      for (var itemIndex = 0; itemIndex < items.length; itemIndex++)
        _validateItem(items[itemIndex], index, itemIndex, columns, rows, ids),
    ];

    for (final entry in input.entries) {
      final key = _key(entry.key, 'boards[$index]');
      if (output.containsKey(key)) continue;
      output[key] = _safeCopy(entry.value, 'boards[$index].$key', 2);
    }
    return output;
  }

  Map<String, dynamic> _validateItem(
    Object? value,
    int boardIndex,
    int itemIndex,
    int columns,
    int rows,
    Set<String> ids,
  ) {
    final path = 'boards[$boardIndex].items[$itemIndex]';
    final input = _map(value, path);
    final output = <String, dynamic>{};

    final id = _requiredString(input, 'id', '$path.id', limits.maxIdLength);
    _addId(ids, id, '$path.id');
    output['id'] = id;

    if (input.containsKey('title')) {
      output['title'] = _providedString(
        input['title'],
        '$path.title',
        limits.maxTitleLength,
      );
    }

    final type = _optionalString(input, 'type', '$path.type', 64);
    if (type != null) output['type'] = type;

    final action = _optionalString(input, 'action', '$path.action', 64);
    if (action != null) {
      _validateAction(action, input['payload'], '$path.action');
      output['action'] = action;
    }

    if (input.containsKey('payload')) {
      output['payload'] = _nullableString(
        input['payload'],
        '$path.payload',
        limits.maxPayloadLength,
      );
    }
    if (input.containsKey('icon')) {
      output['icon'] = _nullableString(
        input['icon'],
        '$path.icon',
        limits.maxIconLength,
      );
    }
    if (input.containsKey('icon_base64')) {
      final icon = input['icon_base64'];
      output['icon_base64'] = icon == null
          ? null
          : _validateIconBase64(icon, '$path.icon_base64');
    }
    if (input.containsKey('system_icon_path')) {
      output['system_icon_path'] = _nullableString(
        input['system_icon_path'],
        '$path.system_icon_path',
        limits.maxSystemIconPathLength,
      );
    }

    final spanColumns = _optionalInteger(
      input,
      'span_cols',
      '$path.span_cols',
      1,
      limits.maxSpan,
    );
    final spanRows = _optionalInteger(
      input,
      'span_rows',
      '$path.span_rows',
      1,
      limits.maxSpan,
    );
    if (spanColumns > columns || spanRows > rows) {
      throw const _ConfigValidationException('span_out_of_bounds');
    }
    output['span_cols'] = spanColumns;
    output['span_rows'] = spanRows;

    final gridX = _optionalInteger(
      input,
      'grid_x',
      '$path.grid_x',
      0,
      limits.maxCoordinate,
    );
    final gridY = _optionalInteger(
      input,
      'grid_y',
      '$path.grid_y',
      0,
      limits.maxCoordinate,
    );
    if (gridX + spanColumns > columns || gridY + spanRows > rows) {
      throw const _ConfigValidationException('coordinate_out_of_bounds');
    }
    if (input.containsKey('grid_x')) output['grid_x'] = gridX;
    if (input.containsKey('grid_y')) output['grid_y'] = gridY;

    for (final entry in input.entries) {
      final key = _key(entry.key, path);
      if (output.containsKey(key)) continue;
      output[key] = _safeCopy(entry.value, '$path.$key', 3);
    }
    return output;
  }

  void _validateAction(String action, Object? rawPayload, String path) {
    const actions = {
      'launch_app',
      'open_url',
      'audio_volume',
      'audio_mute_toggle',
      'brightness',
      'mpris_action',
      'kde_action',
      'clock_widget',
    };
    if (!actions.contains(action)) {
      throw const _ConfigValidationException('unknown_action');
    }
    final payload = rawPayload == null
        ? null
        : _nullableString(rawPayload, '$path.payload', limits.maxPayloadLength);
    if (action == 'launch_app') {
      if (payload == null ||
          !ApprovedApplicationRegistry.isValidIdentity(payload)) {
        throw const _ConfigValidationException('unsafe_launch_payload');
      }
    } else if (action == 'open_url') {
      if (payload == null || !_isSafeHttpUrl(payload)) {
        throw const _ConfigValidationException('unsafe_url');
      }
    } else if (action == 'mpris_action') {
      const values = {
        'play-pause',
        'play_pause',
        'next',
        'previous',
        'stop',
        'play',
        'pause',
        'volume_up',
        'volume_down',
        'mute',
      };
      if (payload == null || !values.contains(payload)) {
        throw const _ConfigValidationException('invalid_mpris_payload');
      }
    } else if (action == 'kde_action') {
      const values = {'sleep', 'shutdown', 'lock', 'logout'};
      if (payload == null || !values.contains(payload)) {
        throw const _ConfigValidationException('invalid_kde_payload');
      }
    }
  }

  String _validateIconBase64(Object? value, String path) {
    if (value is! String) {
      throw const _ConfigValidationException('icon_base64_not_string');
    }
    if (value.length > limits.maxIconBase64Length) {
      throw const _ConfigValidationException('icon_base64_too_large');
    }
    final match = RegExp(
      r'^data:image/(?:png|jpeg|jpg|gif|svg\+xml);base64,([A-Za-z0-9+/]*={0,2})$',
      caseSensitive: false,
    ).firstMatch(value);
    if (match == null || match.group(1)!.isEmpty) {
      throw const _ConfigValidationException('invalid_icon_base64');
    }
    try {
      base64.decode(match.group(1)!);
    } catch (_) {
      throw const _ConfigValidationException('invalid_icon_base64');
    }
    return value;
  }

  dynamic _safeCopy(Object? value, String path, int depth) {
    if (depth > limits.maxNestingDepth) {
      throw const _ConfigValidationException('config_too_deep');
    }
    if (value == null || value is bool) return value;
    if (value is String) {
      return _string(value, path, limits.maxUnknownStringLength);
    }
    if (value is num) {
      if (!value.isFinite) {
        throw const _ConfigValidationException('non_finite_number');
      }
      return value;
    }
    if (value is List) {
      if (value.length > limits.maxUnknownCollectionEntries) {
        throw const _ConfigValidationException('collection_too_large');
      }
      return [
        for (var index = 0; index < value.length; index++)
          _safeCopy(value[index], '$path[$index]', depth + 1),
      ];
    }
    if (value is Map) {
      if (value.length > limits.maxUnknownCollectionEntries) {
        throw const _ConfigValidationException('collection_too_large');
      }
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final key = _key(entry.key, path);
        result[key] = _safeCopy(entry.value, '$path.$key', depth + 1);
      }
      return result;
    }
    throw const _ConfigValidationException('invalid_value');
  }

  Map _map(Object? value, String path) {
    if (value is! Map) {
      throw const _ConfigValidationException('value_not_map');
    }
    return value;
  }

  String _key(Object? value, String path) {
    if (value is! String || value.isEmpty || value.length > 128) {
      throw const _ConfigValidationException('invalid_key');
    }
    return value;
  }

  String _requiredString(Map input, String key, String path, int maxLength) {
    if (!input.containsKey(key)) {
      throw const _ConfigValidationException('missing_string');
    }
    final value = input[key];
    if (value is! String || value.trim().isEmpty) {
      throw const _ConfigValidationException('invalid_string');
    }
    return _string(value, path, maxLength);
  }

  String? _optionalString(Map input, String key, String path, int maxLength) {
    if (!input.containsKey(key)) return null;
    return _nullableString(input[key], path, maxLength);
  }

  String _providedString(Object? value, String path, int maxLength) {
    if (value is! String) {
      throw const _ConfigValidationException('string_expected');
    }
    return _string(value, path, maxLength);
  }

  String? _nullableString(Object? value, String path, int maxLength) {
    if (value == null) return null;
    if (value is! String) {
      throw const _ConfigValidationException('string_expected');
    }
    return _string(value, path, maxLength);
  }

  String _string(String value, String path, int maxLength) {
    if (value.length > maxLength ||
        value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      throw const _ConfigValidationException('string_too_large_or_control');
    }
    return value;
  }

  int _optionalInteger(
    Map input,
    String key,
    String path,
    int defaultValue,
    int maximum,
  ) {
    if (!input.containsKey(key)) return defaultValue;
    final value = input[key];
    if (value is! int || value < 0 || value > maximum) {
      throw const _ConfigValidationException('invalid_integer');
    }
    if ((key == 'grid_columns' || key == 'grid_rows') && value == 0) {
      throw const _ConfigValidationException('invalid_grid_dimension');
    }
    if ((key == 'span_cols' || key == 'span_rows') && value == 0) {
      throw const _ConfigValidationException('invalid_span');
    }
    return value;
  }

  void _addId(Set<String> ids, String id, String path) {
    if (!ids.add(id)) {
      throw const _ConfigValidationException('duplicate_id');
    }
  }

  bool _isSafeHttpUrl(String value) {
    if (value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
      return false;
    }
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }
}

final class _ConfigValidationException implements Exception {
  const _ConfigValidationException(this.code);

  final String code;
}
