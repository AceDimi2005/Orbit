# Orbit — PC companion

[Română](#romana) · [English](#english)

<a id="romana"></a>

## Română

Orbit are două părți: aplicațiile Apple din `Orbit-iOS` (iPhone/iPad, Apple Watch, Apple TV și Mac) și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

### Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` **4.3.0** pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. Agentul instalează dependențele, păstrează identitatea PC-ului și pornește în fundal în **System Tray** (zona **Hidden icons** din dreapta-jos), cu pictograma Orbit și meniu pentru **Run at Windows startup**, detalii de conectare și **Stop Orbit Companion**.
2. Permite Python în Windows Firewall pe rețeaua **Private**, inclusiv HTTPS **8766** și descoperirea Bonjour/mDNS **UDP 5353**. Pentru prima asociere, telefonul și PC-ul trebuie să fie în aceeași rețea locală.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege aceeași echipă pentru **Orbit** și **OrbitWidgets** și identificatori proprii dacă Xcode îi cere. Configurează același **App Group** în ambele ținte și `ORBIT_APP_GROUP_IDENTIFIER` pentru asocierea automată a widgeturilor; vezi [pașii de semnare](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Rulează Orbit, acordă acces la rețeaua locală și apasă **Find my PC** în onboarding. Alege PC-ul găsit, apoi introdu pe iPhone **codul de șase cifre afișat de agent și în dialogul Windows**. Codul expiră după **120 de secunde** și funcționează o singură dată. Orbit completează automat adresa, tokenurile, certificatul și datele Wake-on-LAN și salvează profilul. Profilul reține **adresa IPv4 reală** a PC-ului (de exemplu `192.168.1.196`), nu numele Bonjour `orbit-….local`: adresa simplă funcționează și prin Tailscale sau alte VPN-uri și pentru Wake-on-LAN. Numele `.local` rămâne salvat ca rezervă: dacă PC-ul primește alt IP, Orbit îl regăsește prin Bonjour și mută profilul automat. Profilurile vechi cu adresă `.local` sunt migrate la prima conectare.
5. Pentru alt calculator, deschide **Tools → My PCs → Find a PC nearby**. **Explore with sample data** permite explorarea interfeței fără conectare și afișează explicit valori simulate.

Asocierea folosește SRP și un răspuns criptat pentru a verifica PC-ul și a transfera credențialele; nu copiezi IP, MAC sau tokenuri în fluxul obișnuit. Tokenul principal al fiecărui PC rămâne separat în Keychain. Monitorizarea și comenzile folosesc **HTTPS cu verificarea certificatului acelui PC**, fără revenire la HTTP când verificarea eșuează. Files, Clipboard, Audio mixer și Sessions cer conexiunea criptată. Portul HTTP **8765** rămâne pentru clienți locali vechi. Nu publica porturile agentului pe Internet.

**Configurarea manuală avansată** rămâne în **Manual configuration** din onboarding și **My PCs → Add manually**. Folosește adresa, tokenul avansat și amprenta SHA-256 afișate de agent, apoi testează conexiunea. Este utilă dacă rețeaua blochează descoperirea; Bonjour nu traversează automat orice VPN sau rețea de oaspeți.

### Ce găsești în aplicație

- **Overview:** dashboard personalizabil cu CPU, GPU, RAM, VRAM, consum CPU/GPU, temperaturi, frecvență CPU, ventilatoare, trafic de rețea, activitate disc, uptime și FPS. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Stream:** streaming complet al PC-ului în aplicație, prin Sunshine, cu protocolul Moonlight implementat nativ (biblioteca `moonlight-common-c`, GPLv3, în `Orbit-iOS/Packages/MoonlightCore`). **Stream Desktop** sau atingerea unei aplicații din bibliotecă lansează aplicația pe PC și deschide stream-ul pe tot ecranul: video H.264/HEVC decodat hardware (VideoToolbox), HDR pe ecrane compatibile, audio Opus stereo/5.1/7.1, controllere (GameController, cu vibrații), tastatură hardware și software, trackpad sau touchscreen. **Stream Settings** cuprinde setările Moonlight: rezoluție (720p…4K sau nativă), 30–120 fps, bitrate recomandat sau manual, codec, HDR, frame pacing, audio pe PC, optimizarea setărilor jocului, închiderea aplicației la deconectare, dimensiunea pachetelor pentru VPN/Tailscale și statistici în timpul stream-ului. **Pair** asociază o dată cu Sunshine prin PIN; cu agentul 4.3 agentul poate introduce PIN-ul singur (**Pair automatically**, după ce salvezi o dată login-ul web UI al Sunshine pe PC) și poate porni Sunshine.
- **Files:** discuri și foldere accesibile contului Windows, transfer în ambele sensuri, previzualizare, favorite și organizare.
- **PC-urile tale în iCloud:** profilurile de PC (adresă, porturi, amprenta certificatului, MAC, token) se sincronizează prin iCloud Key-Value Storage între iPhone, Apple TV și Mac cu același Apple Account; asocierea făcută pe un dispozitiv apare pe celelalte, modificările mai noi câștigă, iar un PC șters dispare peste tot. Adresa păstrată este mereu IPv4 numeric (numele Bonjour `orbit-….local` rămâne doar ca rezervă).
- **Remote:** trackpad, clickuri, scroll, tastatură și media. **Desktop Preview** (din Stream sau Overview) afișează cadrele JPEG trimise de agent, fără audio; pentru jocuri folosește **Stream**.
- **Tools:** My PCs, Clipboard, Audio mixer, Sessions & graphs, Task Manager, specificații și sursele de monitorizare. **Settings** se deschide de aici și grupează Wake-on-LAN, onboarding, preview, widgeturi și Live Activity.

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

### Fișiere și transfer

Deschide **Files** și alege discul sau unul dintre folderele rapide: Desktop, Downloads, Documents, Pictures. **Back / Forward** urmăresc locurile vizitate, inclusiv căutarea și sortarea; **Up** deschide părintele, iar **Home** revine la locații. Favoritele sunt separate pentru fiecare PC, iar meniul vizibil al fiecărei intrări oferă acțiunile disponibile.

- **PC → iPhone:** descarcă fișiere, deschide previzualizarea Quick Look, apoi distribuie sau salvează în Fișiere.
- **Foldere întregi:** apasă **Download this folder as ZIP** sau alege **Download folder as ZIP** din meniul unui folder. Sunt păstrate structura, numele Unicode și directoarele goale. Pregătirea și descărcarea au progres separat și pot fi anulate; ZIP-ul se salvează prin meniul de distribuire. Selecția multiplă acceptă fișiere și foldere.
- **iPhone → PC:** trimite fișiere din Fișiere sau poze/video în folderul deschis, cu progres, viteză și anulare.
- **Organizare:** creează foldere, redenumește, mută pe același disc și trimite în Recycle Bin, cu confirmare. Fișierele existente nu sunt suprascrise automat.

Limitele pentru fișiere sunt **2 GiB/upload**, **16 GiB/download** și **64 MiB/previzualizare**. Arhiva unui folder permite **2 GiB de fișiere sursă și 2 GiB ZIP**, **10.000 de intrări**, **32 de niveluri sub folderul ales** și cel mult **120 de secunde de pregătire**. Agentul păstrează cel mult două operații de arhivare și șterge datele temporare la anulare sau după **10 minute**. Un fișier inaccesibil, protejat sau modificat în timpul pregătirii produce eroare pentru întreaga arhivă; nu se livrează un ZIP incomplet fără avertizare. Originalele rămân pe PC.

Accesul respectă permisiunile contului Windows; tokenurile și stocarea internă Orbit sunt protejate. Linkurile/junctions și căile de rețea UNC nu sunt disponibile. Uploadul de directoare și mutarea între discuri nu sunt incluse; mutarea între discuri este refuzată fără modificări. PC-ul și agentul trebuie să rămână pornite.

### Clipboard, mixer și sesiuni

În **Tools → Clipboard**, folosește **Paste from iPhone → Send text to PC** sau **Read PC clipboard → Copy to iPhone**. Se transferă numai text și linkuri, la cerere, până la **1 MiB**. Orbit nu urmărește clipboardul în fundal și nu salvează un istoric; textul ecranului este șters la ieșire sau la schimbarea PC-ului.

În **Tools → Audio mixer**, sesiunile aplicațiilor au volum și mute proprii, iar **Output** permite alegerea unei ieșiri active sau **System default** pentru aplicația respectivă. Pornește redarea dacă o aplicație nu apare. Glisările sunt grupate și livrate în ordine prin Windows Core Audio. Windows sau aplicația pot cere repornirea redării pentru schimbarea ieșirii; vezi [compatibilitatea și limitele mixerului](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

În **Tools → Sessions & graphs**, jocurile detectate pornesc automat o sesiune; **+** pornește o înregistrare manuală pentru activitatea desktopului. Oprește înregistrarea când ai terminat. Agentul salvează o măsurătoare la **5 secunde**, păstrează cel mult **100 de sesiuni / 30 de zile** și permite ștergerea sesiunilor încheiate. Graficele interactive includ FPS, încărcare și temperaturi CPU/GPU, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc citirile disponibile; senzorii lipsă rămân goluri, fără valori zero inventate. Sesiunile se păstrează pe PC, inclusiv dacă telefonul se deconectează. Acestea sunt mostre periodice, nu o captură completă a fiecărui cadru.

În **Tools → My PCs**, adaugă și selectează mai multe calculatoare. Fiecare are adresă, token, certificat și setări Wake-on-LAN proprii, inclusiv calcularea automată a broadcastului; configurația dashboardului și favoritele sunt separate. Asocierea prin **Find a PC nearby** salvează automat profilul și pregătește widgeturile. Profilurile manuale existente pot fi editate sau reasociate cu un cod nou. Datele profilurilor rămân pe telefon, iar secretele în Keychain. Schimbarea PC-ului închide contextul operațiilor vechi.

### Dashboardul tău

Deschide **Customize dashboard** din Overview sau Settings. Poți afișa/ascunde și reordona cele **17 tipuri de carduri**, alege una sau două coloane și ascunde separat jocul, volumul și comenzile rapide. Presetările **Balanced**, **Gaming** și **Everything** oferă puncte de pornire. Apasă **Done** pentru salvare; configurația se păstrează separat pentru fiecare PC. Textul de accesibilitate mare folosește automat o singură coloană.

Puterea CPU este valoarea **CPU package**, iar puterea GPU provine din senzorul plăcii video. Ele nu reprezintă consumul total al PC-ului la priză. Frecvența CPU indică sursa citirii; dacă nu există senzori live, valoarea nominală raportată de Windows este etichetată explicit. Turațiile ventilatoarelor nu sunt estimate. Debitele de rețea și disc folosesc diferențe între măsurători. Conectarea sau resetarea unui dispozitiv reinițializează numai contorul lui; celelalte continuă să fie măsurate. Traficul mic se afișează și în B/s sau KB/s. Adaptoarele active sunt selectate automat; `ORBIT_NETWORK_INTERFACE` permite alegerea explicită a unuia.

### Task Manager

Deschide **Tools → Task Manager**, caută numele/PID-ul și sortează descrescător după **CPU, GPU, RAM sau VRAM**, ori alfabetic. Memoria GPU dedicată și cea partajată din RAM sunt afișate separat. Citirile GPU folosesc contoarele Windows disponibile în driver; procentul reprezintă motorul cel mai ocupat al procesului. Un senzor sau o mostră lipsă apare ca **—**, inclusiv la prima citire.

**End task** cere confirmare și verifică identitatea PID + momentul creării procesului pentru a evita închiderea unui PID reutilizat. Pe Windows, terminarea este forțată și nu garantează salvarea lucrului. Procesele critice și agentul Orbit sunt protejate; aplicațiile nu sunt închise automat. Vezi [detaliile și limitele Windows](Orbit-Windows-Agent/README.md#task-manager-de-pe-telefon).

### Aspect

Tema implicită este **Noir**: fundal negru pur, suprafețe plate cu o linie fină de contur, o singură culoare de accent (cyan) pentru toate metricile și fără luminozitate ambientală sau gradiente. Este aplicată la fel pe iPhone/iPad, Apple Watch, Apple TV, Mac, widgeturi și Live Activity; instalările care încă foloseau vechiul implicit Ocean trec automat la Noir, iar o temă aleasă explicit se păstrează. **Tools → Appearance** oferă în continuare stilul **Crisp**/**Glass** și celelalte 11 teme (Ocean, Aurora, Violet, Ember, Graphite, Cyberpunk, Solar Gold, Crimson, Matrix, Arctic, Sakura), culoarea unică pentru metrici, lumina ambientală și feedbackul haptic. Fundalul animat a fost înlocuit cu unul static, iar fonturile rotunjite cu San Francisco standard. Setările de accesibilitate ale telefonului (Reduce Motion, Reduce Transparency, text mare) sunt respectate.

**Ce aduce noul UI** (iPhone/iPad, Apple Watch, Apple TV):

- Dashboard cu un card „hero” (gauge inelar pentru CPU, stare pulsând, ping, uptime, versiune agent, TLS) și carduri de metrici cu **sparkline** din ultimele 40 de citiri reale; senzorii lipsă rămân **—**.
- Remote cu trackpad nativ multitouch: un deget mută cursorul, două degete derulează (vertical și orizontal), atingere cu două degete = click dreapta, apăsare lungă = drag; viteză reglabilă, taste rapide, gamepad mapat pe tastatură.
- Pairing cu radar animat, câmp PIN din 6 celule și cronometru de expirare; profiluri PC cu stare TLS și Wake-on-LAN.
- Task Manager, Audio Mixer, Clipboard, Fișiere și Sesiuni cu același limbaj vizual (carduri glass, bare de utilizare, grafice cu zonă umplută).
- Apple Watch: pagini Overview, Power, Air Mouse și Audio, butoane mari și comenzi explicite pentru Crown. Gyro Glide, Laser Pointer și Touchpad trimit comenzi serializate prin iPhone sau HTTP(S), cu confirmare de la PC; pauza și schimbarea paginii opresc mișcarea și eliberează dragul. Datele expirate nu sunt afișate ca live. Wake-on-LAN de pe ceas folosește iPhone-ul apropiat.
- Apple TV: fundal ambient, hero cu gauge, secțiuni unitare și valori reale (fără „0°C” sau etichete inventate când senzorul lipsește); acțiunile media folosesc identificatorii corecți ai agentului.

### Aplicația pentru Mac

`Orbit-iOS/OrbitMac` este o aplicație **nativă macOS 14+** (SwiftUI + AppKit), ținta **OrbitMac** din același `Orbit.xcodeproj`. Nu este un port Catalyst: are fereastră cu bară laterală, meniuri, scurtături, element în bara de meniu și panou de Setări. Se conectează **doar** prin canalul HTTPS criptat cu amprenta PC-ului (fără HTTP vechi).

- **Prima conectare:** deschide **My PCs** (⌘0). PC-urile din rețea apar prin Bonjour; apasă **Pair** și introdu PIN-ul de șase cifre afișat de agent. Alternativ, **Import from iPhone** preia PC-urile deja asociate pe telefon prin iCloud sau prin rețeaua locală, iar **Manual** acceptă o adresă IP. Tokenul fiecărui PC stă în Keychain-ul Mac-ului.
- **Overview (⌘1):** hero cu gauge CPU, ping și uptime; grilă de metrici cu sparkline (CPU, GPU, RAM, VRAM, putere, temperaturi, rețea, disc, FPS), card pentru jocul activ, controale rapide (Lock, Sleep, Restart, Shut Down cu confirmare, HDR, screenshot) și specificațiile complete. Dashboardul se personalizează din butonul **Customize**.
- **Remote (⌘2):** pad de mouse cu captură a cursorului (⎋ eliberează), clickuri, scroll precis, drag, tastatură cu taste speciale, media, acțiuni rapide (Show desktop, Task view, Alt-Tab, Fullscreen) și gamepad.
- **Preview (⌘3):** previzualizarea desktopului în fereastra principală sau într-o fereastră separată (⌥⌘D) care poate sta deasupra celorlalte; modul **Control** trimite clickuri, drag, scroll și tastatură în coordonate normalizate; **Snapshot** copiază sau salvează cadrul curent.
- **Files (⌘4):** browser cu tabel sortabil, breadcrumb, căutare, favorite, descărcare în Finder, upload prin **drag & drop** din Finder, folder nou, redenumire, mutare și coș de reciclare, cu bară de progres pentru transferuri.
- **Processes (⌘5):** Task Manager cu sortare pe coloane, filtrare și **End Task** cu confirmare; auto-refresh configurabil.
- **Audio (⌘6) și Clipboard (⌘7):** mixer pe aplicații cu rutare pe ieșiri (când agentul o permite) și clipboard bidirecțional (Pull / Push / Copy to Mac / Paste from Mac).
- **Sessions (⌘8):** înregistrări de telemetrie cu grafice Swift Charts, statistici min/medie/max și export CSV. **Stream (⌘9):** aplicațiile Sunshine cu box art, asociere prin PIN cu Sunshine și **Stream** în fereastra proprie a aplicației (⇧⌘S pentru desktop): clic pe video capturează mouse-ul și tastatura, ⌃⌥⇧Z le eliberează; controllerele sunt redirecționate automat. Aplicația Moonlight separată rămâne opțională (**Open in Moonlight App**).
- **Bara de meniu:** CPU/GPU/RAM/FPS/temperatură la alegere lângă pictogramă; fereastra rapidă arată gauge-urile, volumul, Lock/Sleep/Screenshot sau **Power On** când PC-ul e oprit.
- **Setări (⌘,):** pornire la login, element în bara de meniu, interval de actualizare, notificări când PC-ul revine online, cele 12 teme comune cu iPhone-ul, Wake-on-LAN și verificarea actualizării agentului.

Notă pentru versiunile anterioare: aplicația Mac se bloca (fir principal la 100 %, „nu răspunde”) din cauza legării directe a elementului din bara de meniu la o preferință `@AppStorage`, ceea ce producea o buclă infinită de actualizare SwiftUI; a fost corectată, iar decodarea cadrelor din Desktop Preview nu mai rulează pe firul principal.

Cerințe: macOS 14 Sonoma sau mai nou; aceeași rețea locală pentru asociere; permisiunea **Local Network** la prima pornire. Dacă senzorul lipsește, aplicația afișează **—**, niciodată valori inventate.

### Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. NVIDIA `nvidia-smi` rămâne sursa prioritară pentru încărcare, temperatură, VRAM, consum și ventilator GPU, când sunt suportate. Pentru ceilalți senzori, agentul detectează **MSI Afterburner**, apoi LibreHardwareMonitor ca alternativă. Citirile mai multor plăci nu se amestecă, iar un senzor lipsă rămâne indisponibil. Modelul coolerului sau al sursei poate necesita completare manuală.

**Configurarea recomandată, fără CSV:**

1. Instalează [MSI Afterburner de pe site-ul MSI](https://www.msi.com/Landing/afterburner/graphics-cards), inclusiv **RivaTuner Statistics Server (RTSS)**, și lasă ambele programe pornite pe PC.
2. În **Afterburner → Settings → Monitoring**, bifează senzorii doriți din **Active hardware monitoring graphs**, inclusiv CPU/GPU temperature și Framerate, când există. Apasă **Apply**. **Show in On-Screen Display** este opțional pentru verificarea pe ecran; [ghidul MSI](https://www.msi.com/blog/msi-afterburner-on-screen-display/) arată opțiunile.
3. În RTSS, alege **Application detection level → Low** pentru joc. Poți activa temporar **Show own statistics** ca să verifici detectarea.
4. Pornește jocul și agentul **4.3.0**, apoi deschide Orbit. Datele sunt citite automat, prin memoria partajată locală; nu trebuie să conectezi telefonul direct la Afterburner sau să introduci o cheie suplimentară. În **Tools → Settings → Set up FPS** ai aceiași pași.

**FPS:** RTSS are prioritate și nu cere `ORBIT_PRESENTMON_CSV`. Jocurile care blochează RTSS sau unele sisteme anti-cheat pot rămâne incompatibile. Valoarea descrie cadrele aplicației, fără garanția FPS-ului afișat după generarea cadrelor sau streaming. Pentru un joc nerecunoscut, se poate configura executabilul prin `ORBIT_GAME_PROCESSES`.

**Senzori:** Orbit poate citi doar graficele și unitățile pe care Afterburner le expune; consumul CPU/GPU în wați, capacitatea VRAM și ventilatoarele nu sunt garantate pe orice PC. Dacă lipsește un senzor, LibreHardwareMonitor rămâne opțional: în versiunile **0.9.5+**, activează **Options → Remote Web Server → Run**, port **8085**. Orbit citește `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` permite alt port local. Versiunile vechi pot folosi WMI. Schimbarea interfeței este [confirmată de dezvoltatorii LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Alternativă avansată FPS:** captura PresentMon CSV rămâne acceptată, dacă RTSS nu oferă date recente. Configurează `ORBIT_PRESENTMON_CSV` și pornește captura separat; formatele v1, implicit actual și v2 sunt suportate. `ORBIT_PRESENTATION_CSV` rămâne alias de compatibilitate. Consultă [pașii RTSS și alternativa PresentMon](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Actualizare și diagnosticare

Agentul din această versiune raportează **4.3.0**. Oprește vechiul agent, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește cu `start_agent.bat`. Păstrează fișierele locale `.orbit-token`, `.orbit-widget-token` și folderul `%LOCALAPPDATA%\Orbit` cu identitatea TLS și istoricul; nu copia mediul `.venv` de pe alt calculator. Pentru asociere automată, folosește **Find my PC**; profilurile manuale existente rămân disponibile. Actualizează și aplicația din Xcode. Schimbările din proiect nu actualizează automat copia care rulează pe PC.

În **Tools → Monitoring sources**, verifică versiunea raportată și sursele datelor. Pe PC, `check_monitoring.bat` sau `.venv\Scripts\python.exe check_monitoring.py` verifică sursele disponibile și configurarea FPS fără să trimită comenzi de control. Păstrează Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS; dacă folosești o sursă alternativă, las-o pornită și pe aceea. Senzorii, cadrele jocului și comenzile Windows trebuie validate pe PC-ul tău; verificările automate folosesc și surse simulate.

### Widgeturi și Dynamic Island

WidgetKit oferă **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures**, **PC cooling**, **Storage activity**, **Network activity** și **Choose a PC metric**, plus scurtăturile către aplicație. Poți adăuga mai multe instanțe și alege PC-uri, indicatori și teme diferite.

După asocierea PC-ului, Orbit pregătește automat accesul widgeturilor. Adaugă widgetul pe Home Screen și alege un PC din **Edit Widget → PC**; **nu introduci IP, port sau token**. Aplicația și extensia au nevoie de același **App Group configurat și semnat în Xcode**. Este partajat exclusiv tokenul de monitorizare **read-only**, separat de tokenul principal privat. Widgeturile folosesc HTTPS și verifică certificatul PC-ului. Dacă partajarea nu este disponibilă, verifică semnarea și **Tools → Widgets → Refresh widget access**.

Widgeturile arată capturi periodice cu ora măsurătorii. De fiecare dată când aplicația citește telemetria, salvează ultima citire în App Group și reîmprospătează widgeturile, astfel încât un widget redă imediat ce a văzut aplicația (citiri mai noi de două minute), fără o conexiune proprie. Altfel, widgetul solicită singur o actualizare după **15 minute**, dar iOS decide programarea; citirile mai vechi de 15 minute sunt ascunse. PC-ul trebuie să fie accesibil în rețea.

În **Tools → Live Activity**, alege profilul **Overview / Gaming / Power**, stilul Lock Screen **Standard / Minimal / Detailed**, indicatorul compact, accentul și intervalul **5 / 10 / 15 secunde**. Stilul Detailed afișează și temperaturile CPU/GPU. Butonul **Stop** din insula extinsă sau stilul Detailed oprește activitatea. Când aplicația trece în fundal, ultimele valori rămân afișate până la expirarea lor (trei intervale), apoi activitatea este marcată ca învechită; Orbit cere iOS-ului un refresh în fundal (Background App Refresh) care, atunci când sistemul îl acordă, actualizează activitatea și widgeturile. iOS decide când rulează acest refresh: nu există actualizări continue garantate în fundal. Vezi [configurarea și semnarea iOS](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Conectează PC-ul măcar o dată pentru detectarea adresei MAC și a rețelei sau completează-le manual în Settings. Activează Wake-on-LAN în BIOS/UEFI și în proprietățile adaptorului Ethernet din Windows. PC-ul trebuie să rămână alimentat. Un pachet trimis nu garantează pornirea: Orbit așteaptă răspunsul agentului înainte să afișeze PC-ul drept conectat.

Broadcastul UDP poate avea restricții suplimentare pe iPhone; verifică nota din [ghidul de testare](Orbit-iOS/WIDGETS.md). Testarea pe simulator nu garantează funcționarea Wake-on-LAN pe telefonul fizic.

### Icon

Iconul este deja inclus în `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. Pentru a-l schimba, deschide **Assets → AppIcon** în Xcode și înlocuiește imaginea universală de 1024 × 1024 cu un PNG pătrat, opac. iOS aplică forma colțurilor.

Generat cu instrumentul integrat imagegen. Promptul folosit: „Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Publicare Apple TV

Selectează schema **OrbitTV**, destinația **Any tvOS Device**, apoi **Product → Archive**. Buildul curent este **10**. După actualizarea proiectului creează o arhivă nouă; arhivele vechi din Organizer păstrează configurația veche.

Catalogul `OrbitTV/Assets.xcassets/AppIcon.brandassets` include iconuri pe straturi pentru Home Screen și App Store, plus Top Shelf normal și Wide în variante 1x/2x. Ambele configurații folosesc **AppIcon**. Cheile `CFBundleIcons.CFBundlePrimaryIcon` și `TVTopShelfImage.TVTopShelfPrimaryImageWide` trebuie să existe și în `Info.plist` din aplicația arhivată, împreună cu imaginile compilate. Verificare locală: `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /cale/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. Grafica se poate regenera din iconul Orbit existent cu `swift Orbit-iOS/Tools/generate_tv_assets.swift`.

### Verificări de dezvoltare

Build pentru simulator:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme Orbit -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Build pentru Mac:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme OrbitMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
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

Verificări complete pe macOS, cu Swift și dependențele agentului: transfer HTTPS și asociere prin PIN între clientul Swift real și serverul Python. Folosesc certificate și date temporare; prima verificare SRP descarcă și compilează pachetele Swift fixate în proiect.

```sh
python Orbit-iOS/Tests/check_companion_transport.py
python Orbit-iOS/Tests/check_pin_pairing.py
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

Comanda include regresii pentru asocierea SRP și credențialele criptate, arhive ZIP/anulare, fișiere și transferuri, clipboard, sesiuni audio, istoric SQLite și identitate TLS, alături de Afterburner/RTSS, senzori HTTP/WMI, formatele CSV FPS și contoarele de trafic. Configurarea Windows este descrisă în ghidul agentului. Acțiunile fizice Windows, senzorii reali, Wake-on-LAN și semnarea pe iPhone necesită validare pe dispozitivele respective.

---

## English

Orbit has two parts: the Apple apps in `Orbit-iOS` (iPhone/iPad, Apple Watch, Apple TV and Mac) and the Windows agent in `Orbit-Windows-Agent`. Update both together.

### Getting started

1. Copy the entire `Orbit-Windows-Agent` **4.3.0** folder to your PC and run `start_agent.bat`. Python 3.11 or later is required. The agent installs dependencies, preserves this PC's identity, and runs in the Windows **System Tray** (bottom-right **Hidden icons** area) with the Orbit icon and a menu for **Run at Windows startup**, connection details, and **Stop Orbit Companion**.
2. Allow Python through Windows Firewall on **Private** networks, including HTTPS **8766** and Bonjour/mDNS discovery over **UDP 5353**. Use the same local network for initial pairing.
3. Open `Orbit-iOS/Orbit.xcodeproj` in Xcode. Choose the same team for **Orbit** and **OrbitWidgets**, using unique bundle identifiers if required. Configure the same **App Group** on both targets and `ORBIT_APP_GROUP_IDENTIFIER` for automatic widget setup; see the [signing instructions (Romanian)](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Run Orbit, grant local network access, and choose **Find my PC** during onboarding. Select your PC and enter the **six-digit code shown by the agent and its Windows dialog**. The code expires after **120 seconds** and works once. Orbit automatically fills in the address, tokens, certificate, and Wake-on-LAN details and saves the profile. The profile stores the PC's **plain IPv4 address** (for example `192.168.1.196`) rather than the Bonjour name `orbit-….local`, so it also works through Tailscale and other VPNs and for Wake-on-LAN. The `.local` name is kept as a fallback: if the PC's address changes, Orbit finds it again over Bonjour and moves the profile. Older `.local` profiles are migrated on the next connection.
5. Add another computer through **Tools → My PCs → Find a PC nearby**. **Explore with sample data** lets you try the interface without connecting and clearly marks simulated readings.

Pairing uses SRP and an encrypted response to verify the PC and transfer credentials; the normal flow needs no IP, MAC, or token copying. Each PC's main token stays separately in Keychain. Monitoring and controls use **HTTPS with verification of that PC's certificate**, without falling back to HTTP on a certificate error. Files, Clipboard, Audio mixer, and Sessions require encryption. HTTP port **8765** remains for legacy local clients. Do not expose the agent ports to the Internet.

**Advanced manual setup** remains under **Manual configuration** in onboarding and **My PCs → Add manually**. Enter the address, advanced access token, and SHA-256 fingerprint printed by the agent, then test the connection. This helps when the network blocks discovery; Bonjour does not automatically cross every VPN or guest network.

### Inside the app

- **Overview:** a customizable dashboard for CPU, GPU, RAM, VRAM, CPU/GPU power, temperatures, CPU clock, fans, network traffic, disk activity, uptime, and FPS. Missing readings are shown as unavailable.
- **Full PC specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. Open this screen from Overview or Settings. You can customize component names for each PC; leave a field empty to use the detected name.
- **Stream:** full in-app PC streaming through Sunshine with a native Moonlight protocol implementation (the GPLv3 `moonlight-common-c` library, vendored in `Orbit-iOS/Packages/MoonlightCore`). **Stream Desktop** or tapping a library app launches it on the PC and opens the full-screen stream: hardware-decoded H.264/HEVC video (VideoToolbox), HDR on capable displays, Opus stereo/5.1/7.1 audio, game controllers (GameController, with rumble), hardware and software keyboards, trackpad or touchscreen input. **Stream Settings** holds the Moonlight options: resolution (720p…4K or native), 30–120 fps, recommended or manual bitrate, codec, HDR, frame pacing, audio on the PC, optimize game settings, quit on disconnect, VPN/Tailscale packet size and a statistics overlay. **Pair** associates with Sunshine once by PIN; with agent 4.3 the agent can type the PIN itself (**Pair automatically**, after saving Sunshine's web UI login on the PC once) and start Sunshine.
- **Files:** drives and folders available to the Windows account, transfers in both directions, previews, favorites, and organization.
- **Your PCs in iCloud:** PC profiles (address, ports, certificate fingerprint, MAC, token) sync through iCloud Key-Value Storage between iPhone, Apple TV and Mac signed in to the same Apple Account; a PC paired on one device shows up on the others, newer edits win, and a PC removed anywhere disappears everywhere. The stored address is always the numeric IPv4 (the Bonjour `orbit-….local` name is kept only as a fallback).
- **Remote:** trackpad, clicks, scrolling, keyboard, and media controls. **Desktop Preview** (from Stream or Overview) shows the JPEG frames sent by the agent, without audio; use **Stream** for games.
- **Tools:** My PCs, Clipboard, Audio mixer, Sessions & graphs, Task Manager, specifications, and monitoring sources. Open **Settings** here for Wake-on-LAN, onboarding, preview mode, widgets, and Live Activity.

The volume slider directly updates the Windows audio level while you drag. Commands are sent in order, and intermediate positions are combined to keep the latest value. The old method that lowered the volume to zero before each adjustment has been removed. If the Windows audio service is unavailable, the control is shown as unavailable.

### Files and transfers

Open **Files** and choose a drive or a quick folder: Desktop, Downloads, Documents, or Pictures. **Back / Forward** follow visited locations, restoring search and sort; **Up** opens the parent and **Home** returns to locations. Favorites are saved per PC, and each entry has a visible action menu.

- **PC → iPhone:** download files, open Quick Look previews, and share or save to Files.
- **Entire folders:** use **Download this folder as ZIP**, or **Download folder as ZIP** in a folder's menu. Structure, Unicode names, and empty directories are preserved. Preparation and download show separate progress and support cancellation; save the ZIP through the share sheet. Multiple selection supports files and folders.
- **iPhone → PC:** send files from Files or photos/videos into the open folder, with progress, speed, and cancellation.
- **Organization:** create folders, rename, move on the same drive, and send items to Recycle Bin with confirmation. Existing files are never overwritten automatically.

File limits are **2 GiB/upload**, **16 GiB/download**, and **64 MiB/preview**. A folder archive allows **2 GiB of source files and a 2 GiB ZIP**, **10,000 entries**, **32 levels below the selected folder**, and **120 seconds of preparation**. The agent keeps at most two archive jobs and removes temporary data on cancellation or after **10 minutes**. Inaccessible, protected, or changing entries fail the complete archive rather than silently producing an incomplete ZIP. Originals remain on the PC.

Access follows the Windows account's permissions; Orbit tokens and private internal storage are protected. Links/junctions and UNC network paths are unavailable. Folder upload and moves between drives are not included; cross-drive moves are rejected without changes. The PC and agent must stay running.

### Clipboard, mixer, and sessions

In **Tools → Clipboard**, use **Paste from iPhone → Send text to PC** or **Read PC clipboard → Copy to iPhone**. Only text and links are transferred, on request, up to **1 MiB**. Orbit does not watch the clipboard in the background or save clipboard history. Text on this screen is cleared when you leave or change PCs.

In **Tools → Audio mixer**, application sessions have individual volume and mute controls, and **Output** chooses an active device or **System default** for that application. Start playback if an app is missing. Slider updates are combined and sent in order through Windows Core Audio. Windows or the app may require playback to restart before an output change takes effect; see [mixer compatibility and limits (Romanian)](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

In **Tools → Sessions & graphs**, detected games start sessions automatically; **+** starts a manual recording for desktop work. Stop recording when finished. The agent saves a reading every **5 seconds**, keeps at most **100 sessions / 30 days**, and allows completed sessions to be deleted. Interactive graphs include FPS, CPU/GPU load and temperatures, power, RAM, VRAM, and traffic. Averages and peaks use available measurements; missing sensors remain gaps without invented zeros. Sessions stay on the PC and continue if the phone disconnects. These are periodic samples, not a complete capture of every frame.

In **Tools → My PCs**, add and select multiple computers. Each has its own address, token, certificate, and Wake-on-LAN settings, including automatic broadcast calculation; dashboard configuration and file favorites are separate. Pairing through **Find a PC nearby** automatically saves the profile and prepares widgets. Existing manual profiles can be edited or paired again with a new code. Profile metadata stays on the phone and secrets stay in Keychain. Switching PCs clears the previous operation context.

### Your dashboard

Open **Customize dashboard** from Overview or Settings. Show, hide, and reorder **17 card types**, choose one or two columns, and independently hide the game, volume, and quick controls sections. Start with **Balanced**, **Gaming**, or **Everything**, then tap **Done** to save. Each PC keeps its own configuration. Larger accessibility text automatically uses one column.

CPU power is the **CPU package** reading; GPU power comes from the graphics card sensor. These readings do not measure the PC's total wall power. CPU clock shows its source; when live sensors are unavailable, the nominal Windows clock is explicitly labeled. Fan speeds are never estimated. Network and disk rates use differences between samples. A newly connected or reset device only primes its own counter; other devices keep reporting. Low network traffic also displays in B/s or KB/s. Active interfaces are selected automatically; set `ORBIT_NETWORK_INTERFACE` to choose one explicitly.

### Task Manager

Open **Tools → Task Manager**, search by name/PID, and sort descending by **CPU, GPU, RAM, or VRAM**, or alphabetically. Dedicated GPU memory and shared GPU memory from RAM appear separately. GPU readings use driver-provided Windows counters; the percentage represents the process's busiest GPU engine. Missing sensors or samples show **—**, including the first reading.

**End task** asks for confirmation and verifies PID + process creation time to avoid closing a reused PID. Termination on Windows is forceful and does not guarantee saved work. Critical processes and Orbit Agent are protected; applications are never ended automatically. See the [Windows details and limitations (Romanian)](Orbit-Windows-Agent/README.md#task-manager-de-pe-telefon).

### Appearance

The default theme is **Noir**: a pure black background, flat surfaces with a thin hairline border, one accent colour (cyan) for every metric, and no ambient glow or gradients. It is applied identically on iPhone/iPad, Apple Watch, Apple TV, Mac, widgets and the Live Activity; installs still on the old implicit default (Ocean) move to Noir automatically, while an explicitly chosen theme is kept. **Tools → Appearance** still offers the **Crisp**/**Glass** styles and the other 11 themes (Ocean, Aurora, Violet, Ember, Graphite, Cyberpunk, Solar Gold, Crimson, Matrix, Arctic, Sakura), the single metric colour, the ambient glow and haptic feedback. The animated background became static and rounded fonts were replaced with standard San Francisco. The phone's accessibility settings (Reduce Motion, Reduce Transparency, large text) are respected.

**What the UI refresh brings** (iPhone/iPad, Apple Watch, Apple TV):

- A dashboard hero card (CPU ring gauge, pulsing status, ping, uptime, agent version, TLS) and metric cards with **sparklines** built from the last 40 real readings; missing sensors still show **—**.
- A native multitouch trackpad in Remote: one finger moves, two fingers scroll (vertical and horizontal), two-finger tap right-clicks, long press drags; adjustable speed, quick keys and a keyboard-mapped gamepad.
- Pairing with an animated radar, a six-cell PIN field and an expiry countdown; PC profiles show TLS and Wake-on-LAN status.
- Task Manager, Audio Mixer, Clipboard, Files and Sessions share the same visual language (glass cards, usage bars, area charts).
- Apple Watch: Overview, Power, Air Mouse and Audio pages, large buttons and explicit Crown controls. Gyro Glide, Laser Pointer and Touchpad serialize input through iPhone or HTTP(S), with PC acknowledgement; pausing or leaving the page stops motion and releases drag. Stale readings are not shown as live. Watch Wake-on-LAN uses the nearby paired iPhone.
- Apple TV: ambient background, hero with ring gauge, unified sections and honest values (no “0°C” or invented labels when a sensor is missing); media actions use the agent’s real identifiers.

### Mac app

`Orbit-iOS/OrbitMac` is a **native macOS 14+** app (SwiftUI + AppKit), the **OrbitMac** target in the same `Orbit.xcodeproj`. It is not a Catalyst port: it has a sidebar window, menus, keyboard shortcuts, a menu bar item and a Settings panel. It connects **only** over the encrypted, fingerprint-pinned HTTPS channel (no legacy HTTP).

- **First connection:** open **My PCs** (⌘0). PCs on the network appear via Bonjour; press **Pair** and enter the six-digit PIN shown by the agent. Alternatively, **Import from iPhone** fetches the PCs already paired on your phone over iCloud or the local network, and **Manual** accepts an IP address. Each PC's token lives in the Mac Keychain.
- **Overview (⌘1):** hero with CPU ring, ping and uptime; a metric grid with sparklines (CPU, GPU, RAM, VRAM, power, temperatures, network, disk, FPS), an active-game card, quick controls (Lock, Sleep, Restart, Shut Down with confirmation, HDR, screenshot) and full specifications. Customize the dashboard with the **Customize** button.
- **Remote (⌘2):** a mouse pad with pointer capture (⎋ releases), clicks, precise scrolling, drag, keyboard with special keys, media, quick actions (Show desktop, Task view, Alt-Tab, Fullscreen) and a gamepad.
- **Preview (⌘3):** the desktop preview in the main window or in a separate window (⌥⌘D) that can float above others; **Control** mode sends clicks, drags, scrolling and typing in normalized coordinates; **Snapshot** copies or saves the current frame.
- **Files (⌘4):** a browser with a sortable table, breadcrumbs, search, favorites, download to Finder, upload by **drag & drop** from Finder, new folder, rename, move and recycle bin, with a transfer progress bar.
- **Processes (⌘5):** Task Manager with column sorting, filtering and **End Task** with confirmation; configurable auto-refresh.
- **Audio (⌘6) and Clipboard (⌘7):** per-app mixer with output routing (when the agent allows it) and a two-way clipboard (Pull / Push / Copy to Mac / Paste from Mac).
- **Sessions (⌘8):** telemetry recordings with Swift Charts graphs, min/average/max statistics and CSV export. **Stream (⌘9):** Sunshine apps with box art, PIN pairing with Sunshine and **Stream** in the app's own window (⇧⌘S for the desktop): click the video to capture mouse and keyboard, ⌃⌥⇧Z releases them; controllers are forwarded automatically. The separate Moonlight app stays optional (**Open in Moonlight App**).
- **Menu bar:** your choice of CPU/GPU/RAM/FPS/temperature next to the icon; the quick panel shows the gauges, volume, Lock/Sleep/Screenshot or **Power On** when the PC is off.
- **Settings (⌘,):** launch at login, menu bar item, refresh interval, notifications when the PC comes back online, the same 12 themes as the iPhone app, Wake-on-LAN and agent update checks.

Note for earlier builds: the Mac app used to hang (main thread at 100 %, "not responding") because the menu bar item was bound directly to an `@AppStorage` preference, which produced an endless SwiftUI update loop; this is fixed, and Desktop Preview frames are no longer decoded on the main thread.

Requirements: macOS 14 Sonoma or later; the same local network for pairing; the **Local Network** permission on first launch. When a sensor is missing the app shows **—**, never invented values.

### Sensors and FPS

Hardware inventory uses Windows CIM and system APIs. NVIDIA `nvidia-smi` remains the preferred GPU source for load, temperature, VRAM, power and fan readings where supported. For other sensors, the agent detects **MSI Afterburner**, with LibreHardwareMonitor as a fallback. Readings from different adapters are kept separate and missing sensors stay unavailable. Cooler and power supply names may require manual entry.

**Recommended setup, without CSV:**

1. Install [MSI Afterburner from MSI](https://www.msi.com/Landing/afterburner/graphics-cards), including **RivaTuner Statistics Server (RTSS)**, and keep both running on the PC.
2. In **Afterburner → Settings → Monitoring**, tick the desired **Active hardware monitoring graphs**, including CPU/GPU temperature and Framerate when present. Click **Apply**. **Show in On-Screen Display** is optional for checking readings on the PC; see the [MSI monitoring guide](https://www.msi.com/support/technical_details/VGA_MSI_Utility_AfterBurner).
3. In RTSS, set **Application detection level → Low** for the game. Enable **Show own statistics** temporarily if you want to check detection.
4. Start the game and agent **4.3.0**, then open Orbit. Readings are detected through local shared memory; there is no direct phone connection to Afterburner or extra pairing key. **Tools → Settings → Set up FPS** includes the same steps.

**FPS:** RTSS has priority and does not need `ORBIT_PRESENTMON_CSV`. Games that block RTSS and some anti-cheat systems may be incompatible. The reading describes application frames and does not guarantee displayed FPS after frame generation or streaming. Set `ORBIT_GAME_PROCESSES` to the executable if a game is not recognized.

**Sensors:** Orbit can read only the graphs and units exposed by Afterburner. CPU/GPU watts, VRAM capacity and fan readings are not guaranteed on every PC. LibreHardwareMonitor remains optional for missing sensors: on **0.9.5+**, enable **Options → Remote Web Server → Run**, port **8085**. Orbit reads `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` supports another local port. Older versions can still use WMI. The interface change is [confirmed by the LibreHardwareMonitor maintainers](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Advanced FPS fallback:** PresentMon CSV captures remain supported when RTSS has no recent reading. Configure `ORBIT_PRESENTMON_CSV` and start the capture separately; v1, current default and v2 formats are supported. `ORBIT_PRESENTATION_CSV` remains a compatibility alias. See the [RTSS setup and PresentMon fallback (Romanian)](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Updating and troubleshooting

The agent in this version reports **4.3.0**. Stop the old agent, copy the updated **entire `Orbit-Windows-Agent` folder** to your PC, and restart with `start_agent.bat`. Keep the local `.orbit-token`, `.orbit-widget-token`, and `%LOCALAPPDATA%\Orbit` folder containing TLS identity and history; do not copy another computer's `.venv`. Use **Find my PC** for automatic pairing; existing manual profiles remain available. Update the app through Xcode too. Editing the project does not automatically update the copy running on your PC.

Open **Tools → Monitoring sources** to check the reported version and providers. On the PC, `check_monitoring.bat` or `.venv\Scripts\python.exe check_monitoring.py` checks available sources and FPS configuration without sending control commands. Keep Afterburner and RTSS running and open a game to check FPS; keep any fallback source you use running as well. Actual sensors, game frames, and Windows controls still need validation on your PC; automated checks also use mocked sources.

### Widgets and Dynamic Island

WidgetKit includes **PC overview**, **Gaming snapshot**, **CPU & GPU power**, **CPU & GPU temperatures**, **PC cooling**, **Storage activity**, **Network activity**, and **Choose a PC metric**, plus app shortcuts. Add multiple instances and choose different PCs, metrics, and themes.

Pairing the PC automatically prepares widget access. Add a Home Screen widget and select a PC under **Edit Widget → PC**; **no IP, port, or token entry is needed**. The app and extension require the same **App Group registered and signed in Xcode**. Only the **read-only** monitoring token is shared; the main control token remains private. Widgets use HTTPS and verify the PC certificate. If sharing is unavailable, check signing and **Tools → Widgets → Refresh widget access**.

Widgets show periodic snapshots with the measurement timestamp. Every time the app reads telemetry it stores the latest reading in the App Group and reloads the widgets, so a widget renders immediately from what the app just saw (readings under two minutes old) without opening its own connection. Otherwise the widget requests an update after **15 minutes**, but iOS controls scheduling; readings older than 15 minutes are hidden. The PC must be reachable on your network.

Under **Tools → Live Activity**, choose **Overview / Gaming / Power**, a **Standard / Minimal / Detailed** Lock Screen style, compact metric, accent, and **5 / 10 / 15-second** interval. The Detailed style also shows CPU/GPU temperatures. **Stop** in the expanded island or Detailed style ends the activity. When the app goes to the background the last values stay visible until they expire (three intervals), then the activity is marked stale; Orbit asks iOS for a Background App Refresh which, when the system grants it, updates the activity and the widgets. iOS decides when that runs, so continuous background updates are not guaranteed. See the [iOS setup and signing guide (Romanian)](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Connect to your PC at least once to detect its MAC address and network settings, or enter them manually in Settings. Enable Wake-on-LAN in BIOS/UEFI and in the Windows Ethernet adapter properties. The PC must remain connected to power. Sending a packet does not guarantee a successful wake: Orbit waits for the agent to respond before showing the PC as connected.

UDP broadcast may face additional restrictions on iPhone; see the note in the [testing guide (Romanian)](Orbit-iOS/WIDGETS.md). A successful simulator test does not guarantee Wake-on-LAN will work on a physical phone.

### App icon

The icon is already included at `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. To change it, open **Assets → AppIcon** in Xcode and replace the universal 1024 × 1024 image with a square, opaque PNG. iOS applies the rounded corners.

Generated with the built-in imagegen tool. Prompt: “Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Apple TV submission

Choose **OrbitTV**, destination **Any tvOS Device**, then **Product → Archive**. The current build is **10**. Create a fresh archive after updating the project; existing archives in Organizer retain their old configuration.

`OrbitTV/Assets.xcassets/AppIcon.brandassets` contains layered Home Screen/App Store icons and standard/Wide Top Shelf images at 1x/2x. Both configurations select **AppIcon**. The archived app must contain `CFBundleIcons.CFBundlePrimaryIcon` and `TVTopShelfImage.TVTopShelfPrimaryImageWide` as well as the compiled images. Verify locally with `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /path/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. Regenerate the assets from the existing Orbit artwork with `swift Orbit-iOS/Tools/generate_tv_assets.swift`.

### Development checks

Build for the simulator:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme Orbit -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Build for Mac:

```sh
xcodebuild -project Orbit-iOS/Orbit.xcodeproj -scheme OrbitMac -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
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

End-to-end checks on macOS with Swift and the agent dependencies: HTTPS transfers and PIN pairing between the production Swift client and Python server. They use temporary certificates and data; the first SRP check resolves and builds the pinned Swift packages.

```sh
python Orbit-iOS/Tests/check_companion_transport.py
python Orbit-iOS/Tests/check_pin_pairing.py
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

This includes SRP pairing and encrypted credentials, ZIP archives/cancellation, files/transfers, clipboard, audio sessions, SQLite history, and TLS identity, alongside Afterburner/RTSS shared memory, HTTP/WMI sensors, FPS CSV formats, and traffic counter regressions. Windows setup is described in the agent guide. Native Windows controls, real sensors, Wake-on-LAN, and iPhone signing must be validated on the respective devices.

## Licență / License

Orbit este software liber: aplicațiile Apple sunt distribuite sub **GNU GPLv3 cu App Store Distribution Exception** (vezi `LICENSE`), pentru că includ motorul de streaming Moonlight (`moonlight-common-c`, GPLv3). Codul scris pentru Orbit este disponibil și sub MIT. Lista completă a componentelor terțe și licențele lor: `THIRD_PARTY_NOTICES.md`. Streaming-ul are nevoie de [Sunshine](https://app.lizardbyte.dev/Sunshine/) (LizardByte, GPLv3) pe PC.

Orbit is free software: the Apple apps are distributed under the **GNU GPLv3 with the App Store Distribution Exception** (see `LICENSE`) because they bundle the Moonlight streaming engine (`moonlight-common-c`, GPLv3). Code written for Orbit is also available under MIT. The full list of third-party components and licenses is in `THIRD_PARTY_NOTICES.md`. Streaming requires [Sunshine](https://app.lizardbyte.dev/Sunshine/) (LizardByte, GPLv3) on the PC.
