// The start picker (docs/SPEC.md, "Profiles"): with more than one profile and none set to open by itself, the app
// starts here. The last one used is listed first; "Always open this one" skips the picker from then on (Settings →
// Account turns that off again). Adding a provider opens the setup form.

import 'package:material_ui/material_ui.dart';

import '../l10n/gen/app_localizations.dart';
import '../services/session.dart';
import '../theme.dart';
import 'app_logo.dart';
import 'setup_screen.dart';

class ProfilePicker extends StatefulWidget {
  const ProfilePicker({super.key, required this.session});
  final Session session;

  @override
  State<ProfilePicker> createState() => _ProfilePickerState();
}

class _ProfilePickerState extends State<ProfilePicker> {
  bool _always = false;
  String? _failed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final s = widget.session;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(Tokens.space * 2),
              children: [
                Center(child: AppLogoMark(logo: s.logo, size: 72)),
                const SizedBox(height: Tokens.space * 2),
                Text(
                  l10n.profileChoose,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Tokens.space * 2),
                for (final (i, p) in s.profiles.indexed)
                  ListTile(
                    key: Key('profile.$i'),
                    autofocus: i == 0, // the remote starts on the last one used
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(p.name),
                    subtitle: _failed == p.id ? Text(l10n.profileFailed) : null,
                    onTap: () async {
                      final ok = await s.openProfile(p, always: _always);
                      if (!ok && mounted) setState(() => _failed = p.id);
                    },
                  ),
                CheckboxListTile(
                  key: const Key('profile.always'),
                  title: Text(l10n.profileAlways),
                  value: _always,
                  onChanged: (v) => setState(() => _always = v ?? false),
                ),
                ListTile(
                  key: const Key('profile.add'),
                  leading: const Icon(Icons.add),
                  title: Text(l10n.profileAdd),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SetupScreen(session: s),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
