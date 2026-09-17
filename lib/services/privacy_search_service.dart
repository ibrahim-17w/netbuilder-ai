// Privacy-safe redaction + generic query builder for the
// "[Search Web For Fix]" button. Fully offline, unit-testable.
//
// Guarantee: never send full configs. Only a short generic query
// after user preview + Approve.
class PrivacySearchService {
  /// Replace secrets with placeholders.
  static String redact(String raw) {
    var s = raw;
    // passwords / secrets
    s = s.replaceAll(
      RegExp(r'(password|secret|passwd)\s+\S+', caseSensitive: false),
      r'$1 <REDACTED>',
    );
    s = s.replaceAll(
      RegExp(r'enable\s+secret\s+\S+', caseSensitive: false),
      'enable secret <REDACTED>',
    );
    // crude private/public IPv4 -> keep structure but anonymize host part
    s = s.replaceAllMapped(
      RegExp(r'\b(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(/\d{1,2})?'),
      (m) => '${m.group(1)}.${m.group(2)}.${m.group(3)}.x${m.group(5) ?? ''}',
    );
    // hostnames after `hostname`
    s = s.replaceAllMapped(
      RegExp(r'^hostname\s+\S+', multiLine: true),
      (_) => 'hostname <REDACTED>',
    );
    return s;
  }

  /// Build a short generic web query from an error + target.
  /// Example: "cisco ios ospf authentication mismatch fix"
  static String buildQuery({
    required String errorText,
    required String target,
    String? vendorHint,
  }) {
    final lower = errorText.toLowerCase();
    final keys = <String>[];
    if (vendorHint != null && vendorHint.isNotEmpty) keys.add(vendorHint);
    if (target.contains('cisco') ||
        target.contains('packet') ||
        target.contains('gns3')) {
      keys.add('cisco ios');
    } else if (target.contains('aws')) {
      keys.add('aws vpc');
    } else if (target.contains('mikrotik')) {
      keys.add('mikrotik routeros');
    }
    for (final k in [
      'ospf',
      'eigrp',
      'bgp',
      'vlan',
      'nat',
      'acl',
      'dhcp',
      'dns',
      'vpn',
      'overlap',
      'authentication',
      'mismatch',
      '%',
    ]) {
      if (lower.contains(k) && !keys.contains(k)) keys.add(k);
    }
    // keep first meaningful words (max 10)
    final words = lower
        .replaceAll(RegExp(r'[^a-z0-9 %/._-]'), ' ')
        .split(RegExp(r'\s+'))
        .where(
          (w) => w.length > 2 && !w.startsWith('192') && !w.startsWith('10.'),
        )
        .take(10);
    final q = [...keys, ...words].join(' ').trim();
    final base = q.isEmpty ? 'network configuration fix' : q;
    return '$base fix'.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// What EXACTLY would be sent. UI must show this before Approve.
  static String previewPayload(String query) =>
      'Web search query (only this text leaves the device):\n"$query"';
}
