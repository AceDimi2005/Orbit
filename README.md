# Orbit — PC companion

[Română](#romana) · [English](#english)

<a id="romana"></a>

## Română

Orbit are două părți: aplicația iPhone/iPad din `Orbit-iOS` și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

### Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` **4.0.0** pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. La prima pornire se instalează dependențele și se generează un token privat și un certificat pentru acel PC.
2. Păstrează fereastra agentului deschisă. Notează **PC IP**, **Pairing token** și **Certificate SHA-256 fingerprint**. Permite accesul Python în Windows Firewall pentru rețeaua **Private**, inclusiv portul securizat **8766**.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege echipa ta la **Signing & Capabilities**, atât pentru **Orbit**, cât și pentru **OrbitWidgets**. Pentru iPhone personal poți folosi Personal Team. Dacă Xcode cere, schimbă bundle identifiers în două valori proprii, păstrând prefixul comun.
4. Rulează Orbit și acordă permisiunea pentru rețeaua locală. În onboarding, introdu **adresa PC-ului**, **tokenul** și **amprenta SHA-256 a certificatului** copiate din fereastra agentului, apoi **Test connection → Continue to my PC**. Portul securizat este implicit **8766**; schimbă-l în **Custom agent port** doar dacă ai configurat altul. Prima conectare reușită salvează automat profilul PC-ului. Telefonul și PC-ul trebuie să fie accesibile în aceeași rețea sau prin VPN privat.
5. **Explore with sample data** permite explorarea interfeței înainte de conectare. Modul este marcat vizibil; valorile lui sunt simulate.

Aplicația păstrează tokenul fiecărui PC separat în Keychain. Cu amprenta configurată, monitorizarea și comenzile folosesc **HTTPS cu verificarea certificatului acelui PC**; o eroare de certificat nu produce revenirea la HTTP. Files, Clipboard, Audio mixer și Sessions cer această conexiune criptată. Portul HTTP **8765** rămâne pentru widgeturile și clienții vechi, cu token separat pentru widgeturi. Nu publica porturile agentului pe Internet.

### Ce găsești în aplicație

- **Overview:** dashboard personalizabil cu CPU, GPU, RAM, VRAM, consum CPU/GPU, temperaturi, frecvență CPU, ventilatoare, trafic de rețea, activitate disc, uptime și FPS. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Library:** aplicațiile configurate în Sunshine pe PC. Lansarea cere un răspuns reușit de la agent. Moonlight gestionează streamingul pentru jocuri și propriile setări de calitate.
- **Files:** discuri și foldere accesibile contului Windows, transfer în ambele sensuri, previzualizare, favorite și organizare.
- **Remote:** trackpad, clickuri, scroll, tastatură și media. Desktop preview primește capturi JPEG, fără audio; pentru jocuri folosește Moonlight.
- **Tools:** My PCs, Clipboard, Audio mixer, Sessions & graphs, Task Manager, specificații și sursele de monitorizare. **Settings** se deschide de aici și grupează Wake-on-LAN, onboarding, preview, widgeturi și Live Activity.

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

### Fișiere și transfer

Deschide tabul **Files** și alege discul sau unul dintre folderele rapide: Desktop, Downloads, Documents, Pictures. Poți naviga, căuta în folderul curent, sorta și selecta mai multe intrări. Favoritele se păstrează separat pentru fiecare PC.

- **PC → iPhone:** descarcă, deschide previzualizarea Quick Look, apoi distribuie sau salvează în aplicația Fișiere.
- **iPhone → PC:** alege fișiere din Fișiere sau poze din biblioteca foto și trimite-le în folderul deschis. Transferul arată progresul și viteza și poate fi anulat.
- **Organizare:** creează foldere, redenumește, mută pe același disc și trimite în Recycle Bin, cu confirmare. Fișierele existente nu sunt suprascrise automat.

Accesul este limitat la permisiunile contului Windows; tokenurile Orbit și stocarea internă privată sunt protejate. Limitele curente sunt **2 GiB/upload**, **16 GiB/download** și **64 MiB/previzualizare**. Transferurile sunt pentru fișiere individuale; nu arhivează automat foldere. Linkurile/junctions și căile de rețea UNC nu sunt disponibile. Mutarea între discuri este refuzată fără modificări; folosește transferul și gestionează separat originalul. PC-ul și agentul trebuie să rămână pornite.

### Clipboard, mixer și sesiuni

În **Tools → Clipboard**, folosește **Paste from iPhone → Send text to PC** sau **Read PC clipboard → Copy to iPhone**. Se transferă numai text și linkuri, la cerere, până la **1 MiB**. Orbit nu urmărește clipboardul în fundal și nu salvează un istoric; textul ecranului este șters la ieșire sau la schimbarea PC-ului.

În **Tools → Audio mixer**, fiecare sesiune audio a ieșirii Windows implicite are volum și mute proprii. Pornește sunetul într-o aplicație dacă nu apare. O aplicație poate avea mai multe sesiuni, iar schimbarea ieșirii implicite poate schimba lista. Glisările sunt grupate și livrate în ordine, folosind direct Windows Core Audio.

În **Tools → Sessions & graphs**, jocurile detectate pornesc automat o sesiune; **+** pornește o înregistrare manuală pentru activitatea desktopului. Oprește înregistrarea când ai terminat. Agentul salvează o măsurătoare la **5 secunde**, păstrează cel mult **100 de sesiuni / 30 de zile** și permite ștergerea sesiunilor încheiate. Graficele interactive includ FPS, încărcare și temperaturi CPU/GPU, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc citirile disponibile; senzorii lipsă rămân goluri, fără valori zero inventate. Sesiunile se păstrează pe PC, inclusiv dacă telefonul se deconectează. Acestea sunt mostre periodice, nu o captură completă a fiecărui cadru.

În **Tools → My PCs**, adaugă și selectează mai multe calculatoare. Fiecare are adresă, token, certificat și setări Wake-on-LAN proprii, inclusiv calcularea automată a broadcastului; configurația dashboardului și favoritele sunt separate. Prima conexiune reușită creează profilul automat. Conexiunea veche este migrată dacă lista este goală; editează profilul pentru a completa amprenta lipsă. Datele profilurilor rămân pe telefon, iar secretele în Keychain. Schimbarea PC-ului închide contextul operațiilor vechi.

### Dashboardul tău

Deschide **Customize dashboard** din Overview sau Settings. Poți afișa/ascunde și reordona cele **17 tipuri de carduri**, alege una sau două coloane și ascunde separat jocul, volumul și comenzile rapide. Presetările **Balanced**, **Gaming** și **Everything** oferă puncte de pornire. Apasă **Done** pentru salvare; configurația se păstrează separat pentru fiecare PC. Textul de accesibilitate mare folosește automat o singură coloană.

Puterea CPU este valoarea **CPU package**, iar puterea GPU provine din senzorul plăcii video. Ele nu reprezintă consumul total al PC-ului la priză. Frecvența CPU indică sursa citirii; dacă nu există senzori live, valoarea nominală raportată de Windows este etichetată explicit. Turațiile ventilatoarelor nu sunt estimate. Debitele de rețea și disc folosesc diferențe între măsurători. Conectarea sau resetarea unui dispozitiv reinițializează numai contorul lui; celelalte continuă să fie măsurate. Traficul mic se afișează și în B/s sau KB/s. Adaptoarele active sunt selectate automat; `ORBIT_NETWORK_INTERFACE` permite alegerea explicită a unuia.

### Task Manager

Deschide **Tools → Task Manager**, caută aplicația sau sortează lista după CPU/RAM, apoi folosește **End task** numai după verificarea procesului. Lista poate fi reîmprospătată manual. Orbit cere confirmare și verifică identitatea procesului înainte de închidere, pentru a evita închiderea altui proces care a reutilizat același PID. Pe Windows, închiderea prin acest mecanism este forțată: aplicația nu are garanția că își salvează lucrul. Orbit nu închide automat aplicații.

### Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. NVIDIA `nvidia-smi` rămâne sursa prioritară pentru încărcare, temperatură, VRAM, consum și ventilator GPU, când sunt suportate. Pentru ceilalți senzori, agentul detectează **MSI Afterburner**, apoi LibreHardwareMonitor ca alternativă. Citirile mai multor plăci nu se amestecă, iar un senzor lipsă rămâne indisponibil. Modelul coolerului sau al sursei poate necesita completare manuală.

**Configurarea recomandată, fără CSV:**

1. Instalează [MSI Afterburner de pe site-ul MSI](https://www.msi.com/Landing/afterburner/graphics-cards), inclusiv **RivaTuner Statistics Server (RTSS)**, și lasă ambele programe pornite pe PC.
2. În **Afterburner → Settings → Monitoring**, bifează senzorii doriți din **Active hardware monitoring graphs**, inclusiv CPU/GPU temperature și Framerate, când există. Apasă **Apply**. **Show in On-Screen Display** este opțional pentru verificarea pe ecran; [ghidul MSI](https://www.msi.com/blog/msi-afterburner-on-screen-display/) arată opțiunile.
3. În RTSS, alege **Application detection level → Low** pentru joc. Poți activa temporar **Show own statistics** ca să verifici detectarea.
4. Pornește jocul și agentul **4.0.0**, apoi deschide Orbit. Datele sunt citite automat, prin memoria partajată locală; nu trebuie să conectezi telefonul direct la Afterburner sau să introduci o cheie suplimentară. În **Tools → Settings → Set up FPS** ai aceiași pași.

**FPS:** RTSS are prioritate și nu cere `ORBIT_PRESENTMON_CSV`. Jocurile care blochează RTSS sau unele sisteme anti-cheat pot rămâne incompatibile. Valoarea descrie cadrele aplicației, fără garanția FPS-ului afișat după generarea cadrelor sau streaming. Pentru un joc nerecunoscut, se poate configura executabilul prin `ORBIT_GAME_PROCESSES`.

**Senzori:** Orbit poate citi doar graficele și unitățile pe care Afterburner le expune; consumul CPU/GPU în wați, capacitatea VRAM și ventilatoarele nu sunt garantate pe orice PC. Dacă lipsește un senzor, LibreHardwareMonitor rămâne opțional: în versiunile **0.9.5+**, activează **Options → Remote Web Server → Run**, port **8085**. Orbit citește `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` permite alt port local. Versiunile vechi pot folosi WMI. Schimbarea interfeței este [confirmată de dezvoltatorii LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Alternativă avansată FPS:** captura PresentMon CSV rămâne acceptată, dacă RTSS nu oferă date recente. Configurează `ORBIT_PRESENTMON_CSV` și pornește captura separat; formatele v1, implicit actual și v2 sunt suportate. `ORBIT_PRESENTATION_CSV` rămâne alias de compatibilitate. Consultă [pașii RTSS și alternativa PresentMon](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Actualizare și diagnosticare

Agentul din această versiune raportează **4.0.0**. Oprește vechiul agent, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește cu `start_agent.bat`. Păstrează fișierele locale `.orbit-token`, `.orbit-widget-token` și folderul `%LOCALAPPDATA%\Orbit` cu identitatea TLS și istoricul; nu copia mediul `.venv` de pe alt calculator. Completează certificatul din Tools → My PCs pentru funcțiile noi. Actualizează și aplicația din Xcode. Schimbările din proiect nu actualizează automat copia care rulează pe PC.

În **Tools → Monitoring sources**, verifică versiunea raportată și sursele datelor. Pe PC, `check_monitoring.bat` sau `.venv\Scripts\python.exe check_monitoring.py` verifică sursele disponibile și configurarea FPS fără să trimită comenzi de control. Păstrează Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS; dacă folosești o sursă alternativă, las-o pornită și pe aceea. Senzorii, cadrele jocului și comenzile Windows trebuie validate pe PC-ul tău; verificările automate folosesc și surse simulate.

### Widgeturi și Dynamic Island

Extensia WidgetKit oferă cinci widgeturi de monitorizare: **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures** și **Choose a PC metric**. Ultimul permite alegerea CPU, GPU, RAM, VRAM, puterii, temperaturii sau FPS; poți adăuga mai multe instanțe pentru metrici sau PC-uri diferite. Scurtăturile existente către aplicație și controale rămân disponibile.

Conectează PC-ul, apoi deschide **Tools → Settings → Widgets → Prepare widget access** și copiază **read-only widget token**. Adaugă widgetul pe Home Screen, ține-l apăsat și alege **Edit Widget**, apoi introdu adresa PC-ului, portul **8765** și acest token separat. Widgeturile actuale folosesc HTTP numai în rețeaua privată, separat de conexiunea HTTPS a aplicației. Widgetul citește direct agentul, fără App Groups sau cont Apple Developer plătit. Nu folosi tokenul principal de control în configurația widgetului.

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

Comanda include regresii pentru fișiere și transferuri, clipboard, sesiuni audio, istoric SQLite și identitate TLS, alături de Afterburner/RTSS, senzori HTTP/WMI, formatele CSV FPS și contoarele de trafic. Configurarea Windows este descrisă în ghidul agentului. Acțiunile fizice Windows, senzorii reali, Wake-on-LAN și semnarea pe iPhone necesită validare pe dispozitivele respective.

---

## English

Orbit has two parts: the iPhone/iPad app in `Orbit-iOS` and the Windows agent in `Orbit-Windows-Agent`. Update both together.

### Getting started

1. Copy the entire `Orbit-Windows-Agent` **4.0.0** folder to your PC and run `start_agent.bat`. Python 3.11 or later is required. The first run installs dependencies and generates a private token and certificate for that PC.
2. Keep the agent window open. Note **PC IP**, **Pairing token**, and **Certificate SHA-256 fingerprint**. Allow Python through Windows Firewall on **Private** networks, including secure port **8766**.
3. Open `Orbit-iOS/Orbit.xcodeproj` in Xcode. Select your team under **Signing & Capabilities** for both **Orbit** and **OrbitWidgets**. You can use a Personal Team for your own iPhone. If Xcode requires it, change both bundle identifiers to unique values while keeping their shared prefix.
4. Run Orbit and grant local network permission. During onboarding, enter the **PC address**, **token**, and **certificate SHA-256 fingerprint** copied from the agent window, then choose **Test connection → Continue to my PC**. The secure port defaults to **8766**; change it under **Custom agent port** only if you configured another one. The first successful connection saves the PC profile automatically. Your phone and PC must be reachable on the same network or through a private VPN.
5. **Explore with sample data** lets you try the interface before connecting. Preview mode is clearly labeled and uses simulated readings.

The app keeps each PC's token separately in Keychain. Once the fingerprint is configured, monitoring and controls use **HTTPS with verification of that PC's certificate**; a certificate error never falls back to HTTP. Files, Clipboard, Audio mixer, and Sessions require this encrypted connection. HTTP port **8765** remains for legacy widgets and clients, with a separate read-only token for widgets. Do not expose the agent ports to the Internet.

### Inside the app

- **Overview:** a customizable dashboard for CPU, GPU, RAM, VRAM, CPU/GPU power, temperatures, CPU clock, fans, network traffic, disk activity, uptime, and FPS. Missing readings are shown as unavailable.
- **Full PC specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. Open this screen from Overview or Settings. You can customize component names for each PC; leave a field empty to use the detected name.
- **Library:** apps configured in Sunshine on your PC. Launching requires a successful response from the agent. Moonlight handles game streaming and its own quality settings.
- **Files:** drives and folders available to the Windows account, transfers in both directions, previews, favorites, and organization.
- **Remote:** trackpad, clicks, scrolling, keyboard, and media controls. Desktop preview receives JPEG screenshots without audio; use Moonlight for games.
- **Tools:** My PCs, Clipboard, Audio mixer, Sessions & graphs, Task Manager, specifications, and monitoring sources. Open **Settings** here for Wake-on-LAN, onboarding, preview mode, widgets, and Live Activity.

The volume slider directly updates the Windows audio level while you drag. Commands are sent in order, and intermediate positions are combined to keep the latest value. The old method that lowered the volume to zero before each adjustment has been removed. If the Windows audio service is unavailable, the control is shown as unavailable.

### Files and transfers

Open **Files** and choose a drive or a quick folder: Desktop, Downloads, Documents, or Pictures. Browse, search the current folder, sort, and select multiple entries. Favorites are saved separately for each PC.

- **PC → iPhone:** download a file, open its Quick Look preview, then share or save it to Files.
- **iPhone → PC:** choose files from Files or pictures from Photos and send them to the open PC folder. Transfers show progress and speed and can be cancelled.
- **Organization:** create folders, rename, move on the same drive, and send items to Recycle Bin with confirmation. Existing files are not overwritten automatically.

Access follows the Windows account's permissions; Orbit tokens and private internal storage are protected. Current limits are **2 GiB/upload**, **16 GiB/download**, and **64 MiB/preview**. Transfers handle individual files and do not automatically archive folders. Links/junctions and UNC network paths are unavailable. Moves between drives are rejected without changes; use transfers and manage the original separately. The PC and agent must stay running.

### Clipboard, mixer, and sessions

In **Tools → Clipboard**, use **Paste from iPhone → Send text to PC** or **Read PC clipboard → Copy to iPhone**. Only text and links are transferred, on request, up to **1 MiB**. Orbit does not watch the clipboard in the background or save clipboard history. Text on this screen is cleared when you leave or change PCs.

In **Tools → Audio mixer**, each audio session on the default Windows output has its own volume and mute controls. Play sound in an app if it does not appear. One app may have several sessions; changing the default output can change the list. Slider updates are combined and delivered in order through Windows Core Audio.

In **Tools → Sessions & graphs**, detected games start sessions automatically; **+** starts a manual recording for desktop work. Stop recording when finished. The agent saves a reading every **5 seconds**, keeps at most **100 sessions / 30 days**, and allows completed sessions to be deleted. Interactive graphs include FPS, CPU/GPU load and temperatures, power, RAM, VRAM, and traffic. Averages and peaks use available measurements; missing sensors remain gaps without invented zeros. Sessions stay on the PC and continue if the phone disconnects. These are periodic samples, not a complete capture of every frame.

In **Tools → My PCs**, add and select multiple computers. Each has its own address, token, certificate, and Wake-on-LAN settings, including automatic broadcast calculation; dashboard configuration and file favorites are separate. The first successful connection creates a profile automatically. The previous connection is migrated when the list is empty; edit it to add a missing fingerprint. Profile metadata stays on the phone and secrets stay in Keychain. Switching PCs clears the previous operation context.

### Your dashboard

Open **Customize dashboard** from Overview or Settings. Show, hide, and reorder **17 card types**, choose one or two columns, and independently hide the game, volume, and quick controls sections. Start with **Balanced**, **Gaming**, or **Everything**, then tap **Done** to save. Each PC keeps its own configuration. Larger accessibility text automatically uses one column.

CPU power is the **CPU package** reading; GPU power comes from the graphics card sensor. These readings do not measure the PC's total wall power. CPU clock shows its source; when live sensors are unavailable, the nominal Windows clock is explicitly labeled. Fan speeds are never estimated. Network and disk rates use differences between samples. A newly connected or reset device only primes its own counter; other devices keep reporting. Low network traffic also displays in B/s or KB/s. Active interfaces are selected automatically; set `ORBIT_NETWORK_INTERFACE` to choose one explicitly.

### Task Manager

Open **Tools → Task Manager**, search for an app or sort by CPU/RAM, then check the process before choosing **End task**. Refresh the list manually when needed. Orbit asks for confirmation and checks the process identity before termination, preventing another process that reused the same PID from being closed. On Windows, this termination is forceful: the application is not guaranteed an opportunity to save work. Orbit never ends applications automatically.

### Sensors and FPS

Hardware inventory uses Windows CIM and system APIs. NVIDIA `nvidia-smi` remains the preferred GPU source for load, temperature, VRAM, power and fan readings where supported. For other sensors, the agent detects **MSI Afterburner**, with LibreHardwareMonitor as a fallback. Readings from different adapters are kept separate and missing sensors stay unavailable. Cooler and power supply names may require manual entry.

**Recommended setup, without CSV:**

1. Install [MSI Afterburner from MSI](https://www.msi.com/Landing/afterburner/graphics-cards), including **RivaTuner Statistics Server (RTSS)**, and keep both running on the PC.
2. In **Afterburner → Settings → Monitoring**, tick the desired **Active hardware monitoring graphs**, including CPU/GPU temperature and Framerate when present. Click **Apply**. **Show in On-Screen Display** is optional for checking readings on the PC; see the [MSI monitoring guide](https://www.msi.com/support/technical_details/VGA_MSI_Utility_AfterBurner).
3. In RTSS, set **Application detection level → Low** for the game. Enable **Show own statistics** temporarily if you want to check detection.
4. Start the game and agent **4.0.0**, then open Orbit. Readings are detected through local shared memory; there is no direct phone connection to Afterburner or extra pairing key. **Tools → Settings → Set up FPS** includes the same steps.

**FPS:** RTSS has priority and does not need `ORBIT_PRESENTMON_CSV`. Games that block RTSS and some anti-cheat systems may be incompatible. The reading describes application frames and does not guarantee displayed FPS after frame generation or streaming. Set `ORBIT_GAME_PROCESSES` to the executable if a game is not recognized.

**Sensors:** Orbit can read only the graphs and units exposed by Afterburner. CPU/GPU watts, VRAM capacity and fan readings are not guaranteed on every PC. LibreHardwareMonitor remains optional for missing sensors: on **0.9.5+**, enable **Options → Remote Web Server → Run**, port **8085**. Orbit reads `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` supports another local port. Older versions can still use WMI. The interface change is [confirmed by the LibreHardwareMonitor maintainers](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Advanced FPS fallback:** PresentMon CSV captures remain supported when RTSS has no recent reading. Configure `ORBIT_PRESENTMON_CSV` and start the capture separately; v1, current default and v2 formats are supported. `ORBIT_PRESENTATION_CSV` remains a compatibility alias. See the [RTSS setup and PresentMon fallback (Romanian)](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Updating and troubleshooting

The agent in this version reports **4.0.0**. Stop the old agent, copy the updated **entire `Orbit-Windows-Agent` folder** to your PC, and restart with `start_agent.bat`. Keep the local `.orbit-token`, `.orbit-widget-token`, and `%LOCALAPPDATA%\Orbit` folder containing TLS identity and history; do not copy another computer's `.venv`. Add the certificate in Tools → My PCs for the new features. Update the app through Xcode too. Editing the project does not automatically update the copy running on your PC.

Open **Tools → Monitoring sources** to check the reported version and providers. On the PC, `check_monitoring.bat` or `.venv\Scripts\python.exe check_monitoring.py` checks available sources and FPS configuration without sending control commands. Keep Afterburner and RTSS running and open a game to check FPS; keep any fallback source you use running as well. Actual sensors, game frames, and Windows controls still need validation on your PC; automated checks also use mocked sources.

### Widgets and Dynamic Island

The WidgetKit extension includes five monitoring widgets: **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures**, and **Choose a PC metric**. The last lets you choose CPU, GPU, RAM, VRAM, power, temperature, or FPS; add multiple instances for different readings or PCs. Existing app and control shortcuts remain available.

Connect the PC, open **Tools → Settings → Widgets → Prepare widget access**, and copy the **read-only widget token**. Add a widget to your Home Screen, touch and hold it, choose **Edit Widget**, and enter the PC address, port **8765**, and this separate token. Current widgets use HTTP on the private network, separately from the app’s HTTPS connection. The widget reads directly from the agent, without App Groups or a paid Apple Developer account. Do not enter the main control token in widget configuration.

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

This includes files/transfers, clipboard, audio sessions, SQLite history, and TLS identity, alongside Afterburner/RTSS shared memory, HTTP/WMI sensors, FPS CSV formats, and traffic counter regressions. Windows setup is described in the agent guide. Native Windows controls, real sensors, Wake-on-LAN, and iPhone signing must be validated on the respective devices.
