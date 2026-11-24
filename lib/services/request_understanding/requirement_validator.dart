import '../../models/request_interpretation.dart';
import '../../models/request_requirement.dart';
import 'requirement_merger.dart';

/// Pure request validation: no plan mutation, address repair, or inferred
/// inventory. All issues retain the exact requirements and source evidence.
class RequirementValidator {
  const RequirementValidator();

  /// Accepts active requirements (the coordinator's normal path), or raw
  /// requirements in tests/importers. Precedence and corrections are respected.
  List<RequestIssue> validate(Iterable<Requirement> requirements) {
    final merged = RequirementMerger.merge(requirements);
    final active = merged.active;
    final issues = <RequestIssue>[];
    for (final conflict in merged.conflicts) {
      issues.add(
        _issue(
          RequestIssueKind.conflict,
          'incompatible_requirements',
          conflict.reason,
          merged.requirements.where(
            (r) => conflict.requirementIds.contains(r.id),
          ),
        ),
      );
    }
    _validateCounts(active, issues);
    _validateAddresses(active, issues);
    for (final r in active) {
      if (r.comparator != RequirementComparator.equals) continue;
      if (const {
        'unsupported',
        'unsupported_policy',
        'isolation_policy',
        'advanced_config',
        'advanced_configuration',
        'unsupported_service_configuration',
      }.contains(_property(r))) {
        issues.add(
          _issue(
            RequestIssueKind.unsupported,
            'unsupported_requirement',
            'The requested ${_property(r).replaceAll('_', ' ')} needs support '
                'that the deterministic request validator cannot establish.',
            [r],
          ),
        );
      }
      if (_property(r) == 'ospf_area' &&
          (r.value is! int ||
              (r.value as int) < 0 ||
              (r.value as int) > 0xffffffff)) {
        issues.add(
          _issue(
            RequestIssueKind.invalid,
            'invalid_ospf_area',
            'An OSPF area must be an integer from 0 to 4294967295.',
            [r],
          ),
        );
      }
    }
    issues.sort((a, b) => a.id.compareTo(b.id));
    return List.unmodifiable(issues);
  }

