import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../services/admin_auth_service.dart';
import '../utils/app_snackbar.dart';

/// Reachable from the login screen via a "First-time setup" link, or pushed
/// automatically by the login screen when the admins collection is empty.
/// Creates the first admin record so the app can move past the
/// hardcoded-phone bypass that existed before Phase 3.
class AdminSetupScreen extends StatefulWidget {
  const AdminSetupScreen({super.key});

  @override
  State<AdminSetupScreen> createState() => _AdminSetupScreenState();
}

class _AdminSetupScreenState extends State<AdminSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _whatsapp = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _whatsapp.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await AdminAuthService().createAdmin(
        phone: _phone.text.trim(),
        name: _name.text.trim(),
        password: _password.text,
        whatsappNumber: _whatsapp.text.trim().isEmpty
            ? null
            : _whatsapp.text.trim(),
      );
      AppSnackBar.success(
        'Admin "${_name.text.trim()}" created. You can now sign in.',
        title: 'Setup complete',
      );
      Get.offAllNamed('/login');
    } catch (e) {
      AppSnackBar.error('Could not create admin:\n$e', title: 'Setup failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : Colors.white,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back(),
        ),
        title: Text(
          'Admin setup',
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Text(
                'Create the first admin account.',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'These credentials are stored in your Appwrite admins '
                'collection. Anyone using this phone number with the right '
                'password will get full admin access in the app.',
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              _label('NAME'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: _decoration(hint: 'e.g. Zeel Shiyani'),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Required'
                    : null,
              ),
              const SizedBox(height: 20),
              _label('PHONE'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 10,
                decoration: _decoration(
                  hint: '10-digit phone number',
                  counter: '',
                ),
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.length != 10) return 'Enter a 10-digit phone number';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _label('WHATSAPP NUMBER (OPTIONAL)'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _whatsapp,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                maxLength: 10,
                decoration: _decoration(
                  hint: 'Leave blank to use the phone above',
                  counter: '',
                ),
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return null;
                  if (s.length != 10) return 'Enter a 10-digit number or leave blank';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _label('PASSWORD'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _password,
                obscureText: _obscurePassword,
                decoration: _decoration(
                  hint: 'At least 8 characters',
                  suffix: IconButton(
                    icon: Icon(_obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    onPressed: () => setState(
                        () => _obscurePassword = !_obscurePassword),
                  ),
                ),
                validator: (v) {
                  final s = v ?? '';
                  if (s.length < 8) return 'Use at least 8 characters';
                  return null;
                },
              ),
              const SizedBox(height: 20),
              _label('CONFIRM PASSWORD'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _confirm,
                obscureText: _obscurePassword,
                decoration: _decoration(hint: 'Re-enter your password'),
                validator: (v) =>
                    (v != _password.text) ? 'Passwords do not match' : null,
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.brand,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : Text(
                          'Create admin',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String s) => Text(
        s,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: AppTheme.textMuted,
          letterSpacing: 1.5,
        ),
      );

  InputDecoration _decoration({
    required String hint,
    String? counter,
    Widget? suffix,
  }) =>
      InputDecoration(
        hintText: hint,
        counterText: counter,
        suffixIcon: suffix,
      );
}
