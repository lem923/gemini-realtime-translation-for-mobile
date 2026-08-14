class TranslationLanguage {
  const TranslationLanguage({
    required this.code,
    required this.name,
    required this.flag,
  });

  final String code;
  final String name;
  final String flag;

  String get label => '$flag  $name';
}

// BCP-47 codes documented by Google for Gemini Live Translation.
const List<TranslationLanguage> supportedLanguages = <TranslationLanguage>[
  TranslationLanguage(code: 'af', name: 'Afrikaans', flag: '🇿🇦'),
  TranslationLanguage(code: 'ak', name: 'Akan', flag: '🇬🇭'),
  TranslationLanguage(code: 'sq', name: 'Albanian', flag: '🇦🇱'),
  TranslationLanguage(code: 'am', name: 'Amharic', flag: '🇪🇹'),
  TranslationLanguage(code: 'ar', name: 'Arabic', flag: '🇸🇦'),
  TranslationLanguage(code: 'hy', name: 'Armenian', flag: '🇦🇲'),
  TranslationLanguage(code: 'az', name: 'Azerbaijani', flag: '🇦🇿'),
  TranslationLanguage(code: 'eu', name: 'Basque', flag: '🇪🇺'),
  TranslationLanguage(code: 'be', name: 'Belarusian', flag: '🇧🇾'),
  TranslationLanguage(code: 'bn', name: 'Bengali', flag: '🇧🇩'),
  TranslationLanguage(code: 'bg', name: 'Bulgarian', flag: '🇧🇬'),
  TranslationLanguage(code: 'my', name: 'Burmese', flag: '🇲🇲'),
  TranslationLanguage(code: 'ca', name: 'Catalan', flag: '🇪🇸'),
  TranslationLanguage(code: 'zh-Hans', name: '简体中文', flag: '🇨🇳'),
  TranslationLanguage(code: 'zh-Hant', name: '繁體中文', flag: '🇭🇰'),
  TranslationLanguage(code: 'hr', name: 'Croatian', flag: '🇭🇷'),
  TranslationLanguage(code: 'cs', name: 'Czech', flag: '🇨🇿'),
  TranslationLanguage(code: 'da', name: 'Danish', flag: '🇩🇰'),
  TranslationLanguage(code: 'nl', name: 'Dutch', flag: '🇳🇱'),
  TranslationLanguage(code: 'en', name: 'English', flag: '🇺🇸'),
  TranslationLanguage(code: 'et', name: 'Estonian', flag: '🇪🇪'),
  TranslationLanguage(code: 'fil', name: 'Filipino', flag: '🇵🇭'),
  TranslationLanguage(code: 'fi', name: 'Finnish', flag: '🇫🇮'),
  TranslationLanguage(code: 'fr', name: 'French', flag: '🇫🇷'),
  TranslationLanguage(code: 'gl', name: 'Galician', flag: '🇪🇸'),
  TranslationLanguage(code: 'ka', name: 'Georgian', flag: '🇬🇪'),
  TranslationLanguage(code: 'de', name: 'German', flag: '🇩🇪'),
  TranslationLanguage(code: 'el', name: 'Greek', flag: '🇬🇷'),
  TranslationLanguage(code: 'gu', name: 'Gujarati', flag: '🇮🇳'),
  TranslationLanguage(code: 'ha', name: 'Hausa', flag: '🇳🇬'),
  TranslationLanguage(code: 'he', name: 'Hebrew', flag: '🇮🇱'),
  TranslationLanguage(code: 'hi', name: 'Hindi', flag: '🇮🇳'),
  TranslationLanguage(code: 'hu', name: 'Hungarian', flag: '🇭🇺'),
  TranslationLanguage(code: 'is', name: 'Icelandic', flag: '🇮🇸'),
  TranslationLanguage(code: 'id', name: 'Indonesian', flag: '🇮🇩'),
  TranslationLanguage(code: 'it', name: 'Italian', flag: '🇮🇹'),
  TranslationLanguage(code: 'ja', name: '日本語', flag: '🇯🇵'),
  TranslationLanguage(code: 'jv', name: 'Javanese', flag: '🇮🇩'),
  TranslationLanguage(code: 'kn', name: 'Kannada', flag: '🇮🇳'),
  TranslationLanguage(code: 'kk', name: 'Kazakh', flag: '🇰🇿'),
  TranslationLanguage(code: 'km', name: 'Khmer', flag: '🇰🇭'),
  TranslationLanguage(code: 'rw', name: 'Kinyarwanda', flag: '🇷🇼'),
  TranslationLanguage(code: 'ko', name: '한국어', flag: '🇰🇷'),
  TranslationLanguage(code: 'lo', name: 'Lao', flag: '🇱🇦'),
  TranslationLanguage(code: 'lv', name: 'Latvian', flag: '🇱🇻'),
  TranslationLanguage(code: 'lt', name: 'Lithuanian', flag: '🇱🇹'),
  TranslationLanguage(code: 'mk', name: 'Macedonian', flag: '🇲🇰'),
  TranslationLanguage(code: 'ms', name: 'Malay', flag: '🇲🇾'),
  TranslationLanguage(code: 'ml', name: 'Malayalam', flag: '🇮🇳'),
  TranslationLanguage(code: 'mr', name: 'Marathi', flag: '🇮🇳'),
  TranslationLanguage(code: 'mn', name: 'Mongolian', flag: '🇲🇳'),
  TranslationLanguage(code: 'ne', name: 'Nepali', flag: '🇳🇵'),
  TranslationLanguage(code: 'no', name: 'Norwegian', flag: '🇳🇴'),
  TranslationLanguage(code: 'fa', name: 'Persian', flag: '🇮🇷'),
  TranslationLanguage(code: 'pl', name: 'Polish', flag: '🇵🇱'),
  TranslationLanguage(code: 'pt-BR', name: 'Português (Brasil)', flag: '🇧🇷'),
  TranslationLanguage(
    code: 'pt-PT',
    name: 'Português (Portugal)',
    flag: '🇵🇹',
  ),
  TranslationLanguage(code: 'pa', name: 'Punjabi', flag: '🇮🇳'),
  TranslationLanguage(code: 'ro', name: 'Romanian', flag: '🇷🇴'),
  TranslationLanguage(code: 'ru', name: 'Русский', flag: '🇷🇺'),
  TranslationLanguage(code: 'sr', name: 'Serbian', flag: '🇷🇸'),
  TranslationLanguage(code: 'sd', name: 'Sindhi', flag: '🇵🇰'),
  TranslationLanguage(code: 'si', name: 'Sinhala', flag: '🇱🇰'),
  TranslationLanguage(code: 'sk', name: 'Slovak', flag: '🇸🇰'),
  TranslationLanguage(code: 'sl', name: 'Slovenian', flag: '🇸🇮'),
  TranslationLanguage(code: 'es', name: 'Español', flag: '🇪🇸'),
  TranslationLanguage(code: 'su', name: 'Sundanese', flag: '🇮🇩'),
  TranslationLanguage(code: 'sw', name: 'Swahili', flag: '🇰🇪'),
  TranslationLanguage(code: 'sv', name: 'Swedish', flag: '🇸🇪'),
  TranslationLanguage(code: 'ta', name: 'Tamil', flag: '🇮🇳'),
  TranslationLanguage(code: 'te', name: 'Telugu', flag: '🇮🇳'),
  TranslationLanguage(code: 'th', name: 'ไทย', flag: '🇹🇭'),
  TranslationLanguage(code: 'tr', name: 'Türkçe', flag: '🇹🇷'),
  TranslationLanguage(code: 'uk', name: 'Ukrainian', flag: '🇺🇦'),
  TranslationLanguage(code: 'ur', name: 'Urdu', flag: '🇵🇰'),
  TranslationLanguage(code: 'uz', name: 'Uzbek', flag: '🇺🇿'),
  TranslationLanguage(code: 'vi', name: 'Tiếng Việt', flag: '🇻🇳'),
  TranslationLanguage(code: 'zu', name: 'Zulu', flag: '🇿🇦'),
];

TranslationLanguage languageByCode(String code) {
  return tryLanguageByCode(code) ?? supportedLanguages.first;
}

TranslationLanguage? tryLanguageByCode(String code) {
  final String normalized = switch (code) {
    'nb' => 'no',
    'iw' => 'he',
    'zh' => 'zh-Hans',
    'pt' => 'pt-BR',
    _ => code,
  };
  for (final TranslationLanguage language in supportedLanguages) {
    if (language.code == normalized) {
      return language;
    }
  }
  return null;
}
