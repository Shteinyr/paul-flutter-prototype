import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'user_profile.dart';

const _blue = Color(0xFF14679E);

class PublicProfileView extends StatelessWidget {
  const PublicProfileView({
    super.key,
    required this.profile,
    required this.avatar,
    this.contactCount = 0,
    this.onEdit,
    this.onChat,
    this.onDisconnect,
  });

  final UserProfile profile;
  final Widget avatar;
  final int contactCount;
  final VoidCallback? onEdit;
  final VoidCallback? onChat;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) => ProfilePage(
    title: 'Public Profile',
    action: onEdit != null
        ? IconButton(
            key: const Key('edit-public-profile'),
            tooltip: 'Edit profile',
            onPressed: onEdit,
            color: _blue,
            icon: const Icon(Icons.edit_outlined, size: 21),
          )
        : onChat == null
        ? null
        : IconButton(
            key: const Key('open-profile-chat'),
            tooltip: 'Chat',
            onPressed: onChat,
            color: _blue,
            icon: const Icon(Icons.chat_bubble_outline, size: 21),
          ),
    child: SingleChildScrollView(
      key: const Key('public-profile-scroll'),
      padding: const EdgeInsets.fromLTRB(37.5, 40, 37.5, 56),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: avatar),
          const SizedBox(height: 30),
          Text(
            profile.name,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            profile.occupation,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.6,
              fontWeight: FontWeight.w300,
            ),
          ),
          const SizedBox(height: 24),
          Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Contacts  '),
                TextSpan(
                  text: '$contactCount',
                  style: const TextStyle(color: _blue),
                ),
              ],
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, letterSpacing: .5),
          ),
          if (profile.summary.trim().isNotEmpty) ...[
            const SizedBox(height: 28),
            Text(
              profile.summary,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 25 / 12,
                fontWeight: FontWeight.w300,
                letterSpacing: .2,
              ),
            ),
          ],
          const SizedBox(height: 60),
          _SkillSection(
            title: 'Offer Skills',
            values: profile.skills,
            sectionKey: 'offered',
          ),
          const SizedBox(height: 60),
          _SkillSection(
            title: 'Network Hiring',
            values: profile.searchingSkills,
            sectionKey: 'searching',
          ),
          if (onDisconnect != null) ...[
            const SizedBox(height: 64),
            TextButton(
              key: const Key('delete-connection'),
              onPressed: onDisconnect,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFF645C),
                textStyle: const TextStyle(fontSize: 12, letterSpacing: .5),
              ),
              child: const Text('Delete Connection'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _SkillSection extends StatelessWidget {
  const _SkillSection({
    required this.title,
    required this.values,
    required this.sectionKey,
  });
  final String title;
  final List<String> values;
  final String sectionKey;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, letterSpacing: .5),
      ),
      const SizedBox(height: 26),
      if (values.isEmpty)
        const Text(
          'No skills added yet',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: Colors.black54),
        )
      else
        _SkillLabels(
          values: values.take(11).toList(),
          trailing: values.length > 11
              ? TextButton(
                  key: Key('see-more-$sectionKey'),
                  style: TextButton.styleFrom(
                    foregroundColor: _blue,
                    minimumSize: const Size(72, 36),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w300,
                    ),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ProfilePage(
                        title: title,
                        child: SingleChildScrollView(
                          key: Key('all-$sectionKey-skills'),
                          padding: const EdgeInsets.fromLTRB(
                            37.5,
                            50,
                            37.5,
                            48,
                          ),
                          child: _SkillLabels(values: values),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('See More'),
                )
              : null,
        ),
    ],
  );
}

class _SkillLabels extends StatelessWidget {
  const _SkillLabels({required this.values, this.trailing});
  final List<String> values;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: 20,
    runSpacing: 8,
    children: [
      for (final value in values)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              fontWeight: FontWeight.w300,
              letterSpacing: .2,
            ),
          ),
        ),
      ?trailing,
    ],
  );
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 402),
        child: Padding(
          padding: EdgeInsets.only(
            top: math.max(MediaQuery.viewPaddingOf(context).top, 24),
            bottom: MediaQuery.viewPaddingOf(context).bottom,
          ),
          child: Column(
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('profile-back'),
                      tooltip: 'Back',
                      onPressed: () {
                        ScaffoldMessenger.of(context).clearSnackBars();
                        Navigator.of(context).pop();
                      },
                      color: _blue,
                      icon: const Icon(Icons.chevron_left, size: 28),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    SizedBox(width: 48, child: action),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  );
}
