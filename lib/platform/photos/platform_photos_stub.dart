import 'dart:typed_data';
import '../../photo_picker.dart';
import '../../photo_selection_journal.dart';

Future<void> recoverPlatformPhotos() async {}
String onboardingPhotoOwner() => 'browser-onboarding';
void clearOnboardingPhotoOwner() {}
Future<Uint8List?> pickPlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
}) => pickProfilePhoto();
Uint8List? pendingPlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
}) => null;
void completePlatformPhoto({
  required String ownerId,
  required PhotoDestination destination,
  required String targetId,
  required Uint8List photo,
}) {}
