import '../../models/network_intent.dart';

/// Minimal AWS VPC Terraform generator (example cloud target).
class TerraformAdapter {
  static String renderAwsVpc(
    NetworkIntent intent, {
    String cidr = '10.0.0.0/16',
  }) {
    final sb = StringBuffer();
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
