import '../models/environment_profile.dart';

/// Reads the environment facts a message states out loud - "this is for the
/// office", "40 users", "I'm a beginner" - as an [EnvironmentProfile] holding
/// only what that sentence said.
///
/// The venue, scale and budget word lists mirror the advisor's own reader
/// (`_AdvisorContext` in advisor_service.dart) on purpose: the advisor still
/// trusts the message over the profile, and the two readers must agree on
/// what a stated fact is, or a fact the profile remembers is one the advisor
/// would have derived - and then the merge looks like it "changed" answers.
/// Change one, change both.
class EnvironmentProfileService {
  const EnvironmentProfileService._();

  static final RegExp _budget = RegExp(
    r'\b(?:cheap|cheapest|budget|affordable|low[- ]cost|inexpensive|'
    r'tight budget|small budget|low budget|free)\b',
  );

  static final RegExp _homeWords = RegExp(
    r'\b(?:home|house|apartment|flat|villa|family|bedroom|residential)\b',
  );
  static final RegExp _schoolWords = RegExp(
    r'\b(?:school|university|college|campus|classroom|students)\b',
  );
  static final RegExp _clinicWords = RegExp(
    r'\b(?:clinic|hospital|medical|pharmacy|patients)\b',
  );
  static final RegExp _hospitalityWords = RegExp(
    r'\b(?:cafe|café|restaurant|hotel|shop|store|salon|customers|guests)\b',
  );
  static final RegExp _industrialWords = RegExp(
    r'\b(?:warehouse|factory|industrial|production|workshop)\b',
  );
  static final RegExp _officeWords = RegExp(
    r'\b(?:office|business|company|branches?|startup|employees|staff|'
    r'workstations?)\b',
  );

  static final RegExp _scalePattern = RegExp(
    r'\b(\d{1,4})\s*[- ]?\s*(?:active\s+)?(?:users?|employees?|people|staff|'
    r'students?|patients?|clients?|guests?|customers?|pcs?|computers?|'
    r'devices?|seats?|workstations?|endpoints?|rooms?|floors?|sites?)\b',
  );

  /// Skill is the one fact the advisor never derived from a message, so
  /// these lists are the single definition.
  static final RegExp _beginnerWords = RegExp(
    r"\b(?:beginner|beginners|newbie|new to networking|just starting|"
    r"first lab|student|learning networking|no experience)\b",
  );
  static final RegExp _advancedWords = RegExp(
    r'\b(?:advanced|experienced|professional|network engineer|ccnp|ccie|'
    r'years of experience)\b',
  );

  /// What [text] states about the environment, with unstated fields left at
  /// their "unknown" value. Never throws.
  static EnvironmentProfile statedIn(String text) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty) return const EnvironmentProfile();
    return EnvironmentProfile(
      venue: _venueOf(t),
      scale: _scaleOf(t),
      budget: _budget.hasMatch(t) ? true : null,
      skill: _skillOf(t),
    );
  }

  static String _venueOf(String t) {
    if (_schoolWords.hasMatch(t)) return 'school';
    if (_clinicWords.hasMatch(t)) return 'clinic';
    if (_hospitalityWords.hasMatch(t)) return 'hospitality';
    if (_industrialWords.hasMatch(t)) return 'industrial';
    if (_officeWords.hasMatch(t)) return 'office';
    if (_homeWords.hasMatch(t)) return 'home';
    return '';
  }

  static int _scaleOf(String t) {
    final m = _scalePattern.firstMatch(t);
    if (m == null) return 0;
    final n = int.tryParse(m.group(1)!);
    if (n == null || n <= 0 || n > 5000) return 0;
    return n;
  }

  static String _skillOf(String t) {
    // Advanced before beginner, so "no longer a beginner, I am an
    // experienced engineer" does not read as its negated word.
    if (_advancedWords.hasMatch(t)) return 'advanced';
    if (_beginnerWords.hasMatch(t)) return 'beginner';
    return '';
  }

  /// The chat's auto-learn step, in one testable place: fold what [text]
  /// states into [current], stamp the message as the source, and return
  /// null when the text states nothing new (so the caller can stay quiet -
  /// re-stating a known fact is not a notification).
  static EnvironmentProfile? learnFrom(
    String text,
    EnvironmentProfile? current,
  ) {
    final stated = statedIn(text);
    if (stated.isEmpty) return null;
    final merged = (current ?? const EnvironmentProfile()).merge(
      EnvironmentProfile(
        venue: stated.venue,
        scale: stated.scale,
        budget: stated.budget,
        skill: stated.skill,
        source: text.trim(),
      ),
    );
    if (current != null && merged.sameFactsAs(current)) return null;
    return merged;
  }
}
