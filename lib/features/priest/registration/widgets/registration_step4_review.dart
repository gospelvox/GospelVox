// Step 4 — review everything before the final submit.
//
// This is the commitment page. The priest has already done the typing;
// now they get a single scrollable surface that mirrors what the admin
// reviewer will see, with per-section Edit pencils that jump back
// directly to the relevant step (arming `returnToReview` on the cubit
// so the next Continue brings them straight back here).
//
// The Terms acknowledgement lives here (not on Step 3) because
// acknowledging "everything is accurate" only makes sense once the
// priest can see everything in one place.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/features/priest/registration/data/priest_registration_model.dart';

class RegistrationStep4Review extends StatefulWidget {
  final PriestRegistrationModel data;
  // Jumps back to the given step index and arms returnToReview on
  // the cubit so the next Continue returns the priest to this page.
  final void Function(int stepIndex) onEdit;
  final VoidCallback onSubmit;

  const RegistrationStep4Review({
    super.key,
    required this.data,
    required this.onEdit,
    required this.onSubmit,
  });

  @override
  State<RegistrationStep4Review> createState() =>
      _RegistrationStep4ReviewState();
}

class _RegistrationStep4ReviewState extends State<RegistrationStep4Review> {
  bool _termsAccepted = false;

  // Defensive sanity check. In theory the per-step validators prevent
  // a priest from reaching this page with holes — but a user who
  // edits back to a step, clears a field, then hits Continue while
  // returnToReview is armed could still slip past if validation
  // regressed. Blocking submit here is a belt-and-braces second
  // line of defence rather than trusting earlier steps.
  List<String> _missingFields(PriestRegistrationModel d) {
    final missing = <String>[];
    if (d.fullName.trim().isEmpty) missing.add('Full name');
    if (d.phone.trim().isEmpty) missing.add('Phone');
    if (d.email.trim().isEmpty) missing.add('Email');
    if (d.photoPath == null || d.photoPath!.isEmpty) {
      missing.add('Profile photo');
    }
    if (d.denomination.trim().isEmpty) missing.add('Denomination');
    if (d.churchName.trim().isEmpty) missing.add('Church name');
    if (d.location.trim().isEmpty) missing.add('Location');
    if (d.yearsOfExperience <= 0) missing.add('Years of ministry');
    if (d.bio.trim().isEmpty || d.bio.trim().length < 50) {
      missing.add('Bio');
    }
    if (d.specializations.isEmpty) missing.add('Specializations');
    if (d.languages.isEmpty) missing.add('Languages');
    if (d.idProofPath == null || d.idProofPath!.isEmpty) {
      missing.add('ID Proof');
    }
    // Ordination certificate is intentionally NOT in this list —
    // it's optional per spec.
    return missing;
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final d = widget.data;
    final missing = _missingFields(d);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            'Review your application',
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Please check every detail before submitting',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 24),

          _SummaryCard(
            label: 'PERSONAL INFO',
            onEdit: () => widget.onEdit(0),
            children: [
              Row(
                children: [
                  _PhotoThumb(path: d.photoPath),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _ReadOnlyRow(
                          label: 'Name',
                          value: d.fullName,
                        ),
                        const SizedBox(height: 10),
                        _ReadOnlyRow(
                          label: 'Phone',
                          value: d.phone.isEmpty ? '—' : '+91 ${d.phone}',
                        ),
                        const SizedBox(height: 10),
                        _ReadOnlyRow(
                          label: 'Email',
                          value: d.email,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),

          _SummaryCard(
            label: 'MINISTRY DETAILS',
            onEdit: () => widget.onEdit(1),
            children: [
              _ReadOnlyRow(
                label: 'Denomination',
                value: _denominationDisplay(d),
              ),
              const SizedBox(height: 10),
              _ReadOnlyRow(
                label: 'Church',
                value: d.churchName,
              ),
              if (d.diocese.isNotEmpty) ...[
                const SizedBox(height: 10),
                _ReadOnlyRow(label: 'Diocese', value: d.diocese),
              ],
              const SizedBox(height: 10),
              _ReadOnlyRow(
                label: 'Location',
                value: d.location,
              ),
              const SizedBox(height: 10),
              _ReadOnlyRow(
                label: 'Experience',
                value:
                    '${d.yearsOfExperience} year${d.yearsOfExperience == 1 ? '' : 's'}',
              ),
              if (d.specializations.isNotEmpty) ...[
                const SizedBox(height: 14),
                _ReadOnlyChipGroup(
                  label: 'Specializations',
                  items: d.specializations,
                ),
              ],
              if (d.languages.isNotEmpty) ...[
                const SizedBox(height: 14),
                _ReadOnlyChipGroup(
                  label: 'Languages',
                  items: d.languages,
                ),
              ],
            ],
          ),

          _SummaryCard(
            label: 'ABOUT YOU',
            onEdit: () => widget.onEdit(1),
            children: [
              Text(
                d.bio.isEmpty ? '—' : d.bio,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: AppColors.deepDarkBrown,
                  height: 1.6,
                ),
              ),
            ],
          ),

          _SummaryCard(
            label: 'DOCUMENTS',
            onEdit: () => widget.onEdit(2),
            children: [
              _DocumentRow(
                title: 'ID Proof',
                path: d.idProofPath,
                isRequired: true,
              ),
              const SizedBox(height: 14),
              _DocumentRow(
                title: 'Ordination Certificate',
                path: d.certificatePath,
                isRequired: false,
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Incomplete-fields banner. Rendered only when the defensive
          // check flags at least one hole; a clean application sees a
          // calm page. Clicking Fix now jumps back to Step 1 — we
          // don't try to target the exact step because missing items
          // often span multiple steps, and walking the priest back
          // to the start lets them re-check everything.
          if (missing.isNotEmpty) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: AppColors.errorRed.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.errorRed.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 18,
                        color: AppColors.errorRed,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Some fields are missing',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.errorRed,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    missing.join(', '),
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: AppColors.errorRed.withValues(alpha: 0.85),
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ],

          // Terms acknowledgement — the "I have read and I mean it"
          // moment. Lives here so the checkbox label ("everything I
          // provided is accurate") is literally true of what's on
          // screen.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () =>
                    setState(() => _termsAccepted = !_termsAccepted),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    color: _termsAccepted
                        ? AppColors.primaryBrown
                        : Colors.transparent,
                    border: Border.all(
                      color: _termsAccepted
                          ? AppColors.primaryBrown
                          : AppColors.muted.withValues(alpha: 0.3),
                      width: 1.5,
                    ),
                  ),
                  child: _termsAccepted
                      ? const Icon(
                          Icons.check,
                          size: 14,
                          color: Colors.white,
                        )
                      : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      color: AppColors.muted,
                      height: 1.5,
                    ),
                    children: [
                      const TextSpan(
                        text:
                            'I confirm that all information above is accurate and I agree to the ',
                      ),
                      TextSpan(
                        text: 'Terms of Service',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                      const TextSpan(text: ' and '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: AppColors.primaryBrown,
                        ),
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          _SubmitButton(
            enabled: _termsAccepted && missing.isEmpty,
            onTap: widget.onSubmit,
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              "You'll confirm once more before it's final",
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w400,
                color: AppColors.muted,
              ),
            ),
          ),

          SizedBox(height: bottomPad + 20),
        ],
      ),
    );
  }