  void _validateCounts(List<Requirement> active, List<RequestIssue> issues) {
    final counts = active
        .where(
          (r) =>
              const {
                'device_count',
                'role_device_count',
              }.contains(_property(r)) &&
              r.comparator == RequirementComparator.equals &&
              r.quantityRole != QuantityRole.increment,
        )
        .toList();
    final valid = <Requirement>[];
    for (final r in counts) {
      if (r.value is! int || (r.value as int) < 0) {
        issues.add(
          _issue(
            RequestIssueKind.invalid,
            'invalid_device_count',
            'An exact device count must be a non-negative integer.',
            [r],
          ),
        );
      } else {
        valid.add(r);
      }
    }
    final totals = valid.where(
      (r) =>
          r.scope.kind == RequirementScopeKind.project &&
          _site(r.scope).isEmpty &&
          _property(r) == 'device_count' &&
          const {
            'total',
            'deviceInventory',
            'unspecified',
          }.contains(r.quantityRole.name),
    );
    for (final total in totals) {
      final kind = _kind(total.subject);
      final inventory = active
          .where(
            (r) =>
                _sameProject(r.scope, total.scope) &&
                const {
                  'allocation_sites',
                  'site_inventory',
                }.contains(_property(r)),
          )
          .toList();
      final knownSites = <String>{};
      final completeSites = <String>{};
      for (final r in inventory) {
        final value = r.value;
        if (value is Map) {
          final sites = _strings(value['sites']);
          knownSites.addAll(sites);
          if (value['complete'] == true) {
            completeSites.addAll(sites);
          } else {
            completeSites.addAll(_strings(value['complete']));
          }
        } else {
          knownSites.addAll(_strings(value));
        }
      }
      final allocations = valid
          .where(
            (r) =>
                _sameProject(r.scope, total.scope) &&
                _site(r.scope).isNotEmpty &&
                (kind == 'device' || _kind(r.subject) == kind),
          )
          .toList();
      if (allocations.isEmpty && inventory.isEmpty) continue;
      knownSites.addAll(allocations.map((r) => _site(r.scope)));
      final bySite = <String, List<Requirement>>{};
      for (final r in allocations) {
        bySite.putIfAbsent(_site(r.scope), () => []).add(r);
      }
      var allocated = 0;
      var allKnown = inventory.isNotEmpty && knownSites.isNotEmpty;
      final evidence = <Requirement>[total, ...inventory];
      for (final site in knownSites) {
        final atSite = bySite[site] ?? const <Requirement>[];
        final ordinary = atSite
            .where((r) => _property(r) == 'device_count')
            .toList();
        final roles = atSite
            .where((r) => _property(r) == 'role_device_count')
            .toList();
        evidence.addAll(atSite);
        if (kind != 'device') {
          // Role counts are a lower bound, not additional physical devices
          // when an ordinary site inventory already counts those servers.
          final hasCount = ordinary.isNotEmpty;
          allocated += hasCount ? _sum(ordinary) : _roleLowerBound(roles);
          if (!hasCount &&
              (!completeSites.contains(site) || roles.isNotEmpty)) {
            allKnown = false;
          }
        } else {
          // An aggregate total can be checked against all typed inventory.
          // Explicit site-wide totals cover, rather than add to, typed counts.
          final aggregate = ordinary
              .where((r) => _kind(r.subject) == 'device')
              .toList();
          if (aggregate.isNotEmpty) {
            allocated += _sum(aggregate);
          } else {
            allocated += _sum(ordinary);
            for (final roleKind in roles.map((r) => _kind(r.subject)).toSet()) {
              if (!ordinary.any((r) => _kind(r.subject) == roleKind)) {
                allocated += _roleLowerBound(
                  roles.where((r) => _kind(r.subject) == roleKind),
                );
              }
            }
            if (!completeSites.contains(site)) allKnown = false;
          }
        }
      }
      final requested = total.value as int;
      if (allocated > requested || (allocated < requested && allKnown)) {
        issues.add(
          _issue(
            RequestIssueKind.conflict,
            'allocation_total_mismatch',
            'The ${kind == 'device' ? 'device' : kind} allocations total '
                '$allocated, but the exact project total is $requested.',
            evidence,
          ),
        );
      } else if (allocated < requested) {
        issues.add(
          _issue(
            RequestIssueKind.missingInput,
            'incomplete_allocations',
            'Known $kind allocations account for $allocated of $requested. '
                'Complete the site inventory before treating the remainder as a '
                'contradiction.',
            evidence,
          ),
        );
      }
    }
    // Typed service roles constrain a site's server inventory; they are not
    // competing scalar counts and are not added to that site's server total.
    final siteTotals = valid.where(
      (r) => _site(r.scope).isNotEmpty && _property(r) == 'device_count',
    );
    for (final total in siteTotals) {
      final roles = valid
          .where(
            (r) =>
                _property(r) == 'role_device_count' &&
                _project(r.scope) == _project(total.scope) &&
                _site(r.scope) == _site(total.scope) &&
                _kind(r.subject) == _kind(total.subject),
          )
          .toList();
      if (roles.any((r) => (r.value as int) > (total.value as int))) {
        issues.add(
          _issue(
            RequestIssueKind.conflict,
            'role_allocation_exceeds_total',
            'A typed role allocation exceeds the ${total.subject} inventory '
                'at ${_site(total.scope)}.',
            [total, ...roles],
          ),
        );
      }
    }
  }

