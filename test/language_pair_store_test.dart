import 'package:flutter_test/flutter_test.dart';
import 'package:realtime_translation/preferences/language_pair_store.dart';

void main() {
  test('stores both language codes as one atomic preference value', () async {
    final _MemoryStringPreferences preferences = _MemoryStringPreferences();
    final SharedPreferencesLanguagePairStore store =
        SharedPreferencesLanguagePairStore(preferences: preferences);

    await store.write(
      const StoredLanguagePair(languageA: 'zh-Hans', languageB: 'en'),
    );
    final StoredLanguagePair? restored = await store.read();

    expect(preferences.values, hasLength(1));
    expect(restored?.languageA, 'zh-Hans');
    expect(restored?.languageB, 'en');
  });

  test('rejects malformed or incomplete persisted values', () async {
    final _MemoryStringPreferences preferences = _MemoryStringPreferences();
    final SharedPreferencesLanguagePairStore store =
        SharedPreferencesLanguagePairStore(preferences: preferences);

    for (final String invalid in <String>[
      'not-json',
      '[]',
      '["en"]',
      '["en", 42]',
      '["en", "fr", "de"]',
      '{"a":"en","b":"fr"}',
    ]) {
      preferences.values['translation_language_pair_v1'] = invalid;
      expect(await store.read(), isNull, reason: invalid);
    }
  });
}

class _MemoryStringPreferences implements StringPreferenceGateway {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}
