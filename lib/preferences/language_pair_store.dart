import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StoredLanguagePair {
  const StoredLanguagePair({required this.languageA, required this.languageB});

  final String languageA;
  final String languageB;
}

abstract interface class LanguagePairStore {
  Future<StoredLanguagePair?> read();
  Future<void> write(StoredLanguagePair pair);
}

class DisabledLanguagePairStore implements LanguagePairStore {
  const DisabledLanguagePairStore();

  @override
  Future<StoredLanguagePair?> read() async => null;

  @override
  Future<void> write(StoredLanguagePair pair) async {}
}

abstract interface class StringPreferenceGateway {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
}

class SharedPreferencesStringGateway implements StringPreferenceGateway {
  SharedPreferencesStringGateway({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<String?> getString(String key) => _preferences.getString(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);
}

class SharedPreferencesLanguagePairStore implements LanguagePairStore {
  SharedPreferencesLanguagePairStore({StringPreferenceGateway? preferences})
    : _preferences = preferences ?? SharedPreferencesStringGateway();

  static const String _storageKey = 'translation_language_pair_v1';
  final StringPreferenceGateway _preferences;

  @override
  Future<StoredLanguagePair?> read() async {
    final String? encoded = await _preferences.getString(_storageKey);
    if (encoded == null) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List<Object?> ||
          decoded.length != 2 ||
          decoded[0] is! String ||
          decoded[1] is! String) {
        return null;
      }
      return StoredLanguagePair(
        languageA: decoded[0]! as String,
        languageB: decoded[1]! as String,
      );
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(StoredLanguagePair pair) {
    return _preferences.setString(
      _storageKey,
      jsonEncode(<String>[pair.languageA, pair.languageB]),
    );
  }
}
