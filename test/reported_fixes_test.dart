import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:net_builder/models/network_intent.dart';
import 'package:net_builder/models/chat_message.dart';
import 'package:net_builder/models/build_record.dart';
import 'package:net_builder/services/adapters/cisco_adapter.dart';
import 'package:net_builder/services/adapters/gns3_adapter.dart';
import 'package:net_builder/services/ai_provider.dart';
import 'package:net_builder/services/autopilot_service.dart';
import 'package:net_builder/services/engine_configuration_sync.dart';
import 'package:net_builder/services/engine_status.dart';
import 'package:net_builder/services/build_artifact_service.dart';
import 'package:net_builder/services/pkt/pkt_codec.dart';
import 'package:net_builder/services/gemini_service.dart';
import 'package:net_builder/services/memory_service.dart';
import 'package:net_builder/services/nlu/slots.dart';
import 'package:net_builder/services/secret_vault.dart';
import 'package:net_builder/services/settings_service.dart';
import 'package:net_builder/services/validator_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final secureValues = <String, String>{};
  var dropWrites = false;
  setUp(() {
    secureValues.clear();
    dropWrites = false;
    SharedPreferences.setMockInitialValues({});
    SecretVault.storage = const FlutterSecureStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = call.arguments as Map;
            final key = args['key'] as String?;
            switch (call.method) {
              case 'read':
                return secureValues[key];
              case 'write':
                if (!dropWrites) secureValues[key!] = args['value'];
                return null;
              case 'delete':
                secureValues.remove(key);
                return null;
              case 'containsKey':
                return secureValues.containsKey(key);
              case 'readAll':
                return secureValues;
            }
            return null;
          },
        );
  });

  int count(NetworkIntent plan, String type) =>
      plan.nodes.where((n) => n.type == type).length;
  test('qualified device quantities and distinct server roles are retained', () {
    final slots = BriefSlotPipeline.extract(
      'lab',
      '2 core multilayer switches, 2 access switches, a DHCP server, a DNS server, a TACACS+ AAA server and a web server',
    );
    expect(slots.count('switch'), 4);
    expect(slots.count('server'), 4);
  });
  test('HQ and each branch are counted separately', () {
    final slots = BriefSlotPipeline.extract(
      'lab',
      'HQ needs 2 routers, 4 switches and 20 PCs. Each of two branch offices needs 1 router, 1 switch and 8 PCs.',
    );
    expect(slots.count('router'), 4);
    expect(slots.count('switch'), 6);
    expect(slots.count('pc'), 36);
  });
  test('each branch does not multiply the separate headquarters server', () {
    final plan = NetworkIntent.parseSimple(
      'lab',
      'Two branch offices connected by a serial WAN, each with a router, a switch and 3 PCs, plus one server at headquarters',
    );
    expect(count(plan, 'router'), 2);
    expect(count(plan, 'pc'), 6);
    expect(count(plan, 'server'), 1);
  });
  test(
    'the full enterprise request retains 55 devices and reports the existing limit',
    () {
      final plan = NetworkIntent.parseSimple(
        'lab',
        'HQ needs 2 routers, 1 firewall, 2 core multilayer switches, 2 access switches, a WLC with 3 access points, 20 PCs, a DHCP server, a DNS server, a TACACS+ AAA server and a web server. Each of two branch offices needs 1 router, 1 switch and 8 PCs.',
      );
      expect(count(plan, 'router'), 4);
      expect(count(plan, 'switch'), 6);
      expect(count(plan, 'pc'), 36);
      expect(count(plan, 'server'), 4);
      expect(plan.nodes.length, 55);
      expect(
        ValidatorService.validate(
          plan,
          target: 'packet-tracer',
        ).any((i) => i.message.contains('more than 50')),
        true,
      );
    },
  );
  test(
    'replacement followed by an addition does not add the corrected quantity',
    () {
      const base = '1 router, 1 switch, 20 PCs and a web server';
      const change = 'Actually make it 30 PCs and add a second web server';
      final result = NetworkIntent.followUp(
        previous: NetworkIntent.parseSimple('lab', base),
        previousBrief: base,
        brief: change,
        parsed: NetworkIntent.parseSimple('lab', change),
        project: 'lab',
      );
      expect(count(result.plan, 'pc'), 30);
      expect(count(result.plan, 'server'), 2);
      expect(count(result.plan, 'router'), 1);
    },
  );
  test('a laptop-only quantity does not invent infrastructure', () {
    final plan = NetworkIntent.parseSimple('lab', 'Add more than six laptops');
    expect(count(plan, 'laptop'), 7);
    expect(plan.nodes.length, 7);
  });
  test('a correction scoped to HQ retains branch PCs', () {
    const base =
        'HQ needs 2 routers, 2 switches and 20 PCs. Each of two branch offices needs 1 router, 1 switch and 8 PCs.';
    const change = 'Actually make it 30 PCs at HQ';
    final result = NetworkIntent.followUp(
      previous: NetworkIntent.parseSimple('lab', base),
      previousBrief: base,
      brief: change,
      parsed: NetworkIntent.parseSimple('lab', change),
      project: 'lab',
    );
    expect(count(result.plan, 'pc'), 46);
    expect(count(result.plan, 'router'), 4);
  });
  test('names that previously collided have independent credentials', () async {
    await SecretVault.store('Office Lab', {'aaaPassword': 'one'});
    await SecretVault.store('Office_Lab', {'aaaPassword': 'two'});
    expect((await SecretVault.load('Office Lab'))['aaaPassword'], 'one');
    expect((await SecretVault.load('Office_Lab'))['aaaPassword'], 'two');
    await SecretVault.purge('Office_Lab');
    expect((await SecretVault.load('Office Lab'))['aaaPassword'], 'one');
  });
  test(
    'unambiguous legacy slots migrate and ambiguous slots are not assigned to either project',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await MemoryService.createSchema(db);
      addTearDown(db.close);
      final memory = MemoryService(injected: db);
      for (final name in ['Office Lab', 'Office_Lab', 'Other Lab']) {
        await db.insert(
          'builds',
          BuildRecord(
            projectName: name,
            instruction: '1 router',
            intentJson: '{}',
            target: 'cisco-ssh',
            status: 'planned',
            success: false,
            createdAt: DateTime.now(),
          ).toMap(),
        );
      }
      secureValues['project_secret_office_lab_aaaPassword'] = 'Ambiguous123';
      secureValues['project_secret_other_lab_aaaPassword'] = 'Known123';
      await memory.migrateStoredPrivacy();
      expect(
        (await db.rawQuery('PRAGMA secure_delete')).single.values.single,
        1,
      );
      expect(await SecretVault.load('Office Lab'), isEmpty);
      expect(await SecretVault.load('Office_Lab'), isEmpty);
      expect((await SecretVault.load('Other Lab'))['aaaPassword'], 'Known123');
      expect(memory.privacyError, contains('shared a credential slot'));
    },
  );
  test(
    'enable secrets and service account passwords survive redacted saves',
    () async {
      final plan = <String, dynamic>{
        'security': {'enableSecret': 'Enable123'},
        'nodes': [
          {
            'name': 'AAA1',
            'serviceRules': {
              'aaa': {
                'users': [
                  {'username': 'admin', 'password': 'Account123'},
                ],
              },
            },
          },
        ],
      };
      await SecretVault.store('lab', SecretVault.extract(plan));
      final portable = {
        'security': <String, dynamic>{},
        'nodes': [
          {
            'name': 'AAA1',
            'serviceRules': {
              'aaa': {
                'users': [
                  {'username': 'admin'},
                ],
              },
            },
          },
        ],
      };
      final restored = SecretVault.inject(
        portable,
        await SecretVault.load('lab'),
      );
      expect(restored['security']['enableSecret'], 'Enable123');
      expect(
        restored['nodes'][0]['serviceRules']['aaa']['users'][0]['password'],
        'Account123',
      );
    },
  );
  test(
    'provider storage failures are reported and keys can be cleared',
    () async {
      final settings = SettingsService();
      dropWrites = true;
      expect(await settings.setOpenAiKey('key123'), false);
      dropWrites = false;
      expect(await settings.setOpenAiKey('key123'), true);
      expect(await settings.setOpenAiKey(''), true);
      expect(await settings.getOpenAiKey(), isNull);
    },
  );
  test('custom authentication headers are stored securely', () async {
    final settings = SettingsService();
    await settings.load();
    expect(await settings.setOpenAiHeaders('X-API-Key: secret123'), true);
    expect(
      (await SharedPreferences.getInstance()).getString('openai_headers'),
      isNull,
    );
    final reloaded = SettingsService();
    await reloaded.load();
    expect(reloaded.openAiHeaders, 'X-API-Key: secret123');
  });
  test(
    'chat credentials are vaulted and absent from the database and export',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await MemoryService.createSchema(db);
      addTearDown(db.close);
      final memory = MemoryService(injected: db);
      const text = 'Use AAA username admin password TopSecret123';
      await memory.logChat(
        ChatMessage(role: 'user', text: text, createdAt: '2026-10-11'),
        conversation: 'lab',
      );
      expect(
        jsonEncode(await db.query('chat')),
        isNot(contains('TopSecret123')),
      );
      expect(await memory.exportJson(), isNot(contains('TopSecret123')));
      expect(
        (await SecretVault.load('lab'))['brief'],
        contains('TopSecret123'),
      );
    },
  );
  test(
    'privacy configuration clears the engine credential immediately',
    () async {
      final settings = SettingsService();
      await settings.setApiKey('cloud-key');
      await settings.setPrivateMode(true);
      Map<String, dynamic>? sent;
      final engine = AutopilotService(
        c: MockClient((request) async {
          sent = jsonDecode(request.body);
          return http.Response('{"ok":true}', 200);
        }),
      );
      await EngineConfigurationSync.push(settings, engine);
      expect(sent!['enabled'], false);
      expect(sent!['apiKey'], '');
      expect(sent!['configRevision'], isA<int>());
    },
  );
  test(
    'changing Private Mode automatically disables the configured engine',
    () async {
      final settings = SettingsService();
      await settings.setApiKey('cloud-key');
      await settings.setLlmFix(true);
      final posts = <Map<String, dynamic>>[];
      final engine = AutopilotService(
        c: MockClient((request) async {
          posts.add(jsonDecode(request.body));
          return http.Response('{"ok":true}', 200);
        }),
      );
      final sync = EngineConfigurationSync(settings, engine, EngineStatus());
      addTearDown(sync.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(posts.last['enabled'], true);
      await settings.setPrivateMode(true);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(posts.last['enabled'], false);
      expect(posts.last['apiKey'], '');
      expect(posts.last['extraHeaders'], isEmpty);
    },
  );
  test(
    'legacy credentials migrate before redaction and projects still reopen',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await MemoryService.createSchema(db);
      addTearDown(db.close);
      final memory = MemoryService(injected: db);
      final plan = NetworkIntent.parseSimple(
        'Office Lab',
        '1 router, 1 switch',
      ).toJson();
      plan['security'] = {
        'enableSecret': 'Enable123',
        'aaaPassword': 'Shared123',
      };
      final record = BuildRecord(
        projectName: 'Office Lab',
        instruction: 'Use enable secret Enable123',
        intentJson: jsonEncode(plan),
        target: 'cisco-ssh',
        success: false,
        status: 'planned',
        createdAt: DateTime.now(),
      );
      await db.insert('builds', record.toMap());
      await memory.migrateStoredPrivacy();
      await memory.migrateStoredPrivacy();
      final stored = BuildRecord.fromMap((await db.query('builds')).single);
      expect(stored.intentJson, isNot(contains('Enable123')));
      expect(stored.instruction, isNot(contains('Enable123')));
      expect(await memory.exportJson(), isNot(contains('Shared123')));
      final restored = await BuildArtifactService.restoreAsync(stored);
      expect(restored.intent.security.enableSecret, 'Enable123');
      expect(restored.intent.security.aaaPassword, 'Shared123');
    },
  );
  test(
    'structured chat state credentials survive while stored state stays redacted',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await MemoryService.createSchema(db);
      addTearDown(db.close);
      final memory = MemoryService(injected: db);
      final state = {
        'intentJson': jsonEncode({
          'security': {'enableSecret': 'Enable123'},
          'nodes': [
            {
              'name': 'AAA1',
              'serviceRules': {
                'aaa': {
                  'users': [
                    {'username': 'admin', 'password': 'Account123'},
                  ],
                },
              },
            },
          ],
        }),
      };
      await memory.setSessionState('chat-lab', jsonEncode(state));
      final stored = await memory.sessionStateJson('chat-lab');
      expect(stored, isNot(contains('Account123')));
      expect(stored, isNot(contains('Enable123')));
      final savedPlan = jsonDecode(jsonDecode(stored)['intentJson']);
      final restored = SecretVault.inject(
        Map<String, dynamic>.from(savedPlan),
        await SecretVault.load('chat-lab'),
      );
      expect(restored['security']['enableSecret'], 'Enable123');
      expect(
        restored['nodes'][0]['serviceRules']['aaa']['users'][0]['password'],
        'Account123',
      );
    },
  );
  test('failed secure writes do not persist a plaintext transcript', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await MemoryService.createSchema(db);
    addTearDown(db.close);
    final memory = MemoryService(injected: db);
    dropWrites = true;
    await expectLater(
      memory.logChat(
        ChatMessage(role: 'user', text: 'password Unsafe123', createdAt: 'now'),
        conversation: 'lab',
      ),
      throwsStateError,
    );
    expect(await db.query('chat'), isEmpty);
  });
  test(
    'the Dart codec bounds actual expansion, including an authenticated hostile file',
    () {
      final body = ZLibEncoder().convert(utf8.encode('<${'x' * 1000000}/>'));
      final framed = Uint8List(4 + body.length)
        ..setRange(4, 4 + body.length, body);
      ByteData.view(framed.buffer).setUint32(0, 8);
      for (var i = 0; i < framed.length; i++) {
        framed[i] ^= (framed.length - i) & 0xff;
      }
      final key = TwofishKey(ptKey);
      final sealed = Eax(key.encryptBlock).encryptPkt(ptNonce, framed);
      final joined = [...sealed.ciphertext, ...sealed.tag];
      final pkt = Uint8List(joined.length);
      for (var i = 0; i < joined.length; i++) {
        pkt[joined.length - 1 - i] =
            joined[i] ^ ((joined.length - i * joined.length) & 0xff);
      }
      expect(() => decryptPkt(pkt), throwsA(isA<PktFormatError>()));
    },
  );
  test(
    'OpenAI-compatible planning uses its endpoint and context-sensitive cache',
    () async {
      const config = AiProviderConfig(
        kind: AiProviderKind.openai,
        model: 'local-model',
        baseUrl: 'http://localhost:1234/v1',
      );
      final candidate = NetworkIntent.parseSimple(
        'lab',
        '1 router, 1 switch',
      ).toPlannerJson();
      final service = GeminiService(
        client: MockClient((request) async {
          expect(
            request.url.toString(),
            'http://localhost:1234/v1/chat/completions',
          );
          expect(jsonDecode(request.body)['model'], 'local-model');
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': jsonEncode(candidate)},
                },
              ],
            }),
            200,
          );
        }),
      );
      await service.generateIntent(
        apiKey: '',
        model: config.model,
        providerConfig: config,
        instruction: 'build',
        contextBlock: 'OSPF preference',
        target: 'pt',
        offlineCandidate: candidate,
      );
      final identity = GeminiService.cacheIdentity(
        config: config,
        contextBlock: 'OSPF preference',
        offlineCandidate: candidate,
      );
      expect(
        await GeminiService.cachedPlan(
          'build',
          'pt',
          contextIdentity: identity,
        ),
        isNotNull,
      );
      final changed = GeminiService.cacheIdentity(
        config: config,
        contextBlock: 'static preference',
        offlineCandidate: candidate,
      );
      expect(
        await GeminiService.cachedPlan('build', 'pt', contextIdentity: changed),
        isNull,
      );
      await GeminiService.invalidateCachedPlan('build', 'pt');
      expect(
        await GeminiService.cachedPlan(
          'build',
          'pt',
          contextIdentity: identity,
        ),
        isNull,
      );
    },
  );
  test('GNS3 exports the complete IOS configuration', () {
    final plan = NetworkIntent.parseSimple(
      'lab',
      '2 routers and 2 switches with OSPF and VLANs 10 and 20',
    );
    expect(
      Gns3Adapter.projectPayload(plan)['configs'],
      CiscoAdapter.render(plan),
    );
  });
}
