/// One capability of the app, expressed the way the user invokes it.
///
/// A skill is either a **slash command** the chat handles on its own
/// (`/build`, `/scan`) or a **sentence** the offline readers understand
/// ("what router should I use in this case?"). Both are real, tested
/// paths - the catalog never promises something the app cannot do.
class Skill {
  /// The slash token this skill answers to (`/build`). Empty for skills
  /// that are sentences rather than commands.
  final String command;

  final String title;
  final String detail;
  final String category;

  /// What goes into the composer when the skill is tapped.
  final String send;

  /// A complete, argument-free command is sent immediately on tap;
  /// everything else is inserted so the user can edit it first.
  final bool sendNow;

  const Skill({
    required this.command,
    required this.title,
    required this.detail,
    required this.category,
    required this.send,
    this.sendNow = false,
  });
}

/// The catalog behind the "/" menu in the composer and `/skills` in chat.
class SkillCatalog {
  static const List<Skill> all = [
    // --- Packet Tracer: read -------------------------------------------------
    Skill(
      command: '/scan ',
      title: 'Read a .pkt',
      detail: 'Decrypt and audit a Packet Tracer save offline - no '
          'Packet Tracer needed.',
      category: 'Packet Tracer: read',
      send: '/scan ',
    ),
    Skill(
      command: '',
      title: 'Audit and fix a .pkt',
      detail: 'Propose repairs for the capture on the table; each fix is '
          'approved before anything changes.',
      category: 'Packet Tracer: read',
      send: 'fix the plan',
    ),
    // --- Packet Tracer: write ------------------------------------------------
    Skill(
      command: '/build',
      title: 'Write a .pkt',
      detail: 'Compile the current plan into a real, openable .pkt file - '
          'offline, with or without a key.',
      category: 'Packet Tracer: write',
      send: '/build',
      sendNow: true,
    ),
    Skill(
      command: '',
      title: 'Edit the .pkt',
      detail: 'Change a file this conversation built; a backup is kept '
          'before anything is rewritten.',
      category: 'Packet Tracer: write',
      send: 'edit the file and ',
    ),
    Skill(
      command: '',
      title: 'Undo the last change',
      detail: 'Revert the last repair from the exact change log.',
      category: 'Packet Tracer: write',
      send: 'undo that',
    ),
    Skill(
      command: '',
      title: 'Show the drawing',
      detail: 'See the layout the plan would be built with, before it is '
          'built.',
      category: 'Packet Tracer: write',
      send: 'show the drawing',
    ),
    // --- Targets -------------------------------------------------------------
    Skill(
      command: '/target gns3',
      title: 'Build for GNS3',
      detail: 'Switch the build target to GNS3 (the default).',
      category: 'Targets: GNS3, real gear, AWS',
      send: '/target gns3',
      sendNow: true,
    ),
    Skill(
      command: '/target packet-tracer',
      title: 'Drive the real Packet Tracer',
      detail: 'Target the Packet Tracer window the autopilot clicks and '
          'verifies.',
      category: 'Targets: GNS3, real gear, AWS',
      send: '/target packet-tracer',
      sendNow: true,
    ),
    Skill(
      command: '/target cisco-ssh',
      title: 'Real Cisco gear over SSH',
      detail: 'Target a real switch or router over SSH instead of a '
          'simulator.',
      category: 'Targets: GNS3, real gear, AWS',
      send: '/target cisco-ssh',
      sendNow: true,
    ),
    Skill(
      command: '/target aws-vpc',
      title: 'AWS VPC',
      detail: 'Target an AWS VPC design.',
      category: 'Targets: GNS3, real gear, AWS',
      send: '/target aws-vpc',
      sendNow: true,
    ),
    // --- Design advice -------------------------------------------------------
    Skill(
      command: '',
      title: 'Which router / firewall should I use?',
      detail: 'An offline recommendation with options, trade-offs and '
          'reasons grounded in your numbers.',
      category: 'Design advice',
      send: 'what router should I use in this case?',
    ),
    Skill(
      command: '',
      title: 'Review my design',
      detail: 'A layered review of the plan on the table: edge, '
          'addressing, services, security, wireless.',
      category: 'Design advice',
      send: 'review my design for a small office',
    ),
    Skill(
      command: '',
      title: 'Segment this plan into VLANs',
      detail: 'Whether the lab needs VLANs, and how to split it.',
      category: 'Design advice',
      send: 'should this plan be segmented into VLANs?',
    ),
    // --- Addressing ----------------------------------------------------------
    Skill(
      command: '',
      title: 'Subnet facts',
      detail: 'Broadcast, hosts, wildcard and network of any prefix - '
          'computed, not recited.',
      category: 'Addressing',
      send: 'how many hosts does a /26 subnet support?',
    ),
    Skill(
      command: '',
      title: 'Summarise an address plan',
      detail: 'Route summarisation for a set of subnets.',
      category: 'Addressing',
      send: 'summarise 10.0.1.0/24, 10.0.2.0/24 and 10.0.3.0/24',
    ),
    // --- Troubleshooting -----------------------------------------------------
    Skill(
      command: '',
      title: 'Something is slow',
      detail: 'The wire-out triage ladder: prove, place, tune, then buy.',
      category: 'Troubleshooting',
      send: 'my network is slow, what should I check first?',
    ),
    Skill(
      command: '',
      title: 'No internet on a VLAN',
      detail: 'Work down the gateway / DHCP / NAT ladder.',
      category: 'Troubleshooting',
      send: 'a device on the guest VLAN has no internet, what do I check?',
    ),
    // --- Learn ---------------------------------------------------------------
    Skill(
      command: '',
      title: 'Explain a concept',
      detail: 'VLANs, OSPF, DHCP, ACLs, STP and the rest of the corpus, '
          'answered offline.',
      category: 'Learn',
      send: 'explain what a VLAN is',
    ),
    // --- App -----------------------------------------------------------------
    Skill(
      command: '/skills',
      title: 'List every skill',
      detail: 'The same catalog, as a list in the chat.',
      category: 'App',
      send: '/skills',
      sendNow: true,
    ),
    Skill(
      command: '/help',
      title: 'Help',
      detail: 'What you can do right here.',
      category: 'App',
      send: '/help',
      sendNow: true,
    ),
    Skill(
      command: '/ledger',
      title: 'The ledger',
      detail: 'Every capture, decision, change and export on record.',
      category: 'App',
      send: '/ledger',
      sendNow: true,
    ),
    Skill(
      command: '/models',
      title: 'Detect available models',
      detail: 'Ask the key which models it can use, and pick the '
          'recommendation.',
      category: 'App',
      send: '/models',
      sendNow: true,
    ),
    Skill(
      command: '/key ',
      title: 'Store the Gemini key',
      detail: 'Save a key without echoing it.',
      category: 'App',
      send: '/key ',
    ),
    Skill(
      command: '/budget ',
      title: 'Set the context budget',
      detail: 'Tokens the model may see per turn (8k..1M).',
      category: 'App',
      send: '/budget ',
    ),
    Skill(
      command: '/pc ',
      title: 'Point at a sidecar',
      detail: 'Where the .pkt engine runs, for phones or another machine.',
      category: 'App',
      send: '/pc ',
    ),
  ];

