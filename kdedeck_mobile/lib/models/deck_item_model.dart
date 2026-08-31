/// Strongly-typed model representing an individual tile/button on a KDE Deck board.
class DeckItemModel {
  final String id;
  final String title;
  final String type; // 'button', 'volume_slider', 'brightness_slider'
  final String action; // 'launch_app', 'open_url', 'audio_volume', 'brightness', etc.
  final String payload;
  final String icon;
  final int spanCols;
  final int spanRows;

  DeckItemModel({
    required this.id,
    required this.title,
    this.type = 'button',
    this.action = 'launch_app',
    this.payload = '',
    this.icon = 'terminal',
    this.spanCols = 1,
    this.spanRows = 1,
  });

  factory DeckItemModel.fromJson(Map<String, dynamic> json) {
    return DeckItemModel(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Button',
      type: json['type']?.toString() ?? 'button',
      action: json['action']?.toString() ?? 'launch_app',
      payload: json['payload']?.toString() ?? '',
      icon: json['icon']?.toString() ?? 'terminal',
      spanCols: (json['span_cols'] as num? ?? 1).toInt(),
      spanRows: (json['span_rows'] as num? ?? 1).toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "title": title,
      "type": type,
      "action": action,
      "payload": payload,
      "icon": icon,
      "span_cols": spanCols,
      "span_rows": spanRows,
    };
  }

  DeckItemModel copyWith({
    String? id,
    String? title,
    String? type,
    String? action,
    String? payload,
    String? icon,
    int? spanCols,
    int? spanRows,
  }) {
    return DeckItemModel(
      id: id ?? this.id,
      title: title ?? this.title,
      type: type ?? this.type,
      action: action ?? this.action,
      payload: payload ?? this.payload,
      icon: icon ?? this.icon,
      spanCols: spanCols ?? this.spanCols,
      spanRows: spanRows ?? this.spanRows,
    );
  }
}