  String _denominationDisplay(PriestRegistrationModel d) {
    if (d.denomination.isEmpty) return '—';
    if (d.subDenomination.isEmpty) return d.denomination;
    return '${d.denomination} • ${d.subDenomination}';
  }
}

// ─── Summary building blocks ───────────────────────────────────

class _SummaryCard extends StatelessWidget {
  final String label;
  final VoidCallback onEdit;
  final List<Widget> children;

  const _SummaryCard({
    required this.label,
    required this.onEdit,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surfaceWhite,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.08),
        ),
        boxShadow: [
          BoxShadow(
            blurRadius: 8,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.03),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                  letterSpacing: 0.8,
                ),
              ),
              _EditPill(onTap: onEdit),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _EditPill extends StatefulWidget {
  final VoidCallback onTap;
  const _EditPill({required this.onTap});

  @override
  State<_EditPill> createState() => _EditPillState();
}

class _EditPillState extends State<_EditPill> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.94 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: AppColors.primaryBrown.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.edit_outlined,
                size: 12,
                color: AppColors.primaryBrown,
              ),
              const SizedBox(width: 4),
              Text(
                'Edit',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primaryBrown,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadOnlyRow extends StatelessWidget {
  final String label;
  final String value;

  const _ReadOnlyRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value.isEmpty ? '—' : value,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: AppColors.deepDarkBrown,
          ),
        ),
      ],
    );
  }
}

