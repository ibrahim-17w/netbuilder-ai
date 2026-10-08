import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:net_builder/models/environment_profile.dart';
import 'package:net_builder/services/environment_profile_service.dart';
import 'package:net_builder/services/memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('EnvironmentProfileService.statedIn', () {
    test('reads venue, scale, budget and skill from one sentence', () {
      final p = EnvironmentProfileService.statedIn(
        "I'm a beginner setting up a home network for 40 users on a budget",
      );
      expect(p.venue, 'home');
      expect(p.scale, 40);
      expect(p.budget, true);
      expect(p.skill, 'beginner');
      expect(p.summaryLine, 'home, ~40 users, budget-conscious, beginner');
    });

    test('reads each venue the advisor knows', () {
      expect(
        EnvironmentProfileService.statedIn('this is for an office').venue,
        'office',
      );
      expect(
        EnvironmentProfileService.statedIn('a school with 300 students').venue,
        'school',
      );
      expect(
        EnvironmentProfileService.statedIn('a warehouse network').venue,
        'industrial',
      );
      expect(
        EnvironmentProfileService.statedIn('a cafe for customers').venue,
        'hospitality',
      );
      expect(
        EnvironmentProfileService.statedIn('a small clinic network').venue,
        'clinic',
      );
    });

    test('states nothing when the message says nothing about the site', () {
      expect(EnvironmentProfileService.statedIn('use OSPF').isEmpty, isTrue);
      expect(EnvironmentProfileService.statedIn('').isEmpty, isTrue);
    });

    test('a rejected count is not a scale', () {
      expect(
        EnvironmentProfileService.statedIn('not 6 access points').scale,
        0,
      );
    });

    test('skill: advanced wording wins over beginner wording', () {
      expect(
        EnvironmentProfileService.statedIn('I am no longer a beginner, I am '
            'an experienced network engineer').skill,
        'advanced',
      );
    });
  });

  test('learnFrom: the chat auto-learn step in one place', () {
    // First fact.
    final first = EnvironmentProfileService.learnFrom(
      'this is for the office, 20 users',
      null,
    );
    expect(first, isNotNull);
    expect(first!.venue, 'office');
    expect(first.scale, 20);
    expect(first.source, 'this is for the office, 20 users');

    // A second message adds a fact without erasing the first.
    final second = EnvironmentProfileService.learnFrom(
      "I'm a beginner by the way",
      first,
    );
    expect(second!.venue, 'office');
    expect(second.skill, 'beginner');

    // Re-stating a known fact is not news: null, so the chat stays quiet.
    final noNews = EnvironmentProfileService.learnFrom(
      'the office again',
      second,
    );
    expect(noNews, isNull);
  });

  group('EnvironmentProfile merge', () {
    const base = EnvironmentProfile(venue: 'office', scale: 40);

    test('stated fields win, unstated fields survive', () {
      final merged = base.merge(const EnvironmentProfile(scale: 60));
      expect(merged.venue, 'office');
      expect(merged.scale, 60);
    });

    test('a later message cannot erase what an earlier one learned', () {
      final merged = base.merge(const EnvironmentProfile(skill: 'beginner'));
      expect(merged.venue, 'office');
      expect(merged.scale, 40);
      expect(merged.skill, 'beginner');
    });

    test('sameFactsAs ignores timestamps and provenance', () {
      const a = EnvironmentProfile(venue: 'home');
      final b = a.merge(const EnvironmentProfile());
      expect(b.sameFactsAs(a), isTrue);
      expect(a.sameFactsAs(const EnvironmentProfile(venue: 'office')), isFalse);
    });

    test('JSON round trip, and a corrupt row decodes to null', () {
      const p = EnvironmentProfile(
        venue: 'school',
        scale: 300,
        budget: false,
        skill: 'intermediate',
        updatedAt: '2026-10-07T10:00:00',
        source: 'the chat',
      );
      final decoded = EnvironmentProfile.tryDecode(jsonEncode(p.toJson()));
      expect(decoded, isNotNull);
      expect(decoded!.venue, 'school');
      expect(decoded.scale, 300);
      expect(decoded.budget, false);
      expect(decoded.skill, 'intermediate');
      expect(EnvironmentProfile.tryDecode('not json'), isNull);
      expect(EnvironmentProfile.tryDecode(''), isNull);
    });
  });

  group('MemoryService environment store', () {
    Future<MemoryService> fresh() async {
      final dir = await Directory.systemTemp.createTemp('nb-env-test');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
      final db = await databaseFactoryFfi.openDatabase('${dir.path}/env.db');
      await MemoryService.createSchema(db);
      return MemoryService(injected: db);
    }

    test('set, read, forget', () async {
      final mem = await fresh();
      expect(await mem.environmentProfile(), isNull);
      await mem.setEnvironmentProfile(const EnvironmentProfile(
        venue: 'office',
        scale: 20,
        source: 'this is for the office, 20 users',
      ));
      final stored = await mem.environmentProfile();
      expect(stored, isNotNull);
      expect(stored!.venue, 'office');
      expect(stored.scale, 20);
      expect(stored.source, 'this is for the office, 20 users');
      expect(stored.updatedAt, isNotEmpty);
      await mem.forgetEnvironmentProfile();
      expect(await mem.environmentProfile(), isNull);
    });

    test('set writes the profile it is given: merging is the caller\'s job',
        () async {
      // The chat hook merges before writing ([EnvironmentProfile.merge]);
      // the Memory screen writes the whole edited profile. A raw partial
      // write therefore replaces wholesale - the store never invents facts.
      final mem = await fresh();
      await mem.setEnvironmentProfile(const EnvironmentProfile(
        venue: 'office',
        scale: 50,
      ));
      final stored = await mem.environmentProfile();
      expect(stored!.venue, 'office');
      expect(stored.scale, 50);
    });

    test('a corrupt stored row reads as nothing learned', () async {
      final mem = await fresh();
      final db = mem.injected!;
      await db.insert('environment_profile', {
        'id': 1,
        'json': '{broken',
        'updatedAt': 'x',
      });
      expect(await mem.environmentProfile(), isNull);
    });

    test('export carries the profile and a bumped schema version', () async {
      final mem = await fresh();
      await mem.setEnvironmentProfile(const EnvironmentProfile(venue: 'home'));
      final doc =
          jsonDecode(await mem.exportJson()) as Map<String, dynamic>;
      // v3 introduced the profile; v4 added the clarification answers.
      expect(doc['schemaVersion'], greaterThanOrEqualTo(3));
      expect((doc['environmentProfile'] as Map)['venue'], 'home');
    });

    test('clearAll forgets the environment too', () async {
      final mem = await fresh();
      await mem.setEnvironmentProfile(const EnvironmentProfile(venue: 'home'));
      await mem.clearAll();
      expect(await mem.environmentProfile(), isNull);
    });
  });
}
