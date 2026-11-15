import '../../push/push_browser_types.dart';

class NativePushEnvelope {
  const NativePushEnvelope(this.click, this.kind);
  final PushClick click;
  final String kind;
  static NativePushEnvelope? parse(Map<String, dynamic> data) {
    final version = data['version'];
    final kind = data['kind'];
    if ((version != 1 && version != '1') ||
        (kind != 'message_created' && kind != 'community_created')) {
      return null;
    }
    final click = PushClick.parse({...data, 'version': 1});
    return click == null ? null : NativePushEnvelope(click, kind as String);
  }

  Map<String, dynamic> toData() => {
    'version': '1',
    'kind': kind,
    'delivery_id': click.deliveryId,
    'binding_id': click.bindingId,
    'recipient_user_id': click.recipientId,
  };
}
