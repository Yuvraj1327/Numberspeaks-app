import 'package:flutter/material.dart';

import '../core/app_theme.dart';

/// One column of a [GridTable]: its header text and its base width.
class GridColumn {
  final String label;
  final double width;

  /// Right-aligns the header and the cells (for amounts).
  final bool numeric;

  const GridColumn(this.label, this.width, {this.numeric = false});
}

/// A real table for the review and results screens: a sticky header row and
/// many rows, scrolling vertically (rows) and, when the screen is narrower
/// than the table, horizontally (a phone) — on a wide screen the columns
/// simply stretch to fill the width.
///
/// Rows are built lazily, so a report with thousands of users stays smooth.
class GridTable extends StatelessWidget {
  final List<GridColumn> columns;
  final int itemCount;

  /// The cells of row [index], one widget per column, in column order.
  final List<Widget> Function(BuildContext context, int index) cellsBuilder;

  /// Called when a row is tapped. Taps on buttons inside a cell are handled
  /// by those buttons and do not trigger this.
  final void Function(int index)? onRowTap;
  final double rowHeight;

  const GridTable({
    super.key,
    required this.columns,
    required this.itemCount,
    required this.cellsBuilder,
    this.onRowTap,
    this.rowHeight = 60,
  });

  @override
  Widget build(BuildContext context) {
    final baseWidth = columns.fold<double>(0, (sum, c) => sum + c.width);

    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = constraints.maxWidth > baseWidth ? constraints.maxWidth / baseWidth : 1.0;
        final widths = [for (final c in columns) c.width * scale];
        final totalWidth = baseWidth * scale;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: totalWidth,
            height: constraints.maxHeight,
            child: Column(
              children: [
                _HeaderRow(columns: columns, widths: widths),
                Expanded(
                  child: ListView.builder(
                    itemCount: itemCount,
                    itemExtent: rowHeight,
                    itemBuilder: (context, index) {
                      final cells = cellsBuilder(context, index);
                      assert(cells.length == columns.length, 'One cell per column is required.');
                      return InkWell(
                        onTap: onRowTap == null ? null : () => onRowTap!(index),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: index.isOdd ? AppTheme.surfaceMuted.withValues(alpha: 0.45) : null,
                            border: Border(
                              bottom: BorderSide(color: AppTheme.navy.withValues(alpha: 0.07)),
                            ),
                          ),
                          child: Row(
                            children: [
                              for (var i = 0; i < columns.length; i++)
                                SizedBox(
                                  width: widths[i],
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 12),
                                    child: Align(
                                      alignment: columns[i].numeric
                                          ? Alignment.centerRight
                                          : Alignment.centerLeft,
                                      child: cells[i],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _HeaderRow extends StatelessWidget {
  final List<GridColumn> columns;
  final List<double> widths;

  const _HeaderRow({required this.columns, required this.widths});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: AppTheme.surfaceMuted,
        border: Border(bottom: BorderSide(color: AppTheme.navy.withValues(alpha: 0.12))),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: widths[i],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: columns[i].numeric ? Alignment.centerRight : Alignment.centerLeft,
                  child: Text(
                    columns[i].label.toUpperCase(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: columns[i].numeric ? TextAlign.right : TextAlign.left,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
