// Step 2 — ministry details, grouped into warm white section cards.
//
// The AI Write button is intentionally *not* AI: it stitches a bio
// from the already-filled fields. This keeps the app premium-feeling
// without adding model inference costs or latency, and the output
// reads naturally because it's built from the priest's own data.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:gospel_vox/core/theme/app_colors.dart';
import 'package:gospel_vox/core/widgets/app_snackbar.dart';
import 'package:gospel_vox/core/widgets/info_hint.dart';

const List<String> _kDenominations = [
  'Catholic',
  'Protestant',
  'Orthodox',
  'Pentecostal',
  'Evangelical',
  'Anglican',
  'Methodist',
  'Baptist',
  'Presbyterian',
  'Assemblies of God',
  'Church of South India',
  'Church of North India',
  'Brethren',
  'Other',
];

const List<String> _kSpecializations = [
  'Counseling',
  'Prayer Support',
  'Healing Ministry',
  'Deliverance',
  'Bible Teaching',
  'Youth Ministry',
  'Family Counseling',
  'Marriage Guidance',
  'Grief Support',
  'Addiction Recovery',
  'Spiritual Direction',
  'Evangelism',
  'Worship Leading',
  "Children's Ministry",
];

const List<String> _kLanguages = [
  'English',
  'Malayalam',
  'Hindi',
  'Tamil',
  'Telugu',
  'Kannada',
  'Marathi',
  'Bengali',
  'Gujarati',
  'Urdu',
  'Punjabi',
  'Odia',
  'Other',
];

class RegistrationStep2 extends StatefulWidget {
  // Passed in from the shell so the AI bio generator can personalise
  // with the priest's actual name without re-reading the cubit state.
  final String priestName;

  // Hydrate from cubit state when the user navigates back+forward or
  // resumes from a draft.
  final String initialDenomination;
  final String initialSubDenomination;
  final String initialChurchName;
  final String initialDiocese;
  final String initialLocation;
  final int initialYears;
  final String initialBio;
  final List<String> initialLanguages;
  final List<String> initialSpecializations;

  final void Function(
    String denomination,
    String subDenomination,
    String churchName,
    String diocese,
    String location,
    int yearsOfExperience,
    String bio,
    List<String> languages,
    List<String> specializations,
  ) onNext;

  const RegistrationStep2({
    super.key,
    required this.priestName,
    required this.onNext,
    this.initialDenomination = '',
    this.initialSubDenomination = '',
    this.initialChurchName = '',
    this.initialDiocese = '',
    this.initialLocation = '',
    this.initialYears = 0,
    this.initialBio = '',
    this.initialLanguages = const [],
    this.initialSpecializations = const [],
  });

  @override
  State<RegistrationStep2> createState() => _RegistrationStep2State();
}

class _RegistrationStep2State extends State<RegistrationStep2> {
  late final TextEditingController _subDenominationController;
  late final TextEditingController _churchController;
  late final TextEditingController _dioceseController;
  late final TextEditingController _locationController;
  late final TextEditingController _yearsController;
  late final TextEditingController _bioController;

  final FocusNode _churchFocus = FocusNode();
  final FocusNode _yearsFocus = FocusNode();
  final FocusNode _locationFocus = FocusNode();
  final FocusNode _bioFocus = FocusNode();

  String? _denomination;
  late final Set<String> _selectedLanguages;
  late final Set<String> _selectedSpecializations;

  String? _denominationError;
  String? _churchError;
  String? _yearsError;
  String? _locationError;
  String? _bioError;
  String? _specializationsError;
  String? _languagesError;

