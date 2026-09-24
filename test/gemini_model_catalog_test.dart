import 'package:flutter_test/flutter_test.dart';
import 'package:net_builder/services/gemini_model_catalog.dart';

void main() {
  // A trimmed-down ListModels response in Google's actual shape.
  const body = '''
{
  "models": [
    {
      "name": "models/gemini-2.5-flash",
      "displayName": "Gemini 2.5 Flash",
      "description": "Stable, fast and versatile.",
      "supportedGenerationMethods": ["generateContent", "streamGenerateContent", "countTokens"],
      "inputTokenLimit": 1048576,
      "outputTokenLimit": 65536
    },
    {
      "name": "models/gemini-2.5-pro",
      "displayName": "Gemini 2.5 Pro",
      "description": "Our most powerful thinking model.",
      "supportedGenerationMethods": ["generateContent", "streamGenerateContent"],
      "inputTokenLimit": 1048576,
      "outputTokenLimit": 65536
    },
    {
      "name": "models/gemini-2.0-flash-exp",
      "displayName": "Gemini 2.0 Flash Experimental",
      "description": "Experimental preview release.",
      "supportedGenerationMethods": ["generateContent"],
      "inputTokenLimit": 1000000
    },
    {
      "name": "models/text-embedding-004",
      "description": "Embeddings.",
      "supportedGenerationMethods": ["embedContent"]
    },
    {
      "name": "models/imagen-3.0-generate-002",
      "description": "Image generation.",
      "supportedGenerationMethods": ["predict"]
    },
    {
      "name": "models/gemma-3-27b-it",
      "description": "Open model.",
      "supportedGenerationMethods": ["generateContent"]
    },
    {
      "name": "models/gemini-1.5-flash-8b",
      "description": "Older stable model.",
      "supportedGenerationMethods": ["generateContent"],
      "inputTokenLimit": 1048576
    }
  ]
}
''';

  group('parseListModels', () {
    test('parses names, display names, methods and limits', () {
      final models = GeminiModelCatalog.parseListModels(body);
      final flash = models.firstWhere((m) => m.name == 'gemini-2.5-flash');
      expect(flash.displayName, 'Gemini 2.5 Flash');
      expect(flash.supportsChat, isTrue);
      expect(flash.supportsStreaming, isTrue);
      expect(flash.inputTokenLimit, 1048576);
    });

    test('returns empty on garbage input instead of throwing', () {
      expect(GeminiModelCatalog.parseListModels('not json'), isEmpty);
    });
  });

  group('isChatModel', () {
    test('keeps Gemini generateContent models', () {
      final models = GeminiModelCatalog.parseListModels(body);
      final flash = models.firstWhere((m) => m.name == 'gemini-2.5-flash');
      expect(GeminiModelCatalog.isChatModel(flash), isTrue);
    });

    test('drops embeddings, image models, gemma, and non-chat verbs', () {
      final models = GeminiModelCatalog.parseListModels(body);
      final byName = {for (final m in models) m.name: m};
      expect(GeminiModelCatalog.isChatModel(byName['text-embedding-004']!), isFalse);
      expect(GeminiModelCatalog.isChatModel(byName['imagen-3.0-generate-002']!), isFalse);
      expect(GeminiModelCatalog.isChatModel(byName['gemma-3-27b-it']!), isFalse);
    });
  });

  group('recommend', () {
    test('recommends the latest stable generation, pro before flash', () {
      final models = GeminiModelCatalog.parseListModels(body);
      expect(GeminiModelCatalog.recommend(models)!.name, 'gemini-2.5-pro');
    });

    test('never recommends an experimental model while a stable one exists',
        () {
      final models = GeminiModelCatalog.parseListModels('''
{
  "models": [
    {
      "name": "models/gemini-3.0-flash-exp",
      "description": "Experimental.",
      "supportedGenerationMethods": ["generateContent"]
    },
    {
      "name": "models/gemini-2.5-flash",
      "description": "Stable.",
      "supportedGenerationMethods": ["generateContent"]
    }
  ]
}
''');
      expect(GeminiModelCatalog.recommend(models)!.name, 'gemini-2.5-flash');
    });

    test('returns null for an empty list', () {
      expect(GeminiModelCatalog.recommend(const []), isNull);
    });
  });

  group('version and ranking', () {
    test('parses version families as sortable numbers', () {
      final models = GeminiModelCatalog.parseListModels(body);
      final flash25 = models.firstWhere((m) => m.name == 'gemini-2.5-flash');
      final flash15 = models.firstWhere((m) => m.name == 'gemini-1.5-flash-8b');
      expect(flash25.version, 2.5);
      expect(flash15.version, 1.5);
      expect(flash25.rankScore, greaterThan(flash15.rankScore));
    });
  });
}
