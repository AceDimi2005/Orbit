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

- **Overview:** CPU, GPU, memorie, utilizarea discului sistemului, jocul detectat, FPS disponibil, volum și comenzi rapide. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Library:** aplicațiile configurate în Sunshine pe PC. Lansarea cere un răspuns reușit de la agent. Moonlight gestionează streamingul pentru jocuri și propriile setări de calitate.
- **Remote:** trackpad, clickuri, scroll, tastatură și media. Desktop preview primește capturi JPEG, fără audio; pentru jocuri folosește Moonlight.
- **Settings:** conexiune, Wake-on-LAN, reluarea onboardingului, mod preview și Live Activity. Parametrii avansați sunt strânși într-un meniu separat.

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

### Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. Monitorizarea GPU NVIDIA folosește `nvidia-smi`; alte plăci pot avea inventarul disponibil fără toate valorile live. Temperatura CPU și a lichidului necesită senzori expuși de LibreHardwareMonitor. Windows nu raportează universal modelul coolerului sau al sursei: completează manual denumirea coolerului când este nevoie.

FPS necesită o captură PresentMon compatibilă și configurarea variabilei `ORBIT_PRESENTMON_CSV`. Este măsurată rata cadrelor prezentate de aplicație; nu este dedusă din profilul de streaming. Agentul recunoaște jocuri din bibliotecile uzuale și permite declararea executabilelor suplimentare prin `ORBIT_GAME_PROCESSES`. Pașii și limitările sunt în [ghidul agentului](Orbit-Windows-Agent/README.md).

### Widgeturi și Dynamic Island

Sunt implementate o extensie WidgetKit reală și o Live Activity locală ActivityKit. Widgeturile sunt scurtături către Overview, Remote și Wake PC. Live Activity afișează măsurătorile recente pe Lock Screen și, pe iPhone compatibil, în Dynamic Island.

Actualizarea funcționează cât timp aplicația poate rula. iOS poate suspenda Orbit în fundal; după 15 secunde fără actualizare valorile sunt marcate ca expirate. Nu există monitorizare permanentă în fundal în această versiune. Implementarea nu cere App Groups sau notificări push. Vezi [testarea gratuită și sursele Apple](Orbit-iOS/WIDGETS.md).

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

Testele agentului și configurarea Windows sunt descrise în ghidul agentului. Acțiunile fizice Windows, senzorii reali, Wake-on-LAN și semnarea pe iPhone necesită validare pe dispozitivele respective.

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

- **Overview:** CPU, GPU, memory, system drive usage, the detected game, available FPS readings, volume, and quick controls. Missing readings are shown as unavailable.
- **Full PC specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. Open this screen from Overview or Settings. You can customize component names for each PC; leave a field empty to use the detected name.
- **Library:** apps configured in Sunshine on your PC. Launching requires a successful response from the agent. Moonlight handles game streaming and its own quality settings.
- **Remote:** trackpad, clicks, scrolling, keyboard, and media controls. Desktop preview receives JPEG screenshots without audio; use Moonlight for games.
- **Settings:** connection, Wake-on-LAN, replaying onboarding, preview mode, and Live Activity. Advanced options are tucked into a separate menu.

The volume slider directly updates the Windows audio level while you drag. Commands are sent in order, and intermediate positions are combined to keep the latest value. The old method that lowered the volume to zero before each adjustment has been removed. If the Windows audio service is unavailable, the control is shown as unavailable.

### Sensors and FPS

Hardware inventory uses Windows CIM and system APIs. NVIDIA GPU monitoring uses `nvidia-smi`; other GPUs may appear in the inventory without all live readings. CPU and coolant temperatures require sensors exposed by LibreHardwareMonitor. Windows does not universally report cooler or power supply models: enter a custom cooler name when needed.

FPS requires a compatible PresentMon capture and the `ORBIT_PRESENTMON_CSV` environment variable. Orbit measures the application's frame presentation rate; it does not infer FPS from the streaming profile. The agent recognizes games in common libraries and supports additional executable names through `ORBIT_GAME_PROCESSES`. Setup steps and limitations are in the [Windows agent guide (Romanian)](Orbit-Windows-Agent/README.md).

### Widgets and Dynamic Island

Orbit includes a real WidgetKit extension and a local ActivityKit Live Activity. Widgets provide shortcuts to Overview, Remote, and Wake PC. The Live Activity shows recent readings on the Lock Screen and, on supported iPhones, in Dynamic Island.

Updates work while the app can run. iOS may suspend Orbit in the background; readings are marked stale after 15 seconds without an update. This version does not provide continuous background monitoring. The implementation does not require App Groups or push notifications. See the [free testing instructions and Apple references (Romanian)](Orbit-iOS/WIDGETS.md).

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

Agent tests and Windows setup are described in the agent guide. Native Windows controls, real sensors, Wake-on-LAN, and iPhone signing must be validated on the respective devices.
