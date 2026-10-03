import 'package:net_builder/models/chat_message.dart';

/// What the user means when they talk about "the file" after a build.
///
/// The bug this exists to stop: "edit it" was read as a fresh build request,
/// so the app answered by generating a SECOND .pkt and leaving the first one
/// behind. A person who says "edit it" is pointing at a file that already
/// exists, and the only honest answer is either to change that file or to say
/// which of the two they want.
enum FileEditIntent {
  /// Nothing here is about the artifact (an ordinary new request, a question).
  none,

  /// Unambiguously "change the file I already have".
  editExisting,

  /// Unambiguously "give me a new one".
  createNew,

  /// Points at the existing file but does not say whether to keep it. The
  /// answer must offer the choice rather than pick one.
  ambiguous,
}

/// Reads the file intent out of one plain-English turn.
///
/// Deliberately a pure function over words: it decides before any model is
/// consulted, so the choice is offered identically online and offline, and a
/// model cannot talk the app into overwriting a file the user did not name.
class FileEditIntentReader {
  const FileEditIntentReader._();

  /// A pointer at the existing file: "it", "that", "the file", "the same
  /// project", "the one I just made".
  static final RegExp _pointsAtExisting = RegExp(
    r'\b(it|that|this|them|those)\b|'
    r'\bthe\s+(?:same\s+|existing\s+|current\s+|original\s+|newest\s+|last\s+)?'
    r'(?:file|project|lab|network|topology|pkt|save|artifact|one)\b|'
    r'\bthe\s+one\s+(?:i|we)\s+(?:just\s+)?(?:made|built|created|have)\b',
    caseSensitive: false,
  );

  /// An instruction to change something.
  static final RegExp _editVerb = RegExp(
    r'\b(edit|change|modify|update|adjust|tweak|fix|rename|extend|increase|'
    r'decrease|add|remove|delete|drop|insert|replace|swap|move|give\s+(?:it|'
    r'me)|set|make)\b',
    caseSensitive: false,
  );

  /// "a new file", "another copy", "a separate project" - a new-file word
  /// right next to a file noun. The adjective on its own means nothing:
  /// "add another switch" is a device, not a second .pkt.
  static final RegExp _newFileWords = RegExp(
    r'\b(?:new|fresh|separate|second|another|different|duplicate|renamed|'
    r'extra|spare)\s+(?:one|file|copy|project|version|lab|network|topology|'
    r'pkt|save|artifact)s?\b|\ba\s+new\s+(?:one|file|project|lab|network|'
    r'topology|pkt|save)\b|\binstead\s+of\s+(?:a\s+)?new\b',
    caseSensitive: false,
  );

  /// "the existing one", "the current file", "in place", "the one I just made".
  static final RegExp _sameFileWords = RegExp(
    r'\b(same|existing|current|already|in\s*place)\b|'
    r'\bthe\s+one\s+(?:i|we)\s+(?:just\s+)?(?:made|built|created)\b|'
    r'\bnot\s+a\s+new\b',
    caseSensitive: false,
  );

  /// "make a new one", "create another file", "a separate project".
  ///
  /// The file noun is REQUIRED: with it optional, "add another switch" matched
  /// and a device request was read as a request for a second file.
  static final RegExp _explicitNew = RegExp(
    r'\b(?:make|create|build|generate|give|start|save|write|open|do)?\s*'
    r'(?:me\s+)?(?:a\s+|an\s+|the\s+)?'
    r'(?:brand[\s-]?new|new|different|fresh|second|another|separate|extra|'
    r'spare|duplicate|renamed)\s+'
    r'(?:one|file|copy|project|version|lab|network|topology|pkt|save|'
    r'artifact)s?\b',
    caseSensitive: false,
  );

