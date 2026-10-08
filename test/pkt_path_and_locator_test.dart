import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:net_builder/services/packet_tracer_locator.dart';
import 'package:net_builder/widgets/chat_markdown.dart';

/// The tappable `.pkt` path: what counts as one, what the markdown emits for
/// it, and how the locator decides whether Packet Tracer exists.
void main() {
  group('isPktFilePath', () {
    test('a full path to a .pkt is tappable', () {
      expect(ChatMarkdown.isPktFilePath(r'C:\Users\me\labs\office.pkt'), isTrue);
      expect(ChatMarkdown.isPktFilePath('/home/me/labs/office.pkt'), isTrue);
      expect(ChatMarkdown.isPktFilePath(r'C:\PROGRA~1\LAB.PKT'), isTrue);
    });

    test('bare names, non-pkt code and noise stay inert', () {
      expect(ChatMarkdown.isPktFilePath('office.pkt'), isFalse,
          reason: 'no separator: a backup name in prose is not a control');
      expect(ChatMarkdown.isPktFilePath('spanning-tree mode rapid-pvst'),
          isFalse);
      expect(ChatMarkdown.isPktFilePath('192.168.1.0/24'), isFalse);
      expect(ChatMarkdown.isPktFilePath(''), isFalse);
      expect(ChatMarkdown.isPktFilePath(r'C:\dir\'), isFalse);
    });
  });

  group('ChatMarkdown.inline emits a tappable span', () {
    List<InlineSpan> render(String text, {void Function(String)? onTap}) =>
        ChatMarkdown.inline(
          text,
          const TextStyle(fontSize: 14),
          linkColor: const Color(0xFF3366CC),
          onFilePathTap: onTap,
        );

    test('a .pkt path becomes a ChatFilePathSpan', () {
      final spans = render(r'- File: `C:\labs\office.pkt`', onTap: (_) {});
      final widgetSpans = spans.whereType<WidgetSpan>().toList();
      expect(widgetSpans.length, 1);
      final span = widgetSpans.first.child;
      expect(span, isA<ChatFilePathSpan>());
      expect((span as ChatFilePathSpan).path, r'C:\labs\office.pkt');
    });

    test('plain inline code stays a plain TextSpan', () {
      final spans = render('run `show ip route` on R1');
      expect(spans.whereType<WidgetSpan>(), isEmpty);
    });

    test('without the callback even a path stays a plain TextSpan', () {
      final spans = ChatMarkdown.inline(
        r'`C:\labs\office.pkt`',
        const TextStyle(fontSize: 14),
      );
      expect(spans.whereType<WidgetSpan>(), isEmpty);
    });

    testWidgets('tapping the rendered span fires the callback', (tester) async {
      String? tapped;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatMarkdownView(
            source: 'Built. File: `C:\\labs\\office.pkt`',
            onFilePathTap: (p) => tapped = p,
          ),
        ),
      ));
      expect(find.text(r'C:\labs\office.pkt'), findsOneWidget);
      await tester.tap(find.text(r'C:\labs\office.pkt'));
      expect(tapped, r'C:\labs\office.pkt');
    });
  });

  group('PacketTracerLocator', () {
    ProcessResult ok(String out) => ProcessResult(0, 0, out, '');

    ProcessResult fail() => ProcessResult(1, 1, '', '');

    test('App Paths registry hit means installed', () async {
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async =>
            exe == 'reg' ? ok('PacketTracer.exe REG_SZ C:\\pt.exe') : fail(),
      );
      expect(await locator.isInstalled(), isTrue);
    });

    test('nothing found anywhere means not installed', () async {
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async => fail(),
        exists: (path) => false,
        listDir: (path) => const <FileSystemEntity>[],
      );
      expect(await locator.isInstalled(), isFalse);
    });

    test('a .pkt file association alone counts: the OS can open the file',
        () async {
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async =>
            exe == 'cmd' ? ok('.pkt=PacketTracer8') : fail(),
        exists: (path) => false,
        listDir: (path) => const <FileSystemEntity>[],
      );
      expect(await locator.isInstalled(), isTrue);
    });

    test('the installer directory layout counts', () async {
      final dir = Directory.systemTemp
          .createTempSync('Cisco Packet Tracer 8.2');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bin = Directory('${dir.path}${Platform.pathSeparator}bin')
        ..createSync();
      File('${bin.path}${Platform.pathSeparator}PacketTracer.exe')
          .writeAsStringSync('');
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async => fail(),
        exists: (path) =>
            path.endsWith('.exe') || path.startsWith(r'C:\Program Files'),
        listDir: (path) => [dir],
      );
      expect(await locator.isInstalled(), isTrue);
    });

    test('the answer is computed once and cached', () async {
      var regCalls = 0;
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async {
          if (exe == 'reg') regCalls++;
          return ok('found');
        },
      );
      expect(await locator.isInstalled(), isTrue);
      expect(await locator.isInstalled(), isTrue);
      expect(regCalls, 1, reason: 'the first probe settles it for the session');
      locator.resetForTest();
    });

    test('a crashing subprocess is "not found", not an error', () async {
      final locator = PacketTracerLocator(
        forcePlatform: 'windows',
        runProcess: (exe, args) async => throw StateError('no shell'),
        exists: (path) => false,
        listDir: (path) => const <FileSystemEntity>[],
      );
      expect(await locator.isInstalled(), isFalse);
    });

    test('Linux: which finds packettracer', () async {
      final locator = PacketTracerLocator(
        forcePlatform: 'linux',
        runProcess: (exe, args) async => ok('/usr/bin/packettracer'),
      );
      expect(await locator.isInstalled(), isTrue);
    });
  });
}
