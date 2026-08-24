import 'package:flutter/material.dart';

class DynamicMatrixGrid extends StatelessWidget {
  final int cols;
  final int rows;
  final double spacing;
  final int itemCount;
  final int Function(int index) getSpanCols;
  final int Function(int index) getSpanRows;
  final Widget Function(BuildContext context, int index, int spanCols, int spanRows) itemBuilder;
  final Widget Function(BuildContext context)? emptyBuilder;

  const DynamicMatrixGrid({
    super.key,
    required this.cols,
    required this.rows,
    this.spacing = 8.0,
    required this.itemCount,
    required this.getSpanCols,
    required this.getSpanRows,
    required this.itemBuilder,
    this.emptyBuilder,
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

        for (int i = 0; i < itemCount; i++) {
          final int spanCols = getSpanCols(i).clamp(1, cols);
          final int spanRows = getSpanRows(i).clamp(1, rows);

          // Find first available spot
          bool placed = false;
          for (int r = 0; r < rows && !placed; r++) {
            for (int c = 0; c < cols && !placed; c++) {
              if (_canFit(occupied, r, c, spanRows, spanCols)) {
                // Mark occupied
                _markOccupied(occupied, r, c, spanRows, spanCols);

                // Add positioned widget
                positionedChildren.add(
                  Positioned(
                    left: c * (cellWidth + spacing),
                    top: r * (cellHeight + spacing),
                    width: (spanCols * cellWidth) + ((spanCols - 1) * spacing),
                    height: (spanRows * cellHeight) + ((spanRows - 1) * spacing),
                    child: itemBuilder(context, i, spanCols, spanRows),
                  ),
                );
                placed = true;
              }
            }
          }
        }

        // Fill remaining empty slots
        if (emptyBuilder != null) {
          for (int r = 0; r < rows; r++) {
            for (int c = 0; c < cols; c++) {
              if (!occupied[r][c]) {
                positionedChildren.add(
                  Positioned(
                    left: c * (cellWidth + spacing),
                    top: r * (cellHeight + spacing),
                    width: cellWidth,
                    height: cellHeight,
                    child: emptyBuilder!(context),
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
