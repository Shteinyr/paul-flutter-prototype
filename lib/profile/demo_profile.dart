import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../photo_picker.dart';
import 'user_profile.dart';

Future<UserProfile> loadDemoProfile() async {
  final image = await rootBundle.load('assets/people/paul-galda.png');
  final photo = await normalizeProfilePhoto(
    image.buffer.asUint8List(),
    targetWidth: 384,
  );
  return UserProfile(
    name: 'Paul Galda',
    occupation: 'Business Analyst',
    photo: photo,
    summary:
        'I help teams turn business needs into clear requirements and practical product decisions. My focus is understanding workflows, identifying gaps, and defining what a solution needs to achieve.\n\n'
        'I connect stakeholders and development teams through structured documentation, process maps, and clear acceptance criteria. I’m interested in projects where better processes and thoughtful digital tools can make everyday work easier.',
    skills: const [
      'Business Analysis',
      'Requirements Gathering',
      'Process Mapping',
      'Stakeholder Interviews',
      'User Stories',
      'Acceptance Criteria',
      'BPMN',
      'UML',
      'Gap Analysis',
      'Product Discovery',
      'Requirements Documentation',
      'Backlog Refinement',
    ],
    searchingSkills: const [
      'UX Research',
      'UI Design',
      'Product Design',
      'Frontend Development',
      'Backend Development',
      'Mobile Development',
      'QA Testing',
      'Test Automation',
      'API Integration',
      'Data Analytics',
      'DevOps',
      'Project Management',
    ],
  );
}

/// Update the previous untouched example while retaining edits and deletion.
Future<UserProfile> migrateDemoProfile(UserProfile profile) async {
  if (profile.name != 'Julia Robinson' ||
      profile.occupation != 'UI/UX Designer' ||
      profile.summary !=
          'Hi, I am passionate Artist with a keen eye for detail and a love for creating visuals that inspire and connect. With years of experience in crafting compelling designs, I thrive on transforming ideas' ||
      !listEquals(profile.skills, const [
        'Marketing',
        'UI Design',
        'UX Research',
        'Figma',
        'Prototyping',
      ]) ||
      !listEquals(profile.searchingSkills, const [
        'Dog walker',
        'Photography',
      ])) {
    return profile;
  }
  final image = await rootBundle.load('assets/people/julia-robinson.png');
  final oldPhoto = await normalizeProfilePhoto(
    image.buffer.asUint8List(),
    targetWidth: 384,
  );
  if (!listEquals(profile.photo, oldPhoto)) return profile;
  return loadDemoProfile();
}