  void _validateAddresses(List<Requirement> active, List<RequestIssue> issues) {
    final assigned = <_SubnetRequirement>[];
    final bases = <_SubnetRequirement>[];
    for (final r in active) {
      if (r.comparator != RequirementComparator.equals ||
          !const {'subnet', 'base_subnet'}.contains(_property(r))) {
        continue;
      }
      final cidr = r.value is String ? _Cidr.parse(r.value as String) : null;
      if (cidr == null) {
        issues.add(
          _issue(
            RequestIssueKind.invalid,
            'invalid_ipv4_cidr',
            'The requested subnet must be a valid IPv4 CIDR.',
            [r],
          ),
        );
      } else if (cidr.address != cidr.network) {
        issues.add(
          _issue(
            RequestIssueKind.invalid,
            'invalid_network_address',
            'The requested subnet ${r.value} has host bits set; a network '
                'address is required. The original request was not changed.',
            [r],
          ),
        );
      } else if (_property(r) != 'base_subnet') {
        assigned.add(_SubnetRequirement(r, cidr, _domain(r.scope)));
      } else {
        bases.add(_SubnetRequirement(r, cidr, _domain(r.scope)));
      }
    }
    for (var i = 0; i < assigned.length; i++) {
      for (var j = i + 1; j < assigned.length; j++) {
        final a = assigned[i], b = assigned[j];
        if (_project(a.requirement.scope) != _project(b.requirement.scope)) {
          continue;
        }
        final specificDomain =
            a.domain.contains('role:') ||
            a.domain.contains('vlan:') ||
            a.domain.contains('device:') ||
            a.domain.contains('linkInterface:');
        if (a.cidr.network == b.cidr.network &&
            a.cidr.prefix == b.cidr.prefix &&
            a.domain == b.domain) {
          continue;
        }
        if (a.domain == b.domain && specificDomain) {
          if (a.cidr.network == b.cidr.network &&
              a.cidr.prefix == b.cidr.prefix) {
            continue; // Repeated descriptions of the same LAN are compatible.
          }
          issues.add(
            _issue(
              RequestIssueKind.conflict,
              'multiple_domain_subnets',
              'Different subnets are assigned to the same network domain.',
              [a.requirement, b.requirement],
            ),
          );
        } else if (a.cidr.network <= b.cidr.broadcast &&
            b.cidr.network <= a.cidr.broadcast) {
          issues.add(
            _issue(
              RequestIssueKind.conflict,
              'overlapping_subnets',
              'Assigned subnets ${a.requirement.value} and ${b.requirement.value} '
                  'overlap in independent routed LANs.',
              [a.requirement, b.requirement],
            ),
          );
        }
      }
    }
    final gateways = active
        .where(
          (r) =>
              _property(r) == 'gateway' &&
              r.comparator == RequirementComparator.equals,
        )
        .toList();
    for (var i = 0; i < gateways.length; i++) {
      final r = gateways[i];
      final address = r.value is String
          ? _ipv4((r.value as String).trim())
          : null;
      if (address == null) {
        issues.add(
          _issue(
            RequestIssueKind.invalid,
            'invalid_gateway',
            'The requested gateway must be a valid IPv4 address.',
            [r],
          ),
        );
        continue;
      }
      final domain = _domain(r.scope);
      final matches = assigned
          .where(
            (s) =>
                _sameProject(s.requirement.scope, r.scope) &&
                s.domain == domain,
          )
          .toList();
      if (matches.isEmpty) {
        final matchingBases = bases
            .where(
              (s) =>
                  _sameProject(s.requirement.scope, r.scope) &&
                  s.domain == domain,
            )
            .toList();
        if (matchingBases.length == 1) matches.add(matchingBases.single);
      }
      if (matches.isEmpty) {
        issues.add(
          _issue(
            RequestIssueKind.missingInput,
            'gateway_subnet_missing',
            'Specify the assigned subnet for the requested gateway.',
            [r],
          ),
        );
      } else if (matches.length > 1 && domain.isEmpty) {
        issues.add(
          _issue(
            RequestIssueKind.ambiguity,
            'gateway_domain_ambiguous',
            'Identify the LAN or VLAN to which this gateway belongs.',
            [r, ...matches.map((s) => s.requirement)],
          ),
        );
      } else {
        final unique = <String, _SubnetRequirement>{
          for (final s in matches) '${s.cidr.network}/${s.cidr.prefix}': s,
        };
        if (unique.length == 1) {
          final subnet = unique.values.single;
          if (address < subnet.cidr.network ||
              address > subnet.cidr.broadcast) {
            issues.add(
              _issue(
                RequestIssueKind.invalid,
                'gateway_outside_subnet',
                'Gateway ${r.value} is outside subnet ${subnet.requirement.value}.',
                [r, subnet.requirement],
              ),
            );
          } else if (subnet.cidr.prefix <= 30 &&
              (address == subnet.cidr.network ||
                  address == subnet.cidr.broadcast)) {
            issues.add(
              _issue(
                RequestIssueKind.invalid,
                'gateway_not_host_address',
                'A gateway cannot use the subnet network or broadcast address.',
                [r, subnet.requirement],
              ),
            );
          }
        }
      }
      for (var j = i + 1; j < gateways.length; j++) {
        final other = gateways[j];
        if (_project(r.scope) == _project(other.scope) &&
            domain == _domain(other.scope) &&
            other.value is String) {
          final otherAddress = _ipv4((other.value as String).trim());
          if (otherAddress != null && otherAddress != address) {
            issues.add(
              _issue(
                RequestIssueKind.conflict,
                'multiple_domain_gateways',
                'Different gateways are requested for the same network domain.',
                [r, other],
              ),
            );
          }
        }
      }
    }
  }
}

String _text(String text) =>
    text.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String _property(Requirement r) => r.property
    .trim()
    .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]}_${m[2]}')
    .toLowerCase()
    .replaceAll(RegExp(r'[\s-]+'), '_');
