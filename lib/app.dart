import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'demo_contacts.dart';
import 'demo_connect.dart';
import 'chat/demo_chat_controller.dart';
import 'chat/demo_chat_view.dart';
import 'photo_picker.dart';
import 'profile/profile_controller.dart';
import 'profile/public_profile_view.dart';
import 'profile/user_profile.dart';
import 'skills/skill_suggestions.dart';

const _background = Color(0xFFF4F4F4);
const _blue = Color(0xFF14679E);
const _red = Color(0xFFFF645C);
const _tracking = 0.5;

class PaulDemoApp extends StatelessWidget {
  const PaulDemoApp({
    super.key,
    required this.controller,
    this.pickPhoto,
    this.chatController,
  });

  final ProfileController controller;
  final PickProfilePhoto? pickPhoto;
  final DemoChatController? chatController;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Profile creation — Demo',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'NotoSans',
      scaffoldBackgroundColor: _background,
      colorScheme: ColorScheme.fromSeed(seedColor: _blue, surface: _background),
      textSelectionTheme: const TextSelectionThemeData(cursorColor: _blue),
    ),
    home: _DemoScreen(
      controller: controller,
      pickPhoto: pickPhoto ?? pickProfilePhoto,
      chatController: chatController,
    ),
  );
}

class _DemoScreen extends StatefulWidget {
  const _DemoScreen({
    required this.controller,
    required this.pickPhoto,
    this.chatController,
  });
  final ProfileController controller;
  final PickProfilePhoto pickPhoto;
  final DemoChatController? chatController;

