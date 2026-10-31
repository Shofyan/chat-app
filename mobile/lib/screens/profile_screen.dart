import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../core/models.dart';
import '../widgets/common.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, required this.app, this.peer});
  final AppController app;
  final ChatUser? peer;
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _busy = false;
  @override
  Widget build(BuildContext context) {
    final user = widget.peer ?? widget.app.user!;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.peer == null ? 'Profil & preferensi' : 'Info kontak',
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 20),
              Center(
                child: Hero(
                  tag: 'avatar-${user.id}',
                  child: UserAvatar(user: user, radius: 54, showOnline: false),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                user.name,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 25,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.peer == null
                    ? user.email
                    : user.online
                    ? 'Sedang online'
                    : 'Sedang offline',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 40),
              if (widget.peer == null) ...[
                const Text(
                  'TAMPILAN',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                ListenableBuilder(
                  listenable: widget.app,
                  builder: (context, _) => RadioGroup<ThemeMode>(
                    groupValue: widget.app.themeMode,
                    onChanged: (v) {
                      if (v != null) widget.app.setTheme(v);
                    },
                    child: const Column(
                      children: [
                        RadioListTile(
                          value: ThemeMode.system,
                          title: Text('Ikuti sistem'),
                          secondary: Icon(Icons.brightness_auto_outlined),
                        ),
                        RadioListTile(
                          value: ThemeMode.light,
                          title: Text('Tema terang'),
                          secondary: Icon(Icons.light_mode_outlined),
                        ),
                        RadioListTile(
                          value: ThemeMode.dark,
                          title: Text('Tema gelap'),
                          secondary: Icon(Icons.dark_mode_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const BrandMark(size: 38),
                  title: const Text(
                    'Ruang Chat',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Versi 1.0.0'),
                ),
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            await widget.app.logout();
                            if (context.mounted) {
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            }
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(_busy ? 'Keluar...' : 'Keluar dari akun'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    minimumSize: const Size(0, 52),
                  ),
                ),
              ] else ...[
                const Divider(),
                const ListTile(
                  leading: Icon(Icons.swipe_right_outlined),
                  title: Text('Geser untuk membalas'),
                  subtitle: Text('Geser pesan ke kanan di ruang chat.'),
                ),
                const ListTile(
                  leading: Icon(Icons.add_reaction_outlined),
                  title: Text('Berikan reaksi'),
                  subtitle: Text('Tekan lama pesan untuk memilih emoji.'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
