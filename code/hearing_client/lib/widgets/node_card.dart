import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/node_session.dart';
import '../services/ws_server.dart';
import '../theme.dart';

/// One node, one card.
///
/// Collapsed it is a single row: link state, what it is playing, and the live
/// level. Expanded it holds that node's OWN frequency / level / ear controls, so
/// three nodes can run different tones at the same time.
///
/// The frequency and level controls are the same shape: a fine text box plus a
/// slider. The level is in dB now (not the old 0-100 volume) -- the slider moves
/// in 5 dB steps, the box takes any value, and because that control also tracks
/// the subject's live level during playback there is no separate "subject level"
/// readout.
///
/// Stateful so it can own the two text controllers and keep them in sync with the
/// node's values -- when a heartbeat repaints the card, or the subject's X/Y
/// presses move the level during playback, the boxes must follow without wiping
/// whatever the operator is mid-way through typing.
class NodeCard extends StatefulWidget {
  final NodeSession node;
  final WsServer server;
  final VoidCallback onToggleExpand;
  final VoidCallback onOpenRecords;
  final void Function(String message) onStatus;

  const NodeCard({
    super.key,
    required this.node,
    required this.server,
    required this.onToggleExpand,
    required this.onOpenRecords,
    required this.onStatus,
  });

  @override
  State<NodeCard> createState() => _NodeCardState();
}

class _NodeCardState extends State<NodeCard> {
  late final TextEditingController _freqCtl;
  late final TextEditingController _levelCtl;
  final FocusNode _freqFocus = FocusNode();
  final FocusNode _levelFocus = FocusNode();

  NodeSession get node => widget.node;
  WsServer get server => widget.server;

  // Must match config.DB_FLOOR / DB_CEILING on the node. The floor is a clamp,
  // not a mute: the node still emits a real (very quiet) tone at -120 dB, so a
  // subject can keep stepping down instead of hitting sudden digital silence.
  static const double _dbMin = -120;
  static const double _dbMax = 0;
  static const double _dbStep = 5;

  @override
  void initState() {
    super.initState();
    _freqCtl = TextEditingController(text: node.frequency.toStringAsFixed(0));
    _levelCtl = TextEditingController(text: node.levelDb.toStringAsFixed(1));
  }

  @override
  void dispose() {
    _freqCtl.dispose();
    _levelCtl.dispose();
    _freqFocus.dispose();
    _levelFocus.dispose();
    super.dispose();
  }

  /// Pull the node's current values into the text boxes, but never while the box
  /// is focused (that would fight the operator's typing). This is what makes the
  /// sliders and the live X/Y updates show up in the boxes.
  void _syncFields() {
    if (!_freqFocus.hasFocus) {
      final t = node.frequency.toStringAsFixed(0);
      if (_freqCtl.text != t) _freqCtl.text = t;
    }
    if (!_levelFocus.hasFocus) {
      final t = node.levelDb.toStringAsFixed(1);
      if (_levelCtl.text != t) _levelCtl.text = t;
    }
  }

  void _setFrequency(double hz) {
    node.frequency = hz;
    server.refresh();
  }

  void _setLevel(double db) {
    node.levelDb = db.clamp(_dbMin, _dbMax);
    server.refresh();
  }

