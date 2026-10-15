# Widgeturi și Dynamic Island

Orbit **4.0.0** include o extensie reală WidgetKit (`OrbitWidgets`) și o Live Activity ActivityKit. Nu folosește App Groups, notificări push sau entitlements care cer un abonament Apple Developer plătit. Setările sunt acum în **Tools → Settings**; sursele de monitorizare sunt și în **Tools → Monitoring sources**.

## Testare gratuită

1. Deschide `Orbit.xcodeproj` în Xcode.
2. În **Signing & Capabilities**, alege același **Personal Team** pentru țintele **Orbit** și **OrbitWidgets**. Păstrează **Automatically manage signing** activ.
3. Dacă identificatorii existenți nu sunt disponibili pentru contul tău, schimbă-i în ambele ținte: de exemplu `com.nume.orbit` și `com.nume.orbit.widgets`. Identificatorul extensiei trebuie să înceapă cu identificatorul aplicației.
4. Rulează aplicația pe simulator sau pe iPhone. Pentru telefonul personal, activează Developer Mode dacă iOS îl solicită și acordă acces la rețeaua locală.
5. Pentru widget: ține apăsat pe Home Screen, alege **Edit → Add Widget → Orbit**, apoi alege un stil și o dimensiune. Widgeturile de monitorizare trebuie asociate cu PC-ul folosind pașii de mai jos. Există și variante pentru Lock Screen.
6. Pentru Live Activity: conectează PC-ul și pornește funcția din Orbit. Alege profilul **Overview**, **Gaming** sau **Power** din setările Live Activity. Verifică Lock Screen; Dynamic Island apare numai pe modelele de iPhone care au acest hardware. Extinde insula prin apăsare lungă. Permisiunea pentru Live Activities trebuie activată în setările iOS ale aplicației.

Personal Team are limite de instalare și semnare; aplicația trebuie de regulă reconstruită și reinstalată după șapte zile. Un abonament plătit este necesar pentru distribuirea prin App Store/TestFlight, nu pentru implementarea locală a widgeturilor și Live Activities.

## Alegerea widgetului

| Widget | Conținut | Dimensiuni |
| --- | --- | --- |
| **PC overview** | CPU, GPU, RAM și VRAM | Mic, mediu, mare |
| **Gaming snapshot** | FPS măsurat, VRAM utilizată, încărcare și temperatură GPU | Mic, mediu |
| **CPU & GPU power** | Putere CPU package și GPU în wați | Mic, mediu |
| **CPU & GPU temperatures** | Temperaturile CPU și GPU | Mic, mediu |
| **Choose a PC metric** | Un indicator ales: CPU, GPU, RAM, VRAM în procente sau GB, putere CPU/GPU, temperatură CPU/GPU ori FPS | Mic, mediu, Lock Screen circular sau dreptunghiular |

Poți adăuga mai multe instanțe, fiecare cu altă metrică sau alt PC. Există în continuare widgeturi cu scurtături către aplicație și controale. **Wake PC** deschide controalele și nu trimite automat o comandă.

Puterea CPU/GPU nu reprezintă consumul total al PC-ului la priză. Senzorii lipsă apar cu „—”. FPS apare când RTSS raportează cadre recente pentru joc. Agentul detectează automat RTSS pe PC, fără CSV. PresentMon rămâne alternativă; sursa sa poate fi **application FPS** (`MsBetweenPresents`) sau **CPU frame FPS** (`FrameTime` v2). Citirile nu garantează FPS-ul ecranului, al cadrelor generate sau al streamingului.

## Asocierea widgeturilor de monitorizare

1. Instalează și pornește agentul Windows actualizat. Conectează PC-ul în Orbit și acordă accesul la rețeaua locală pe iPhone.
2. În aplicație, deschide **Tools → Settings → Widgets → Prepare widget access**. Apasă **Copy read-only widget token**.
3. Adaugă unul dintre widgeturile de monitorizare pe Home Screen. Ține apăsat widgetul și alege **Edit Widget**.
4. Completează **PC address** cu IP-ul sau hostname-ul PC-ului, fără port; **Agent port** este implicit `8765`. Lipește tokenul în **Read-only widget token**. Pentru **Choose a PC metric**, selectează și **Metric**.
5. Păstrează PC-ul pornit și accesibil în aceeași rețea sau prin conexiunea ta VPN privată. Prima citire depinde de programarea iOS. Dacă apare o eroare de token, verifică dacă ai copiat tokenul pentru widgeturi, apoi repetă asocierea.

