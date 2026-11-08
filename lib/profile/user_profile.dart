import 'dart:convert';
import 'dart:typed_data';

class UserProfile {
  const UserProfile({
    this.name = '',
    this.occupation = '',
    this.photo,
    this.summary = '',
    this.skills = const [],
    this.searchingSkills = const [],
  });

  static const empty = UserProfile();
  final String name;
  final String occupation;
  final Uint8List? photo;
  final String summary;
  final List<String> skills;
  final List<String> searchingSkills;

  bool get hasContact => name.trim().isNotEmpty;
  bool get hasData =>
      name.isNotEmpty ||
      occupation.isNotEmpty ||
      photo != null ||
      summary.isNotEmpty ||
      skills.isNotEmpty ||
      searchingSkills.isNotEmpty;

  UserProfile copyWith({
    String? name,
    String? occupation,
    Uint8List? photo,
    bool clearPhoto = false,
    String? summary,
    List<String>? skills,
    List<String>? searchingSkills,
  }) => UserProfile(
    name: name ?? this.name,
    occupation: occupation ?? this.occupation,
    photo: clearPhoto ? null : photo ?? this.photo,
    summary: summary ?? this.summary,
    skills: skills == null ? this.skills : List.unmodifiable(skills),
    searchingSkills: searchingSkills == null
        ? this.searchingSkills
        : List.unmodifiable(searchingSkills),
  );

  UserProfile withoutPhoto() => copyWith(clearPhoto: true);

  String encode() => jsonEncode({
    'version': 2,
    'name': name,
    'occupation': occupation,
    'photo': photo == null ? null : base64Encode(photo!),
    'summary': summary,
    'skills': skills,
    'searchingSkills': searchingSkills,
  });

  factory UserProfile.decode(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> ||
        (data['version'] != 1 && data['version'] != 2) ||
        data['name'] is! String ||
        data['occupation'] is! String ||
        (data['photo'] != null && data['photo'] is! String)) {
      throw const FormatException('Invalid saved profile.');
    }
    final encodedPhoto = data['photo'] as String?;
    final summary = data['summary'];
    if (summary != null && summary is! String) {
      throw const FormatException('Invalid saved summary.');
    }
    return UserProfile(
      name: data['name'] as String,
      occupation: data['occupation'] as String,
      photo: encodedPhoto == null ? null : base64Decode(encodedPhoto),
      summary: summary as String? ?? '',
      skills: _decodeSkills(data['skills']),
      searchingSkills: _decodeSkills(data['searchingSkills']),
    );
  }

  static List<String> _decodeSkills(Object? value) {
    if (value == null) return const [];
    if (value is! List || value.any((skill) => skill is! String)) {
      throw const FormatException('Invalid saved skills.');
    }
    return List<String>.unmodifiable(value.cast<String>());
  }
}
