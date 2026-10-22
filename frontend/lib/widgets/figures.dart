import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/formatters.dart';

/// Number text used by every table and card, so amounts line up the same way
/// everywhere: tabular (equal-width) digits, thousands separators, and one
/// colour code: green = profit / credit, red = loss / deduction, grey = zero.
class Figure extends StatelessWidget {
  final String text;
  final Color? color;
  final FontWeight weight;
  final double? size;

  const Figure._(this.text, this.color, this.weight, this.size, {super.key});

  static const _tabular = [FontFeature.tabularFigures()];

  static Color signColor(double value) =>
      value > 0 ? AppTheme.success : (value < 0 ? AppTheme.danger : Colors.black54);

  /// Profit / Loss points: `1,250` green, `-2,000` red, `0` grey.
  factory Figure.profitLoss(double value, {Key? key}) => Figure._(
        value > 0 ? '+${Formatters.points(value)}' : Formatters.points(value),
        signColor(value),
        FontWeight.w700,
        null,
        key: key,
      );

  /// A bonus adjustment / balance with an explicit sign (`+30.00`, `-300.00`).
  /// Null (not calculated yet) shows a dash.
  factory Figure.signed(double? value, {Key? key}) => value == null
      ? Figure._('—', Colors.black38, FontWeight.w400, null, key: key)
      : Figure._(Formatters.signed(value), signColor(value), FontWeight.w700, null, key: key);

  /// The week's actual win/loss: bigger and bolder than the other figures.
  factory Figure.signedBig(double? value, {Key? key}) => value == null
      ? Figure._('—', Colors.black38, FontWeight.w400, null, key: key)
      : Figure._(Formatters.signed(value), signColor(value), FontWeight.w900, 16, key: key);

  /// A payable amount in rupees: green when above zero, muted at zero.
  factory Figure.payable(double value, {double? size, Key? key}) => Figure._(
        Formatters.rupees(value),
        value > 0 ? AppTheme.success : Colors.black45,
        FontWeight.w800,
        size,
        key: key,
      );

  /// A plain points value (casino / sport points).
  factory Figure.points(double value, {Key? key}) =>
      Figure._(Formatters.points(value), null, FontWeight.w500, null, key: key);

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFeatures: _tabular,
          fontWeight: weight,
          color: color,
          fontSize: size,
        ),
      );
}
