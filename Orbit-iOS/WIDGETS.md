# Widgeturi și Dynamic Island

Orbit include o extensie reală WidgetKit (`OrbitWidgets`) și o Live Activity ActivityKit. Widgeturile folosesc un **App Group** comun și Keychain pentru asociere automată, fără notificări push. În tabelul Apple actual, App Groups și Keychain Sharing sunt disponibile și coloanei gratuite **Apple Developer**. Setările se găsesc în **Tools → Settings**; aspectul, widgeturile și Live Activity au pagini dedicate și în **Tools**.

## Testare gratuită

1. Deschide `Orbit.xcodeproj` în Xcode.
2. În **Signing & Capabilities**, alege același **Personal Team** pentru țintele **Orbit** și **OrbitWidgets**. Păstrează **Automatically manage signing** activ.
3. Dacă identificatorii existenți nu sunt disponibili pentru contul tău, schimbă-i în ambele ținte: de exemplu `com.nume.orbit` și `com.nume.orbit.widgets`. Identificatorul extensiei trebuie să înceapă cu identificatorul aplicației. Activează același App Group în ambele ținte și setează `ORBIT_APP_GROUP_IDENTIFIER` la identificatorul înregistrat (de exemplu `group.com.nume.orbit`). Xcode trebuie să includă grupul în profilurile ambelor ținte. Nu este suficientă schimbarea textului din entitlements fără înregistrarea grupului.
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
| **PC cooling** | Ventilatoare CPU/GPU și lichid de răcire | Mic, mediu |
| **Storage activity** | Transfer citire/scriere al discurilor | Mic, mediu |
| **Network activity** | Transfer download/upload | Mic, mediu |
| **Choose a PC metric** | Un indicator ales: CPU, GPU, RAM, VRAM în procente sau GB, putere CPU/GPU, temperatură CPU/GPU ori FPS | Mic, mediu, Lock Screen circular sau dreptunghiular |

Poți adăuga mai multe instanțe, fiecare cu altă metrică sau alt PC. Există în continuare widgeturi cu scurtături către aplicație și controale. **Wake PC** deschide controalele și nu trimite automat o comandă.

Puterea CPU/GPU nu reprezintă consumul total al PC-ului la priză. Senzorii lipsă apar cu „—”. FPS apare când RTSS raportează cadre recente pentru joc. Agentul detectează automat RTSS pe PC, fără CSV. PresentMon rămâne alternativă; sursa sa poate fi **application FPS** (`MsBetweenPresents`) sau **CPU frame FPS** (`FrameTime` v2). Citirile nu garantează FPS-ul ecranului, al cadrelor generate sau al streamingului.

## Asociere automată a widgeturilor

1. Asociază PC-ul în aplicația Orbit. Aplicația pregătește automat accesul de monitorizare pentru widgeturi.
2. Adaugă widgetul pe Home Screen. PC-ul asociat este disponibil în lista **PC**; nu introduci IP, port sau token.
3. Prin **Edit Widget**, alege alt PC asociat, o metrică și o temă; implicită este **Noir** (fundal negru, un singur accent). Opțiunea **Use one accent colour** înlocuiește culorile separate ale metricilor cu accentul ales la celelalte teme.
4. Dacă accesul necesită refacere, deschide **Tools → Widgets → Refresh widget access** în timp ce PC-ul este conectat. Un PC șters din aplicație este eliminat și din lista disponibilă widgeturilor.

Widgeturile se conectează prin **HTTPS**, pe portul securizat al profilului, și verifică exact certificatul PC-ului deja asociat. Redirecturile nu sunt urmate. În Keychain-ul grupului comun este păstrat exclusiv tokenul **read-only** pentru `GET /api/widget/status`; tokenul principal de control rămâne în Keychain-ul privat al aplicației. Numele, adresa și amprenta certificatului sunt partajate separat pentru configurare. Datele de acces nu apar în câmpurile Edit Widget.

Widgeturile nu pot trimite comenzi, accesa fișiere sau închide procese. Un widget configurat explicit pentru un PC rămâne la acel PC când schimbi computerul activ în aplicație. Dacă nu are o selecție explicită, folosește PC-ul implicit partajat de aplicație. Configurația dashboardului nu înlocuiește layoutul ales pentru widget.

