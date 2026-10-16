# Bus Board (ESP32 + SSD1306)

Polls `GET https://YOUR-GHOSTBUS-WORKER.workers.dev/api/departures?stop=17941&route=E`
every 60s and shows the next 2 E Line departures (route, headsign, minutes, LIVE/SCHED).

JSON shape: `{stop_id, stop_name, generated_at, ttl_s, departures:[{route, headsign,
direction, departs_in_min, departure_text, live, vehicle_id, trip_id}]}`.

## Wiring (default ESP32 I2C)

| OLED pin | ESP32 pin |
|----------|-----------|
| VCC      | 3V3       |
| GND      | GND       |
| SDA      | GPIO 21   |
| SCL      | GPIO 22   |

OLED I2C address: `0x3C`. Uses default `Wire` (SDA 21 / SCL 22).

## Libraries (Arduino IDE Library Manager)

- Adafruit SSD1306
- Adafruit GFX Library
- ArduinoJson (v6)

Board: ESP32 Dev Module.

## Config

Edit the top of [bus-board.ino](/Users/amin/development/musebar/esp32/bus-board/bus-board.ino):
`WIFI_SSID`, `WIFI_PASS`, `STOP_ID` (default `17941`), `ROUTE` (default `E`).

## Behavior

- WiFi reconnect on every poll if disconnected.
- HTTP 5xx: after 3 consecutive fails, back off to 5 min.
- Empty `departures`: shows `No buses / E Line 17941`.
