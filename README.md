# OGX-Mini
![OGX-Mini Boards](images/OGX-Mini-github.jpg "OGX-Mini Boards")

## Schnellanleitung: Pico 2 W + Bluetooth-Controller an der PS3

Dieser Fork ist auf ein Setup zugeschnitten: **Raspberry Pi Pico 2 W** als Adapter,
ein **Bluetooth-Controller** (getestet mit Xbox Elite Series 2), Ausgabe an die
**PlayStation 3**. Die Original-Dokumentation (englisch) folgt weiter unten.

Gegenüber dem Original ändert der Fork:

- **L2/R2 sind an der PS3 analog.** Bisher kam nur „gedrückt/nicht gedrückt“ an,
  Spiele wie Gran Turismo bekamen kein abgestuftes Gas und keine abgestufte Bremse.
  Jetzt liefern LT/RT Druckwerte von 1 bis 255.
- **Die Druckwerte von ✕, ○ und □ waren vertauscht** (A meldete den Druck von □,
  B den von ✕, X den von ○). Behoben.
- **Baut mit GCC 16** (fehlendes `#include <algorithm>` in `TaskQueue.h`).

Beides wurde an den USB-Rohdaten nachgemessen, das L2/R2-Verhalten zusätzlich
gegen einen echten DualShock 3: Das L2-Bit geht beim ersten Druckwert über 0 an
und bei 0 wieder aus, ohne Hysterese. Genau so verhält sich jetzt auch der Pico.

### Kurzweg: bauen und flashen per Script

```zsh
sudo pacman -S --needed git cmake ninja python arm-none-eabi-gcc arm-none-eabi-newlib udisks2
git clone --recursive https://github.com/blackbunt/OGX-Mini.git
cd OGX-Mini/Firmware/RP2040
./build-and-flash.sh
```

Das Script fragt, für welchen Pi gebaut wird (Pico, Pico 2, Pico W, Pico 2 W,
RP2040-Zero, Adafruit Feather), und erledigt dann den Rest:

- holt das pico-sdk 2.1.0, falls es fehlt, und baut mit dem GCC-16-Workaround
  in einem eigenen Ordner je Board (`build/<BOARD>`),
- fordert dazu auf, den Pico mit gedrückter **BOOTSEL**-Taste anzustecken, und
  wartet bis zu 2 Minuten auf das Laufwerk,
- bricht ab, wenn ein Pico mit dem anderen Chip steckt (Pico 2 meldet sich als
  `RP2350`, Pico 1 als `RPI-RP2`), statt die falsche Firmware aufzuspielen,
- kopiert die `.uf2` und meldet Erfolg, sobald der Pico neu gestartet ist.

Root-Rechte braucht es nicht, das Laufwerk hängt `udisksctl` ein.
Varianten: `./build-and-flash.sh PI_PICO2W` überspringt die Abfrage,
`--build-only` baut nur, `MAX_GAMEPADS=2 ./build-and-flash.sh` setzt die
Controller-Zahl (1 bis 4, Standard 1).

Danach weiter mit Schritt 3. Wer lieber von Hand baut, folgt Schritt 1 und 2.

### 1. Firmware bauen (Arch Linux)

```zsh
sudo pacman -S cmake ninja arm-none-eabi-gcc arm-none-eabi-newlib
git clone --recursive https://github.com/blackbunt/OGX-Mini.git
cd OGX-Mini
git clone --depth 1 --branch 2.1.0 --recurse-submodules --shallow-submodules \
    https://github.com/raspberrypi/pico-sdk.git Firmware/external/pico-sdk
cd Firmware/RP2040
cmake -S . -B build -G Ninja -DPICO_SDK_PATH="$PWD/../external/pico-sdk" \
      -DCMAKE_BUILD_TYPE=Release -DOGXM_BOARD=PI_PICO2W -DMAX_GAMEPADS=1
CXXFLAGS="-include cstdint" cmake --build build
```

Ergebnis: `build/OGX-Mini-v1.0.0a3-PI_PICO2W.uf2`.