  @override
  State<_DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<_DemoScreen> with WidgetsBindingObserver {
  int _tab = 0;
  final _connectState = DemoConnectState();
  late final DemoChatController _chat;
  bool _askingNotifications = false;

  ProfileController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _chat = widget.chatController ?? DemoChatController();
    _chat.addListener(_chatChanged);
    _chat.onConnected = () => _showMessage('You’re connected!');
    _chat.onNotification = _showDemoNotification;
    controller.addListener(_profileChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _profileChanged() {
    if (mounted) setState(() {});
  }

  void _chatChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _askDemoNotifications() async {
    if (_askingNotifications || _chat.notificationChoiceMade) return;
    _askingNotifications = true;
    final enabled = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Notifications'),
        content: const Text(
          'Enable demo notifications inside this app? No system push permission is requested.',
        ),
        actions: [
          TextButton(
            key: const Key('skip-demo-push'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          TextButton(
            key: const Key('enable-demo-push'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Enable demo'),
          ),
        ],
      ),
    );
    _askingNotifications = false;
    if (mounted) _chat.setNotifications(enabled ?? false);
  }

  void _showDemoNotification(DemoContact contact, String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('${contact.name}: $text'),
          action: SnackBarAction(
            label: 'Open',
            onPressed: () => _openChat(contact),
          ),
        ),
      );
  }

  Future<void> _openChat(DemoContact contact) async {
    await _askDemoNotifications();
    if (!mounted || !_chat.loaded || _chat.loadFailed) return;
    setState(() => _tab = 2);
    _chat.open(contact.id);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DemoChatView(
          contact: contact,
          controller: _chat,
          ownAvatar: ProfileAvatar(photo: controller.profile.photo, size: 48),
        ),
      ),
    );
    await _chat.flush();
  }

  Future<void> _deleteConnection(
    BuildContext profileContext,
    DemoContact contact,
  ) async {
    final confirmed = await showDialog<bool>(
      context: profileContext,
      builder: (context) => AlertDialog(
        title: const Text('Delete connection?'),
        content: Text(
          '${contact.name} will be removed from Contacts. Your local conversation will remain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-delete-connection'),
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || !profileContext.mounted || confirmed != true) return;
    _chat.disconnect(contact.id);
    Navigator.of(profileContext).pop();
    _showMessage('Connection deleted');
    await _chat.flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(controller.flush());
    if (state != AppLifecycleState.resumed) unawaited(_chat.flush());
  }

  void _selectTab(int tab) {
    if (tab == _tab) return;
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(controller.flush());
    setState(() => _tab = tab);
    unawaited(_chat.flush());
    if (tab == 2) unawaited(_askDemoNotifications());
  }

  void _viewOwnProfile() {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(controller.flush());
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (profileContext) => ListenableBuilder(
          listenable: Listenable.merge([controller, _chat]),
          builder: (_, _) => PublicProfileView(
            profile: controller.profile,
            avatar: ProfileAvatar(photo: controller.profile.photo, size: 144),
            contactCount: _chat.contacts.length,
            onEdit: () {
              Navigator.of(profileContext).pop();
              _selectTab(3);
            },
          ),
        ),
      ),
    );
  }

  void _viewContact(DemoContact contact) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (profileContext) => ListenableBuilder(
          listenable: _chat,
          builder: (_, _) => PublicProfileView(
            profile: contact.profile,
            avatar: ProfileAvatar(asset: contact.photoAsset, size: 144),
            onChat: () => _openChat(contact),
            onDisconnect: _chat.isConnected(contact.id)
                ? () => _deleteConnection(profileContext, contact)
                : null,
          ),
        ),
      ),
    );
  }

  void _openDemoQr() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ListenableBuilder(
          listenable: controller,
          builder: (_, _) => DemoQrView(
            profile: controller.profile,
            avatar: ProfileAvatar(photo: controller.profile.photo, size: 144),
            state: _connectState,
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _deleteAccount() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'Your profile, photo, summary and skills will be removed from this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: _red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (await controller.deleteProfile() && mounted) {
      _connectState.reset();
      await _chat.reset();
      if (!mounted) return;
      setState(() {
        _tab = 0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final viewPadding = MediaQuery.viewPaddingOf(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 402),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: Padding(
              padding: EdgeInsets.only(top: math.max(viewPadding.top, 60) + 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: ProfileNavigation(
                      selected: _tab,
                      onSelected: _selectTab,
                    ),
                  ),
                  if (controller.error != null &&
                      controller.loaded &&
                      !controller.deleting)
                    _SaveError(
                      message: controller.error!,
                      retry: controller.deleteFailed
                          ? _deleteAccount
                          : controller.flush,
                    ),
                  if (_chat.error != null &&
                      _chat.loaded &&
                      (_tab == 0 || _tab == 2))
                    _SaveError(message: _chat.error!, retry: _chat.flush),
                  Expanded(child: _body()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (controller.loadFailed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(controller.error!, textAlign: TextAlign.center),
              TextButton(
                onPressed: controller.load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (!controller.loaded) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if ((_tab == 0 || _tab == 2) && (!_chat.loaded || _chat.loadFailed)) {
      return Center(
        child: _chat.loadFailed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_chat.error!, textAlign: TextAlign.center),
                  TextButton(onPressed: _chat.load, child: const Text('Retry')),
                ],
              )
            : const CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (_tab == 1) {
      return const Center(
        child: Text('No active requests yet', style: TextStyle(fontSize: 12)),
      );
    }
    if (_tab == 2) {
      return Column(
        children: [
          Expanded(
            child: ListView(
              key: const Key('chat-list'),
              padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 24),
              children: [
                for (final thread in _chat.conversations)
                  ContactRow(
                    key: Key('chat-thread-${thread.contactId}'),
                    name: demoPeople[thread.contactId]!.name,
                    occupation: demoPeople[thread.contactId]!.occupation,
                    avatar: ProfileAvatar(
                      asset: demoPeople[thread.contactId]!.photoAsset,
                      size: 65,
                    ),
                    unread: thread.unread,
                    onOpen: () => _openChat(demoPeople[thread.contactId]!),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('demo-chat-notification'),
                onPressed: () =>
                    _chat.receive(demoChatContact.id, 'Hey! Ready to connect?'),
                style: TextButton.styleFrom(foregroundColor: _blue),
                icon: const Icon(Icons.notifications_none, size: 18),
                label: const Text(
                  'Demo notification',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      );
    }
    if (_tab == 0) {
      return Stack(
        children: [
          Positioned.fill(
            child: _Contacts(
              contacts: _chat.contacts,
              onOpen: _viewContact,
              profile: controller.profile,
              onOwnOpen: _viewOwnProfile,
            ),
          ),
          if (controller.profile.hasContact)
            Positioned(
              right: 28,
              bottom: 24,
              child: FloatingActionButton.small(
                key: const Key('open-demo-qr'),
                tooltip: 'My QR code',
                backgroundColor: _blue,
                foregroundColor: Colors.white,
                elevation: 1,
                onPressed: _openDemoQr,
                child: const Icon(Icons.qr_code_scanner, size: 23),
              ),
            ),
        ],
      );
    }
    return ProfileEditor(
      key: ValueKey(controller.generation),
      controller: controller,
      pickPhoto: widget.pickPhoto,
      onViewProfile: _viewOwnProfile,
      onDelete: _deleteAccount,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(_profileChanged);
    unawaited(controller.flush());
    _connectState.dispose();
    _chat.removeListener(_chatChanged);
    _chat.onConnected = null;
    _chat.onNotification = null;
    unawaited(_chat.flush());
    if (widget.chatController == null) _chat.dispose();
    super.dispose();
  }
}

class ProfileEditor extends StatefulWidget {
  const ProfileEditor({
    super.key,
    required this.controller,
    this.pickPhoto,
    this.onViewProfile,
    this.onDelete,
    this.occupationRequired = true,
    this.footer,
    this.onInvite,
  });
  final ProfileController controller;
  final PickProfilePhoto? pickPhoto;
  final VoidCallback? onViewProfile;
  final VoidCallback? onDelete;
  final bool occupationRequired;
  final Widget? footer;
  final VoidCallback? onInvite;
  @override
  State<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends State<ProfileEditor> {
  late final TextEditingController _name;
  late final TextEditingController _occupation;
  late final TextEditingController _summary;
  final _nameFocus = FocusNode();
  final _occupationFocus = FocusNode();
  final _summaryFocus = FocusNode();
  final Set<String> _touched = {};
  bool _picking = false;
  ProfileController get controller => widget.controller;
  bool get _validationActive => controller.profile.photo != null;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: controller.profile.name);
    _occupation = TextEditingController(text: controller.profile.occupation);
    _summary = TextEditingController(text: controller.profile.summary);
    _trackField('name', _nameFocus);
    _trackField('occupation', _occupationFocus);
    _trackField('summary', _summaryFocus);
    controller.addListener(_profileChanged);
  }

  void _trackField(String field, FocusNode focus) {
    focus.addListener(() {
      if (!focus.hasFocus && mounted) setState(() => _touched.add(field));
    });
  }

  String? _required(String field, String value) =>
      (_validationActive || _touched.contains(field)) && value.trim().isEmpty
      ? 'Required'
      : null;

  void _profileChanged() {
    if (!mounted) return;
    _sync(_name, controller.profile.name);
    _sync(_occupation, controller.profile.occupation);
    _sync(_summary, controller.profile.summary);
    setState(() {});
  }

  void _sync(TextEditingController field, String text) {
    if (field.text != text) {
      field.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    }
  }

  Future<void> _choosePhoto() async {
    if (_picking || controller.deleting) return;
    final generation = controller.generation;
    setState(() => _picking = true);
    try {
      final photo = await (widget.pickPhoto ?? pickProfilePhoto)();
      if (!mounted || generation != controller.generation || photo == null) {
        return;
      }
      controller.updatePhoto(photo);
      await controller.flush();
    } on PhotoSelectionException catch (e) {
      _showMessage(e.message);
    } catch (_) {
      _showMessage('Could not select a photo. Please try again.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      absorbing: controller.deleting,
      child: SingleChildScrollView(
        key: const Key('profile-scroll'),
        padding: const EdgeInsets.fromLTRB(37.5, 25, 37.5, 36),
        child: Column(
          children: [
            SizedBox(
              height: 44,
              child: controller.profile.hasContact
                  ? Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: const Key('view-own-profile'),
                        onPressed: widget.onViewProfile,
                        style: TextButton.styleFrom(
                          foregroundColor: _blue,
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('View profile'),
                      ),
                    )
                  : null,
            ),
            SizedBox(
              width: 327,
              height: 144,
              child: Stack(
                alignment: Alignment.topCenter,
                clipBehavior: Clip.none,
                children: [
                  Semantics(
                    label: controller.profile.photo == null
                        ? 'Add profile photo'
                        : 'Replace profile photo',
                    button: true,
                    child: InkResponse(
                      key: const Key('choose-photo'),
                      onTap: _choosePhoto,
                      radius: 72,
                      child: ProfileAvatar(
                        photo: controller.profile.photo,
                        size: 144,
                        loading: _picking,
                      ),
                    ),
                  ),
                  if (controller.profile.photo != null)
                    Positioned(
                      top: 115,
                      right: 35,
                      child: IconButton(
                        key: const Key('remove-photo'),
                        tooltip: 'Remove photo',
                        onPressed: () {
                          controller.removePhoto();
                          unawaited(controller.flush());
                        },
                        icon: Transform.rotate(
                          angle: -3 * math.pi / 4,
                          child: const _AssetIcon(
                            'remove-photo.svg',
                            width: 12.5,
                            height: 12.5,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 44),
            _ProfileField(
              fieldKey: const Key('name-field'),
              controller: _name,
              focusNode: _nameFocus,
              errorText: _required('name', controller.profile.name),
              active: controller.profile.hasData,
              hint: 'What’s your name?',
              label: 'Name',
              onChanged: controller.updateName,
              action: TextInputAction.next,
              onSubmitted: (_) => _occupationFocus.requestFocus(),
              autofillHints: const [AutofillHints.name],
            ),
            const SizedBox(height: 23),
            _ProfileField(
              fieldKey: const Key('occupation-field'),
              controller: _occupation,
              focusNode: _occupationFocus,
              errorText: widget.occupationRequired
                  ? _required('occupation', controller.profile.occupation)
                  : null,
              active: controller.profile.hasData,
              hint: 'What’s occupation?',
              label: 'Occupation',
              onChanged: controller.updateOccupation,
              action: TextInputAction.next,
              onSubmitted: (_) => _summaryFocus.requestFocus(),
            ),
            SizedBox(
              height: controller.profile.summary.trim().isEmpty ? 43 : 21,
            ),
            _ProfileField(
              fieldKey: const Key('summary-field'),
              controller: _summary,
              focusNode: _summaryFocus,
              errorText: _required('summary', controller.profile.summary),
              active: controller.profile.hasData,
              hint: 'Short summary',
              label: 'Short summary',
              onChanged: controller.updateSummary,
              action: TextInputAction.newline,
              maxLines: 6,
              minLines: controller.profile.summary.trim().isEmpty ? 1 : 4,
              bottomPadding: controller.profile.summary.trim().isEmpty
                  ? 16
                  : 26,
              maxLength: 500,
              fontSize: 12,
              lineHeight: 25,
              letterSpacing: 0.3,
            ),
            SizedBox(
              height: controller.profile.summary.trim().isEmpty ? 39 : 23,
            ),
            _SkillsEditor(
              key: const Key('personal-skills'),
              label: 'Add your skills',
              fieldKey: const Key('skills-field'),
              addKey: const Key('add-skill'),
              values: controller.profile.skills,
              active: controller.profile.hasData,
              validate: _validationActive,
              onAdd: (value) => controller.addSkill(value),
              onRemove: (value) => controller.removeSkill(value),
              maxSkills: controller.offeringLimit,
              onInvite: widget.onInvite,
            ),
            SizedBox(height: controller.profile.skills.isEmpty ? 51 : 34),
            _SkillsEditor(
              key: const Key('searching-skills'),
              label: 'Add searching skills',
              fieldKey: const Key('searching-skills-field'),
              addKey: const Key('add-searching-skill'),
              values: controller.profile.searchingSkills,
              active: controller.profile.hasData,
              validate: _validationActive,
              isRequired: false,
              onAdd: (value) => controller.addSkill(value, searching: true),
              onRemove: (value) =>
                  controller.removeSkill(value, searching: true),
            ),
            if (controller.profile.hasData && widget.onDelete != null) ...[
              SizedBox(
                height:
                    controller.profile.skills.isEmpty &&
                        controller.profile.searchingSkills.isEmpty
                    ? 160
                    : 80,
              ),
              TextButton(
                key: const Key('delete-account'),
                onPressed: controller.deleting ? null : widget.onDelete,
                style: TextButton.styleFrom(
                  foregroundColor: _red,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    letterSpacing: _tracking,
                    fontWeight: FontWeight.w400,
                  ),
                  minimumSize: const Size(160, 48),
                ),
                child: Text(
                  controller.deleting ? 'Deleting…' : 'Delete Account',
                ),
              ),
            ],
            ?widget.footer,
            TextButton(
              onPressed: () => showSkillCatalogueAttribution(context),
              child: const Text(
                'Skill catalogue source',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    controller.removeListener(_profileChanged);
    unawaited(controller.flush());
    _name.dispose();
    _occupation.dispose();
    _summary.dispose();
    _nameFocus.dispose();
    _occupationFocus.dispose();
    _summaryFocus.dispose();
    super.dispose();
  }
}

class ProfileNavigation extends StatelessWidget {
  const ProfileNavigation({
    super.key,
    required this.selected,
    required this.onSelected,
    this.enabledTabs = const {0, 1, 2, 3},
  });
  final int selected;
  final ValueChanged<int> onSelected;
  final Set<int> enabledTabs;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tab(0, 'Contacts', 'nav-contacts', selected == 0 ? 128 : 24, 24, 17),
          SizedBox(width: selected == 0 ? 27 : 31),
          _tab(
            1,
            'Hiring',
            'nav-events',
            selected == 1 ? 112 : 24,
            22.5,
            22.5884,
          ),
          SizedBox(width: selected == 0 ? 29 : 29),
          _tab(2, 'Chat', 'nav-inbox', selected == 2 ? 97 : 24, 23.5, 17.2143),
          const SizedBox(width: 30),
          _tab(
            3,
            'Profile',
            'nav-profile',
            selected == 3 ? 109 : 24,
            17.5,
            21.5,
          ),
        ],
      ),
    ),
  );

  Widget _tab(
    int index,
    String label,
    String asset,
    double width,
    double iconWidth,
    double iconHeight,
  ) {
    final active = index == selected;
    final enabled = enabledTabs.contains(index);
    return Semantics(
      selected: active,
      button: true,
      enabled: enabled,
      label: enabled ? label : '$label, unavailable',
      excludeSemantics: true,
      child: Tooltip(
        message: enabled ? label : '$label is not available yet',
        excludeFromSemantics: true,
        child: Opacity(
          opacity: enabled ? 1 : .35,
          child: SizedBox(
            width: width,
            height: 48,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: Key('tab-$index'),
                onTap: enabled ? () => onSelected(index) : null,
                borderRadius: BorderRadius.circular(30),
                child: Center(
                  child: Container(
                    height: 37,
                    decoration: BoxDecoration(
                      color: active ? _blue : null,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _AssetIcon(
                          '$asset${active ? '-active' : ''}.svg',
                          width: iconWidth,
                          height: iconHeight,
                        ),
                        if (active) ...[
                          const SizedBox(width: 13),
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                              letterSpacing: _tracking,
                              color: _background,
                            ),
                          ),
                        ],
                      ],
                    ),
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

class _ProfileField extends StatelessWidget {
  const _ProfileField({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.label,
    required this.onChanged,
    required this.action,
    this.onSubmitted,
    this.autofillHints,
    this.focusNode,
    this.errorText,
    this.active = false,
    this.maxLines = 1,
    this.minLines = 1,
    this.maxLength = 120,
    this.fontSize = 15,
    this.lineHeight = 22,
    this.letterSpacing = _tracking,
    this.bottomPadding = 18,
  });
  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final String label;
  final ValueChanged<String> onChanged;
  final TextInputAction action;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final FocusNode? focusNode;
  final String? errorText;
  final bool active;
  final int maxLines;
  final int minLines;
  final int maxLength;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double bottomPadding;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 54),
        child: TextField(
          key: fieldKey,
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          textAlign: TextAlign.center,
          textInputAction: action,
          textCapitalization: TextCapitalization.words,
          autofillHints: autofillHints,
          maxLines: maxLines,
          minLines: minLines,
          keyboardType: maxLines > 1
              ? TextInputType.multiline
              : TextInputType.text,
          maxLength: maxLength,
          style: TextStyle(
            fontSize: fontSize,
            height: lineHeight / fontSize,
            letterSpacing: letterSpacing,
            color: Colors.black,
          ),
          decoration: InputDecoration(
            hintText: hint,
            counterText: '',
            hintStyle: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              fontWeight: FontWeight.w300,
              color: active ? _blue : const Color(0xFF666666),
            ),
            contentPadding: EdgeInsets.only(top: 13, bottom: bottomPadding),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            semanticCounterText: label,
          ),
        ),
      ),
      Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _FieldSeparator(active: active),
      ),
      if (errorText != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: -24,
          child: _ValidationMessage(errorText!),
        ),
    ],
  );
}

class _FieldSeparator extends StatelessWidget {
  const _FieldSeparator({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 327,
    height: 1,
    child: ColoredBox(
      color: active ? const Color(0xB314679E) : const Color(0x99000000),
    ),
  );
}

class _ValidationMessage extends StatelessWidget {
  const _ValidationMessage(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12,
          height: 20 / 12,
          color: _red,
          letterSpacing: _tracking,
          fontWeight: FontWeight.w300,
        ),
      ),
    ),
  );
}

class _SkillsEditor extends StatefulWidget {
  const _SkillsEditor({
    super.key,
    required this.label,
    required this.fieldKey,
    required this.addKey,
    required this.values,
    required this.onAdd,
    required this.onRemove,
    required this.active,
    required this.validate,
    this.isRequired = true,
    this.maxSkills,
    this.onInvite,
  });
  final String label;
  final Key fieldKey;
  final Key addKey;
  final List<String> values;
  final bool Function(String) onAdd;
  final ValueChanged<String> onRemove;
  final bool active;
  final bool validate;
  final bool isRequired;
  final int? maxSkills;
  final VoidCallback? onInvite;

  @override
  State<_SkillsEditor> createState() => _SkillsEditorState();
}

class _SkillsEditorState extends State<_SkillsEditor> {
  final _draft = TextEditingController();
  final _focus = FocusNode();
  String? _error;
  bool _touched = false;

  String? get _fieldError =>
      _error ??
      (widget.isRequired &&
              (widget.validate || _touched) &&
              widget.values.isEmpty &&
              _draft.text.trim().isEmpty
          ? 'Required'
          : null);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) setState(() => _touched = true);
    });
  }

  void _add() {
    final text = _draft.text.trim();
    if (text.isEmpty) {
      setState(() {
        _touched = true;
        _error = widget.isRequired && widget.values.isEmpty ? 'Required' : null;
      });
      _focus.requestFocus();
      return;
    }
    if (widget.maxSkills != null && widget.values.length >= widget.maxSkills!) {
      setState(() => _error = 'Skill limit reached');
      return;
    }
    if (widget.onAdd(text)) {
      _draft.clear();
      setState(() {
        _error = null;
        _touched = true;
      });
      _focus.unfocus();
    } else {
      setState(() {
        _touched = true;
        _error = text.isEmpty ? 'Required' : 'Already added';
      });
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Stack(
        clipBehavior: Clip.none,
        children: [
          SizedBox(
            height: 54,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: TextField(
                    key: widget.fieldKey,
                    controller: _draft,
                    focusNode: _focus,
                    textAlign: TextAlign.center,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.done,
                    maxLength: 64,
                    onChanged: (_) {
                      setState(() => _error = null);
                    },
                    onSubmitted: (_) => _add(),
                    style: const TextStyle(
                      fontSize: 15,
                      height: 22 / 15,
                      letterSpacing: _tracking,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.label,
                      hintStyle: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w100,
                        color: widget.active
                            ? const Color(0x3314679E)
                            : const Color(0x33000000),
                      ),
                      border: InputBorder.none,
                      counterText: '',
                      contentPadding: const EdgeInsets.fromLTRB(20, 13, 35, 18),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _FieldSeparator(active: widget.active),
                ),
                Positioned(
                  right: -10,
                  top: 1,
                  child: IconButton(
                    key: widget.addKey,
                    onPressed: _add,
                    tooltip: widget.label,
                    constraints: const BoxConstraints.tightFor(
                      width: 50,
                      height: 50,
                    ),
                    padding: EdgeInsets.zero,
                    icon: widget.active
                        ? Image.asset(
                            'assets/icons/add-skill-active.png',
                            width: 50,
                            height: 50,
                            excludeFromSemantics: true,
                          )
                        : const _AssetIcon(
                            'add-skill.svg',
                            width: 12.5,
                            height: 12.5,
                          ),
                  ),
                ),
              ],
            ),
          ),
          if (_fieldError == 'Required')
            const Positioned(
              left: 0,
              right: 0,
              bottom: -24,
              child: _ValidationMessage('Required'),
            ),
        ],
      ),
      SkillSuggestions(
        controller: _draft,
        focusNode: _focus,
        selected: widget.values,
        onSelected: (value) {
          _draft.text = value;
          _add();
        },
      ),
      if (_fieldError != null && _fieldError != 'Required')
        _ValidationMessage(_fieldError!),
      if (_fieldError == 'Skill limit reached' && widget.onInvite != null)
        TextButton(
          onPressed: widget.onInvite,
          child: const Text('Invite friends'),
        ),
      if (widget.values.isNotEmpty) ...[
        const SizedBox(height: 21),
        Transform.translate(
          offset: const Offset(-13.5, 0),
          child: Wrap(
            spacing: 8,
            runSpacing: 9,
            children: [
              for (final skill in widget.values)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        skill,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                          height: 20 / 12,
                          letterSpacing: _tracking,
                          color: Colors.black,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove $skill',
                      onPressed: () {
                        widget.onRemove(skill);
                        setState(() => _touched = true);
                      },
                      constraints: const BoxConstraints.tightFor(
                        width: 36,
                        height: 36,
                      ),
                      padding: EdgeInsets.zero,
                      icon: Transform.rotate(
                        angle: -3 * math.pi / 4,
                        child: const _AssetIcon(
                          'remove-photo.svg',
                          width: 12.5,
                          height: 12.5,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    ],
  );

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _Contacts extends StatelessWidget {
  const _Contacts({
    required this.contacts,
    required this.onOpen,
    required this.profile,
    required this.onOwnOpen,
  });
  final List<DemoContact> contacts;
  final ValueChanged<DemoContact> onOpen;
  final UserProfile profile;
  final VoidCallback onOwnOpen;

  @override
  Widget build(BuildContext context) => ListView(
    key: const Key('contacts-list'),
    padding: const EdgeInsets.fromLTRB(37.5, 47, 37.5, 88),
    children: [
      if (profile.hasContact)
        ContactRow(
          key: const Key('contact-row'),
          name: profile.name.trim(),
          occupation: profile.occupation.trim(),
          avatar: ProfileAvatar(photo: profile.photo, size: 65),
          onOpen: onOwnOpen,
        ),
      for (final contact in contacts)
        ContactRow(
          key: Key('demo-contact-${contact.id}'),
          name: contact.name,
          occupation: contact.occupation,
          avatar: ProfileAvatar(asset: contact.photoAsset, size: 65),
          onOpen: () => onOpen(contact),
        ),
    ],
  );
}

class ContactRow extends StatelessWidget {
  const ContactRow({
    super.key,
    required this.name,
    required this.occupation,
    required this.avatar,
    this.onOpen,
    this.unread = 0,
  });
  final String name;
  final String occupation;
  final Widget avatar;
  final VoidCallback? onOpen;
  final int unread;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onOpen,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 17),
      child: SizedBox(
        height: 83,
        child: Stack(
          children: [
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _AssetIcon('separator.svg', width: 327, height: 1),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                avatar,
                const SizedBox(width: 21),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 1.25,
                          fontWeight: FontWeight.w500,
                          letterSpacing: _tracking,
                          color: Colors.black,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        occupation,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 20 / 12,
                          fontWeight: FontWeight.w300,
                          letterSpacing: _tracking,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
                if (unread > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 20, left: 8),
                    child: Semantics(
                      label: '$unread unread messages',
                      child: Container(
                        key: Key('unread-$unread'),
                        width: 18,
                        height: 18,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          color: _blue,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: const TextStyle(
                            fontSize: 9,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.photo,
    this.asset,
    required this.size,
    this.loading = false,
  });
  final Uint8List? photo;
  final String? asset;
  final double size;
  final bool loading;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: photo == null && asset == null
          ? Border.all(color: const Color(0x33000000))
          : null,
    ),
    clipBehavior: Clip.antiAlias,
    child: loading
        ? const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          )
        : asset != null
        ? Image.asset(
            asset!,
            fit: BoxFit.cover,
            cacheHeight: (size * 3).round(),
            errorBuilder: (_, _, _) => _placeholder(),
          )
        : photo != null
        ? Image.memory(
            photo!,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _placeholder(),
          )
        : _placeholder(),
  );

  Widget _placeholder() =>
      const Center(child: _AssetIcon('camera.svg', width: 21.5, height: 19.5));
}

class _AssetIcon extends StatelessWidget {
  const _AssetIcon(this.asset, {required this.width, required this.height});
  final String asset;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/icons/$asset',
    width: width,
    height: height,
    excludeFromSemantics: true,
  );
}

class _SaveError extends StatelessWidget {
  const _SaveError({required this.message, required this.retry});
  final String message;
  final Future<void> Function() retry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: Row(
      children: [
        Expanded(child: Text(message, style: const TextStyle(fontSize: 12))),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}
