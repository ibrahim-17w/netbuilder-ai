import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:net_builder/services/settings_service.dart';

/// Tests for the "is a local model server actually there?" probe.
///
/// The HTTP is faked with `MockClient` the same way the provider tests do
/// it: the probe code is exercised against the real request it builds and
/// the real JSON it must read, with only the transport standing in.
void main() {
  group('LocalModelProber', () {
    test('success parses model ids and names the runtime by port', () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://127.0.0.1:11434/v1/models');
        return http.Response(
          jsonEncode({
            'object': 'list',
            'data': [
              {'id': 'llama3.2:3b'},
              {'id': 'qwen2.5:0.5b'},
              {'id': 'phi3:latest'},
              {'id': 'mistral'},
            ],
          }),
          200,
        );
      });
      final r = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:11434/v1',
        client: client,
      );
      expect(r.reachable, isTrue);
      expect(r.local, isTrue);
      // Only three ids are kept for the UI, but the full count is reported.
      expect(r.models, ['llama3.2:3b', 'qwen2.5:0.5b', 'phi3:latest']);
      expect(r.modelCount, 4);
      expect(r.message, contains('Ollama'));
      expect(r.message, contains('4 models'));
      expect(r.message, isNot(contains('remote')));
    });

    test('connection refused maps to the start-the-server guidance',
        () async {
      final client = MockClient(
        (request) async => throw SocketException('Connection refused'),
      );
      final r = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:11434/v1',
        client: client,
      );
      expect(r.reachable, isFalse);
      expect(r.local, isTrue);
      expect(r.message, contains('Nothing answered on 127.0.0.1:11434'));
      expect(r.message, contains('is Ollama running?'));
      expect(r.message, contains('ollama serve'));
    });

    test('a timeout maps to the same guidance as a refusal', () async {
      // A server that accepts nothing at all: the future never completes,
      // so the probe's own short timeout is what has to end the wait.
      final client = MockClient(
        (request) => Completer<http.Response>().future,
      );
      final r = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:11434/v1',
        client: client,
        timeout: const Duration(milliseconds: 50),
      );
      expect(r.reachable, isFalse);
      expect(r.message, contains('Nothing answered on 127.0.0.1:11434'));
      expect(r.message, contains('ollama serve'));
    });

    test('each preset port names its own runtime in the guidance', () async {
      final client = MockClient(
        (request) async => throw SocketException('Connection refused'),
      );
      final lm = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:1234/v1',
        client: client,
      );
      expect(lm.message, contains('LM Studio'));
      final cpp = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:8080/v1',
        client: client,
      );
      expect(cpp.message, contains('llama.cpp'));
      final unknown = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:9999/v1',
        client: client,
      );
      // An unknown port still gets a next step, just not a made-up name.
      expect(unknown.message, contains('is a server running there?'));
    });

    test('a remote host is tested the same way but labeled as remote',
        () async {
      final client = MockClient((request) async {
        expect(request.url.host, 'api.example.com');
        return http.Response(
          jsonEncode({
            'data': [
              {'id': 'llama-3.3-70b-versatile'},
            ],
          }),
          200,
        );
      });
      final r = await LocalModelProber.probe(
        baseUrl: 'https://api.example.com/v1',
        client: client,
      );
      expect(r.reachable, isTrue);
      expect(r.local, isFalse);
      expect(r.models, ['llama-3.3-70b-versatile']);
      expect(r.message, contains('remote address'));
    });

    test('404 points at the /v1 shape instead of just failing', () async {
      final client = MockClient(
        (request) async => http.Response('not found', 404),
      );
      final r = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:11434',
        client: client,
      );
      expect(r.reachable, isFalse);
      expect(r.message, contains('404'));
      expect(r.message, contains('http://127.0.0.1:11434/v1'));
    });

    test('401 explains that the address wants a key', () async {
      final client = MockClient(
        (request) async => http.Response('unauthorized', 401),
      );
      final r = await LocalModelProber.probe(
        baseUrl: 'https://api.example.com/v1',
        client: client,
      );
      expect(r.reachable, isFalse);
      expect(r.message, contains('401'));
      expect(r.message, contains('API key'));
    });

    test('an empty model list asks for a model to be pulled', () async {
      final client = MockClient(
        (request) async => http.Response(jsonEncode({'data': []}), 200),
      );
      final r = await LocalModelProber.probe(
        baseUrl: 'http://127.0.0.1:11434/v1',
        client: client,
      );
      expect(r.reachable, isTrue, reason: 'the server DID answer');
      expect(r.models, isEmpty);
      expect(r.message, contains('no models yet'));
    });

    test('Ollama native tags shape parses through the models[] fallback',
        () {
      // Pure parse, so the real shape Ollama serves at /api/tags is checked
      // against the exact code that will read it.
      final r = LocalModelProber.parse(
        jsonEncode({
          'models': [
            {'name': 'llama3.2:latest'},
            {'name': 'qwen2.5:0.5b'},
          ],
        }),
        baseUrl: 'http://127.0.0.1:11434',
        local: true,
      );
      expect(r.reachable, isTrue);
      expect(r.models, ['llama3.2:latest', 'qwen2.5:0.5b']);
    });

    test('a body that is not a model list says so, not "unreachable"',
        () {
      final r = LocalModelProber.parse(
        '<html>hello</html>',
        baseUrl: 'http://127.0.0.1:8080/v1',
        local: true,
      );
      expect(r.reachable, isFalse);
      expect(r.message, contains('not with a model list'));
    });

    test('an empty base URL asks for one instead of probing nothing',
        () async {
      final client = MockClient(
        (request) async => fail('no request should be made'),
      );
      final r = await LocalModelProber.probe(baseUrl: '', client: client);
      expect(r.reachable, isFalse);
      expect(r.message, contains('Enter a base URL first'));
    });
  });
}
