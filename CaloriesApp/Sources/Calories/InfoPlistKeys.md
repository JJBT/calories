## Info.plist keys

Для записи аудио добавь в Info.plist:
- `NSMicrophoneUsageDescription` = "Нужен доступ к микрофону для голосового ввода еды"

Для фото-пикера обычно достаточно системного PHPicker (без отдельного Photo Library permission), но если будешь использовать прямой доступ к фотобиблиотеке/камере — добавим позже.

## Build settings

Если используешь `Config.xcconfig`, добавь в Info.plist пользовательские ключи:
- `OPENAI_API_KEY` (String)
- `OPENAI_MODEL` (String)
- `OPENAI_TRANSCRIBE_MODEL` (String)

И привяжи значения через build setting substitution (Xcode сам подставит из xcconfig).
