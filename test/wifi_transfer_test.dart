import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangaflow/data/services/transfer/wifi_transfer.dart';

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('wifi'));
  tearDown(() => tmp.delete(recursive: true));

  test('sender serves the pack, receiver finds it, needs the code, gets identical bytes', () async {
    final pack = File('${tmp.path}/p.cbz')..writeAsBytesSync(List.generate(3 << 20, (i) => i % 253));
    final s = await WifiSendSession.start(pack: pack, title: 'Берсерк', chapters: 3, device: 'Pixel', port: 0, beacon: false, pin: '4821');
    final statuses = <WifiSendStatus>[];
    final sub = s.status.listen(statuses.add);
    try {
      final addr = '127.0.0.1:${s.port}';
      final offer = await WifiDiscovery.probe(addr);
      expect(offer, isNotNull);
      expect((offer!.title, offer.chapters, offer.device, offer.bytes), ('Берсерк', 3, 'Pixel', 3 << 20));

      final d = WifiDiscovery(extraHosts: [addr], beaconPort: 0);
      final found = d.offers.first;
      await d.start();
      expect((await found.timeout(const Duration(seconds: 5))).first.address, addr);
      await d.stop();

      await expectLater(downloadOffer(offer, '0000', File('${tmp.path}/x.cbz')), throwsA(isA<WifiPinException>()));
      final progress = <int>[];
      final got = await downloadOffer(offer, '4821', File('${tmp.path}/in/got.cbz'), from: 'Galaxy',
          onProgress: (r, t, _) => progress.add(r));
      expect(got.readAsBytesSync(), pack.readAsBytesSync());
      expect(progress.last, 3 << 20);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(statuses.last.done, isTrue);
      expect(statuses.last.client, 'Galaxy');
    } finally {
      await sub.cancel();
      await s.stop();
    }
  });

  test('addresses typed by hand', () {
    expect(parseAddress(' 192.168.43.1:47810 '), ('192.168.43.1', 47810));
    expect(parseAddress('http://10.0.0.1/'), ('10.0.0.1', wifiTransferPort));
  });
}