String _kind(String kind) => switch (_text(kind)) {
  'pcs' || 'computer' || 'computers' || 'workstation' || 'workstations' => 'pc',
  'routers' => 'router',
  'switches' => 'switch',
  'servers' => 'server',
  'network' || 'devices' || 'all' => 'device',
  _ => _text(kind),
};
Iterable<String> _strings(Object? value) => value is List
    ? value.whereType<String>().map(_text).where((s) => s.isNotEmpty)
    : const <String>[];
int _sum(Iterable<Requirement> requirements) =>
    requirements.fold(0, (sum, r) => sum + (r.value as int));
int _roleLowerBound(Iterable<Requirement> roles) => roles.fold<int>(
  0,
  (largest, r) => (r.value as int) > largest ? r.value as int : largest,
);

// Read context through the portable scope JSON so legacy flat scopes and new
// hierarchical scopes have identical semantics without depending on a reader.
List<Map<String, dynamic>> _ancestry(RequirementScope scope) {
  final result = <Map<String, dynamic>>[];
  Map<String, dynamic>? current = scope.toJson();
  while (current != null) {
    result.add(current);
    final parent = current['parent'];
    current = parent is Map ? Map<String, dynamic>.from(parent) : null;
  }
  return result;
}

String _context(RequirementScope scope, String key, String kind) {
  for (final node in _ancestry(scope)) {
    final context = node[key];
    if (context is String && context.trim().isNotEmpty) return _text(context);
    if (node['kind'] == kind) return _text('${node['scopeId'] ?? ''}');
  }
  return '';
}

String _site(RequirementScope scope) => _context(scope, 'siteId', 'site');
String _project(RequirementScope scope) =>
    _context(scope, 'projectId', 'project');
bool _sameProject(RequirementScope a, RequirementScope b) =>
    _project(a).isEmpty || _project(b).isEmpty || _project(a) == _project(b);
String _domain(RequirementScope scope) {
  final nodes = _ancestry(scope);
  final parts = <String>[];
  final site = _site(scope);
  if (site.isNotEmpty) parts.add('site:$site');
  final role = _context(scope, 'networkRole', 'networkRole');
  if (role.isNotEmpty) parts.add('role:$role');
  for (final node in nodes) {
    if (node['kind'] == 'vlan') {
      parts.add('vlan:${_text('${node['scopeId']}')}');
    }
  }
  if (role.isEmpty && !nodes.any((n) => n['kind'] == 'vlan')) {
    for (final node in nodes) {
      if (const {'device', 'linkInterface', 'service'}.contains(node['kind'])) {
        parts.add('${node['kind']}:${_text('${node['scopeId']}')}');
        break;
      }
    }
  }
  return parts.join('|');
}

RequestIssue _issue(
  RequestIssueKind kind,
  String code,
  String message,
  Iterable<Requirement> requirements,
) {
  final evidence = requirements.toList()..sort((a, b) => a.id.compareTo(b.id));
  final ids = evidence.map((r) => r.id).toSet().toList()..sort();
  final spans =
      <SourceSpan>{for (final r in evidence) ...r.sourceSpans}.toList()
        ..sort((a, b) {
          final message = a.messageId.compareTo(b.messageId);
          if (message != 0) return message;
          final start = a.start.compareTo(b.start);
          return start != 0 ? start : a.end.compareTo(b.end);
        });
  return RequestIssue(
    id: 'validation:$code:${ids.join('|')}',
    kind: kind,
    code: code,
    message: message,
    requirementIds: ids,
    sourceSpans: spans,
  );
}

class _SubnetRequirement {
  final Requirement requirement;
  final _Cidr cidr;
  final String domain;
  const _SubnetRequirement(this.requirement, this.cidr, this.domain);
}

int? _ipv4(String value) {
  if (!RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(value)) return null;
  final octets = value.split('.').map(int.parse).toList();
  if (octets.any((n) => n > 255)) return null;
  return octets.fold<int>(0, (result, octet) => (result << 8) | octet);
}

class _Cidr {
  final int address;
  final int prefix;
  final int network;
  final int broadcast;
  const _Cidr(this.address, this.prefix, this.network, this.broadcast);
  static _Cidr? parse(String value) {
    final match = RegExp(
      r'^\s*(\d{1,3}(?:\.\d{1,3}){3})\s*/\s*(\d{1,2})\s*$',
    ).firstMatch(value);
    if (match == null) return null;
    final address = _ipv4(match[1]!);
    final prefix = int.parse(match[2]!);
    if (address == null || prefix > 32) return null;
    final hostMask = (1 << (32 - prefix)) - 1;
    final network = address & (0xffffffff ^ hostMask);
    return _Cidr(address, prefix, network, network | hostMask);
  }
}
