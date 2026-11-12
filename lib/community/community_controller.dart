import 'dart:async';
import 'dart:convert';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';

import '../live/chat_api.dart';
import '../live/chat_controller.dart';
import '../live/member_capabilities.dart';
import '../push/push_browser_types.dart';
import 'community_api.dart';

class CommunityController extends ChangeNotifier {
  CommunityController(this.repository, {required ChatStateStore drafts})
    : _drafts = drafts {
    _identity = repository.identityChanges.listen(
      (userId) {
        if (userId != repository.userId) {
          if (_draftLoaded) unawaited(_persist());
          _draftTimer?.cancel();
          _authorized = false;
          requests = const [];
          skill = '';
          message = '';
          _operation = null;
          error = const CommunityException('sign_in_required').toString();
          _notify();
        }
      },
      onError: (Object _) {
        error = const CommunityException('sign_in_required').toString();
        _notify();
      },
    );
  }
  final CommunityRepository repository;
  final ChatStateStore _drafts;
  late final StreamSubscription<String?> _identity;
  Future<bool> _writes = Future.value(true);
  Timer? _draftTimer;
  bool _disposed = false;
  bool _authorized = true;
  int _feedGeneration = 0;
  int _capabilityGeneration = 0;
  bool _draftLoaded = false;
  Future<void>? _preparing;
  Future<void>? _refreshingFeed;
  String? _operation;
  CommunityReceipt? _completed;
  final _closeOperations = <String, String>{};
  final _closing = <String>{};
  List<CommunityRequest> requests = const [];
  Map<String, dynamic>? _cursor;
  Duration _serverOffset = Duration.zero;
  bool loading = false;
  bool loadingMore = false;
  bool publishing = false;
  String skill = '';
  String message = '';
  String? error;
  String? pageError;
  String? draftError;
  String? publishError;
  MemberCapabilities? capabilities;
  String? capabilityError;
  bool get pendingPublish => _operation != null;
  bool get draftReady => _draftLoaded;
  bool get hasMore => _cursor != null;
  bool get current =>
      !_disposed &&
      _authorized &&
      repository.currentUserId == repository.userId;
  DateTime get serverNow => DateTime.now().toUtc().add(_serverOffset);
  bool closing(String id) => _closing.contains(id);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  String _state({bool clearPublish = false}) => jsonEncode({
    'version': 1,
    'skill': clearPublish ? '' : skill,
    'message': clearPublish ? '' : message,
    'operation': clearPublish ? null : _operation,
  });

  Future<bool> _persist({bool clearPublish = false}) {
    _draftTimer?.cancel();
    final snapshot = _state(clearPublish: clearPublish);
    _writes = _writes.then((_) async {
      try {
        await _drafts.write('community.${repository.userId}', snapshot);
        draftError = null;
        return true;
      } catch (_) {
        draftError = 'Could not save your request draft. Retry.';
        _notify();
        return false;
      }
    });
    return _writes;
  }

  Future<void> prepareDraft({String initialSkill = ''}) {
    final pending = _preparing;
    if (pending != null) return pending;
    final operation = _prepareDraft(initialSkill);
    _preparing = operation;
    unawaited(operation.whenComplete(() => _preparing = null));
    return operation;
  }

  Future<void> _prepareDraft(String initialSkill) async {
    if (!current) return;
    try {
      if (!_draftLoaded) {
        final source = await _drafts.read('community.${repository.userId}');
        if (!current) return;
        if (source != null) {
          final data = jsonDecode(source) as Map;
          if (data['version'] != 1 ||
              data['skill'] is! String ||
              data['message'] is! String ||
              (data['operation'] != null &&
                  (data['operation'] is! String ||
                      !pushUuid.hasMatch(data['operation'] as String)))) {
            throw const FormatException('Invalid request draft');
          }
          skill = data['skill'] as String;
          message = data['message'] as String;
          _operation = data['operation'] as String?;
        }
        _draftLoaded = true;
      }
      if (skill.isEmpty && !pendingPublish && initialSkill.isNotEmpty) {
        skill = initialSkill;
      }
      draftError = null;
    } catch (_) {
      draftError = 'Could not restore your request draft. Retry.';
    }
    _notify();
    await refreshCapabilities();
  }