- `CXXFLAGS="-include cstdint"` ist nötig, weil das SDK-Werkzeug `pioasm` (SDK 2.1.0)
  mit GCC 16 sonst nicht baut. Die Variable wirkt nur auf die Hilfswerkzeuge,
  die beim Bauen konfiguriert werden, nicht auf die Firmware selbst.
- Der Build patcht das Submodul `bluepad32` absichtlich. Diese Änderung **nicht**
  committen.

### 2. Flashen

1. **BOOTSEL** am Pico gedrückt halten, Pico per USB an den PC stecken, loslassen.
2. Die `.uf2` auf das Laufwerk `RP2350` kopieren. Der Pico startet von selbst neu.

### 3. PS3-Modus einstellen (einmalig)

Ab Werk emuliert die Firmware einen Original-Xbox-Controller. Bei verbundenem
Controller **Menü (☰) + Steuerkreuz links 3 Sekunden halten**. Der Pico speichert
den Modus und startet neu. Er bleibt auch nach dem Ausstecken und nach einem
Firmware-Update im PS3-Modus (beobachtet beim Wechsel von Release alpha3 auf diesen Fork).

Danach den Pico per USB an die PS3 stecken. Die Xbox-Taste ist die PS-Taste.

### 4. Controller koppeln

Die LED am Pico zeigt den Zustand:

| LED | Bedeutung |
|---|---|
| blinkt | kein Controller verbunden, Pico sucht |
| leuchtet dauerhaft | Controller verbunden |

**Der Pico nimmt immer Kopplungen an**, es gibt keinen eigenen Pairing-Modus am Pico.
Er merkt sich gekoppelte Controller, die sich später von selbst wieder verbinden.

**Es ist immer nur ein Controller aktiv** (Build mit `MAX_GAMEPADS=1`). Laut Code
(`Bluepad32.cpp`, nicht ausprobiert) kann sich ein zweiter Controller zwar per
Bluetooth verbinden, seine Eingaben werden aber ignoriert, solange der erste
verbunden ist. Zum Wechseln:

1. Den bisherigen Controller **ausschalten** (Xbox-Controller: Xbox-Taste gedrückt
   halten, bis sie erlischt).
2. Warten, bis die LED am Pico **blinkt**.
3. Den neuen Controller in den Kopplungsmodus bringen:

| Controller | Kopplungsmodus |
|---|---|
| Xbox Series / One (Bluetooth) / Elite 2 | Kopplungstaste oben halten, bis das Xbox-Logo schnell blinkt |
| DualShock 4 | **Share + PS** halten, bis die Lichtleiste schnell blinkt |
| DualSense | **Create + PS** halten, bis das Licht schnell blinkt |
| Switch Pro | Sync-Taste oben neben dem USB-Anschluss halten |
| 8BitDo | je nach Modell verschieden, siehe Anleitung des Controllers bzw. Bluepad32-Liste unten |
| DualShock 3 | lässt sich nicht per Tastendruck koppeln, an der PS3 einfach direkt benutzen |

4. Sobald die LED dauerhaft leuchtet, ist der neue Controller aktiv.

