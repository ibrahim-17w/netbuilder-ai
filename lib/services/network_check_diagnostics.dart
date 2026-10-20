/// Evidence-guided prompts for failed verification checks.
///
/// These are hypotheses to inspect, never claims that a saved file proves a
/// live fault. Runtime-only facts such as ARP tables still need a Packet
/// Tracer check, and the chat may prepare a plan edit only after review.
class NetworkCheckDiagnostics {
  const NetworkCheckDiagnostics._();

  static List<String> likelyCauses(Map<String, dynamic> check) {
    final kind = '${check['kind'] ?? ''}'.trim().toLowerCase();
    final detail = '${check['detail'] ?? check['text'] ?? ''}'.toLowerCase();
    final combined = '$kind $detail';
    if (combined.contains('dns')) {
      return const [
        'Confirm the client has the intended DNS server address.',
        'Check that the DNS service is enabled and the requested record maps to the expected address.',
        'A successful ping alone does not prove a DNS lookup succeeded.',
      ];
    }
    if (combined.contains('dhcp') || combined.contains('lease')) {
      return const [
        'Check that the DHCP service has a pool for the client VLAN and that its address range excludes reserved addresses.',
        'Confirm the client VLAN can reach the server or its configured relay/helper address.',
        'Verify the lease on the client; saved pool settings do not prove a lease was issued.',
      ];
    }
    if (combined.contains('acl') || combined.contains('access-list')) {
      return const [
        'Check whether the interface applies the intended ACL in the correct direction.',
        'Compare the ACL rules with both an allowed and a denied test flow.',
        'The saved configuration cannot prove which rule matched a live packet.',
      ];
    }
    if (combined.contains('vlan') || combined.contains('trunk')) {
      return const [
        'Check the access VLAN on both the client port and its path to the gateway.',
        'Confirm trunk mode, allowed VLANs, and native VLAN settings match at both ends.',
        'A saved VLAN list does not prove that spanning tree or a live trunk is forwarding.',
      ];
    }
    if (combined.contains('route') || combined.contains('routing')) {
      return const [
        'Confirm the source and destination subnets are present in the routing table.',
        'Check the next hop, return route, and whether the routing protocol is advertising the intended networks.',
        'A one-way route can allow a request out while the reply has no path back.',
      ];
    }
    if (combined.contains('arp') || kind == 'gateway') {
      return const [
        'Check the endpoint IP address, mask, and default gateway against the gateway interface.',
        'Confirm the connected interfaces are up and the path uses the intended VLAN.',
        'If addressing matches, inspect live ARP resolution for duplicate addresses or an unanswered gateway MAC request.',
      ];
    }
    if (kind == 'service') {
      return const [
        'Separate basic IP reachability from the service itself: check the server role, listener, credentials, and client settings.',
        'Check routing and ACL rules between the client and service port.',
        'The failed check evidence should identify whether the request timed out, was refused, or reached the wrong host.',
      ];
    }
    return const [
      'Compare the expected source, destination, and result with the recorded check evidence.',
      'Check link state and addressing first, then VLAN/routing and service policy.',
      'If the evidence does not isolate a cause, ask for one targeted live check before editing the plan.',
    ];
  }

  static String promptContext(Map<String, dynamic> check) =>
      likelyCauses(check).map((item) => '- $item').join('\n');
}