  @override
  void initState() {
    super.initState();
    _denomination = widget.initialDenomination.isEmpty
        ? null
        : widget.initialDenomination;
    _subDenominationController =
        TextEditingController(text: widget.initialSubDenomination);
    _churchController =
        TextEditingController(text: widget.initialChurchName);
    _dioceseController =
        TextEditingController(text: widget.initialDiocese);
    _locationController =
        TextEditingController(text: widget.initialLocation);
    _yearsController = TextEditingController(
      text: widget.initialYears > 0 ? widget.initialYears.toString() : '',
    );
    _bioController = TextEditingController(text: widget.initialBio);
    _selectedLanguages = {...widget.initialLanguages};
    _selectedSpecializations = {...widget.initialSpecializations};

    _bioController.addListener(_onBioChanged);

    // On-blur validation for the text fields the user types into.
    _churchFocus.addListener(() {
      if (!_churchFocus.hasFocus) _validateChurch();
    });
    _yearsFocus.addListener(() {
      if (!_yearsFocus.hasFocus) _validateYears();
    });
    _locationFocus.addListener(() {
      if (!_locationFocus.hasFocus) _validateLocation();
    });
    _bioFocus.addListener(() {
      if (!_bioFocus.hasFocus) _validateBio();
    });
  }

  void _onBioChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bioController.removeListener(_onBioChanged);
    _subDenominationController.dispose();
    _churchController.dispose();
    _dioceseController.dispose();
    _locationController.dispose();
    _yearsController.dispose();
    _bioController.dispose();
    _churchFocus.dispose();
    _yearsFocus.dispose();
    _locationFocus.dispose();
    _bioFocus.dispose();
    super.dispose();
  }

  // ── Validators ──

  String? _validateDenomination() {
    final err = _denomination == null
        ? 'Please select a denomination'
        : null;
    if (err != _denominationError && mounted) {
      setState(() => _denominationError = err);
    }
    return err;
  }

  String? _validateChurch() {
    final txt = _churchController.text.trim();
    String? err;
    if (txt.isEmpty) {
      err = 'Church name is required';
    } else if (txt.length < 3) {
      err = 'Church name must be at least 3 characters';
    }
    if (err != _churchError && mounted) {
      setState(() => _churchError = err);
    }
    return err;
  }

  String? _validateYears() {
    final txt = _yearsController.text.trim();
    final years = int.tryParse(txt);
    String? err;
    if (txt.isEmpty) {
      err = 'Years of ministry is required';
    } else if (years == null || years <= 0) {
      err = 'Enter a valid number of years';
    }
    if (err != _yearsError && mounted) {
      setState(() => _yearsError = err);
    }
    return err;
  }

  String? _validateLocation() {
    final txt = _locationController.text.trim();
    final err = txt.isEmpty ? 'Location is required' : null;
    if (err != _locationError && mounted) {
      setState(() => _locationError = err);
    }
    return err;
  }

  String? _validateBio() {
    final bio = _bioController.text.trim();
    String? err;
    if (bio.isEmpty) {
      err = 'Bio is required';
    } else if (bio.length < 50) {
      err = 'Bio must be at least 50 characters';
    }
    if (err != _bioError && mounted) {
      setState(() => _bioError = err);
    }
    return err;
  }

  // ── Denomination picker ──

  Future<void> _pickDenomination() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceWhite,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.muted.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Select denomination',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.deepDarkBrown,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight:
                          MediaQuery.of(context).size.height * 0.5,
                    ),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _kDenominations.length,
                      itemBuilder: (_, i) {
                        final option = _kDenominations[i];
                        final selected = option == _denomination;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () =>
                              Navigator.pop(sheetCtx, option),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 14,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.primaryBrown
                                      .withValues(alpha: 0.06)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    option,
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: selected
                                          ? AppColors.primaryBrown
                                          : AppColors.deepDarkBrown,
                                    ),
                                  ),
                                ),
                                if (selected)
                                  const Icon(
                                    Icons.check,
                                    color: AppColors.primaryBrown,
                                    size: 18,
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (picked != null && mounted) {
      setState(() {
        _denomination = picked;
        _denominationError = null;
      });
    }
  }

  // ── Chip toggles ──

  void _toggleSpecialization(String item) {
    setState(() {
      if (_selectedSpecializations.contains(item)) {
        _selectedSpecializations.remove(item);
      } else {
        _selectedSpecializations.add(item);
      }
      if (_selectedSpecializations.isNotEmpty) {
        _specializationsError = null;
      }
    });
  }

  void _toggleLanguage(String item) {
    setState(() {
      if (_selectedLanguages.contains(item)) {
        _selectedLanguages.remove(item);
      } else {
        _selectedLanguages.add(item);
      }
      if (_selectedLanguages.isNotEmpty) _languagesError = null;
    });
  }

  // ── AI bio generator (string interpolation under the hood) ──

  void _generateBio() {
    final name = widget.priestName.trim();
    final denom = _denomination ?? '';
    final church = _churchController.text.trim();
    final years = _yearsController.text.trim();
    final loc = _locationController.text.trim();
    final specs = _selectedSpecializations.join(', ');
    final langs = _selectedLanguages.join(', ');

    if (name.isEmpty || denom.isEmpty) {
      AppSnackBar.info(
        context,
        'Please fill in your name and denomination first.',
      );
      return;
    }

    final buf = StringBuffer();
    buf.write('I am $name, a $denom minister');
    if (church.isNotEmpty) buf.write(' serving at $church');
    if (loc.isNotEmpty) buf.write(' in $loc');
    buf.write('. ');
    if (years.isNotEmpty && int.tryParse(years) != null) {
      buf.write('With $years years of ministry experience, ');
    }
    if (specs.isNotEmpty) {
      buf.write('I specialize in $specs. ');
    }
    if (langs.isNotEmpty) {
      buf.write('I can counsel in $langs. ');
    }
    buf.write(
      'I am passionate about helping people grow in their faith '
      'and find spiritual peace.',
    );

    setState(() {
      _bioController.text = buf.toString();
      _bioError = null;
    });
  }

  // ── Submit ──

  void _validateAndProceed() {
    final denomErr = _validateDenomination();
    final churchErr = _validateChurch();
    final yearsErr = _validateYears();
    final locErr = _validateLocation();
    final bioErr = _validateBio();

    String? specErr;
    String? langErr;
    if (_selectedSpecializations.isEmpty) {
      specErr = 'Please select at least one specialization';
    }
    if (_selectedLanguages.isEmpty) {
      langErr = 'Please select at least one language';
    }
    if ((specErr != _specializationsError ||
            langErr != _languagesError) &&
        mounted) {
      setState(() {
        _specializationsError = specErr;
        _languagesError = langErr;
      });
    }

    if (denomErr != null ||
        churchErr != null ||
        yearsErr != null ||
        locErr != null ||
        bioErr != null ||
        specErr != null ||
        langErr != null) {
      return;
    }

    widget.onNext(
      _denomination!,
      _subDenominationController.text.trim(),
      _churchController.text.trim(),
      _dioceseController.text.trim(),
      _locationController.text.trim(),
      int.parse(_yearsController.text.trim()),
      _bioController.text.trim(),
      _selectedLanguages.toList(),
      _selectedSpecializations.toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final bioLength = _bioController.text.length;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            'Ministry Details',
            style: GoogleFonts.inter(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tell us about your spiritual service',
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: AppColors.muted,
            ),
          ),
          const SizedBox(height: 28),

          // ── Faith background card ──
          _SectionCard(
            label: 'FAITH BACKGROUND',
            children: [
              _DropdownField(
                label: 'Denomination',
                value: _denomination,
                hint: 'Select your denomination',
                errorText: _denominationError,
                onTap: _pickDenomination,
              ),
              _PlainField(
                label: 'Sub-denomination',
                hint: 'e.g. Latin Rite, Syro-Malabar, CSI',
                controller: _subDenominationController,
                keyboardType: TextInputType.text,
              ),
              _PlainField(
                label: 'Church Name',
                hint: 'Name of your church or parish',
                controller: _churchController,
                focusNode: _churchFocus,
                keyboardType: TextInputType.text,
                errorText: _churchError,
                onChanged: () {
                  if (_churchError != null && mounted) {
                    setState(() => _churchError = null);
                  }
                },
              ),
              _PlainField(
                label: 'Diocese / District',
                hint: 'Your diocese or district',
                controller: _dioceseController,
                keyboardType: TextInputType.text,
                isLast: true,
              ),
            ],
          ),

          // ── Experience + location card ──
          _SectionCard(
            label: 'EXPERIENCE & LOCATION',
            children: [
              _PlainField(
                label: 'Years of Ministry',
                hint: 'e.g. 5',
                controller: _yearsController,
                focusNode: _yearsFocus,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
                errorText: _yearsError,
                onChanged: () {
                  if (_yearsError != null && mounted) {
                    setState(() => _yearsError = null);
                  }
                },
              ),
              _PlainField(
                label: 'Location',
                hint: 'City, State',
                controller: _locationController,
                focusNode: _locationFocus,
                keyboardType: TextInputType.text,
                errorText: _locationError,
                hintId: 'location_hint',
                hintText:
                    'Your location helps users find speakers near them.',
                suffixIcon: Icon(
                  Icons.location_on_outlined,
                  size: 20,
                  color: AppColors.muted.withValues(alpha: 0.7),
                ),
                onChanged: () {
                  if (_locationError != null && mounted) {
                    setState(() => _locationError = null);
                  }
                },
                isLast: true,
              ),
            ],
          ),

          // ── Specializations card ──
          _SectionCard(
            label: 'SPECIALIZATIONS',
            children: [
              Text(
                'Select areas you specialize in',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _kSpecializations.map((item) {
                  return _ChoiceChipTile(
                    label: item,
                    selected: _selectedSpecializations.contains(item),
                    onTap: () => _toggleSpecialization(item),
                  );
                }).toList(),
              ),
              if (_specializationsError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _specializationsError!,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.errorRed,
                  ),
                ),
              ],
            ],
          ),

          // ── Languages card ──
          _SectionCard(
            label: 'LANGUAGES SPOKEN',
            children: [
              Text(
                'Select languages you can counsel in',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _kLanguages.map((lang) {
                  return _ChoiceChipTile(
                    label: lang,
                    selected: _selectedLanguages.contains(lang),
                    onTap: () => _toggleLanguage(lang),
                  );
                }).toList(),
              ),
              if (_languagesError != null) ...[
                const SizedBox(height: 10),
                Text(
                  _languagesError!,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.errorRed,
                  ),
                ),
              ],
            ],
          ),

          // ── Bio card with AI Write ──
          _SectionCard(
            label: 'BIO',
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            'About your ministry',
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              color: AppColors.deepDarkBrown,
                            ),
                          ),
                        ),
                        const InfoHint(
                          id: 'bio_hint',
                          text:
                              'A good bio helps users understand your '
                              'background and feel confident in reaching '
                              'out. Be authentic and mention your key '
                              'areas of ministry.',
                        ),
                      ],
                    ),
                  ),
                  _AiWriteButton(onTap: _generateBio),
                ],
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _bioController,
                focusNode: _bioFocus,
                maxLines: 5,
                maxLength: 500,
                buildCounter: (
                  _, {
                  required currentLength,
                  required isFocused,
                  maxLength,
                }) =>
                    null,
                onChanged: (_) {
                  if (_bioError != null && mounted) {
                    setState(() => _bioError = null);
                  }
                },
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  color: AppColors.deepDarkBrown,
                ),
                decoration: InputDecoration(
                  hintText:
                      'Share about your ministry journey, experience, and how you help people spiritually...',
                  hintStyle: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: AppColors.muted.withValues(alpha: 0.5),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF7F5F2),
                  isDense: true,
                  border: _fieldBorder(
                    AppColors.muted.withValues(alpha: 0.2),
                  ),
                  enabledBorder: _fieldBorder(
                    AppColors.muted.withValues(alpha: 0.2),
                  ),
                  focusedBorder: _fieldBorder(
                    AppColors.primaryBrown,
                    width: 1.5,
                  ),
                  errorBorder: _fieldBorder(AppColors.errorRed),
                  focusedErrorBorder:
                      _fieldBorder(AppColors.errorRed, width: 1.5),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  errorText: _bioError,
                  errorStyle: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: AppColors.errorRed,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '$bioLength/500',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: bioLength < 50
                        ? AppColors.errorRed.withValues(alpha: 0.8)
                        : AppColors.muted,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),
          _ContinueButton(onTap: _validateAndProceed),
          SizedBox(height: bottomPad + 20),
        ],
      ),
    );
  }
}

