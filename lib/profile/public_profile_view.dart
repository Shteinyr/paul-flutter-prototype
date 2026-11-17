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
    this.nameStyle,
  });

  final UserProfile profile;
  final Widget avatar;
  final int contactCount;
  final VoidCallback? onEdit;
  final VoidCallback? onChat;
  final VoidCallback? onDisconnect;
  final TextStyle? nameStyle;

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
            style: const TextStyle(
              fontSize: 15,
              height: 22 / 15,
              fontWeight: FontWeight.w400,
              letterSpacing: .5,
            ).merge(nameStyle),
          ),
          const SizedBox(height: 8),
          Text(
            profile.occupation,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              height: 20 / 12,
              fontWeight: FontWeight.w300,
              letterSpacing: .5,
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
            style: const TextStyle(
              fontSize: 12,
              height: 20 / 12,
              letterSpacing: .5,
            ),
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
                letterSpacing: .3,
              ),
            ),
          ],
          const SizedBox(height: 60),
          _SkillSection(
            title: 'Offer Skills',
            detailTitle: 'Offer skills',
            values: profile.skills,
            sectionKey: 'offered',
          ),
          const SizedBox(height: 60),
          _SkillSection(
            title: 'Searching skills',
            detailTitle: 'Network Hiring',
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
    required this.detailTitle,
    required this.values,
    required this.sectionKey,
  });
  final String title;
  final String detailTitle;
  final List<String> values;
  final String sectionKey;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        title,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 12,
          height: 20 / 12,
          letterSpacing: .5,
        ),
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
                        title: detailTitle,
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
              height: 20 / 12,
              fontWeight: FontWeight.w300,
              letterSpacing: .5,
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
                      color: Colors.black,
                      icon: const Icon(Icons.arrow_back, size: 22),
                    ),
                    Expanded(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 16,
                          height: 20 / 16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: .5,
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
