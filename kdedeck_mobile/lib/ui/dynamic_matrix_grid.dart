import 'package:flutter/material.dart';

class DynamicMatrixGrid extends StatelessWidget {
  final int cols;
  final int rows;
  final double spacing;
  final int itemCount;
  final int Function(int index) getSpanCols;
  final int Function(int index) getSpanRows;
  final int? Function(int index) getGridX;
  final int? Function(int index) getGridY;
  final Widget Function(BuildContext context, int index, int spanCols, int spanRows) itemBuilder;
  final Widget Function(BuildContext context)? emptyBuilder;
  final void Function(int draggedIndex, int targetCol, int targetRow)? onDrop;
  final bool isDraggable;

  const DynamicMatrixGrid({
    super.key,
    required this.cols,
    required this.rows,
    this.spacing = 8.0,
    required this.itemCount,
    required this.getSpanCols,
    required this.getSpanRows,
    required this.getGridX,
    required this.getGridY,
    required this.itemBuilder,
    this.emptyBuilder,
    this.onDrop,
    this.isDraggable = true,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth;
        final double availableHeight = constraints.maxHeight;

        // Calculate cell dimensions
        final double cellWidth = (availableWidth - (cols - 1) * spacing) / cols;
        final double cellHeight = (availableHeight - (rows - 1) * spacing) / rows;

        // Track occupied grid cells
        final List<List<bool>> occupied = List.generate(rows, (_) => List.filled(cols, false));

        final List<Widget> positionedChildren = [];

        // First pass: place items with explicit coordinates
        final List<Map<String, dynamic>> itemsToPlace = [];
        
        for (int i = 0; i < itemCount; i++) {
          final int? x = getGridX(i);
          final int? y = getGridY(i);
          final int spanCols = getSpanCols(i).clamp(1, cols);
          final int spanRows = getSpanRows(i).clamp(1, rows);

          if (x != null && y != null && _canFit(occupied, y, x, spanRows, spanCols)) {
            _markOccupied(occupied, y, x, spanRows, spanCols);
            itemsToPlace.add({
              'index': i, 'c': x, 'r': y, 'spanCols': spanCols, 'spanRows': spanRows
            });
          } else {
            // Needs auto-placement
            itemsToPlace.add({
              'index': i, 'c': null, 'r': null, 'spanCols': spanCols, 'spanRows': spanRows
            });
          }
        }

        // Second pass: auto-place items without valid coordinates
        for (var item in itemsToPlace) {
          if (item['r'] == null || item['c'] == null) {
            bool placed = false;
            for (int r = 0; r < rows && !placed; r++) {
              for (int c = 0; c < cols && !placed; c++) {
                if (_canFit(occupied, r, c, item['spanRows'], item['spanCols'])) {
                  _markOccupied(occupied, r, c, item['spanRows'], item['spanCols']);
                  item['r'] = r;
                  item['c'] = c;
                  placed = true;
                }
              }
            }
          }
        }

        // Build widgets for placed items
        for (var item in itemsToPlace) {
          if (item['r'] == null || item['c'] == null) continue; // Skip if it couldn't fit at all

          final int c = item['c'];
          final int r = item['r'];
          final int spanCols = item['spanCols'];
          final int spanRows = item['spanRows'];
          final int index = item['index'];

          final double w = (spanCols * cellWidth) + ((spanCols - 1) * spacing);
          final double h = (spanRows * cellHeight) + ((spanRows - 1) * spacing);
          final tileWidget = itemBuilder(context, index, spanCols, spanRows);

          Widget childContent;
          if (onDrop != null && isDraggable) {
            childContent = Draggable<int>(
              data: index,
              feedback: Material(
                color: Colors.transparent,
                child: SizedBox(
                  width: w * 0.95,
                  height: h * 0.95,
                  child: Opacity(opacity: 0.85, child: tileWidget),
                ),
              ),
              childWhenDragging: DragTarget<int>(
                onAcceptWithDetails: (details) {
                  if (details.data != index) onDrop!(details.data, c, r);
                },
                builder: (context, candidateData, rejectedData) => Opacity(opacity: 0.25, child: tileWidget),
              ),
              child: DragTarget<int>(
                onAcceptWithDetails: (details) {
                  if (details.data != index) onDrop!(details.data, c, r);
                },
                builder: (context, candidateData, rejectedData) {
                  final bool isHovered = candidateData.isNotEmpty;
                  return Container(
                    decoration: isHovered
                        ? BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.lightBlueAccent, width: 2),
                          )
                        : null,
                    child: tileWidget,
                  );
                },
              ),
            );
          } else {
            childContent = tileWidget;
          }

          positionedChildren.add(
            Positioned(
              left: c * (cellWidth + spacing),
              top: r * (cellHeight + spacing),
              width: w,
              height: h,
              child: childContent,
            ),
          );
        }

        // Fill remaining empty slots with DragTargets
        if (emptyBuilder != null || onDrop != null) {
          for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
              if (!occupied[r][c]) {
                Widget emptyContent = emptyBuilder != null ? emptyBuilder!(context) : const SizedBox();
                
                if (onDrop != null && isDraggable) {
                  final Widget innerContent = emptyContent;
                  emptyContent = DragTarget<int>(
                    onAcceptWithDetails: (details) {
                      onDrop!(details.data, c, r);
                    },
                    builder: (context, candidateData, rejectedData) {
                      final bool isHovered = candidateData.isNotEmpty;
                      return Container(
                        decoration: isHovered
                            ? BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: Colors.lightBlueAccent, width: 2),
                              )
                            : null,
                        child: innerContent,
                      );
                    },
                  );
                }

                positionedChildren.add(
                  Positioned(
                    left: c * (cellWidth + spacing),
                    top: r * (cellHeight + spacing),
                    width: cellWidth,
                    height: cellHeight,
                    child: emptyContent,
                  ),
                );
              }
            }
          }
        }

        return SizedBox(
          width: availableWidth,
          height: availableHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: positionedChildren,
          ),
        );
      },
    );
  }

  bool _canFit(List<List<bool>> occupied, int r, int c, int spanRows, int spanCols) {
    if (r + spanRows > rows || c + spanCols > cols) return false;
    for (int i = r; i < r + spanRows; i++) {
      for (int j = c; j < c + spanCols; j++) {
        if (occupied[i][j]) return false;
      }
    }
    return true;
  }

  void _markOccupied(List<List<bool>> occupied, int r, int c, int spanRows, int spanCols) {
    for (int i = r; i < r + spanRows; i++) {
      for (int j = c; j < c + spanCols; j++) {
        occupied[i][j] = true;
      }
    }
  }
}
