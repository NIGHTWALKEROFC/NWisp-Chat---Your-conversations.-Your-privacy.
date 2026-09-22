import 'package:flutter/material.dart';
import '../data/location_data.dart';
import '../services/community_service.dart';

/// Three OPTIONAL pickers — Country, State / region, District / city — used
/// when creating a community and when filtering the Community list.
///
/// India has complete built-in lists (every state and union territory, and
/// every district in each). For any other country the state and district are
/// typed in by hand. Every level can be left empty; changing a higher level
/// clears the levels under it.
class LocationFields extends StatelessWidget {
  final CommunityLocation value;
  final ValueChanged<CommunityLocation> onChanged;

  const LocationFields({super.key, required this.value, required this.onChanged});

  bool get _hasCountry => value.country != null && value.country!.trim().isNotEmpty;
  bool get _hasState => value.state != null && value.state!.trim().isNotEmpty;
  bool get _india => LocationData.isIndia(value.country);
  bool get _indianStateKnown => _india && LocationData.indiaStates.contains(value.state);

  Future<void> _pickCountry(BuildContext context) async {
    final r = await _pickFromList(
      context,
      title: 'Country',
      options: LocationData.countries,
      selected: value.country,
    );
    if (r == null) return;
    if (r.value == value.country) return;
    onChanged(r.value == null ? const CommunityLocation() : CommunityLocation(country: r.value));
  }

  Future<void> _pickState(BuildContext context) async {
    String? chosen;
    if (_india) {
      final r = await _pickFromList(context, title: 'State / Union territory', options: LocationData.indiaStates, selected: value.state);
      if (r == null) return;
      chosen = r.value;
    } else {
      final text = await _askText(context, title: 'State / region', initial: value.state);
      if (text == null) return;
      chosen = text.isEmpty ? null : text;
    }
    if (chosen == value.state) return;
    onChanged(CommunityLocation(country: value.country, state: chosen));
  }

  Future<void> _pickDistrict(BuildContext context) async {
    String? chosen;
    if (_indianStateKnown) {
      final r = await _pickFromList(
        context,
        title: 'District',
        options: LocationData.districtsOfIndianState(value.state!),
        selected: value.district,
        allowCustom: true,
      );
      if (r == null) return;
      chosen = r.value;
    } else {
      final text = await _askText(context, title: 'District / city', initial: value.district);
      if (text == null) return;
      chosen = text.isEmpty ? null : text;
    }
    onChanged(CommunityLocation(country: value.country, state: value.state, district: chosen));
  }

  Widget _tile(
    BuildContext context, {
    required String label,
    required IconData icon,
    required String hint,
    required String? current,
    required VoidCallback? onTap,
    required VoidCallback onClear,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final has = current != null && current.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            prefixIcon: Icon(icon),
            enabled: onTap != null,
            suffixIcon: has
                ? IconButton(icon: const Icon(Icons.close), tooltip: 'Clear', onPressed: onClear)
                : const Icon(Icons.arrow_drop_down),
          ),
          child: Text(
            has ? current! : hint,
            style: TextStyle(color: has ? null : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _tile(
          context,
          label: 'Country',
          icon: Icons.public,
          hint: 'Any country (optional)',
          current: value.country,
          onTap: () => _pickCountry(context),
          onClear: () => onChanged(const CommunityLocation()),
        ),
        _tile(
          context,
          label: _india ? 'State / Union territory' : 'State / region',
          icon: Icons.map_outlined,
          hint: _hasCountry ? 'Any state (optional)' : 'Choose a country first',
          current: value.state,
          onTap: _hasCountry ? () => _pickState(context) : null,
          onClear: () => onChanged(CommunityLocation(country: value.country)),
        ),
        _tile(
          context,
          label: 'District / city',
          icon: Icons.location_city_outlined,
          hint: _hasState ? 'Any district (optional)' : 'Choose a state first',
          current: value.district,
          onTap: _hasState ? () => _pickDistrict(context) : null,
          onClear: () => onChanged(CommunityLocation(country: value.country, state: value.state)),
        ),
      ],
    );
  }
}

/// What the person chose in a list sheet. [value] == null means "cleared".
class _Pick {
  final String? value;
  const _Pick(this.value);
}

Future<_Pick?> _pickFromList(
  BuildContext context, {
  required String title,
  required List<String> options,
  String? selected,
  bool allowCustom = false,
}) async {
  final r = await showModalBottomSheet<_Pick>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => _PickerSheet(title: title, options: options, selected: selected, allowCustom: allowCustom),
  );
  return r;
}

const _kCustomMarker = '\u0000custom';

class _PickerSheet extends StatefulWidget {
  final String title;
  final List<String> options;
  final String? selected;
  final bool allowCustom;
  const _PickerSheet({required this.title, required this.options, required this.selected, required this.allowCustom});

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _query.text.trim().toLowerCase();
    final filtered = q.isEmpty ? widget.options : widget.options.where((o) => o.toLowerCase().contains(q)).toList();
    final items = <String>[...filtered, if (widget.allowCustom) _kCustomMarker];
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17))),
                  if (widget.selected != null && widget.selected!.isNotEmpty)
                    TextButton(onPressed: () => Navigator.pop(context, const _Pick(null)), child: const Text('Clear')),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _query,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search'),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: items.isEmpty
                  ? Center(child: Text('No matches', style: TextStyle(color: scheme.onSurfaceVariant)))
                  : ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, i) {
                        final item = items[i];
                        if (item == _kCustomMarker) {
                          return ListTile(
                            leading: const Icon(Icons.edit_outlined),
                            title: const Text('Other — type my own'),
                            onTap: () async {
                              final text = await _askText(context, title: widget.title, initial: null);
                              if (text == null || !context.mounted) return;
                              Navigator.pop(context, _Pick(text.isEmpty ? null : text));
                            },
                          );
                        }
                        final isSel = item == widget.selected;
                        return ListTile(
                          title: Text(item),
                          trailing: isSel ? Icon(Icons.check, color: scheme.primary) : null,
                          onTap: () => Navigator.pop(context, _Pick(item)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small text prompt. Returns the trimmed text ("" = cleared), or null if
/// cancelled.
Future<String?> _askText(BuildContext context, {required String title, String? initial}) async {
  final controller = TextEditingController(text: initial ?? '');
  try {
    return await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          maxLength: 60,
          decoration: const InputDecoration(hintText: 'Type it here (optional)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('OK')),
        ],
      ),
    );
  } finally {
    controller.dispose();
  }
}
