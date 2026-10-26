# Geometry Rush für den Kobo / KOReader / AppDock

Gleiche Architektur wie doom-kobo: ein Hintergrundprozess zeichnet und stellt das Bild über einen
VNC-Server bereit, der **nur auf 127.0.0.1:5963** lauscht. `lua/appdock_geodash.lua` zeigt das Bild
in KOReader und schickt Touch als Maus-/Tastenereignisse zurück.

Das Spiel ist **GeometryRush** (https://github.com/volinskii1405-ui/GeometryRush, C++17 + raylib,
alle Grafiken werden aus Primitiven gezeichnet, keine Bilddateien, 6 Levels, Editor). Es wird beim
Bauen geklont und **nicht verändert**. Gerendert wird mit **raylib 6.0** im Software-Renderer
(`PLATFORM=Memory`, `OPENGL_VERSION=Software`): kein OpenGL, kein Fenster, kein X11.

Die Brücke zwischen beiden ist `geodash/gd_shim.cpp`: Per Linker-Option `--wrap` werden
`InitWindow`, `EndDrawing`, `IsKeyDown`, `IsMouseButtonPressed` usw. des Spiels umgeleitet.
`geodash/gd_vnc.c` ist der VNC-Server (wie `doomgeneric_vnc.c`).

## Bauen (GitHub Actions)
1. Dieses Verzeichnis als Repo pushen (Branch `main`).
2. *Actions* → *Build Geometry Rush for Kobo* → *Run workflow*. Die Kobo-Toolchain (koxtoolchain) ist
   dieselbe wie bei Doom; liegt sie schon im Cache (`koxtoolchain-kobo-v1`), dauert der Lauf nur Minuten.
3. Artefakt `geodash-kobo` herunterladen. Bei Fehlern: Artefakt `build-logs`.
4. Wenn es läuft: den ausgegebenen Commit in `scripts/versions.sh` bei `GEOMRUSH_REV` eintragen.

## Installieren
- Inhalt von `.adds/` nach `/mnt/onboard/.adds/` kopieren (ergibt `.adds/geodash/bin/geodash`).
- `lua/appdock_geodash.lua` neben die AppDock-Dateien legen, Start mit `require("appdock_geodash").open()`.
- Log: `/mnt/onboard/.adds/geodash/geodash.log`.

## Bedienung
Tippen aufs Spielbild = Mausklick (Springen, Menüs). Darunter: JUMP (Leertaste), Esc, Enter, ↑, ↓,
Restart (R), Pause (P), Quit. Seitentasten = Sprung. `GD_FPS` (Standard 30), `GD_FRAME_MS`
(Standard 120) und `GD_REFRESH=fast` (E-Ink-Modus in KOReader) sind einstellbar.

## Nicht geprüft
Geprüft: die Eingabe-/Kalibrierlogik des Shims (Tipp zwischen zwei Frames, Maus, Skalierung, alle vier
Varianten von Bildformat/Spiegelung) gegen Attrappen. **Nicht** geprüft: der Build gegen echtes
raylib 6.0 / libvncserver / koxtoolchain, GeometryRushs Quellcode (nicht lesbar gewesen), alles auf dem Gerät.
Wahrscheinliche Stellen zum Nachjustieren:
1. `scripts/03-geodash.sh`: CMake-Optionsnamen von raylib 6.0 (das Skript probiert drei Schreibweisen);
   ob `arm-kobo-linux-gnueabihf-g++` in der Toolchain steckt; ob GeometryRush weitere Quelldateien
   braucht (Liste steht in dessen CMakeLists.txt).
2. Das Spiel ruft evtl. raylib-Funktionen auf, die ich nicht umgeleitet habe (z. B. Touch-Funktionen).
3. Audio: raylibs Audiomodul findet auf dem Kobo kein Gerät; sollte das Spiel daran scheitern, raylib ohne
   `SUPPORT_MODULE_RAUDIO` bauen.
4. Tempo: der Software-Renderer auf dem Kobo-Prozessor ist das Nadelöhr; `GD_FPS` senken, ggf. Fenstergröße
   des Spiels in dessen `config.h` verkleinern.
5. Lizenz: im GeometryRush-Repo ist keine Lizenzdatei zu sehen. Nur privat nutzen, das ZIP nicht öffentlich verteilen.