Widgetul comunică direct cu agentul. Nu citește Keychain-ul aplicației și nu are nevoie de App Groups. Configurarea este separată pentru fiecare instanță, inclusiv pe Lock Screen; dacă se schimbă IP-ul PC-ului, actualizează **Edit Widget**. Configurația dashboardului din aplicație nu schimbă automat layoutul widgeturilor.

**Conexiunea widgetului este separată de profilurile My PCs.** Aplicația 4.0.0 poate folosi certificatul PC-ului pentru HTTPS pe **8766**, dar aceste widgeturi continuă să citească HTTP pe portul compatibil **8765**, cu tokenul lor numai pentru citire. Nu completa portul 8766 în widgetul actual: acesta nu are configurare de certificat. Păstrează accesul pe 8765 în rețeaua privată dacă folosești widgeturile; acest transport nu este criptat. Selectarea altui PC în aplicație nu schimbă automat PC-ul fiecărui widget.

Nu introduce tokenul principal de control al PC-ului într-un widget. Agentul păstrează un secret separat în `.orbit-widget-token`: acesta autorizează numai `GET /api/widget/status`, un rezumat de monitorizare. Obținerea lui prin `POST /api/widget/pairing` cere tokenul principal al aplicației. Tokenul de widget nu poate trimite comenzi, închide procese sau accesa inventarul complet. Pentru revocare, oprește agentul, șterge `.orbit-widget-token`, repornește și asociază din nou widgeturile.

Noile funcții **Files**, **Clipboard**, **Audio mixer** și **Sessions & graphs** cer conexiunea criptată din **Tools → My PCs**, cu tokenul principal și amprenta SHA-256 copiată din fereastra PC-ului. Nu sunt accesibile din tokenul de widget. Istoricul sesiunilor este salvat de agent pe PC și continuă independent de actualizările widgeturilor sau de suspendarea aplicației iOS.

## Actualizare și expirare

**Widgeturile de monitorizare** afișează capturi periodice, împreună cu ora măsurătorii furnizată de agent. Solicită o nouă citire după **15 minute**, dar iOS poate întârzia actualizarea; frecvența nu este garantată. După **15 minute** de la măsurătoare, valorile sunt marcate ca expirate și ascunse. PC-ul oprit, agentul indisponibil sau lipsa accesului la rețea produc un mesaj de indisponibilitate. Deschiderea Orbit permite verificarea conexiunii și citirea telemetriei curente.

**Live Activity** este o funcție separată. Profilul **Overview** pune în față CPU/GPU/RAM, **Gaming** prioritizează FPS/VRAM/GPU, iar **Power** pune în față wații CPU/GPU. Aplicația o actualizează cel mult o dată la cinci secunde, cât timp poate rula și primi date. Ora ultimei actualizări rămâne vizibilă.

iOS poate suspenda aplicația în fundal. După **15 secunde** fără actualizare, Live Activity arată **Open to refresh** și ascunde valorile expirate. La o deconectare cunoscută arată **Offline**. Nu există monitorizare continuă garantată în fundal; o arhitectură suplimentară, de exemplu server și APNs, ar trebui evaluată separat.

## Dacă lipsesc temperaturile sau FPS

Verifică întâi datele în aplicația principală, la **Tools → Monitoring sources**. Acolo vezi versiunea agentului (cea actuală: **4.0.0**), sursa senzorilor CPU/GPU, adaptorul de rețea și motivul indisponibilității FPS. Un widget nu poate crea senzori sau porni programele de monitorizare pe PC.

Configurarea recomandată este **MSI Afterburner + RTSS**, lăsate pornite pe PC. În **Afterburner → Settings → Monitoring**, activează graficele dorite și apasă **Apply**. În RTSS, alege **Application detection level → Low** pentru joc, apoi pornește jocul. Agentul citește automat datele locale; nu ai nevoie de CSV sau alt token între Afterburner și Orbit. Vezi [pașii Windows](../Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat) sau **Tools → Settings → Set up FPS** în aplicație. Senzorii depind de hardware și de graficele expuse; jocurile care blochează RTSS pot rămâne incompatibile.