  void updateDraft({String? skill, String? message}) {
    if (!current || pendingPublish || publishing || !_draftLoaded) return;
    if (skill != null) this.skill = skill;
    if (message != null) this.message = message;
    publishError = null;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_persist()),
    );
    _notify();
  }

  Future<void> refreshCapabilities() async {
    if (!current) return;
    final generation = ++_capabilityGeneration;
    try {
      final level = await repository.capabilities();
      if (!current || generation != _capabilityGeneration) return;
      capabilities = level;
      capabilityError = null;
    } catch (_) {
      if (!current || generation != _capabilityGeneration) return;
      capabilityError = 'Could not refresh your invitation level.';
    }
    _notify();
  }

  Future<void> refresh() {
    if (!current) return Future.value();
    final running = _refreshingFeed;
    if (running != null) return running;
    final operation = _refreshFeed();
    _refreshingFeed = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_refreshingFeed, operation)) _refreshingFeed = null;
      }),
    );
    return operation;
  }

  Future<void> _refreshFeed() async {
    if (!current) return;
    final generation = ++_feedGeneration;
    loading = true;
    loadingMore = false;
    error = null;
    pageError = null;
    _notify();
    try {
      final page = await repository.feed();
      if (!current || generation != _feedGeneration) return;
      _serverOffset = page.serverNow.toUtc().difference(DateTime.now().toUtc());
      requests = List.unmodifiable(page.requests);
      _cursor = page.nextCursor;
    } catch (failure) {
      if (!current || generation != _feedGeneration) return;
      if (failure is CommunityException &&
          const {
            'sign_in_required',
            'session_revoked',
            'membership_required',
            'community_forbidden',
          }.contains(failure.code)) {
        requests = const [];
        _cursor = null;
      }
      error = failure is CommunityException
          ? failure.toString()
          : const CommunityException('server_unavailable').toString();
    }
    if (!current || generation != _feedGeneration) return;
    loading = false;
    _notify();
  }

  Future<void> loadMore() async {
    if (!current || loading || loadingMore || _cursor == null) return;
    final generation = _feedGeneration;
    final cursor = _cursor;
    loadingMore = true;
    pageError = null;
    _notify();
    try {
      final page = await repository.feed(cursor: cursor);
      if (!current || generation != _feedGeneration) return;
      final unique = {for (final item in requests) item.id: item};
      for (final item in page.requests) {
        unique[item.id] = item;
      }
      requests = List.unmodifiable(unique.values);
      _cursor = page.nextCursor;
    } catch (failure) {
      if (!current || generation != _feedGeneration) return;
      pageError = failure is CommunityException
          ? failure.toString()
          : const CommunityException('server_unavailable').toString();
    }
    if (!current || generation != _feedGeneration) return;
    loadingMore = false;
    _notify();
  }

  Future<CommunityReceipt?> publish() async {
    if (!current || publishing || !_draftLoaded) return null;
    if (skill.trim().isEmpty ||
        skill.characters.length > 64 ||
        utf8.encode(skill).length > 32768 ||
        skill.contains('\u0000')) {
      publishError = const CommunityException('invalid_skill').toString();
      _notify();
      return null;
    }
    if (message.trim().isEmpty ||
        message.characters.length > 2000 ||
        utf8.encode(message).length > 65536 ||
        message.contains('\u0000')) {
      publishError = const CommunityException('invalid_message').toString();
      _notify();
      return null;
    }
    publishing = true;
    publishError = null;
    final newOperation = _operation == null;
    _operation ??= newChatOperationId();
    _notify();
    try {
      if (!await _persist()) {
        if (newOperation && current) _operation = null;
        return null;
      }
      if (!current) return null;
      _completed ??= await repository.create(_operation!, skill, message);
      if (!current) return null;
      if (!await _persist(clearPublish: true) || !current) return null;
      final receipt = _completed;
      _operation = null;
      _completed = null;
      skill = '';
      message = '';
      return receipt;
    } catch (failure) {
      if (current) {
        publishError = failure is CommunityException
            ? failure.toString()
            : const CommunityException('server_unavailable').toString();
      }
      return null;
    } finally {
      publishing = false;
      _notify();
    }
  }

  Future<bool> closeRequest(String requestId) async {
    if (!current || _closing.contains(requestId)) return false;
    _closing.add(requestId);
    _notify();
    try {
      final key = 'community.close.${repository.userId}.$requestId';
      if (!_closeOperations.containsKey(requestId)) {
        final stored = await _drafts.read(key);
        if (!current) return false;
        if (stored != null && !pushUuid.hasMatch(stored)) {
          throw const FormatException('Invalid close receipt');
        }
        _closeOperations[requestId] = stored ?? newChatOperationId();
      }
      await _drafts.write(key, _closeOperations[requestId]!);
      if (!current) return false;
      await repository.close(_closeOperations[requestId]!, requestId);
      if (!current) return false;
      // A feed/page started before the close acknowledgement cannot restore
      // the request the server has just removed.
      _feedGeneration++;
      _refreshingFeed = null;
      loading = false;
      loadingMore = false;
      requests = List.unmodifiable(
        requests.where((item) => item.id != requestId),
      );
      return true;
    } catch (failure) {
      if (current) {
        error = failure is CommunityException
            ? failure.toString()
            : const CommunityException('server_unavailable').toString();
      }
      return false;
    } finally {
      _closing.remove(requestId);
      _notify();
    }
  }

  Future<void> flushDraft() async {
    if (_draftLoaded && current && !publishing) await _persist();
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    if (_draftLoaded && current && !publishing) unawaited(_persist());
    _disposed = true;
    unawaited(_identity.cancel());
    super.dispose();
  }
}