  /// What the turn is about, if anything.
  ///
  /// [hasArtifact] is false when no .pkt has been produced yet, and then there
  /// is nothing to edit: the answer is a build, not a choice.
  ///
  /// [candidates] is how many files this conversation could be pointing at.
  /// With one file there is nothing to disambiguate: "edit the file and make
  /// one server an AAA server" names the file and says what to do to it, so it
  /// IS the edit - asking "edit it or start a new file?" after the user said
  /// "edit the file" reads like the app did not listen. The choice is offered
  /// only when the target is genuinely ambiguous: several files, none named.
  static FileEditIntent read(
    String text, {
    required bool hasArtifact,
    int candidates = 1,
  }) {
    final t = text.trim().toLowerCase();
    if (t.isEmpty || !hasArtifact) return FileEditIntent.none;

    if (_explicitNew.hasMatch(t)) return FileEditIntent.createNew;

    // A brand-new device count in a fresh lab ("make a 2-router lab") is a new
    // request that happens to contain a verb; only a pointer makes it an edit.
    if (!_pointsAtExisting.hasMatch(t)) return FileEditIntent.none;

    if (_sameFileWords.hasMatch(t)) return FileEditIntent.editExisting;
    if (_newFileWords.hasMatch(t)) return FileEditIntent.createNew;

    if (_editVerb.hasMatch(t)) {
      return candidates > 1
          ? FileEditIntent.ambiguous
          : FileEditIntent.editExisting;
    }
    // A pointer with nothing to do to it ("what about that file?") is a
    // question about the file, not an instruction.
    return FileEditIntent.ambiguous;
  }

  /// The two choices offered for [FileEditIntent.ambiguous], as quick replies.
  static List<String> choiceReplies(String artifactName) => [
        'Edit $artifactName',
        'Create a new file instead',
      ];

  /// The first pointer at the existing artifact ("it", "that file", "the
  /// same project") with its position in [text], or null. The
  /// message-understanding card uses it to show which words referred to a
  /// file; offsets let a future UI highlight them.
  static ({String excerpt, int offset})? referenceIn(String text) {
    final m = _pointsAtExisting.firstMatch(text.toLowerCase());
    if (m == null) return null;
    return (excerpt: text.substring(m.start, m.end), offset: m.start);
  }

  /// The card actions for [FileEditIntent.ambiguous].
  ///
  /// The user chooses; the app never quietly picks. "Edit" carries the path so
  /// the executor writes over that exact file (with a backup), and "new" is the
  /// ordinary timestamped build.
  static List<ChatAction> choiceActions({
    required String path,
    required String name,
    int devices = 0,
    int links = 0,
    String revision = '',
    String project = '',
    int blocking = 0,
  }) => [
        ChatAction(
          kind: 'pkt_edit',
          summary: 'Edit $name in place (a timestamped backup is kept first)',
          payload: <String, dynamic>{
            'path': path,
            'name': name,
            'mode': 'in-place',
            if (devices > 0) 'devices': devices,
            if (links > 0) 'links': links,
            // The plan version this choice was written against, so the edit
            // cannot be run against a plan the user never saw.
            if (revision.isNotEmpty) 'revision': revision,
          },
        ),
        ChatAction(
          kind: 'pkt_generate',
          summary: 'Create a new .pkt from the same plan instead',
          payload: <String, dynamic>{
            'mode': 'new',
            if (revision.isNotEmpty) 'revision': revision,
            if (project.isNotEmpty) 'project': project,
            'devices': devices,
            'links': links,
            'blocking': blocking,
          },
        ),
      ];

  /// The answer when the user points at a file the app can see but cannot
  /// re-create.
  ///
  /// The words of one edit are not a network: "edit it and make one server an
  /// AAA server" parses to a single server, and rewriting the file from that
  /// would replace a whole lab with the one piece the user mentioned. With no
  /// plan saved for the file there is nothing to apply the change to, so the
  /// app says which file it means and stops.
  static String noPlanText(String name) =>
      'I can see `$name`, but not the plan it was built from - this '
      'conversation has no saved plan for that file (it may predate plan '
      'memory, or the plan was cleared).\n\n'
      'I will not rewrite a file from the words of one edit: that would '
      'replace the whole lab with just the piece you mentioned. Tell me the '
      'network again and I will rebuild it, or open the file from the Packet '
      'Tracer files screen to inspect what is in it now.';

  /// The answer text for [FileEditIntent.ambiguous], in the app's own voice.
  static String choiceText(
    String name, {
    int devices = 0,
    int links = 0,
    String writtenAt = '',
  }) {
    final shape = devices > 0
        ? ' The plan on the table has $devices device(s)'
              '${links > 0 ? ' and $links link(s)' : ''}.'
        : '';
    final when = writtenAt.isEmpty ? '' : ' (written $writtenAt)';
    return 'I have `$name`$when already, so I am not going to quietly build a '
        'second file and leave the first one behind.$shape\n\n'
        'Do you want me to **edit that file** (a timestamped backup is kept '
        'first), or **create a new .pkt** from the same plan?';
  }
}
