import 'package:flutter/material.dart';

import '../core/app_controller.dart';
import '../widgets/common.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.app});
  final AppController app;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController();
  bool _register = false, _busy = false, _obscure = true;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.app.authenticate(
        email: _email.text.trim(),
        password: _password.text,
        name: _register ? _name.text.trim() : null,
      );
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _server() async {
    var server = widget.app.api.baseUrl;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alamat server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Pada ponsel fisik, gunakan IP komputer yang berada di Wi-Fi yang sama.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: server,
              onChanged: (value) => server = value,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'URL server',
                hintText: 'http://192.168.1.10:8080',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, server),
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
    if (value != null) {
      try {
        await widget.app.setServer(value);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: AutofillGroup(
                child: Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const BrandMark(size: 40),
                          const SizedBox(width: 12),
                          const Text(
                            'ruang',
                            style: TextStyle(
                              fontSize: 27,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _busy ? null : _server,
                            tooltip: 'Pengaturan server',
                            icon: const Icon(Icons.tune_rounded),
                          ),
                        ],
                      ),
                      const SizedBox(height: 52),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 7,
                        ),
                        decoration: BoxDecoration(
                          color: color.primary.withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Text(
                          'RUANG UNTUK TERHUBUNG',
                          style: TextStyle(
                            color: color.primary,
                            fontSize: 10,
                            letterSpacing: 1.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _register
                            ? 'Kenalan dulu,\nyuk.'
                            : 'Cerita dimulai\ndari sapaan.',
                        style: const TextStyle(
                          fontSize: 40,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.5,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _register
                            ? 'Buat akun dan mulai percakapan pertamamu.'
                            : 'Masuk untuk melanjutkan percakapan dengan orang-orang terdekat.',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.6,
                          color: color.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (_register) ...[
                        TextFormField(
                          controller: _name,
                          enabled: !_busy,
                          textCapitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          decoration: const InputDecoration(
                            labelText: 'Nama lengkap',
                            prefixIcon: Icon(Icons.person_outline_rounded),
                          ),
                          validator: (v) => (v?.trim().length ?? 0) < 2
                              ? 'Masukkan nama minimal 2 karakter.'
                              : null,
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        controller: _email,
                        enabled: !_busy,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        autofillHints: const [AutofillHints.email],
                        decoration: const InputDecoration(
                          labelText: 'Email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (v) =>
                            v == null ||
                                !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                    .hasMatch(v.trim())
                            ? 'Masukkan email yang valid.'
                            : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _obscure,
                        autofillHints: [
                          _register
                              ? AutofillHints.newPassword
                              : AutofillHints.password,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_outline_rounded),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            tooltip: _obscure
                                ? 'Tampilkan password'
                                : 'Sembunyikan password',
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (v) => (v?.length ?? 0) < 8
                            ? 'Password minimal 8 karakter.'
                            : null,
                        onFieldSubmitted: (_) => _submit(),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Text(
                            _error!,
                            style: TextStyle(color: color.error),
                          ),
                        ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          onPressed: _busy ? null : _submit,
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _register
                                            ? 'Buat akun'
                                            : 'Masuk ke Ruang',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Icon(
                                      Icons.arrow_forward_rounded,
                                      size: 19,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Center(
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _register = !_register;
                                  _error = null;
                                }),
                          child: Text(
                            _register
                                ? 'Sudah punya akun? Masuk'
                                : 'Belum punya akun? Daftar',
                          ),
                        ),
                      ),
                      const SizedBox(height: 26),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline_rounded,
                            size: 14,
                            color: color.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Dekat, meski dari jauh.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: color.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