Dacă apare mesajul despre App Group, verifică semnarea ambelor ținte în Xcode; aplicația nu pretinde că accesul a fost partajat dacă salvarea în Keychain eșuează. După o instalare nouă, deblochează telefonul cel puțin o dată pentru accesul la aceste date. Conexiunile locale ale widgeturilor pot depinde și de permisiunea **Local Network** acordată aplicației.

## Actualizare și expirare

**Widgeturile de monitorizare** afișează capturi periodice, împreună cu ora măsurătorii furnizată de agent. Aplicația salvează după fiecare citire reușită un instantaneu în App Group (`Orbit.WidgetSnapshot.v1.<id PC>`) și reîmprospătează widgeturile cel mult o dată pe minut; un widget care găsește un instantaneu mai nou de două minute îl afișează direct, fără conexiune proprie. Altfel solicită o nouă citire după **15 minute**, dar iOS poate întârzia actualizarea; frecvența nu este garantată. După **15 minute** de la măsurătoare, valorile sunt marcate ca expirate și ascunse. PC-ul oprit, agentul indisponibil sau lipsa accesului la rețea produc un mesaj de indisponibilitate. Deschiderea Orbit permite verificarea conexiunii și citirea telemetriei curente.

**Live Activity** este separată de widgeturi. În **Tools → Live Activity** poți porni sau opri sesiunea și alege:

- Profilul **Overview**, **Gaming** sau **Power**.
- Stilul Lock Screen **Standard**, **Minimal** sau **Detailed**.
- Citirea compactă a insulei: automată, CPU, GPU, RAM, FPS, putere CPU/GPU sau VRAM.
- Accentul, afișarea numelui jocului și a orei ultimei actualizări.
- Intervalul de actualizare în foreground: **5, 10 sau 15 secunde**.

Insula extinsă și stilul Detailed oferă un buton real **Stop**, fără deschiderea aplicației; stilul Detailed afișează și temperaturile CPU/GPU. La trecerea în fundal, ultimele valori rămân afișate până la expirare (trei intervale), apoi iOS marchează activitatea ca învechită și apare **Paused · tap to refresh**. Orbit programează un **Background App Refresh** (`com.dimitrie.orbit.refresh`, `UIBackgroundModes: fetch`) cât timp activitatea rulează; când sistemul îl acordă, aplicația citește o dată telemetria și actualizează activitatea și instantaneul widgeturilor. Datele offline sau senzorii indisponibili nu sunt prezentate ca valori curente. Preferințele se aplică la următoarea actualizare a activității.

iOS poate suspenda aplicația; alegerea unui interval mai scurt nu acordă rulare continuă în fundal. Nu există promisiunea unor actualizări în timp real cu aplicația suspendată. Dynamic Island apare doar pe modele compatibile, iar iOS controlează prezentarea ei.

## Aspectul aplicației

Tema implicită este **Noir** (fundal negru, suprafețe plate, un singur accent). **Tools → Appearance** oferă stilurile **Crisp**/**Glass**, celelalte teme, o singură culoare pentru metrici și reducerea luminii de fundal. Aplicația respectă textul mărit și Reduce Transparency; modul de text accesibil folosește o coloană pe dashboard.

## Dacă lipsesc temperaturile sau FPS

Verifică întâi datele în aplicația principală, la **Tools → Monitoring sources**. Acolo vezi versiunea agentului (cea actuală: **4.1.0**), sursa senzorilor CPU/GPU, adaptorul de rețea și motivul indisponibilității FPS. Un widget nu poate crea senzori sau porni programele de monitorizare pe PC.

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
- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) — tabelul actual confirmă App Groups și Keychain Sharing pentru Apple Developer, inclusiv fără abonament plătit.
- [Configuring app groups](https://developer.apple.com/documentation/xcode/configuring-app-groups) — același grup pentru aplicație și extensie; grupul poate fi folosit și drept Keychain access group.
- [Sharing access to keychain items among a collection of apps](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) — partajarea selectivă a credențialelor între ținte.
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — UDP unicast nu cere entitlement multicast; UDP broadcast îl cere pe iOS.
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) — cerința se aplică indiferent de API, inclusiv BSD sockets.

Semnarea și afișarea pe un iPhone real depind de contul și permisiunile dispozitivului; buildul pentru simulator nu înlocuiește această verificare.
