import 'deck_item_model.dart';

/// Strongly-typed model representing a KDE Deck Board (page of tiles).
class BoardModel {
  final String id;
  final String title;
  final int gridColumns;
  final int gridRows;
  final List<DeckItemModel> items;

  BoardModel({
    required this.id,
    required this.title,
    this.gridColumns = 5,
    this.gridRows = 3,
    required this.items,
  });

  factory BoardModel.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? [];
    return BoardModel(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Board',
      gridColumns: (json['grid_columns'] as num? ?? 5).toInt(),
      gridRows: (json['grid_rows'] as num? ?? 3).toInt(),
      items: rawItems.map((e) => DeckItemModel.fromJson(Map<String, dynamic>.from(e))).toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      "id": id,
      "title": title,
      "grid_columns": gridColumns,
      "grid_rows": gridRows,
      "items": items.map((item) => item.toJson()).toList(),
    };
  }

  BoardModel copyWith({
    String? id,
    String? title,
    int? gridColumns,
    int? gridRows,
    List<DeckItemModel>? items,
  }) {
    return BoardModel(
      id: id ?? this.id,
      title: title ?? this.title,
      gridColumns: gridColumns ?? this.gridColumns,
      gridRows: gridRows ?? this.gridRows,
      items: items ?? this.items,
    );
  }
}
