# Orbit — PC companion

[Română](#romana) · [English](#english)

<a id="romana"></a>

## Română

Orbit are două părți: aplicația iPhone/iPad din `Orbit-iOS` și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

### Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. La prima pornire se instalează dependențele și se generează un token privat pentru acel PC.
2. Păstrează fereastra agentului deschisă. Notează IP-ul și tokenul afișate. Permite accesul agentului în Windows Firewall pentru rețeaua privată de acasă.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege echipa ta la **Signing & Capabilities**, atât pentru **Orbit**, cât și pentru **OrbitWidgets**. Pentru iPhone personal poți folosi Personal Team. Dacă Xcode cere, schimbă bundle identifiers în două valori proprii, păstrând prefixul comun.
4. Rulează Orbit. În onboarding, introdu IP-ul și tokenul, apoi **Test connection → Continue to my PC**. Telefonul și PC-ul trebuie să fie în aceeași rețea. Acordă permisiunea iOS pentru rețeaua locală.
5. **Explore with sample data** permite explorarea interfeței înainte de conectare. Modul este marcat vizibil; valorile lui sunt simulate.

Tokenul vechi comun a fost eliminat. Copiază tokenul nou din agent; aplicația îl păstrează în Keychain. Folosește agentul numai într-o rețea de încredere sau printr-un VPN privat; transportul local este HTTP, fără criptare proprie.

### Ce găsești în aplicație

- **Overview:** dashboard personalizabil cu CPU, GPU, RAM, VRAM, consum CPU/GPU, temperaturi, frecvență CPU, ventilatoare, trafic de rețea, activitate disc, uptime și FPS. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Library:** aplicațiile configurate în Sunshine pe PC. Lansarea cere un răspuns reușit de la agent. Moonlight gestionează streamingul pentru jocuri și propriile setări de calitate.
- **Remote:** trackpad, clickuri, scroll, tastatură și media. Desktop preview primește capturi JPEG, fără audio; pentru jocuri folosește Moonlight.
- **Task Manager:** lista proceselor PC-ului, căutare, sortare după CPU/RAM și închiderea unui proces cu confirmare. Procesele de sistem și agentul sunt protejate.
- **Settings:** conexiune, Wake-on-LAN, reluarea onboardingului, mod preview, configurarea widgeturilor și Live Activity. **Monitoring sources** arată versiunea agentului, sursele senzorilor/GPU, adaptorul de rețea și motivul pentru care FPS lipsește. Parametrii avansați sunt strânși într-un meniu separat.

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

### Dashboardul tău

Deschide **Customize dashboard** din Overview sau Settings. Poți afișa/ascunde și reordona cele **17 tipuri de carduri**, alege una sau două coloane și ascunde separat jocul, volumul și comenzile rapide. Presetările **Balanced**, **Gaming** și **Everything** oferă puncte de pornire. Apasă **Done** pentru salvare; configurația se păstrează separat pentru fiecare PC. Textul de accesibilitate mare folosește automat o singură coloană.

Puterea CPU este valoarea **CPU package**, iar puterea GPU provine din senzorul plăcii video. Ele nu reprezintă consumul total al PC-ului la priză. Frecvența CPU indică sursa citirii; dacă nu există senzori live, valoarea nominală raportată de Windows este etichetată explicit. Turațiile ventilatoarelor nu sunt estimate. Debitele de rețea și disc folosesc diferențe între măsurători. Conectarea sau resetarea unui dispozitiv reinițializează numai contorul lui; celelalte continuă să fie măsurate. Traficul mic se afișează și în B/s sau KB/s. Adaptoarele active sunt selectate automat; `ORBIT_NETWORK_INTERFACE` permite alegerea explicită a unuia.

### Task Manager

Deschide **Task Manager**, caută aplicația sau sortează lista după CPU/RAM, apoi folosește **End task** numai după verificarea procesului. Lista poate fi reîmprospătată manual. Orbit cere confirmare și verifică identitatea procesului înainte de închidere, pentru a evita închiderea altui proces care a reutilizat același PID. Pe Windows, închiderea prin acest mecanism este forțată: aplicația nu are garanția că își salvează lucrul. Orbit nu închide automat aplicații.

### Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. NVIDIA `nvidia-smi` oferă încărcare, temperatură, VRAM, consum și ventilator când sunt suportate. LibreHardwareMonitor poate oferi și senzori GPU AMD/Intel/NVIDIA când `nvidia-smi` nu este disponibil; citirile mai multor plăci nu se amestecă. Temperatura CPU preferă package/Tctl/Tdie, apoi cel mai cald nucleu măsurat când lipsește un senzor package. Modelul coolerului sau al sursei poate necesita completare manuală.

**Temperaturi:** LibreHardwareMonitor 0.9.5+ a eliminat WMI. Orbit citește acum API-ul HTTP local; activează **Options → Remote Web Server → Run**, pe portul **8085**, și lasă programul deschis. Pornește-l ca administrator dacă senzorii PC-ului cer asta. Adresa implicită este `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` permite alt port local. Versiunile vechi LibreHardwareMonitor/OpenHardwareMonitor pot folosi în continuare WMI. Schimbarea interfeței este [confirmată de dezvoltatorii LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**FPS:** pornește separat o captură PresentMon și configurează **`ORBIT_PRESENTMON_CSV`**. Agentul acceptă CSV v1, formatul implicit actual și v2 cu `CPUStartTime`/`FrameTime`. Pentru intervale `MsBetweenPresents`, sursa este **application FPS**; pentru `FrameTime`, sursa este **CPU frame FPS**. Acestea descriu ritmul aplicației, fără să garanteze rata afișată după generarea cadrelor sau streaming. `ORBIT_PRESENTATION_CSV` este acceptată ca alias de compatibilitate; folosește denumirea recomandată `ORBIT_PRESENTMON_CSV`.

După pornirea PresentMon, din PowerShell în folderul agentului:

```powershell
$env:ORBIT_PRESENTMON_CSV = 'C:\Orbit\presentmon.csv'
$env:ORBIT_GAME_PROCESSES = 'example.exe'
.\start_agent.bat
```

Înlocuiește `example.exe` cu executabilul jocului. Variabilele se aplică agentului pornit din acea fereastră; nu pornesc captura și nu instalează PresentMon. Consultă [pașii compleți și formatele FPS](Orbit-Windows-Agent/README.md#fps-real-cu-presentmon-opțional).

### Actualizare și diagnosticare

Agentul din această versiune raportează **3.1.0**. Oprește vechiul agent, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește cu `start_agent.bat`. Păstrează fișierele locale `.orbit-token` și `.orbit-widget-token`; nu copia mediul `.venv` de pe alt calculator. Actualizează și aplicația din Xcode. Schimbările din proiect nu actualizează automat copia care rulează pe PC.

În **Settings → Monitoring sources**, verifică versiunea raportată și sursele datelor. Pe PC, `check_monitoring.bat` sau `.venv\Scripts\python.exe check_monitoring.py` verifică sursele disponibile și configurarea FPS fără să trimită comenzi de control. Păstrează LibreHardwareMonitor și captura PresentMon pornite pentru această verificare. Senzorii, cadrele jocului și comenzile Windows trebuie validate pe PC-ul tău; verificările automate folosesc și surse simulate.

### Widgeturi și Dynamic Island

Extensia WidgetKit oferă cinci widgeturi de monitorizare: **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures** și **Choose a PC metric**. Ultimul permite alegerea CPU, GPU, RAM, VRAM, puterii, temperaturii sau FPS; poți adăuga mai multe instanțe pentru metrici sau PC-uri diferite. Scurtăturile existente către aplicație și controale rămân disponibile.

Conectează PC-ul, apoi deschide **Settings → Widgets → Prepare widget access** și copiază **read-only widget token**. Adaugă widgetul pe Home Screen, ține-l apăsat și alege **Edit Widget**, apoi introdu adresa PC-ului, portul agentului și acest token separat. Widgetul citește direct agentul, fără App Groups sau cont Apple Developer plătit. Nu folosi tokenul principal de control în configurația widgetului.

Widgeturile arată capturi periodice cu ora măsurătorii. iOS decide când le actualizează; o nouă citire la fiecare 15 minute este solicitată, fără garanția frecvenței. După 15 minute valorile sunt marcate ca expirate. PC-ul trebuie să fie accesibil în rețea.

Live Activity locală ActivityKit este separată: afișează măsurători recente pe Lock Screen și, pe iPhone compatibil, în Dynamic Island, cu profil **Overview**, **Gaming** sau **Power**. Actualizările depind de rularea aplicației; după 15 secunde fără date, ascunde valorile expirate. Nu există monitorizare permanentă garantată în fundal. Vezi [configurarea, testarea gratuită și sursele Apple](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Conectează PC-ul măcar o dată pentru detectarea adresei MAC și a rețelei sau completează-le manual în Settings. Activează Wake-on-LAN în BIOS/UEFI și în proprietățile adaptorului Ethernet din Windows. PC-ul trebuie să rămână alimentat. Un pachet trimis nu garantează pornirea: Orbit așteaptă răspunsul agentului înainte să afișeze PC-ul drept conectat.

Broadcastul UDP poate avea restricții suplimentare pe iPhone; verifică nota din [ghidul de testare](Orbit-iOS/WIDGETS.md). Testarea pe simulator nu garantează funcționarea Wake-on-LAN pe telefonul fizic.

### Icon

Iconul este deja inclus în `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. Pentru a-l schimba, deschide **Assets → AppIcon** în Xcode și înlocuiește imaginea universală de 1024 × 1024 cu un PNG pătrat, opac. iOS aplică forma colțurilor.

Generat cu instrumentul integrat imagegen. Promptul folosit: „Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Verificări de dezvoltare

Build pentru simulator:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme Orbit -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Testele pentru livrarea fluidă a volumului:

```sh
swiftc -parse-as-library Orbit-iOS/Orbit/VolumeCommandQueue.swift Orbit-iOS/Tests/VolumeCommandQueueTests.swift -o /tmp/orbit-volume-tests
/tmp/orbit-volume-tests
```

Testul de compatibilitate JSON agent–iOS (Python cu dependențele agentului și Swift instalat):

```sh
python Orbit-iOS/Tests/check_protocol.py
```

Testele configurației dashboardului:

```sh
swiftc -parse-as-library Orbit-iOS/Orbit/DashboardConfiguration.swift Orbit-iOS/Tests/DashboardConfigurationTests.swift -o /tmp/orbit-dashboard-tests
/tmp/orbit-dashboard-tests
```

Regresiile agentului, din rădăcina proiectului, cu dependențele din `Orbit-Windows-Agent/requirements-dev.txt` instalate în mediul Python activ:

```sh
python -m unittest discover -s Orbit-Windows-Agent -p 'test_*.py' -v
```

Comanda include testele pentru senzori HTTP/WMI, formatele FPS și contoarele de trafic. Configurarea Windows este descrisă în ghidul agentului. Acțiunile fizice Windows, senzorii reali, Wake-on-LAN și semnarea pe iPhone necesită validare pe dispozitivele respective.

---

## English

Orbit has two parts: the iPhone/iPad app in `Orbit-iOS` and the Windows agent in `Orbit-Windows-Agent`. Update both together.

### Getting started

1. Copy the entire `Orbit-Windows-Agent` folder to your PC and run `start_agent.bat`. Python 3.11 or later is required. The first run installs the dependencies and generates a private token for that PC.
2. Keep the agent window open. Note the displayed IP address and token. Allow the agent through Windows Firewall on your private home network.
3. Open `Orbit-iOS/Orbit.xcodeproj` in Xcode. Select your team under **Signing & Capabilities** for both **Orbit** and **OrbitWidgets**. You can use a Personal Team for your own iPhone. If Xcode requires it, change both bundle identifiers to unique values while keeping their shared prefix.
4. Run Orbit. Enter the IP address and token during onboarding, then choose **Test connection → Continue to my PC**. Your phone and PC must be on the same network. Grant iOS local network permission.
5. **Explore with sample data** lets you try the interface before connecting. Preview mode is clearly labeled and uses simulated readings.

The old shared token has been removed. Copy the new token from the agent; the app stores it in Keychain. Only use the agent on a trusted network or through a private VPN. Local communication uses HTTP without its own encryption.

### Inside the app

- **Overview:** a customizable dashboard for CPU, GPU, RAM, VRAM, CPU/GPU power, temperatures, CPU clock, fans, network traffic, disk activity, uptime, and FPS. Missing readings are shown as unavailable.
- **Full PC specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. Open this screen from Overview or Settings. You can customize component names for each PC; leave a field empty to use the detected name.
- **Library:** apps configured in Sunshine on your PC. Launching requires a successful response from the agent. Moonlight handles game streaming and its own quality settings.
- **Remote:** trackpad, clicks, scrolling, keyboard, and media controls. Desktop preview receives JPEG screenshots without audio; use Moonlight for games.
- **Task Manager:** the PC process list, search, CPU/RAM sorting, and process termination with confirmation. System processes and the agent are protected.
- **Settings:** connection, Wake-on-LAN, replaying onboarding, preview mode, widget configuration, and Live Activity. **Monitoring sources** shows the reported agent version, sensor/GPU providers, network interface, and FPS availability reason. Advanced options are tucked into a separate menu.

The volume slider directly updates the Windows audio level while you drag. Commands are sent in order, and intermediate positions are combined to keep the latest value. The old method that lowered the volume to zero before each adjustment has been removed. If the Windows audio service is unavailable, the control is shown as unavailable.

### Your dashboard

Open **Customize dashboard** from Overview or Settings. Show, hide, and reorder **17 card types**, choose one or two columns, and independently hide the game, volume, and quick controls sections. Start with **Balanced**, **Gaming**, or **Everything**, then tap **Done** to save. Each PC keeps its own configuration. Larger accessibility text automatically uses one column.

CPU power is the **CPU package** reading; GPU power comes from the graphics card sensor. These readings do not measure the PC's total wall power. CPU clock shows its source; when live sensors are unavailable, the nominal Windows clock is explicitly labeled. Fan speeds are never estimated. Network and disk rates use differences between samples. A newly connected or reset device only primes its own counter; other devices keep reporting. Low network traffic also displays in B/s or KB/s. Active interfaces are selected automatically; set `ORBIT_NETWORK_INTERFACE` to choose one explicitly.

### Task Manager

Open **Task Manager**, search for an app or sort by CPU/RAM, then check the process before choosing **End task**. Refresh the list manually when needed. Orbit asks for confirmation and checks the process identity before termination, preventing another process that reused the same PID from being closed. On Windows, this termination is forceful: the application is not guaranteed an opportunity to save work. Orbit never ends applications automatically.

### Sensors and FPS

Hardware inventory uses Windows CIM and system APIs. NVIDIA `nvidia-smi` provides load, temperature, VRAM, power, and fan readings where supported. LibreHardwareMonitor can also provide AMD/Intel/NVIDIA GPU sensors when `nvidia-smi` is unavailable; readings from different adapters are kept separate. CPU temperature prefers package/Tctl/Tdie, falling back to the hottest measured core when no package sensor is exposed. Cooler and power supply names may require manual entry.

**Temperatures:** LibreHardwareMonitor 0.9.5+ removed WMI. Orbit now reads its local HTTP API. Enable **Options → Remote Web Server → Run** on port **8085** and keep LibreHardwareMonitor open. Run it as administrator if your hardware sensors require that access. The default address is `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` supports another local port. Older LibreHardwareMonitor/OpenHardwareMonitor installations can still use WMI. The interface change is [confirmed by the LibreHardwareMonitor maintainers](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**FPS:** start a separate PresentMon capture and configure **`ORBIT_PRESENTMON_CSV`**. The agent accepts v1, current default CSV output, and v2 with `CPUStartTime`/`FrameTime`. `MsBetweenPresents` readings are labeled **application FPS**; `FrameTime` readings are labeled **CPU frame FPS**. Both describe application timing and do not guarantee displayed FPS after frame generation or streaming. `ORBIT_PRESENTATION_CSV` is tolerated as a compatibility alias; use the recommended name `ORBIT_PRESENTMON_CSV`.

With PresentMon already capturing, run this in PowerShell from the agent folder:

```powershell
$env:ORBIT_PRESENTMON_CSV = 'C:\Orbit\presentmon.csv'
$env:ORBIT_GAME_PROCESSES = 'example.exe'
.\start_agent.bat
```

Replace `example.exe` with the game's executable. These variables apply to the agent started from that window; they do not start a capture or install PresentMon. See the [complete FPS setup and supported formats (Romanian)](Orbit-Windows-Agent/README.md#fps-real-cu-presentmon-opțional).

### Updating and troubleshooting

The agent in this version reports **3.1.0**. Stop the old agent, copy the updated **entire `Orbit-Windows-Agent` folder** to your PC, and restart with `start_agent.bat`. Keep the local `.orbit-token` and `.orbit-widget-token` files; do not copy another computer's `.venv`. Update the app through Xcode too. Editing the project does not automatically update the copy running on your PC.

Open **Settings → Monitoring sources** to check the reported version and providers. On the PC, `check_monitoring.bat` or `.venv\Scripts\python.exe check_monitoring.py` checks available sources and FPS configuration without sending control commands. Keep LibreHardwareMonitor and the PresentMon capture running during the check. Actual sensors, game frames, and Windows controls still need validation on your PC; automated checks also use mocked sources.

### Widgets and Dynamic Island

The WidgetKit extension includes five monitoring widgets: **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures**, and **Choose a PC metric**. The last lets you choose CPU, GPU, RAM, VRAM, power, temperature, or FPS; add multiple instances for different readings or PCs. Existing app and control shortcuts remain available.

Connect the PC, open **Settings → Widgets → Prepare widget access**, and copy the **read-only widget token**. Add a widget to your Home Screen, touch and hold it, choose **Edit Widget**, and enter the PC address, agent port, and this separate token. The widget reads directly from the agent, without App Groups or a paid Apple Developer account. Do not enter the main control token in widget configuration.

Widgets show periodic snapshots with the measurement time. They request another reading after 15 minutes, but iOS decides when updates run and does not guarantee that frequency. Readings expire after 15 minutes. The PC must be reachable on your network.

The local ActivityKit Live Activity is separate. It shows recent readings on the Lock Screen and, on supported iPhones, in Dynamic Island, with **Overview**, **Gaming**, or **Power** focus. Updates depend on the app being allowed to run; readings expire and are hidden after 15 seconds without new data. Continuous background monitoring is not guaranteed. See the [setup, free testing instructions, and Apple references (Romanian)](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Connect to your PC at least once to detect its MAC address and network settings, or enter them manually in Settings. Enable Wake-on-LAN in BIOS/UEFI and in the Windows Ethernet adapter properties. The PC must remain connected to power. Sending a packet does not guarantee a successful wake: Orbit waits for the agent to respond before showing the PC as connected.

UDP broadcast may face additional restrictions on iPhone; see the note in the [testing guide (Romanian)](Orbit-iOS/WIDGETS.md). A successful simulator test does not guarantee Wake-on-LAN will work on a physical phone.

### App icon

The icon is already included at `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. To change it, open **Assets → AppIcon** in Xcode and replace the universal 1024 × 1024 image with a square, opaque PNG. iOS applies the rounded corners.

Generated with the built-in imagegen tool. Prompt: “Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Development checks

Build for the simulator:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme Orbit -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Test smooth volume command delivery:

```sh
swiftc -parse-as-library Orbit-iOS/Orbit/VolumeCommandQueue.swift Orbit-iOS/Tests/VolumeCommandQueueTests.swift -o /tmp/orbit-volume-tests
/tmp/orbit-volume-tests
```

Check JSON compatibility between the agent and iOS (requires Python with the agent dependencies and an installed Swift toolchain):

```sh
python Orbit-iOS/Tests/check_protocol.py
```

Test dashboard configuration:

```sh
swiftc -parse-as-library Orbit-iOS/Orbit/DashboardConfiguration.swift Orbit-iOS/Tests/DashboardConfigurationTests.swift -o /tmp/orbit-dashboard-tests
/tmp/orbit-dashboard-tests
```

Run agent regressions from the project root, with `Orbit-Windows-Agent/requirements-dev.txt` installed in the active Python environment:

```sh
python -m unittest discover -s Orbit-Windows-Agent -p 'test_*.py' -v
```

This includes HTTP/WMI sensors, FPS formats, and traffic counter regressions. Windows setup is described in the agent guide. Native Windows controls, real sensors, Wake-on-LAN, and iPhone signing must be validated on the respective devices.
