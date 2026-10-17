# EtohostMesh

iOS-клиент Meshtastic с зеркалом сети через [mesh-mirror](https://m.etohost.ru).

- Подключение к ноде по Bluetooth и Wi-Fi (TCP), MQTT Client Proxy.
- Общий чат и личные сообщения: эфир от ноды и сообщения с зеркала в одной ленте.
- Список нод с фильтрами, карточка ноды, traceroute, избранные и игнор.
- Настройки ноды — те же экраны и подписи, что в официальном клиенте.

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