OutlineInputBorder _fieldBorder(Color color, {double width = 1}) {
  return OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: color, width: width),
  );
}

class _SectionCard extends StatelessWidget {
  final String label;
  final List<Widget> children;
  const _SectionCard({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
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
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppColors.primaryBrown,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }
}

class _PlainField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final TextInputType keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final String? errorText;
  final Widget? suffixIcon;
  final VoidCallback? onChanged;
  // Kills the trailing bottom padding on the last field in a section,
  // so the section card doesn't have awkward dead space.
  final bool isLast;

  // Optional hint shown as a tap-to-reveal icon beside the label.
  // The id scopes read/unread tracking per-field.
  final String? hintText;
  final String? hintId;

  const _PlainField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.keyboardType,
    this.focusNode,
    this.inputFormatters,
    this.errorText,
    this.suffixIcon,
    this.onChanged,
    this.isLast = false,
    this.hintText,
    this.hintId,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: AppColors.deepDarkBrown,
                ),
              ),
              if (hintText != null && hintId != null)
                InfoHint(id: hintId!, text: hintText!),
            ],
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: controller,
            focusNode: focusNode,
            keyboardType: keyboardType,
            textInputAction: TextInputAction.next,
            inputFormatters: inputFormatters,
            onChanged: (_) => onChanged?.call(),
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w400,
              color: AppColors.deepDarkBrown,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: AppColors.muted.withValues(alpha: 0.5),
              ),
              suffixIcon: suffixIcon,
              filled: true,
              fillColor: const Color(0xFFF7F5F2),
              isDense: true,
              border: _fieldBorder(
                AppColors.muted.withValues(alpha: 0.2),
              ),
              enabledBorder: _fieldBorder(
                AppColors.muted.withValues(alpha: 0.2),
              ),
              focusedBorder:
                  _fieldBorder(AppColors.primaryBrown, width: 1.5),
              errorBorder: _fieldBorder(AppColors.errorRed),
              focusedErrorBorder:
                  _fieldBorder(AppColors.errorRed, width: 1.5),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 14,
              ),
              errorText: errorText,
              errorStyle: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.errorRed,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownField extends StatelessWidget {
  final String label;
  final String? value;
  final String hint;
  final String? errorText;
  final VoidCallback onTap;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.hint,
    required this.onTap,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.deepDarkBrown,
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F5F2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: errorText != null
                      ? AppColors.errorRed
                      : AppColors.muted.withValues(alpha: 0.2),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      value ?? hint,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        color: value == null
                            ? AppColors.muted.withValues(alpha: 0.5)
                            : AppColors.deepDarkBrown,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.keyboard_arrow_down,
                    color: AppColors.muted.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 6),
            Text(
              errorText!,
              style: GoogleFonts.inter(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: AppColors.errorRed,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ChoiceChipTile extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceChipTile({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primaryBrown.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppColors.primaryBrown
                : AppColors.muted.withValues(alpha: 0.25),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color:
                selected ? AppColors.primaryBrown : AppColors.muted,
          ),
        ),
      ),
    );
  }
}

class _AiWriteButton extends StatefulWidget {
  final VoidCallback onTap;
  const _AiWriteButton({required this.onTap});

  @override
  State<_AiWriteButton> createState() => _AiWriteButtonState();
}

class _AiWriteButtonState extends State<_AiWriteButton> {
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
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primaryBrown,
                AppColors.primaryBrown.withValues(alpha: 0.8),
              ],
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_awesome,
                size: 14,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                'AI Write',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ContinueButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ContinueButton({required this.onTap});

  @override
  State<_ContinueButton> createState() => _ContinueButtonState();
}

class _ContinueButtonState extends State<_ContinueButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: Container(
          width: double.infinity,
          height: 54,
          decoration: BoxDecoration(
            color: AppColors.primaryBrown,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: AppColors.primaryBrown.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              'Continue',
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