Weitere Controller und Details: [Bluepad32 – Supported gamepads](https://bluepad32.readthedocs.io/en/latest/supported_gamepads/).

### 5. Belegung an der PS3

| Xbox | PS3 | analog |
|---|---|---|
| A / B / X / Y | ✕ / ○ / □ / △ | nein, nur 0 oder 255 (der Xbox-Controller misst dort keinen Druck) |
| LB / RB | L1 / R1 | nein |
| **LT / RT** | **L2 / R2** | **ja, 1 bis 255** |
| Sticks, L3 / R3 | Sticks, L3 / R3 | ja |
| Steuerkreuz | Steuerkreuz | nein |
| Ansicht (⧉) / Menü (☰) / Xbox | Select / Start / PS | – |

### 6. Feinschliff in der Web-App

[Web-App](https://wiredopposite.github.io/OGX-Mini-WebApp/) öffnen und per Bluetooth
verbinden (beim Pico 2 W ohne Tastenkombination).

- **Trigger-Deadzone auf etwa 1 % setzen.** Der Abzug des Elite rauscht kurz über dem
  Nullpunkt (Werte 1 bis 2). Ohne Deadzone kann das L2/R2-Bit beim langsamen Loslassen
  mehrmals hintereinander an- und ausgehen. Die Firmware selbst bleibt dabei
  originalgetreu.

### Bekannte Eigenheiten

- **Am Linux-PC vibriert der Controller dauerhaft**, sobald der Pico im PS3-Modus
  angesteckt wird. An der PS3 passiert das nicht. Die Vibration endet, sobald der
  PC einen neuen Vibrationsbefehl schickt. Ursache noch nicht geklärt.
- Nach dem Flashen startet der Pico unter Umständen im Original-Xbox-Modus.
  Dann Schritt 3 wiederholen.

Firmware for the RP2040, capable of emulating gamepads for several game consoles. The firmware comes in many flavors, supported on the [Adafruit Feather USB Host board](https://www.adafruit.com/product/5723), Pi Pico, Pi Pico 2, Pi Pico W, Pi Pico 2 W, Waveshare RP2040-Zero, Pico/ESP32 hybrid, and a 4-Channel RP2040-Zero setup.

[**Visit the web app here**](https://wiredopposite.github.io/OGX-Mini-WebApp/) to change your mappings and deadzone settings. To pair the OGX-Mini with the web app via USB, plug your controller in, then connect it to your PC, hold **Start + Left Bumper + Right Bumper** to enter web app mode. Click "Connect via USB" in the web app and select the OGX-Mini. You can also pair via Bluetooth, no extra steps are needed in that case. 

## Supported platforms
- Original Xbox
- Playstation 3
- Nintendo Switch (docked)
- XInput (use [**UsbdSecPatch**](https://github.com/InvoxiPlayGames/UsbdSecPatch) for Xbox 360, or select the patch in J-Runner while flashing your NAND)
- Playstation Classic
- DInput

## Changing platforms
By default the OGX-Mini will emulate an OG Xbox controller, you must hold a button combo for 3 seconds to change which platform you want to play on. Your chosen mode will persist after powering off the device. 

Start = Plus (Switch) = Options (Dualsense/DS4)

- XInput
    - Start + Dpad Up 
- Original Xbox
    - Start + Dpad Right
- Original Xbox Steel Battalion
    - Start + Dpad Right + Right Bumper
- Original Xbox DVD Remote
    - Start + Dpad Right + Left Bumper
- Switch
    - Start + Dpad Down
- PlayStation 3
    - Start + Dpad Left
- PlayStation Classic
    - Start + A (Cross for PlayStation and B for Switch gamepads)
- Web Application Mode
    - Start + Left Bumper + Right Bumper

After a new mode is stored, the RP2040 will reset itself so you don't need to unplug it.

## Supported devices
### Wired controllers
- Original Xbox Duke and S
- Xbox 360, One, Series, and Elite
- Dualshock 3 (PS3)
- Dualshock 4 (PS4)
- Dualsense (PS5)
- Nintendo Switch Pro
- Nintendo Switch wired
- Nintendo 64 Generic USB
- Playstation Classic
- Generic DInput
- Generic HID (mappings may need to be editted in the web app)

Note: There are some third party controllers that can change their VID/PID, these might not work correctly.

### Wireless adapters
- Xbox 360 PC adapter (Microsoft or clones)
- 8Bitdo v1 and v2 Bluetooth adapters (set to XInput mode)
- Most wireless adapters that present themselves as Switch/XInput/PlayStation controllers should work

### Wireless Bluetooth controllers (Pico W & ESP32)
**Note:** Bluetooth functionality is in early testing, some may have quirks.
- Xbox Series, One, and Elite 2
- Dualshock 3
- Dualshock 4
- Dualsense
- Switch Pro
- Steam
- Stadia
- And more

Please visit [**this page**](https://bluepad32.readthedocs.io/en/latest/supported_gamepads/) for a more comprehensive list of supported controllers and Bluetooth pairing instructions.

## Features new to v1.0.0
- Bluetooth functionality for the Pico W, Pico 2 W, and Pico+ESP32.
- Web application (connectable via USB or Bluetooth) for configuring deadzones and buttons mappings, supports up to 8 saved profiles.
- Pi Pico 2 and Pico 2 W (RP2350) support.
- Reduced latency by about 3-4 ms, graphs showing comparisons are coming.
- 4 channel functionality, connect 4 Picos and use one Xbox 360 wireless adapter to control all 4.
- Delayed USB mount until a controller is plugged in, useful for internal installation (non-Bluetooth boards only). 
- Generic HID controller support.
- Dualshock 3 emulation (minus gyros), rumble now works.
- Steel Battalion controller emulation with a wireless Xbox 360 chatpad.
- Xbox DVD dongle emulation. You must provide or dump your own dongle firmware, see the Tools directory.
- Analog button support on OG Xbox and PS3.
- RGB LED support for RP2040-Zero and Adafruit Feather boards.

## Planned additions
- More accurate report parser for unknown HID controllers
- Hardware design for internal OG Xbox install
- Hardware design for 4 channel RP2040-Zero adapter
- Wired Xbox 360 chatpad support
- Wired Xbox One chatpad support
- Switch (as input) rumble support
- OG Xbox communicator support (in some form)
- Generic bluetooth dongle support
- Button macros
- Rumble settings (intensity, enabled/disable, etc.)

## Hardware
For Pi Pico, RP2040-Zero, 4 channel, and ESP32 configurations, please see the hardware folder for diagrams.

I've designed a PCB for the RP2040-Zero so you can make a small form-factor adapter yourself. The gerber files, schematic, and BOM are in Hardware folder.

<img src="images/OGX-Mini-rpzero-int.jpg" alt="OGX-Mini Boards" width="400">

If you would like a prebuilt unit, you can purchase one, with cable and Xbox adapter included, from my [**Etsy store**](https://www.etsy.com/listing/1426992904/ogx-mini-controller-adapter-for-original).

## Adding supported controllers
If your third party controller isn't working, but the original version is listed above, send me the device's VID and PID and I'll add it so it's recognized properly.

## Build
### RP2040
You can compile this for different boards with the CMake argument ```OGXM_BOARD``` while configuring the project. 

The options are:
- ```PI_PICO``` 
- ```PI_PICO2``` 
- ```PI_PICOW``` 
- ```PI_PICO2W``` 
- ```RP2040_ZERO``` 
- ```ADAFRUIT_FEATHER``` 
- ```ESP32_BLUEPAD32_I2C```
- ```ESP32_BLUERETRO_I2C``` 
- ```EXTERNAL_4CH_I2C```

You can also set ```MAX_GAMEPADS``` which, if greater than one, will only support DInput (PS3) and Switch.

You'll need git, python3, CMake, Ninja and the GCC ARM toolchain installed. CMake scripts will patch some files in Bluepad32 and BTStack and also make sure all git submodules (plus their submodules and dependencies) are downloaded. Here's an example on Windows:
```
git clone --recursive https://github.com/wiredopposite/OGX-Mini.git
cd OGX-Mini/Firmware/RP2040
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DOGXM_BOARD=PI_PICOW -DMAX_GAMEPADS=1
cmake --build build
```
Or just install the GCC ARM toolchain and use the CMake Tools extension in VSCode.

### ESP32
Please see the Hardware directory for a diagram showing how to hookup the ESP32 to your RP2040.

You will need ESP-IDF v5.1, esptool, python3, and git installed. If you use VSCode, you can install the ESP-IDF extension and configure the project for ESP-IDF v5.1, it'll download everything for you and then you just click the build button at the bottom of the window.

When you build with ESP-IDF, Cmake will run a python script that copies the necessary BTStack files into the components directory, this is needed since BTStack isn't configured as an ESP-IDF component when you download it with git. 
