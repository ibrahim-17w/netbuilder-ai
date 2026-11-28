/// Which paragraph direction a message should be laid out in.
///
/// The app's chrome is English, so the app locale stays LTR; each message is
/// laid out in the direction of its own first strong character. That is the
/// Unicode bidi rule browsers and chat apps use, and it keeps an Arabic
/// sentence right-to-left while the IP addresses, CLI commands and file names
/// inside it stay left-to-right.
class BidiText {
  const BidiText._();

  /// True when the first strong character in [text] is right-to-left.
  ///
  /// Digits, punctuation, emoji and whitespace are neutral and are skipped:
  /// a message that is only an address or a path stays LTR. When the text has
  /// no strong character at all the answer is false (LTR), because that is
  /// the app's default paragraph direction.
  static bool isRtl(String text) {
    for (final rune in text.runes) {
      // Arabic-Indic digits are weak, not strong RTL. Without this exception a
      // message that is just "٢٠٢٦" would flip the whole paragraph.
      if ((rune >= 0x0660 && rune <= 0x0669) ||
          (rune >= 0x06f0 && rune <= 0x06f9)) {
        continue;
      }
      if (_isRtlRune(rune)) return true;
      if (_isLtrRune(rune)) return false;
    }
    return false;
  }

  static bool _isRtlRune(int rune) =>
      (rune >= 0x0590 && rune <= 0x05ff) || // Hebrew
      (rune >= 0x0600 && rune <= 0x06ff) || // Arabic
      (rune >= 0x0700 && rune <= 0x074f) || // Syriac
      (rune >= 0x0750 && rune <= 0x077f) || // Arabic Supplement
      (rune >= 0x08a0 && rune <= 0x08ff) || // Arabic Extended-A
      (rune >= 0xfb1d && rune <= 0xfdff) || // Hebrew/Arabic presentation A
      (rune >= 0xfe70 && rune <= 0xfeff); // Arabic presentation B

  static bool _isLtrRune(int rune) =>
      (rune >= 0x0041 && rune <= 0x005a) || // A-Z
      (rune >= 0x0061 && rune <= 0x007a) || // a-z
      (rune >= 0x00c0 && rune <= 0x02af) || // Latin-1 Supplement..IPA
      (rune >= 0x1e00 && rune <= 0x1eff); // Latin Extended Additional
}
