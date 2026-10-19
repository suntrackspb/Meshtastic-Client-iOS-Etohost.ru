# EtohostMesh

Клиент Meshtastic для iPhone, iPad и Mac, интегрированный с зеркалом сети
[meshtastic-mqtt-mirror](https://github.com/suntrackspb/meshtastic-mqtt-mirror).

- Подключение к ноде по Bluetooth и Wi-Fi (TCP), MQTT Client Proxy.
- Общий чат и личные сообщения: эфир от ноды и сообщения с зеркала в одной ленте.
- Список нод с фильтрами, карточка ноды, traceroute, избранные и игнор.
- Настройки ноды — те же экраны и подписи, что в официальном клиенте.
- Работает на Mac (Mac Catalyst) с тем же интерфейсом; подключение к ноде по Wi-Fi проверено, по Bluetooth — пока нет.

## Установка

Готовые сборки — на странице [Releases](https://github.com/suntrackspb/Meshtastic-Client-iOS-Etohost.ru/releases).

**iPhone / iPad** — файл `EtohostMesh-<версия>-unsigned.ipa`. Сборка не подписана:
установите её через [AltStore](https://altstore.io) или [Sideloadly](https://sideloadly.io),
они подпишут приложение вашим Apple ID. С бесплатным Apple ID подпись действует 7 дней,
потом приложение нужно переподписать (AltStore делает это сам).

**Mac** — файл `EtohostMesh-<версия>-macOS.zip`. Распакуйте и перенесите `EtohostMesh.app`
в «Программы». Сборка не нотаризована, поэтому перед первым запуском выполните:

```sh
xattr -cr /Applications/EtohostMesh.app
```

или откройте приложение через правый клик → «Открыть». При первом поиске нод macOS спросит
доступ к Bluetooth — разрешите.

## Зеркало

[meshtastic-mqtt-mirror](https://github.com/suntrackspb/meshtastic-mqtt-mirror) — сервер, который
слушает MQTT Meshtastic и отдаёт сообщения и ноды сети по REST и WebSocket. Публичный экземпляр
работает на [m.etohost.ru](https://m.etohost.ru).

Клиент с ним работает так:
- сообщения из зеркала приходят в реальном времени (WebSocket) и попадают в ту же ленту, что эфир с ноды;
- список нод дополняется нодами, которые видит зеркало, даже без подключения к своей ноде;
- если у ноды нет публичного ключа в базе радио, ключ для личных сообщений берётся с зеркала;
- адрес зеркала меняется в «Настройки → Приложение», там же зеркало можно выключить.

## Сборка

Нужны Xcode 16+ и [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen
open EtohostMesh.xcodeproj
```

В `project.yml` укажите свой `DEVELOPMENT_TEAM` для подписи. Для Mac выберите в Xcode
destination «My Mac (Mac Catalyst)».

## Релизы

Воркфлоу [`.github/workflows/release.yml`](.github/workflows/release.yml) собирает
неподписанный `.ipa` и Mac-приложение (ad-hoc подпись) и создаёт **draft**-релиз с обоими файлами.

Запуск:
- пуш тега — версия берётся из тега:
  ```sh
  git tag v0.2.0
  git push origin v0.2.0
  ```
- вручную: Actions → Release → Run workflow (версию можно указать, пусто — из `project.yml`).

Номер сборки — номер запуска воркфлоу. После проверки файлов опубликуйте черновик на странице Releases.

## Лицензия

Часть кода (транспорт BLE/TCP, экраны настроек, MQTT-прокси и др.) взята из
[Meshtastic-Apple](https://github.com/meshtastic/Meshtastic-Apple), который распространяется
под GPL v3. Поэтому EtohostMesh целиком распространяется под
[GNU General Public License v3.0](LICENSE).

Meshtastic® — зарегистрированный товарный знак Meshtastic LLC. Проект не связан с Meshtastic LLC.
