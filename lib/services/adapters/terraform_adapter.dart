import '../../models/network_intent.dart';

/// A starter AWS VPC skeleton (example cloud target).
///
/// It is deliberately not a faithful translation of the plan: it derives one
/// subnet per device (at most four), with no route tables, NAT gateways,
/// security groups, NACLs or per-site addressing. The generated file says so
/// in its header, because HCL looks authoritative once it is on disk and this
/// output is a starting point to edit, not something to apply unreviewed.
class TerraformAdapter {
  static String renderAwsVpc(
    NetworkIntent intent, {
    String cidr = '10.0.0.0/16',
  }) {
    final sb = StringBuffer();
    sb.writeln('# Starter example only: one VPC, one internet gateway and one');
    sb.writeln(
      '# subnet per device (at most four). Route tables, NAT, security',
    );
    sb.writeln(
      '# groups and per-site addressing are not derived from the plan.',
    );
    sb.writeln('# Review before applying.');
    sb.writeln('');
    sb.writeln('resource "aws_vpc" "main" {');
    sb.writeln('  cidr_block = "$cidr"');
    sb.writeln('  tags = { Name = "${intent.projectName}" }');
    sb.writeln('}');
    sb.writeln('');
    sb.writeln('resource "aws_internet_gateway" "igw" {');
    sb.writeln('  vpc_id = aws_vpc.main.id');
    sb.writeln('}');
    var i = 0;
    for (final n in intent.nodes.take(4)) {
      sb.writeln('');
      sb.writeln('resource "aws_subnet" "s$i" {');
      sb.writeln('  vpc_id = aws_vpc.main.id');
      sb.writeln('  cidr_block = "10.0.$i.0/24"');
      sb.writeln('  tags = { Name = "${n.name}" }');
      sb.writeln('}');
      i++;
    }
    return sb.toString();
  }
}
