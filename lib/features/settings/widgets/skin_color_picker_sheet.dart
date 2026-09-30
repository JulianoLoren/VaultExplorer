import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vaultexplorer/core/extensions/l10n_extension.dart';
import 'package:vaultexplorer/core/widgets/sheets/app_bottom_sheet.dart';

/// The result of [showSkinColorPicker].
///
/// Wrapping the color lets "the person chose Default" ([color] null) be told
/// apart from "the person dismissed the sheet" (the future completes with
/// null instead).
class SkinColorPick {
  final Color? color;
  const SkinColorPick(this.color);
}

/// Swatches offered by the picker. Deliberately includes white, black and a
/// few greys so names can be made high-contrast on any theme.
const List<Color> kSkinPalette = [
  Color(0xFFEF5350),
  Color(0xFFFF7043),
  Color(0xFFFFA726),
  Color(0xFFFFB300),
  Color(0xFFFFEE58),
  Color(0xFF9CCC65),
  Color(0xFF66BB6A),
  Color(0xFF26A69A),
  Color(0xFF26C6DA),
  Color(0xFF42A5F5),
  Color(0xFF5C6BC0),
  Color(0xFF7E57C2),
  Color(0xFFAB47BC),
  Color(0xFFEC407A),
  Color(0xFF8D6E63),
  Color(0xFF78909C),
  Color(0xFFBDBDBD),
  Color(0xFF616161),
  Color(0xFFFFFFFF),
  Color(0xFF000000),
];

/// `RRGGBB` for [color], without alpha or a leading `#`.
String skinColorToHex(Color color) =>
    (color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

/// Parses exactly six hex digits into an opaque color; null for anything else.
Color? skinColorFromHex(String hex) {
  if (hex.length != 6) return null;
  final value = int.tryParse(hex, radix: 16);
  if (value == null) return null;
  return Color(0xFF000000 | value);
}

/// Opens the picker. Completes with null if dismissed.
///
/// [allowDefault] adds a "Default" button that completes with
/// `SkinColorPick(null)`, for options where "follow the theme" is a valid
/// choice (names, details) as opposed to ones that always need a color.
Future<SkinColorPick?> showSkinColorPicker(
  BuildContext context, {
  required String title,
  Color? initial,
  bool allowDefault = true,
}) {
  return showModalBottomSheet<SkinColorPick>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SkinColorPickerSheet(
      title: title,
      initial: initial,
      allowDefault: allowDefault,
    ),
  );
}

class _SkinColorPickerSheet extends StatefulWidget {
  final String title;
  final Color? initial;
  final bool allowDefault;

  const _SkinColorPickerSheet({
    required this.title,
    required this.initial,
    required this.allowDefault,
  });

  @override
  State<_SkinColorPickerSheet> createState() => _SkinColorPickerSheetState();
}

class _SkinColorPickerSheetState extends State<_SkinColorPickerSheet> {
  late final TextEditingController _hexController;
  Color? _hexColor;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _hexController = TextEditingController(
      text: initial == null ? '' : skinColorToHex(initial),
    );
    _hexColor = initial;
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  void _pick(Color? color) => Navigator.of(context).pop(SkinColorPick(color));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return AppBottomSheet(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final color in kSkinPalette)
                  _Swatch(
                    color: color,
                    selected: widget.initial == color,
                    onTap: () => _pick(color),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _hexController,
                    maxLength: 6,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
                    ],
                    decoration: InputDecoration(
                      labelText: context.l10n.fileSkinColorHexLabel,
                      prefixText: '#',
                      counterText: '',
                    ),
                    onChanged: (value) =>
                        setState(() => _hexColor = skinColorFromHex(value)),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _hexColor ?? Colors.transparent,
                      shape: BoxShape.circle,
                      border: Border.all(color: cs.outlineVariant),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                    ),
                    onPressed: _hexColor == null ? null : () => _pick(_hexColor),
                    child: Text(context.l10n.done),
                  ),
                ),
              ],
            ),
            if (widget.allowDefault) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => _pick(null),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: Text(context.l10n.fileSkinColorDefault),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 26,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check_rounded,
                size: 22,
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              )
            : null,
      ),
    );
  }
}
