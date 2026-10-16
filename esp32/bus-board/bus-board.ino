#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ArduinoJson.h>

// ---------------- Config ----------------
#define WIFI_SSID "YOUR_SSID"
#define WIFI_PASS "YOUR_PASSWORD"
#define STOP_ID "17941"
#define ROUTE "E"
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define POLL_INTERVAL_MS 60000UL
#define BACKOFF_INTERVAL_MS 300000UL  // 5 min after 3 consecutive 5xx fails

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

const char* HOST = "YOUR-GHOSTBUS-WORKER.workers.dev";
String url = String("https://") + HOST + "/api/departures?stop=" + STOP_ID + "&route=" + ROUTE;

int fail5xx = 0;
unsigned long nextPoll = 0;

void showLines(const char* l1, const char* l2 = "", const char* l3 = "", const char* l4 = "") {
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.println(l1);
  display.println(l2);
  display.println(l3);
  display.println(l4);
  display.display();
}

void ensureWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) delay(500);
}

void poll() {
  ensureWiFi();
  if (WiFi.status() != WL_CONNECTED) {
    showLines("WiFi down", "retrying...");
    return;
  }
  WiFiClientSecure client;
  client.setInsecure();  // no CA bundle on ESP32 for Workers cert
  HTTPClient http;
  http.setTimeout(15000);
  if (!http.begin(client, url)) {
    showLines("HTTP begin fail");
    return;
  }
  int code = http.GET();
  if (code >= 500 && code < 600) {
    fail5xx++;
    http.end();
    if (fail5xx >= 3) {
      nextPoll = millis() + BACKOFF_INTERVAL_MS;
      fail5xx = 0;
      showLines("Server error", "retry in 5 min");
    } else {
      showLines("Server error", ("HTTP " + String(code)).c_str(), "retry in 60s");
    }
    return;
  }
  if (code != 200) {
    http.end();
    showLines("HTTP error", ("code " + String(code)).c_str(), "retry in 60s");
    return;
  }
  fail5xx = 0;
  String body = http.getString();
  http.end();

  StaticJsonDocument<4096> doc;
  if (deserializeJson(doc, body)) {
    showLines("JSON parse err");
    return;
  }
  JsonArray deps = doc["departures"].as<JsonArray>();
  if (deps.size() == 0) {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 20);
    display.println("No buses");
    display.println("E Line 17941");
    display.display();
    return;
  }
  display.clearDisplay();
  display.setTextSize(1);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.println("E Line 17941");
  display.drawLine(0, 9, 128, 9, SSD1306_WHITE);
  int y = 13;
  for (int i = 0; i < 2 && i < (int)deps.size(); i++) {
    JsonObject d = deps[i];
    String route = d["route"] | "?";
    String head = d["headsign"] | "?";
    int mins = d["departs_in_min"] | -1;
    bool live = d["live"] | false;
    display.setCursor(0, y);
    display.print(route + " " + head.substring(0, 12));
    y += 10;
    display.setCursor(0, y);
    display.print(String(mins) + " min " + (live ? "LIVE" : "SCHED"));
    y += 12;
  }
  display.display();
}

void setup() {
  Serial.begin(115200);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);
  showLines("E Line 17941", "connecting...");
  ensureWiFi();
  poll();
  nextPoll = millis() + POLL_INTERVAL_MS;
}

void loop() {
  if ((long)(millis() - nextPoll) >= 0) {
    poll();
    if (nextPoll <= millis()) nextPoll = millis() + POLL_INTERVAL_MS;
  }
  delay(500);
}
