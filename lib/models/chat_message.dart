import 'dart:convert';

/// One attachment on a chat message.
///
/// Images live on disk (see [ChatService.persistImage]) and only the path is
/// stored in the database. Keeping multi-megabyte PNGs out of SQLite keeps
/// the memory DB small enough that the rest of the app stays fast, and the
/// path is what gets read back to build a Gemini `inlineData` part.
class ChatImage {
  final String path;
  final String name;
  final String mimeType;
  final int bytes;

  const ChatImage({
    required this.path,
    required this.name,
    this.mimeType = 'image/png',
    this.bytes = 0,
  });

  Map<String, dynamic> toMap() => {
    'path': path,
    'name': name,
    'mimeType': mimeType,
    'bytes': bytes,
  };

  factory ChatImage.fromMap(Map<String, dynamic> m) => ChatImage(
    path: (m['path'] ?? '').toString(),
    name: (m['name'] ?? 'image').toString(),
    mimeType: (m['mimeType'] ?? 'image/png').toString(),
    bytes: (m['bytes'] as num?)?.toInt() ?? 0,
  );

  String get sizeLabel => bytes <= 0
      ? ''
      : bytes < 1024
      ? '${bytes}B'
      : '${(bytes / 1024).round()}KB';
}

/// A concrete, approvable thing the assistant proposed doing.
///
/// The model never executes anything. It returns these, the UI renders each
/// as a card with its own approve button, and only a click runs it - the same
/// gate [AnalyzeScreen] puts in front of suggested fixes. That keeps a bad
/// model answer from ever changing a device on its own.
class ChatAction {
  final String kind;
  final Map<String, dynamic> payload;
  final String summary;

  const ChatAction({
    required this.kind,
    required this.payload,
    this.summary = '',
  });

  static const supported = {
    'save_rule',
    'save_preference',
    'paste_cli',
    'config_pcs',
    'run_control',
    'open_project',
    // Offline capture work: no Packet Tracer, no window, no clicks.
    'pkt_scan',
    'pkt_fix',
    'pkt_undo',
    'pkt_generate',
    'ledger',
  };

  Map<String, dynamic> toMap() => {
    'kind': kind,
    'payload': payload,
    'summary': summary,
  };

  factory ChatAction.fromMap(Map<String, dynamic> m) => ChatAction(
    kind: (m['kind'] ?? '').toString(),
    payload: Map<String, dynamic>.from((m['payload'] as Map?) ?? const {}),
    summary: (m['summary'] ?? '').toString(),
  );

  /// Parse the model's `actions` array, dropping anything unsupported.
  ///
  /// Dropping is the safe direction: an unknown kind is a model invention,
  /// and silently ignoring it is better than inventing an executor for it.
  static List<ChatAction> parseList(dynamic raw) {
    if (raw is! List) return const [];
    final out = <ChatAction>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final kind = (entry['kind'] ?? '').toString().trim();
      if (!supported.contains(kind)) continue;
      final payload = <String, dynamic>{};
      entry.forEach((k, v) {
        if (k == 'kind' || k == 'summary') return;
        payload[k.toString()] = v;
      });
      out.add(
        ChatAction(
          kind: kind,
          payload: payload,
          summary: (entry['summary'] ?? '').toString(),
        ),
      );
    }
    return out;
  }

  String get label {
    if (summary.isNotEmpty) return summary;
    switch (kind) {
      case 'save_rule':
        return 'Save a rule: ${payload['rule'] ?? ''}';
      case 'save_preference':
        return 'Remember ${payload['key'] ?? '?'} = ${payload['value'] ?? ''}';
      case 'paste_cli':
        final configs = (payload['configs'] as Map?) ?? const {};
        return 'Type CLI on ${configs.length} device(s): '
            '${configs.keys.join(', ')}';
      case 'config_pcs':
        final pcs = (payload['pcs'] as Map?) ?? const {};
        return 'Set desktop IPs on ${pcs.length} PC(s): ${pcs.keys.join(', ')}';
      case 'run_control':
        return '${(payload['command'] ?? 'pause').toString().toUpperCase()} '
            'the autopilot';
      case 'open_project':
        return 'Open project ${payload['project'] ?? ''}';
    }
    return kind;
  }

  /// True when approving this changes something outside the app's memory.
  bool get touchesPacketTracer =>
      kind == 'paste_cli' || kind == 'config_pcs' || kind == 'run_control';
}

/// One turn of the conversation, including any attachments and proposals.
class ChatMessage {
  final int? id;
  final String role; // 'user' | 'model' | 'system'
  final String text;
  final List<ChatImage> images;
  final List<ChatAction> actions;
  final List<String> executed;
  final String createdAt;

  const ChatMessage({
    this.id,
    required this.role,
    required this.text,
    this.images = const [],
    this.actions = const [],
    this.executed = const [],
    this.createdAt = '',
  });

  bool get isUser => role == 'user';
  bool get isError => role == 'system';

  Map<String, dynamic> toMap() => {
    if (id != null) 'id': id,
    'role': role,
    'text': text,
    'imagesJson': jsonEncode(images.map((i) => i.toMap()).toList()),
    'actionsJson': jsonEncode(actions.map((a) => a.toMap()).toList()),
    'executedJson': jsonEncode(executed),
    'createdAt': createdAt,
  };

  factory ChatMessage.fromMap(Map<String, dynamic> m) {
    List<ChatImage> images = const [];
    try {
      final raw = jsonDecode((m['imagesJson'] ?? '[]').toString());
      if (raw is List) {
        images = raw
            .whereType<Map>()
            .map((e) => ChatImage.fromMap(Map<String, dynamic>.from(e)))
            .where((i) => i.path.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    List<ChatAction> actions = const [];
    try {
      final raw = jsonDecode((m['actionsJson'] ?? '[]').toString());
      actions = ChatAction.parseList(raw);
    } catch (_) {}
    List<String> executed = const [];
    try {
      final raw = jsonDecode((m['executedJson'] ?? '[]').toString());
      if (raw is List) executed = raw.map((e) => e.toString()).toList();
    } catch (_) {}
    return ChatMessage(
      id: (m['id'] as num?)?.toInt(),
      role: (m['role'] ?? 'user').toString(),
      text: (m['text'] ?? '').toString(),
      images: images,
      actions: actions,
      executed: executed,
      createdAt: (m['createdAt'] ?? '').toString(),
    );
  }

  ChatMessage copyWith({
    String? text,
    List<ChatImage>? images,
    List<ChatAction>? actions,
    List<String>? executed,
  }) => ChatMessage(
    id: id,
    role: role,
    text: text ?? this.text,
    images: images ?? this.images,
    actions: actions ?? this.actions,
    executed: executed ?? this.executed,
    createdAt: createdAt,
  );

  /// The turn as the Gemini API expects it, newest last.
  ///
  /// Only text goes here: attachments are attached separately as
  /// `inlineData` parts on the current user turn, because replaying every
  /// historical screenshot would blow the request size for no benefit.
  Map<String, dynamic> toGeminiTurn() => {
    'role': isUser ? 'user' : 'model',
    'parts': [
      {'text': text.isEmpty ? '(no text)' : text},
    ],
  };
}
