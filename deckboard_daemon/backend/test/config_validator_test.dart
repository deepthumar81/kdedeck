import 'dart:convert';
import 'dart:io';

import 'package:backend/config_validator.dart';
import 'package:test/test.dart';

void main() {
  test(
    'accepts the checked-in config without dropping client fields',
    () async {
      final fixture = jsonDecode(
        await File('deckboard_config.json').readAsString(),
      );
      final result = const ConfigValidator().validate(fixture);

      expect(result.isValid, isTrue, reason: result.errorCode);
      expect(result.config, isNotNull);
      final items = (result.config!['boards'] as List)
          .expand((board) => (board as Map)['items'] as List)
          .cast<Map>();
      expect(items.any((item) => item['type'] == 'volume_slider'), isTrue);
      expect(items.any((item) => item['action'] == 'launch_app'), isTrue);
      expect(items.any((item) => item['action'] == 'open_url'), isTrue);
      expect(items.any((item) => item['action'] == 'mpris_action'), isTrue);
      expect(items.any((item) => item['system_icon_path'] != null), isTrue);
      expect(items.any((item) => item['icon_base64'] != null), isTrue);
    },
  );

  test('rejects malformed top-level, board, and item collections', () {
    expect(_validate({'boards': null}), isFalse);
    expect(_validate({'boards': {}}), isFalse);
    expect(
      _validate({
        'boards': [{}],
      }),
      isFalse,
    );
    expect(
      _validate({
        'boards': [
          {'id': 'board', 'items': {}},
        ],
      }),
      isFalse,
    );
  });

  test('rejects empty and duplicate IDs', () {
    expect(_validate(_config(boardId: '')), isFalse);
    expect(_validate(_config(itemId: '')), isFalse);
    expect(
      _validate({
        'boards': [
          {
            'id': 'same',
            'items': [
              {'id': 'same'},
            ],
          },
        ],
      }),
      isFalse,
    );
  });

  test('enforces injectable board and item limits', () {
    final validator = ConfigValidator(
      limits: const ConfigLimits(maxBoards: 1, maxItemsPerBoard: 1),
    );
    expect(
      validator.validate({
        'boards': [_board('one'), _board('two')],
      }).isValid,
      isFalse,
    );
    expect(
      validator.validate({
        'boards': [
          {
            'id': 'board',
            'items': [
              {'id': 'one'},
              {'id': 'two'},
            ],
          },
        ],
      }).isValid,
      isFalse,
    );
  });

  test(
    'rejects invalid dimensions, spans, coordinates, and fractional values',
    () {
      expect(_validate(_config(gridColumns: 0)), isFalse);
      expect(_validate(_config(gridRows: -1)), isFalse);
      expect(_validate(_config(spanCols: 3)), isFalse);
      expect(_validate(_config(gridX: 2)), isFalse);
      expect(_validate(_config(gridY: 2)), isFalse);
      expect(_validate(_config(spanCols: 1.0)), isFalse);
    },
  );

  test('rejects oversized strings, images, and non-finite numbers', () {
    final limits = const ConfigLimits(
      maxTitleLength: 4,
      maxPayloadLength: 4,
      maxIconLength: 4,
      maxIconBase64Length: 20,
    );
    final validator = ConfigValidator(limits: limits);
    expect(validator.validate(_config(title: 'title')).isValid, isFalse);
    expect(validator.validate(_config(payload: 'payload')).isValid, isFalse);
    expect(validator.validate(_config(icon: 'icon')).isValid, isFalse);
    expect(
      validator.validate(_config(iconBase64: _pngDataUrl(24))).isValid,
      isFalse,
    );
    expect(
      validator.validate({
        ..._config(),
        'metadata': {'score': double.infinity},
      }).isValid,
      isFalse,
    );
  });

  test('rejects unknown or dangerous actions and payloads', () {
    expect(_validate(_config(action: 'run_shell')), isFalse);
    expect(
      _validate(_config(action: 'launch_app', payload: 'foo; rm -rf /')),
      isFalse,
    );
    expect(
      _validate(_config(action: 'open_url', payload: 'file:///tmp/a')),
      isFalse,
    );
    expect(
      _validate(
        _config(action: 'open_url', payload: 'https://user:pass@example.test'),
      ),
      isFalse,
    );
    expect(
      _validate(_config(action: 'mpris_action', payload: 'shell')),
      isFalse,
    );
    expect(
      _validate(_config(action: 'kde_action', payload: 'systemctl poweroff')),
      isFalse,
    );
  });

  test('returns a defensive copy and retains safe unknown JSON fields', () {
    final input = {
      ..._config(),
      'metadata': {'label': 'safe'},
    };
    final result = const ConfigValidator().validate(input);
    expect(result.isValid, isTrue, reason: result.errorCode);
    expect(result.config, isNot(same(input)));
    expect((result.config!['metadata'] as Map)['label'], 'safe');
  });
}

bool _validate(Map<String, dynamic> config) =>
    const ConfigValidator().validate(config).isValid;

Map<String, dynamic> _config({
  String boardId = 'board',
  String itemId = 'item',
  String title = 'Button',
  String action = 'launch_app',
  String payload = 'konsole',
  String icon = 'terminal',
  Object? iconBase64,
  int gridColumns = 2,
  int gridRows = 2,
  Object spanCols = 1,
  int spanRows = 1,
  int gridX = 0,
  int gridY = 0,
}) {
  final item = <String, dynamic>{
    'id': itemId,
    'title': title,
    'type': 'button',
    'action': action,
    'payload': payload,
    'icon': icon,
    'span_cols': spanCols,
    'span_rows': spanRows,
    'grid_x': gridX,
    'grid_y': gridY,
  };
  if (iconBase64 != null) item['icon_base64'] = iconBase64;
  return {
    'boards': [
      {
        'id': boardId,
        'title': 'Board',
        'grid_columns': gridColumns,
        'grid_rows': gridRows,
        'items': [item],
      },
    ],
  };
}

Map<String, dynamic> _board(String id) => {'id': id, 'items': []};

String _pngDataUrl(int encodedLength) =>
    'data:image/png;base64,${'A' * (encodedLength - 22)}';
