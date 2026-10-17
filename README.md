# EtohostMesh

iOS-клиент Meshtastic, интегрированный с зеркалом сети
[meshtastic-mqtt-mirror](https://github.com/suntrackspb/meshtastic-mqtt-mirror).

- Подключение к ноде по Bluetooth и Wi-Fi (TCP), MQTT Client Proxy.
- Общий чат и личные сообщения: эфир от ноды и сообщения с зеркала в одной ленте.
- Список нод с фильтрами, карточка ноды, traceroute, избранные и игнор.
- Настройки ноды — те же экраны и подписи, что в официальном клиенте.

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

В `project.yml` укажите свой `DEVELOPMENT_TEAM` для подписи.

## Лицензия

Часть кода (транспорт BLE/TCP, экраны настроек, MQTT-прокси и др.) взята из
[Meshtastic-Apple](https://github.com/meshtastic/Meshtastic-Apple), который распространяется
под GPL v3. Поэтому EtohostMesh целиком распространяется под
[GNU General Public License v3.0](LICENSE).

Meshtastic® — зарегистрированный товарный знак Meshtastic LLC. Проект не связан с Meshtastic LLC.
