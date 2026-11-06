import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/nlu/slots.dart';

/// The reported failure: a brief stated its inventory, then described how
/// some of those devices are cabled. The connection numbers must not become
/// inventory numbers, and the stated 25 PCs / 6 switches must survive.
void main() {
  test('connection instructions do not change stated device totals', () {
    const brief =
        'Create 3 routers, 6 switches, 25 PCs, 8 laptops, 4 servers and '
        '4 printers. Connect 5 PCs to Switch 1 and connect 1 printer to '
        'Switch 1.';
    final slots = BriefSlotPipeline.extract('Distribution lab', brief);

    expect(slots.count('router'), 3);
    expect(slots.count('switch'), 6);
    expect(slots.count('pc'), 25);
    expect(slots.count('laptop'), 8);
    expect(slots.count('server'), 4);
    expect(slots.count('printer'), 4);
  });

  test('a connection quantity is marked as distribution, not inventory', () {
    final quantities = BriefSlotPipeline.extractQuantities(
      'Connect 5 PCs to Switch 1 and connect 1 printer to Switch 1.',
    );
    final pcs = quantities.where((q) => q.kind == 'pc').toList();
    final printers = quantities.where((q) => q.kind == 'printer').toList();

    expect(pcs, isNotEmpty);
    expect(pcs.every((q) => q.distribution), isTrue);
    expect(pcs.first.value, 5);
    expect(printers, isNotEmpty);
    expect(printers.every((q) => q.distribution), isTrue);
  });

  test('an inventory line is still read as inventory', () {
    final quantities = BriefSlotPipeline.extractQuantities(
      'Design a campus with 4 switches and 12 PCs.',
    );
    expect(quantities.where((q) => q.distribution), isEmpty);
    expect(
      quantities.where((q) => q.kind == 'switch').single.value,
      4,
    );
    expect(quantities.where((q) => q.kind == 'pc').single.value, 12);
  });

  test('a connection verb without a destination is still inventory', () {
    // "connect two routers over a serial WAN" asks for two routers. It is not
    // a distribution of routers that already exist.
    final slots = BriefSlotPipeline.extract(
      'Serial WAN',
      'connect two routers over a serial WAN with 1 switch',
    );
    expect(slots.count('router'), 2);
    expect(slots.count('switch'), 1);
  });
}