  @override
  Widget build(BuildContext context) {
    _syncFields();
    final online = node.online;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: online ? AppTheme.panel : AppTheme.panelDim,
        border: Border.all(
          color: node.selected && online ? AppTheme.amber : AppTheme.panelBorder,
          width: node.selected && online ? 1.5 : 1,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          _header(online),
          if (!node.expanded && online) _collapsedSummary(),
          if (node.expanded && online) _controls(context),
        ],
      ),
    );
  }

  // ---------- header ----------

  Widget _header(bool online) {
    final playing = node.isPlaying;
    final busy = node.awaitingResult;

    Color dot;
    String state;
    if (!online) {
      dot = AppTheme.offline;
      state = node.everRegistered
          ? 'Offline - reconnecting'
          : 'Offline - not set up yet';
    } else if (playing) {
      dot = AppTheme.amber;
      state = 'Playing - waiting for result';
    } else if (busy) {
      dot = AppTheme.amber;
      state = 'Starting...';
    } else if (node.timedOut) {
      dot = AppTheme.online;
      state = 'Ready (last test timed out)';
    } else {
      dot = AppTheme.online;
      state = 'Idle';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 8, 8),
      child: Row(
        children: [
          Checkbox(
            // Always toggleable, even offline: an offline node (e.g. one not set
            // up yet) must still be de-selectable so it is skipped by Play all.
            value: node.selected,
            onChanged: (v) {
              node.selected = v ?? false;
              server.refresh();
            },
            side: const BorderSide(color: Colors.white70, width: 1.5),
            fillColor: WidgetStateProperty.resolveWith(
                (s) => s.contains(WidgetState.selected)
                    ? AppTheme.amber
                    : Colors.transparent),
            checkColor: AppTheme.deepCyan,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Node name in its signature colour -- matches the record border
                // colour, so which card goes with which history is obvious.
                Row(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: AppTheme.nodeColor(node.nodeId),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Text(node.nodeId,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.bold)),
                  ],
                ),
                Text(state,
                    style: TextStyle(
                        color: playing || busy
                            ? AppTheme.amber
                            : Colors.white.withValues(alpha: 0.65),
                        fontSize: 11)),
              ],
            ),
          ),
          if (online) ...[
            _iconAction(
              icon: Icons.play_circle_filled,
              tooltip: busy ? 'Waiting for the current test to finish' : 'Play',
              enabled: !busy,
              onTap: () {
                server.play(node);
                widget.onStatus('${node.nodeId}: playing '
                    '${AppTheme.formatHz(node.frequency)} Hz, '
                    '${AppTheme.earLabel(node.ear)}');
              },
            ),
            _iconAction(
              icon: Icons.stop_circle,
              tooltip: 'Stop (this test will be discarded)',
              enabled: playing || busy,
              onTap: () {
                server.stop(node);
                widget.onStatus('${node.nodeId}: stopping');
              },
            ),
            _iconAction(
              icon: Icons.person_add_alt_1,
              tooltip: 'New patient (start a new audiogram group)',
              enabled: !busy,
              onTap: () {
                server.newPatient(node);
                widget.onStatus('${node.nodeId}: new patient started');
              },
            ),
          ],
          _iconAction(
            icon: Icons.list_alt,
            tooltip: 'Records for this node',
            enabled: true,
            onTap: widget.onOpenRecords,
          ),
          if (online)
            _iconAction(
              icon: node.expanded ? Icons.expand_less : Icons.expand_more,
              tooltip: node.expanded ? 'Collapse' : 'Expand',
              enabled: true,
              onTap: widget.onToggleExpand,
            ),
        ],
      ),
    );
  }

  Widget _iconAction({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton(
      icon: Icon(icon, size: 22),
      color: Colors.white,
      disabledColor: Colors.white24,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      padding: EdgeInsets.zero,
      onPressed: enabled ? onTap : null,
    );
  }

  // ---------- collapsed summary ----------

  Widget _collapsedSummary() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(38, 0, 12, 10),
      child: Row(
        children: [
          _chip('${AppTheme.formatHz(node.frequency)} Hz'),
          const SizedBox(width: 5),
          _chip(AppTheme.earLabel(node.ear)),
          const SizedBox(width: 5),
          // The number that moves while the subject hunts, during playback.
          _chip('${node.levelDb.toStringAsFixed(1)} dB', highlight: node.isPlaying),
        ],
      ),
    );
  }

  Widget _chip(String text, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: highlight ? AppTheme.amber : Colors.white24,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text,
          style: TextStyle(
              color: highlight ? AppTheme.deepCyan : Colors.white,
              fontSize: 11,
              fontWeight: highlight ? FontWeight.bold : FontWeight.normal)),
    );
  }

  // ---------- expanded controls ----------

  Widget _controls(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppTheme.panelBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
      child: Column(
        children: [
          // Once a test is in flight the tone is fixed: the only thing the phone
          // can still do to the node is Stop. Frequency, level and ear all lock.
          _frequencyRow(context, node.awaitingResult),
          const SizedBox(height: 12),
          _levelRow(context, node.awaitingResult),
          const SizedBox(height: 12),
          _earRow(node.awaitingResult),
        ],
      ),
    );
  }

  Widget _frequencyRow(BuildContext context, bool locked) {
    return _controlRow(
      label: 'Frequency',
      field: _numberField(
        controller: _freqCtl,
        focusNode: _freqFocus,
        suffix: ' Hz',
        enabled: !locked,
        onSubmitted: (v) {
          final parsed = double.tryParse(v);
          if (parsed != null && parsed > 0) {
            _setFrequency(parsed);
          } else {
            _freqCtl.text = node.frequency.toStringAsFixed(0);
          }
        },
      ),
      // Frequency is fixed for the whole test: changing it mid-tone would restart
      // the hunt at a new pitch and invalidate the threshold, so the control is
      // disabled while a test is in flight and never re-sends to a playing node.
      slider: Slider(
        value: node.freqSliderIndex
            .toDouble()
            .clamp(0, (AppTheme.frequencies.length - 1).toDouble()),
        min: 0,
        max: (AppTheme.frequencies.length - 1).toDouble(),
        divisions: AppTheme.frequencies.length - 1,
        onChanged: locked
            ? null
            : (v) {
                node.freqSliderIndex = v.round();
                _setFrequency(AppTheme.frequencies[node.freqSliderIndex]);
              },
      ),
      activeColor: AppTheme.darkCyan,
    );
  }

  Widget _levelRow(BuildContext context, bool locked) {
    return _controlRow(
      label: 'Level',
      field: _numberField(
        controller: _levelCtl,
        focusNode: _levelFocus,
        suffix: ' dB',
        allowSign: true,
        // During a test the level tracks the subject's live X/Y adjustments; the
        // operator can watch it but not change it. Only Stop affects the node.
        readOnly: locked,
        onSubmitted: (v) {
          final parsed = double.tryParse(v);
          if (parsed != null) {
            _setLevel(parsed);
          } else {
            _levelCtl.text = node.levelDb.toStringAsFixed(1);
          }
        },
      ),
      // No divisions: a typed fine value (e.g. -12) keeps its exact thumb
      // position, while dragging snaps to whole 5 dB steps via the rounding.
      slider: Slider(
        value: node.levelDb.clamp(_dbMin, _dbMax),
        min: _dbMin,
        max: _dbMax,
        onChanged:
            locked ? null : (v) => _setLevel((v / _dbStep).round() * _dbStep),
      ),
      activeColor: AppTheme.amber,
    );
  }

  Widget _controlRow({
    required String label,
    required Widget field,
    required Widget slider,
    required Color activeColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        const SizedBox(height: 4),
        Row(
          children: [
            SizedBox(width: 104, child: field),
            const SizedBox(width: 10),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: activeColor,
                  inactiveTrackColor: Colors.white38,
                  thumbColor: activeColor == AppTheme.amber
                      ? AppTheme.amber
                      : Colors.white,
                  overlayColor: activeColor.withValues(alpha: 0.2),
                  trackHeight: 5,
                ),
                child: slider,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _earRow(bool locked) {
    return Row(
      children: [
        _earOption('L', 'Left', locked),
        const SizedBox(width: 8),
        _earOption('both', 'Both', locked),
        const SizedBox(width: 8),
        _earOption('R', 'Right', locked),
      ],
    );
  }

  Widget _earOption(String value, String label, bool locked) {
    final selected = node.ear == value;
    return Expanded(
      child: GestureDetector(
        // Ear is part of the tone, so it is fixed once a test is in flight.
        onTap: locked
            ? null
            : () {
                node.ear = value;
                server.refresh();
              },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppTheme.darkCyan : Colors.white24,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? Colors.white : Colors.white38,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
                  color: Colors.white, size: 15),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    fontSize: 12,
                  )),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- small parts ----------

  Widget _numberField({
    required TextEditingController controller,
    required FocusNode focusNode,
    String? suffix,
    bool allowSign = false,
    bool enabled = true,
    bool readOnly = false,
    required ValueChanged<String> onSubmitted,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: enabled ? Colors.white : const Color(0xFFE0E0E0),
        borderRadius: BorderRadius.circular(6),
      ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        readOnly: readOnly,
        keyboardType: TextInputType.numberWithOptions(
            decimal: allowSign, signed: allowSign),
        inputFormatters: [
          allowSign
              ? FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]'))
              : FilteringTextInputFormatter.digitsOnly,
        ],
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 6),
          suffixText: suffix,
          suffixStyle: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }
}
