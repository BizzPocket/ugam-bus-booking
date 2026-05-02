import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../config/theme.dart';
import '../models/tour.dart';
import '../utils/app_snackbar.dart';

class BroadcastTemplateScreen extends StatefulWidget {
  final Tour tour;

  const BroadcastTemplateScreen({super.key, required this.tour});

  @override
  State<BroadcastTemplateScreen> createState() => _BroadcastTemplateScreenState();
}

class _BroadcastTemplateScreenState extends State<BroadcastTemplateScreen> {
  late final TextEditingController _msgCtrl;
  bool _isSending = false;

  static const _placeholders = [
    ('{tour_name}', 'Tour Name'),
    ('{from}', 'From City'),
    ('{to}', 'To City'),
    ('{date}', 'Departure Date'),
    ('{price}', 'Price/Seat'),
  ];

  String get _defaultTemplate => '''✈️ New Tour Alert!

Hey! I'm organizing a group trip:

🚌 *{tour_name}*
📍 {from} → {to}
📅 {date}
💰 ₹{price} per seat

Interested? Just reply with:
• How many seats you need
• Your seat preference (sofa/sleeper)

Reply quickly, seats are limited! 🔥''';

  String _buildPreview(String template) {
    return template
        .replaceAll('{tour_name}', widget.tour.title)
        .replaceAll('{from}', widget.tour.fromCity)
        .replaceAll('{to}', widget.tour.toCity)
        .replaceAll('{date}', _formatDate(widget.tour.departureDate))
        .replaceAll('{price}', widget.tour.pricePerSeat.toStringAsFixed(0));
  }

  String _formatDate(DateTime d) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  void initState() {
    super.initState();
    _msgCtrl = TextEditingController(text: _defaultTemplate);
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  void _insertPlaceholder(String placeholder) {
    final text = _msgCtrl.text;
    final sel = _msgCtrl.selection;
    final newText = text.replaceRange(
      sel.start < 0 ? text.length : sel.start,
      sel.end < 0 ? text.length : sel.end,
      placeholder,
    );
    _msgCtrl.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: (sel.start < 0 ? text.length : sel.start) + placeholder.length),
    );
    setState(() {});
  }

  Future<void> _sendBroadcast() async {
    setState(() => _isSending = true);
    final previewText = _buildPreview(_msgCtrl.text);
    await Clipboard.setData(ClipboardData(text: previewText));
    setState(() => _isSending = false);
    Get.back();
    AppSnackBar.success(
      'Broadcast message copied to clipboard. Open WhatsApp Business and paste into your broadcast list.',
      title: 'Ready to Send!',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isDark ? colorScheme.surface : const Color(0xFFF8FAFC),
      appBar: AppBar(
        leading: IconButton(icon: Icon(Icons.arrow_back, color: colorScheme.onSurface), onPressed: () => Get.back()),
        title: Column(
          children: [
            Text('Broadcast Message', style: GoogleFonts.outfit(fontSize: 18, fontWeight: FontWeight.w700, color: colorScheme.onSurface)),
            Text(widget.tour.title, style: GoogleFonts.inter(fontSize: 12, color: colorScheme.onSurfaceVariant)),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () {
              _msgCtrl.text = _defaultTemplate;
              setState(() {});
            },
            child: Text('Reset', style: GoogleFonts.inter(color: AppTheme.brand, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // Placeholder chips
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? colorScheme.surface : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colorScheme.outline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_fix_high_rounded, size: 16, color: AppTheme.brand),
                          const SizedBox(width: 6),
                          Text('Smart Placeholders', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: colorScheme.onSurface)),
                          const SizedBox(width: 8),
                          Text('Tap to insert', style: GoogleFonts.inter(fontSize: 11, color: colorScheme.onSurfaceVariant)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _placeholders.map((p) {
                          return GestureDetector(
                            onTap: () => _insertPlaceholder(p.$1),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: AppTheme.brand.withAlpha(15),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: AppTheme.brand.withAlpha(60)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.add_rounded, size: 14, color: AppTheme.brand),
                                  const SizedBox(width: 4),
                                  Text(p.$2, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.brandDark)),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Editor
                Container(
                  decoration: BoxDecoration(
                    color: isDark ? colorScheme.surface : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colorScheme.outline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                        child: Row(
                          children: [
                            Icon(Icons.edit_note_rounded, size: 16, color: AppTheme.brand),
                            const SizedBox(width: 6),
                            Text('Message Template', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: colorScheme.onSurface)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: colorScheme.outline),
                      TextField(
                        controller: _msgCtrl,
                        maxLines: 14,
                        onChanged: (_) => setState(() {}),
                        style: GoogleFonts.robotoMono(fontSize: 13, color: colorScheme.onSurface, height: 1.6),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(16),
                          hintText: 'Write your WhatsApp broadcast message...',
                          hintStyle: GoogleFonts.inter(fontSize: 13, color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Preview
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF0F172A) : const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppTheme.success.withAlpha(80)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.visibility_rounded, size: 16, color: AppTheme.success),
                              const SizedBox(width: 6),
                              Text('Live Preview', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w700, color: AppTheme.success)),
                            ],
                          ),
                          IconButton(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: _buildPreview(_msgCtrl.text)));
                              AppSnackBar.info('Preview text copied to clipboard');
                            },
                            icon: Icon(Icons.copy_rounded, size: 18, color: colorScheme.onSurfaceVariant),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // WhatsApp bubble style
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E4025) : const Color(0xFFDCF8C6),
                            borderRadius: const BorderRadius.only(
                              topLeft: Radius.circular(4),
                              topRight: Radius.circular(20),
                              bottomLeft: Radius.circular(20),
                              bottomRight: Radius.circular(20),
                            ),
                          ),
                          child: Text(
                            _buildPreview(_msgCtrl.text),
                            style: GoogleFonts.inter(fontSize: 13, height: 1.5, color: isDark ? Colors.white : const Color(0xFF111B21)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 100),
              ],
            ),
          ),

          // Bottom Send Bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            decoration: BoxDecoration(
              color: isDark ? colorScheme.surface : Colors.white,
              border: Border(top: BorderSide(color: colorScheme.outline)),
              boxShadow: isDark ? [] : [
                BoxShadow(color: Colors.black.withAlpha(10), blurRadius: 20, offset: const Offset(0, -10)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Sending to all imported WhatsApp contacts',
                    style: GoogleFonts.inter(fontSize: 12, color: colorScheme.onSurfaceVariant),
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: _isSending ? null : _sendBroadcast,
                    icon: _isSending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.send_rounded),
                    label: Text(
                      _isSending ? 'Broadcasting...' : 'Send Broadcast Message',
                      style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366), // WhatsApp green
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      elevation: 0,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
