import '../models/network_intent.dart';
import 'validator_service.dart';

/// What an export covers for its target, and what stays manual - said in
/// plain words next to the export itself, from sources that actually know:
/// the validator (which already carries the plan's own findings) and the
/// adapter characteristics.
///
/// Producing an export is NOT deploying or verifying it: that line is always
/// included, because conflating the two is exactly the kind of claim this
/// app refuses to make.
class ExportSupport {
  const ExportSupport._();

  /// Support notes for [intent] on [target] ("packet-tracer", "gns3",
  /// "cisco-ssh", "aws-vpc"...).
  static List<String> notesFor(NetworkIntent intent, String target) {
    final notes = <String>[];
    final t = target.trim().toLowerCase();
    switch (t) {
      case 'gns3':
        notes.add(
          'GNS3 has no 1:1 image for Packet Tracer models: ISRs map to a '
          'c3725 dynamips template, PCs become VPCS and switches use the '
          'built-in Ethernet switch; other devices (servers, APs, security '
          'appliances) import as generic nodes and their images must be '
          'picked by hand.',
        );
        break;
      case 'packet-tracer':
        notes.add(
          'The .pkt is compiled by this app\'s own offline builder; opening '
          'it needs a Packet Tracer version that reads 8.x saves. Commands '
          'that need hardware the image lacks - crypto without the Security '
          'Technology package, for example - are reported as skipped, never '
          'faked.',
        );
        break;
      case 'cisco-ssh':
        notes.add(
          'This is raw IOS CLI for real devices: it does not apply itself - '
          'copy it in, or run it through an approved action.',
        );
        break;
      case 'aws-vpc':
        notes.add(
          'The Terraform output is a minimal AWS VPC example and does not '
          'reproduce LAN devices; routers and switches in the plan are not '
          'cloud resources.',
        );
        break;
      default:
        break;
    }
    // The validator's own non-error findings describe plan-specific things
    // that will need attention on ANY target (skipped, partly automated,
    // manual steps) - the same findings the build preflight shows.
    for (final issue in ValidatorService.validate(intent, target: target)) {
      if (issue.severity == 'error') continue;
      final msg = issue.message.trim();
      if (msg.isEmpty) continue;
      if (!notes.contains(msg)) notes.add(msg);
    }
    notes.add(
      'Producing this export does not deploy or verify it on the target - '
      'importing, pushing or running it is a separate, approval-gated step.',
    );
    return notes;
  }
}
