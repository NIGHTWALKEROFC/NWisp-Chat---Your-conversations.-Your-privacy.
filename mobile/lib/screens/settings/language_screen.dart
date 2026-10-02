import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../l10n/app_strings.dart';
import '../../l10n/languages.dart';
import '../../services/locale_service.dart';

/// Settings > App language. A searchable list of every language the app can
/// switch to. Picking one changes the app right away, with no restart.
class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final service = context.watch<LocaleService>();
    final q = _query.trim().toLowerCase();
    final languages = [
      for (final l in AppLanguages.available)
        if (q.isEmpty || l.native.toLowerCase().contains(q) || l.english.toLowerCase().contains(q)) l,
    ];

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('App language'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: context.tr('Search languages'),
                prefixIcon: const Icon(Icons.search),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text(
              context.tr(
                'Languages marked "App text" are translated across the app. For the others, the system parts '
                '(date pickers, dialog buttons, text direction) switch language and the rest stays English for now.',
              ),
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5, height: 1.4),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (q.isEmpty)
                  RadioListTile<String?>(
                    value: null,
                    groupValue: service.code,
                    onChanged: (_) => service.setLanguage(null),
                    title: Text(context.tr('Phone language')),
                    subtitle: Text(context.tr('Use the same language as your phone')),
                  ),
                for (final l in languages)
                  RadioListTile<String?>(
                    value: l.code,
                    groupValue: service.code,
                    onChanged: (_) => service.setLanguage(l.code),
                    title: Text(l.native),
                    subtitle: Text(
                      '${l.english} · ${AppStrings.hasAppText(l.locale.languageCode) && !(l.code == 'zh_TW') ? context.tr('App text') : context.tr('Menus and dialogs')}',
                    ),
                  ),
                if (languages.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Text(context.tr('No language found'), style: TextStyle(color: scheme.onSurfaceVariant)),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
