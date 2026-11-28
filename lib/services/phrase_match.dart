/// Phrase matching shared by the playbook and fact layers.
///
/// Plain phrases match on word boundaries so 'bgp' cannot match inside
/// another word and '16' cannot match inside '1600'. Phrases that contain
/// punctuation (***, 2-way, 802.1q) are matched literally, because a word
/// boundary does not exist there.
class PhraseMatch {
  const PhraseMatch._();

  static bool has(String text, String phrase) {
    if (phrase.isEmpty) return false;
    if (RegExp(r'[^a-z0-9\s]').hasMatch(phrase)) return text.contains(phrase);
    // A short phrase keeps an optional plural so "vlan" still matches "vlans"
    // and "switch" matches "switches". Phrases of three characters or fewer
    // stay exact, so "ip" never becomes "ips".
    final plural = phrase.length >= 4 ? '(?:s|es)?' : '';
    return RegExp(
      '(?:^|[^a-z0-9])${RegExp.escape(phrase)}$plural(?:[^a-z0-9]|\$)',
    ).hasMatch(text);
  }
}
