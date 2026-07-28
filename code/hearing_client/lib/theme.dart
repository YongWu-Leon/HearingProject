import 'package:flutter/material.dart';

/// The app's palette, unchanged from v1 so the rebuilt screens still look like
/// the same product: cyan page, dark-cyan chrome, amber for the volume control
/// and for "something is happening".
class AppTheme {
  static const cyan = Color(0xFF00BCD4);
  static const darkCyan = Color(0xFF0097A7);
  static const deepCyan = Color(0xFF00838F);
  static const paleCyan = Color(0xFFE0F7FA);
  static const amber = Color(0xFFFFC107);

  /// Translucent white panels over the cyan page -- the v1 card treatment.
  static const panel = Color(0x1AFFFFFF); // white10
  static const panelBorder = Color(0x4DFFFFFF); // white30
  static const panelDim = Color(0x0FFFFFFF);

  static const online = Color(0xFFB9F6CA);
  static const offline = Color(0x66FFFFFF);

  /// Row backgrounds in the records view. The subject's own actions are colour
  /// coded: quieter is red, louder is green, and the level the operator set is
  /// plain white.
  static const rowInitial = Colors.white;
  static const rowLowered = Color(0xFFFFEBEE);
  static const rowRaised = Color(0xFFE8F5E9);

  static const rowInitialText = Color(0xFF263238);
  static const rowLoweredText = Color(0xFF8D3B3B);
  static const rowRaisedText = Color(0xFF3B6D42);
  static const rowLoweredIcon = Color(0xFFC62828);
  static const rowRaisedIcon = Color(0xFF2E7D32);

  /// A soft signature colour per node, so node01 / node02 / node03 are told
  /// apart at a glance without the palette shouting -- used for the border and
  /// tinted surfaces around each test group in the records view, and the little
  /// square by the node name on the main screen. Pastels, deliberately gentle.
  static const Map<String, Color> _nodeColors = {
    'node01': Color(0xFFFFCC80), // soft amber
    'node02': Color(0xFFB39DDB), // soft lavender
    'node03': Color(0xFFF48FB1), // soft pink
  };

  /// The darker shade of the same hue, for text/icons placed ON the soft colour
  /// (white would be unreadable on a pastel).
  static const Map<String, Color> _onNodeColors = {
    'node01': Color(0xFFBF360C), // deep orange
    'node02': Color(0xFF4527A0), // deep indigo
    'node03': Color(0xFFAD1457), // deep magenta
  };

  static const List<Color> _nodePalette = [
    Color(0xFFFFCC80), Color(0xFFB39DDB), Color(0xFFF48FB1),
    Color(0xFFA5D6A7), Color(0xFF90CAF9), Color(0xFFBCAAA4),
  ];
  static const List<Color> _onNodePalette = [
    Color(0xFFBF360C), Color(0xFF4527A0), Color(0xFFAD1457),
    Color(0xFF1B5E20), Color(0xFF0D47A1), Color(0xFF4E342E),
  ];

  static Color nodeColor(String nodeId) =>
      _nodeColors[nodeId] ??
      _nodePalette[nodeId.hashCode.abs() % _nodePalette.length];

  /// Text/icon colour to use on top of [nodeColor] for the same node.
  static Color onNodeColor(String nodeId) =>
      _onNodeColors[nodeId] ??
      _onNodePalette[nodeId.hashCode.abs() % _onNodePalette.length];

  static BoxDecoration panelBox({Color? border, double radius = 10}) =>
      BoxDecoration(
        color: panel,
        border: Border.all(color: border ?? panelBorder),
        borderRadius: BorderRadius.circular(radius),
      );

  /// Standard frequency ladder, unchanged from v1.
  static const List<double> frequencies = [
    125, 250, 500, 750, 1000, 1500,
    2000, 3000, 4000, 6000, 8000, 10000,
  ];

  static String formatHz(double hz) => hz >= 1000
      ? '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)}k'
      : hz.toStringAsFixed(0);

  static String earLabel(String ear) {
    switch (ear) {
      case 'L':
        return 'Left';
      case 'R':
        return 'Right';
      default:
        return 'Both';
    }
  }
}