class _ReadOnlyChipGroup extends StatelessWidget {
  final String label;
  final List<String> items;

  const _ReadOnlyChipGroup({required this.label, required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: AppColors.muted,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: items
              .map(
                (item) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color:
                        AppColors.primaryBrown.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    item,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: AppColors.primaryBrown,
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class _PhotoThumb extends StatelessWidget {
  final String? path;
  const _PhotoThumb({required this.path});

  @override
  Widget build(BuildContext context) {
    final has = path != null && path!.isNotEmpty;
    return Container(
      width: 60,
      height: 60,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFFF7F5F2),
        border: Border.all(
          color: AppColors.muted.withValues(alpha: 0.2),
        ),
      ),
      child: has
          ? ClipOval(
              child: Image.file(
                File(path!),
                width: 60,
                height: 60,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.person_outline,
                  size: 24,
                  color: AppColors.muted.withValues(alpha: 0.5),
                ),
              ),
            )
          : Icon(
              Icons.person_outline,
              size: 24,
              color: AppColors.muted.withValues(alpha: 0.5),
            ),
    );
  }
}

class _DocumentRow extends StatelessWidget {
  final String title;
  final String? path;
  final bool isRequired;

  const _DocumentRow({
    required this.title,
    required this.path,
    required this.isRequired,
  });

  @override
  Widget build(BuildContext context) {
    final has = path != null && path!.isNotEmpty;

    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: has
              ? Image.file(
                  File(path!),
                  width: 44,
                  height: 44,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => _placeholder(),
                )
              : _placeholder(),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                has
                    ? 'Ready'
                    : (isRequired ? 'Missing' : 'Not provided'),
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: has
                      ? const Color(0xFF2E7D4F)
                      : (isRequired
                          ? AppColors.errorRed
                          : AppColors.muted),
                ),
              ),
            ],
          ),
        ),
        if (has)
          const Icon(
            Icons.check_circle_rounded,
            size: 18,
            color: Color(0xFF2E7D4F),
          ),
      ],
    );
  }

  Widget _placeholder() {
    return Container(
      width: 44,
      height: 44,
      color: AppColors.muted.withValues(alpha: 0.08),
      child: Icon(
        Icons.description_outlined,
        size: 18,
        color: AppColors.muted.withValues(alpha: 0.5),
      ),
    );
  }
}

class _SubmitButton extends StatefulWidget {
  final bool enabled;
  final VoidCallback onTap;

  const _SubmitButton({required this.enabled, required this.onTap});

  @override
  State<_SubmitButton> createState() => _SubmitButtonState();
}

class _SubmitButtonState extends State<_SubmitButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return GestureDetector(
      onTapDown:
          enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTapCancel:
          enabled ? () => setState(() => _pressed = false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(14),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.primaryBrown
                          .withValues(alpha: 0.2),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : const [],
          ),
          child: Center(
            child: Text(
              'Submit Application',
              style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