LibreHardwareMonitor rămâne o alternativă pentru senzori. Pentru **0.9.5+**, activează pe PC **Options → Remote Web Server → Run**, port **8085**, și păstrează programul deschis; rulează-l ca administrator dacă senzorii cer asta. Aceste versiuni [au eliminat WMI](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143), iar agentul citește acum `http://127.0.0.1:8085/data.json`. Pentru alt port local, configurează `ORBIT_LHM_URL` înainte de pornirea agentului. Versiunile vechi pot folosi WMI. GPU AMD/Intel poate avea date prin LibreHardwareMonitor chiar dacă `nvidia-smi` lipsește.

Dacă RTSS nu oferă FPS, poți folosi PresentMon separat și seta `ORBIT_PRESENTMON_CSV` la CSV-ul activ. Sunt acceptate v1, formatul implicit actual și v2 `CPUStartTime`/`FrameTime`. `ORBIT_PRESENTATION_CSV` este tolerată ca alias, dar folosește denumirea recomandată. Vezi [pașii de configurare și diagnosticare pe Windows](../Orbit-Windows-Agent/README.md#fps-real-cu-presentmon-opțional).

Actualizează **întregul folder `Orbit-Windows-Agent`** de pe PC, păstrând tokenurile locale și `%LOCALAPPDATA%\Orbit` cu certificatul și istoricul, fără a copia `.venv` de pe alt calculator, apoi repornește `start_agent.bat`. Actualizează și aplicația iOS; proiectul nu actualizează automat agentul care rulează pe PC. `check_monitoring.bat` din folderul agentului verifică sursele fără comenzi de control. După remedierea sursei, widgetul așteaptă în continuare actualizarea programată de iOS; Live Activity depinde de actualizările aplicației.

## Limitare separată: Wake-on-LAN pe iPhone

Permisiunea **Local Network** și semnarea gratuită nu garantează trimiterea de pachete broadcast. Apple cere entitlement-ul gestionat `com.apple.developer.networking.multicast` pentru UDP broadcast pe iOS, inclusiv când aplicația folosește BSD sockets. Proiectul nu adaugă acest entitlement restricționat; simpla adăugare manuală nu acordă autorizarea Apple.

Orbit încearcă și trimiterea UDP unicast direct la adresa IPv4 a PC-ului, operație care nu cere entitlement-ul multicast. Această variantă poate depinde de placa de rețea, configurația routerului și păstrarea asocierii IP–MAC în rețea când PC-ul doarme; nu înlocuiește garantat broadcastul. Confirmarea că un pachet a fost acceptat de sistem nu confirmă că PC-ul s-a trezit. Aplicația așteaptă răspunsul agentului pentru confirmare.

Pentru WoL broadcast fiabil pe dispozitiv fizic trebuie evaluată aprobarea Apple pentru Multicast Networking sau o soluție de releu WoL deja disponibilă pe router/un dispozitiv permanent pornit. Acestea nu sunt incluse în proiect. Testarea în simulator nu dovedește că broadcastul va funcționa pe iPhone. Această limitare nu afectează widgeturile, Live Activity locală sau monitorizarea și controlul prin conexiune directă la agent.

## Surse Apple

- [Food Truck: Building a SwiftUI multiplatform app](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) — exemplul Apple explică instalarea cu Personal Team atât pentru aplicație, cât și pentru ținta Widgets.
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) — extensia WidgetKit, pornirea locală în foreground, actualizarea și încetarea prin ActivityKit; push este o opțiune separată.
- [Keeping a widget up to date](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date) — WidgetKit folosește timeline-uri și bugete de actualizare administrate de iOS.
- [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) — limitele Personal Team și profilurile valabile șapte zile.
- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) — disponibilitatea serviciilor după tipul contului.
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — UDP unicast nu cere entitlement multicast; UDP broadcast îl cere pe iOS.
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) — cerința se aplică indiferent de API, inclusiv BSD sockets.

Semnarea și afișarea pe un iPhone real depind de contul și permisiunile dispozitivului; buildul pentru simulator nu înlocuiește această verificare.