  /// The skills matching what is typed in the composer.
  ///
  /// Only the first token matters: a "/" (or a partial command like "/bu")
  /// opens the menu, while a space means an argument has started, so the
  /// menu steps aside. [typed] must therefore not contain a newline.
  static List<Skill> match(String typed) {
    if (typed.contains('\n')) return const [];
    final s = typed.trimLeft();
    if (!s.startsWith('/')) return const [];
    if (s.contains(' ')) return const [];
    final token = s.toLowerCase();
    if (token == '/') return all;
    return [
      for (final skill in all)
        if (skill.command.isNotEmpty &&
            skill.command.trim().toLowerCase().startsWith(token))
          skill,
    ];
  }

  /// The catalog as a markdown list, for the `/skills` command.
  static String asMarkdown() {
    final sb = StringBuffer(
      '**What this app can do.** Type `/` in the box to open the menu, '
      'or tap one of these:\n',
    );
    String? category;
    for (final skill in all) {
      if (skill.category != category) {
        category = skill.category;
        sb.writeln('\n**$category**');
      }
      final head = skill.command.trim();
      sb.writeln(
        head.isEmpty
            ? '- **${skill.title}** - ${skill.detail}'
            : '- `$head` - **${skill.title}** - ${skill.detail}',
      );
    }
    return sb.toString().trim();
  }
}
