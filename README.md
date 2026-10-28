# Orbit — PC companion

[Română](#romana) · [English](#english)

<a id="romana"></a>

## Română

Orbit are două părți: aplicațiile Apple din `Orbit-iOS` (iPhone/iPad, Apple Watch, Apple TV și Mac) și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

### Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` **4.5.2** pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. Agentul instalează dependențele, păstrează identitatea PC-ului și pornește în fundal în **System Tray** (zona **Hidden icons** din dreapta-jos), cu pictograma Orbit și meniu pentru **Run at Windows startup**, detalii de conectare și **Stop Orbit Companion**.
2. Permite Python în Windows Firewall pe rețeaua **Private**, inclusiv HTTPS **8766** și descoperirea Bonjour/mDNS **UDP 5353**. Pentru prima asociere, telefonul și PC-ul trebuie să fie în aceeași rețea locală.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege aceeași echipă pentru **Orbit** și **OrbitWidgets** și identificatori proprii dacă Xcode îi cere. Configurează același **App Group** în ambele ținte și `ORBIT_APP_GROUP_IDENTIFIER` pentru asocierea automată a widgeturilor; vezi [pașii de semnare](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Rulează Orbit, acordă acces la rețeaua locală și apasă **Find my PC** în onboarding. Alege PC-ul găsit, apoi introdu pe iPhone **codul de șase cifre afișat de agent și în dialogul Windows**. Codul expiră după **120 de secunde** și funcționează o singură dată. Orbit completează automat adresa, tokenurile, certificatul și datele Wake-on-LAN și salvează profilul. Profilul reține **adresa IPv4 reală** a PC-ului (de exemplu `192.168.1.196`), nu numele Bonjour `orbit-….local`: adresa simplă funcționează și prin Tailscale sau alte VPN-uri și pentru Wake-on-LAN. Numele `.local` rămâne salvat ca rezervă: dacă PC-ul primește alt IP, Orbit îl regăsește prin Bonjour și mută profilul automat. Profilurile vechi cu adresă `.local` sunt migrate la prima conectare.
5. Pentru alt calculator, deschide **Tools → My PCs → Find a PC nearby**. **Explore with sample data** permite explorarea interfeței fără conectare și afișează explicit valori simulate.

Asocierea folosește SRP și un răspuns criptat pentru a verifica PC-ul și a transfera credențialele; nu copiezi IP, MAC sau tokenuri în fluxul obișnuit. Tokenul principal al fiecărui PC rămâne separat în Keychain. Monitorizarea și comenzile folosesc **HTTPS cu verificarea certificatului acelui PC**, fără revenire la HTTP când verificarea eșuează. Files, Clipboard, Audio mixer și Sessions cer conexiunea criptată. Portul HTTP **8765** rămâne pentru clienți locali vechi. Nu publica porturile agentului pe Internet.

**Configurarea manuală avansată** rămâne în **Manual configuration** din onboarding și **My PCs → Add manually**. Folosește adresa, tokenul avansat și amprenta SHA-256 afișate de agent, apoi testează conexiunea. Este utilă dacă rețeaua blochează descoperirea; Bonjour nu traversează automat orice VPN sau rețea de oaspeți.

### Ce găsești în aplicație

- **Overview:** dashboard personalizabil cu CPU, GPU, RAM, VRAM, consum CPU/GPU, temperaturi, frecvență CPU, ventilatoare, trafic de rețea, activitate disc, uptime și FPS. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Stream:** streaming complet al PC-ului în aplicație, prin Sunshine, cu protocolul Moonlight implementat nativ (biblioteca `moonlight-common-c`, GPLv3, în `Orbit-iOS/Packages/MoonlightCore`). **Stream Desktop** sau atingerea unei aplicații din bibliotecă lansează aplicația pe PC și deschide stream-ul pe tot ecranul: video H.264/HEVC decodat hardware (VideoToolbox), HDR pe ecrane compatibile, audio Opus stereo/5.1/7.1, controllere (GameController, cu vibrații), tastatură hardware și software, trackpad sau touchscreen. Pe iPhone și iPad, tastatura software are deasupra un rând de taste de PC: Win, Ctrl, Alt și Shift se aplică următoarei taste (și literelor tastate pe tastatură, deci Ctrl + c înseamnă Ctrl+C) sau rămân blocate după o atingere dublă, plus Esc, Tab, Del, săgeți, Home/End/PgUp/PgDn, F1–F12 și scurtături dintr-o atingere (Alt+Tab, Task View, Show Desktop, Game Bar, Task Manager, Print Screen; Alt+F4 cere întâi confirmare). **Stream Settings** cuprinde setările Moonlight: rezoluție (720p…4K sau nativă), 30–120 fps, bitrate recomandat sau manual, codec, HDR, frame pacing, audio pe PC, optimizarea setărilor jocului, închiderea aplicației la deconectare, dimensiunea pachetelor pentru rețele din afara casei (**Remote network**) și statistici în timpul stream-ului. **Pair** asociază o dată cu Sunshine prin PIN; cu agentul 4.3 agentul poate introduce PIN-ul singur (**Pair automatically**, după ce salvezi o dată login-ul web UI al Sunshine pe PC) și poate porni Sunshine. Sunshine 2026 are nevoie de agentul 4.3.1, care alege cererea de asociere a dispozitivului tău. Fiecare asociere folosește un certificat nou pentru acel PC (Sunshine 2026 respinge un certificat asociat de două ori), așa că intrările vechi „Orbit on …” din Sunshine → Clients pot fi șterse.
- **Stream pe tot ecranul (Fill Screen):** în **Stream Settings → Picture**, **Fill Screen** cere PC-ului o imagine de forma ecranului, în loc de **16:9**. Ea umple ecranul fără benzi negre doar dacă PC-ul poate da exact acea rezoluție, de obicei printr-un monitor virtual. Rândul de sub **Picture** arată dacă PC-ul e pregătit și deschide **Fill the Screen**: verificările (Sunshine, login-ul web UI al Sunshine, [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) cu comanda `winget` de copiat, rezoluția acestui ecran, monitorul virtual ales în Sunshine) și **Set Up This PC**, care adaugă rezoluția pe monitorul virtual și îl alege în Sunshine; Windows poate cere o dată aprobarea unui prompt PowerShell. Tot acolo sunt **Turn off the PC's monitor while streaming**, **Turn Off Fill Screen on …** și **Undo Orbit's Changes…**. Are nevoie de **Optimize game settings** pornit. Funcționează pe iPhone, iPad și Mac; Apple TV rămâne la 16:9. Vezi [partea de pe PC](Orbit-Windows-Agent/README.md#stream-pe-tot-ecranul-și-al-doilea-ecran-virtual-display-driver).
- **Second Screen** (Orbit Pro, Labs): **Tools → Second Screen** pe iPhone și iPad; pe Mac, cardul **Second Screen** din Stream sau **PC → Use This Mac as a Second Screen…**. Dispozitivul devine un monitor în plus pentru Windows: Orbit adaugă un monitor virtual exact de mărimea ecranului, la stânga sau la dreapta monitorului principal (**Side**, se poate schimba și cât e pornit), și deschide aplicația **Desktop** din Sunshine pe tot ecranul. Pe iPhone și iPad atingerile ajung direct pe monitorul virtual, iar sunetul rămâne pe PC. Pagina verifică pe rând ce trebuie: Sunshine asociat în Orbit, o aplicație **Desktop** în Sunshine, login-ul Sunshine salvat pe PC, Virtual Display Driver și nicio aplicație pornită în Sunshine. **Start Second Screen** îl pornește; **Turn Off** închide stream-ul, oprește monitorul virtual și pune la loc setările Sunshine; **Undo Orbit's Changes…** readuce setările de afișare ale Sunshine de dinainte de Orbit. Dacă rămâne pornit (de exemplu după ce Orbit a fost închis), Stream arată un avertisment cu **Turn Off**.
- **Files:** discuri și foldere accesibile contului Windows, transfer în ambele sensuri, previzualizare, favorite și organizare.
- **Wake-on-LAN de oriunde:** pachetul magic pleacă spre broadcast-ul rețelei, spre adresa PC-ului și, opțional, spre un **releu** (în My PCs → Wake-on-LAN: adresa Tailscale sau numele MagicDNS al routerului ori al unui dispozitiv mereu pornit, cu `:port` opțional), ca să funcționeze și prin Tailscale, nu doar din Wi-Fi-ul de acasă. Pe Overview apare **Locked** cât timp PC-ul este la ecranul de autentificare sau blocat, iar în Stream apare **Unlock PC** (pe Mac, **Unlock PC…**): Orbit îți cere întâi parola de Windows într-un câmp securizat, apoi deschide stream-ul și o tastează singur la ecranul de blocare, prin stream-ul criptat (Enter, o scurtă pauză, parola, Enter; Sunshine acceptă tastatura pe ecranul de login). Parola stă doar în memorie și se șterge după tastare sau dacă stream-ul eșuează; nu se salvează și nu trece prin API-ul de tastatură al agentului. Agentul poate porni **înainte de login** (meniul tray → „Start before Windows sign-in”).
- **PC-urile tale în iCloud:** profilurile de PC (adresă, Secondary IP, porturi, amprenta certificatului, MAC, token) se sincronizează prin iCloud Key-Value Storage între iPhone, Apple TV și Mac cu același Apple Account; asocierea făcută pe un dispozitiv apare pe celelalte, modificările mai noi câștigă, iar un PC șters dispare peste tot. Adresa păstrată este mereu IPv4 numeric (numele Bonjour `orbit-….local` rămâne doar ca rezervă).
- **Secondary IP (de exemplu Tailscale):** în **My PCs**, fiecare PC poate avea o **Secondary IP**: adresa lui Tailscale (sau a altui VPN) ori numele MagicDNS. Agentul raportează adresele Tailscale ale PC-ului (`tailscaleAddresses` în `/api/network-info`), iar Orbit oferă una dintre ele cu o atingere. Când adresa din rețeaua locală nu răspunde, aplicația, widgeturile, Shortcuts, Apple Watch, streaming-ul Sunshine și aplicațiile Mac și Apple TV folosesc adresa secundară, prin același HTTPS cu certificatul PC-ului verificat; pe Overview, **Link** arată **Remote**. Orbit încearcă din nou adresa locală la fiecare 30 de secunde și la orice schimbare de rețea și revine la ea imediat ce răspunde. Wake-on-LAN rămâne mereu pe adresa locală (un PC oprit nu este în Tailscale), iar webcamul folosește doar rețeaua locală.
- **Remote:** trackpad, clickuri, scroll, tastatură și media. **Desktop Preview** (din Stream sau Overview) afișează cadrele JPEG trimise de agent, fără audio; pentru jocuri folosește **Stream**.
- **Presentation:** telecomandă pentru prezentări, în **Tools → Presentation** sau în meniul din Remote (**Presentation Remote**): o zonă mare **Next** (sau glisare stânga/dreapta), **Back**, slide-ul x din y, timpul scurs și ora, **Start Slide Show** (**From the Beginning** / **From the Current Slide**), **Black**, **White**, **Go to** și **End** (cere confirmare). Cât rulează slide show-ul în PowerPoint pentru desktop, Orbit îl controlează direct și arată imaginea slide-ului și notițele vorbitorului, cu text reglabil; pentru Google Slides, un PDF sau alt program, agentul apasă tastele în fereastra din față ([detalii](Orbit-Windows-Agent/README.md#mod-prezentare)). Pe Apple Watch, pagina **Present**: o atingere trece la slide-ul următor, Digital Crown merge înainte sau înapoi, plus timpul scurs și, opțional, o atingere pe încheietură la câteva minute (**Tap reminders**); merge prin iPhone sau direct prin Wi-Fi-ul ceasului. În Shortcuts și Siri există acțiunea **Control Slide Show** și fraza „Next slide with Orbit”.
- **Webcam** (Orbit Pro, Labs): în **Tools → Webcam**, iPhone-ul sau iPad-ul devine camera web a PC-ului pentru aplicațiile care folosesc camere DirectShow (Chrome, Edge, Teams, Discord, Zoom, OBS), unde apare ca „DirectShow Softcam”. Aplicația Camera din Windows și aplicațiile din Microsoft Store nu o văd; sunetul rămâne la microfonul PC-ului. **Set Up on PC** instalează o dată camera virtuală [Softcam](https://github.com/tshino/softcam) (MIT), cu o singură confirmare de administrator în Windows; PC-ul are nevoie de Microsoft Visual C++ 2015–2022 Redistributable (x64 și x86), pe care Orbit îl verifică întâi. Apoi **Start Streaming**: camera din față sau din spate, 720p sau 1080p, 30 sau 15 fps; ținut orizontal, dispozitivul dă o imagine 16:9 completă. Imaginea pleacă criptată, doar prin rețeaua locală, direct la PC (niciodată prin Secondary IP). Orbit trebuie să rămână deschis pe ecranul Webcam: cât trimite imaginea, ecranul rămâne aprins (**Dim Screen** îl întunecă), iar camera se oprește când ieși din ecran sau din Orbit. Eliminarea de pe PC: **Webcam Options → Remove Webcam from PC…**. Vezi [partea de pe PC](Orbit-Windows-Agent/README.md#webcam-din-iphone).
- **Electricity Cost** (Orbit Pro): în **Tools → Electricity Cost**, costul și consumul estimate pentru luna aleasă: total, astăzi, media pe zi și orele de joc, un grafic pe zile (cost sau kWh), consumul pe jocuri și **Desktop & everything else**. Estimarea adună puterea CPU și GPU raportată de PC, restul PC-ului (**Rest of the PC**, implicit 60 W) și pierderile sursei (**Power supply efficiency**, implicit 88 %) și le înmulțește cu prețul pe kWh. Prețul este media publicată pentru gospodării în țara setată în Windows (cu taxe; pentru Europa, de la Eurostat) sau prețul tău (**Set Your Price** / **Change Price**; **Use the Published Average** revine la medie). Factura reală e mai mare: monitoarele, alte dispozitive și timpul în care PC-ul doarme sau e oprit nu sunt incluse. Detaliile unei sesiuni înregistrate arată și **Estimated energy**. Vezi [calculul și API-ul](Orbit-Windows-Agent/README.md#costul-curentului-și-rezumatul-lunar).
- **Monthly Summary** (Orbit Pro): în **Tools → Monthly Summary**, luna ta în jocuri: timpul de joc, zilele și sesiunile, jocul de top, fiecare joc cu FPS-ul mediu și temperatura maximă a GPU-ului, cea mai lungă sesiune și ziua cea mai plină, temperaturile maxime, energia și costul, comparația cu luna trecută. Pe iPhone apare ca pagini de tip story, pe iPad ca grilă de carduri. Butonul de distribuire face o imagine 1080 × 1350 cu luna, jocurile și totalurile, fără numele sau adresa PC-ului. La începutul lunii primești o notificare, dacă ai activat **My monthly summary is ready** în **Notifications**. Pe Mac, costul și rezumatul sunt în cardul **This Month** din Sessions.
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

În **Tools → Audio mixer**, sesiunile aplicațiilor au volum și mute proprii, iar **Output** permite alegerea unei ieșiri active sau **System default** pentru aplicația respectivă. Lista e ordonată ca în Windows Task Manager: întâi **Apps** (aplicațiile cu fereastră), apoi **Background processes**, la final **Windows** (System sounds); în fiecare grup, aplicațiile care redau acum apar primele și sunt marcate cu **Playing**. Fiecare aplicație are numele și iconul ei din Windows (agent 4.4+). Pornește redarea dacă o aplicație nu apare. Glisările sunt grupate și livrate în ordine prin Windows Core Audio. Windows sau aplicația pot cere repornirea redării pentru schimbarea ieșirii; vezi [compatibilitatea și limitele mixerului](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

În **Tools → Sessions & graphs**, jocurile detectate pornesc automat o sesiune; **+** pornește o înregistrare manuală pentru activitatea desktopului. Oprește înregistrarea când ai terminat. Agentul salvează o măsurătoare la **5 secunde**, păstrează cel mult **100 de sesiuni / 30 de zile** și permite ștergerea sesiunilor încheiate. Graficele interactive includ FPS, încărcare și temperaturi CPU/GPU, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc citirile disponibile; senzorii lipsă rămân goluri, fără valori zero inventate. Sesiunile se păstrează pe PC, inclusiv dacă telefonul se deconectează. Acestea sunt mostre periodice, nu o captură completă a fiecărui cadru.

În **Tools → My PCs**, adaugă și selectează mai multe calculatoare. Fiecare are adresă, Secondary IP, token, certificat și setări Wake-on-LAN proprii, inclusiv calcularea automată a broadcastului; configurația dashboardului și favoritele sunt separate. Asocierea prin **Find a PC nearby** salvează automat profilul și pregătește widgeturile. Profilurile manuale existente pot fi editate sau reasociate cu un cod nou. Profilurile se păstrează pe telefon și se sincronizează prin iCloud între dispozitivele tale (vezi **PC-urile tale în iCloud**); tokenul fiecărui PC stă în Keychain. Schimbarea PC-ului închide contextul operațiilor vechi.

### Dashboardul tău

Deschide **Customize dashboard** din Overview sau Settings. Poți afișa/ascunde și reordona cele **17 tipuri de carduri**, alege una sau două coloane și ascunde separat jocul, volumul și comenzile rapide. Presetările **Balanced**, **Gaming** și **Everything** oferă puncte de pornire. Apasă **Done** pentru salvare; configurația se păstrează separat pentru fiecare PC. Textul de accesibilitate mare folosește automat o singură coloană.

Puterea CPU este valoarea **CPU package**, iar puterea GPU provine din senzorul plăcii video. Ele nu reprezintă consumul total al PC-ului la priză. Frecvența CPU indică sursa citirii; dacă nu există senzori live, valoarea nominală raportată de Windows este etichetată explicit. Turațiile ventilatoarelor nu sunt estimate. Debitele de rețea și disc folosesc diferențe între măsurători. Conectarea sau resetarea unui dispozitiv reinițializează numai contorul lui; celelalte continuă să fie măsurate. Traficul mic se afișează și în B/s sau KB/s. Adaptoarele active sunt selectate automat; `ORBIT_NETWORK_INTERFACE` permite alegerea explicită a unuia.

### Task Manager

Deschide **Tools → Task Manager**, caută numele/PID-ul și sortează descrescător după **CPU, GPU, RAM sau VRAM**, ori alfabetic. Procesele care au icon în Windows îl afișează și în Orbit (agent 4.4+). Memoria GPU dedicată și cea partajată din RAM sunt afișate separat. Citirile GPU folosesc contoarele Windows disponibile în driver; procentul reprezintă motorul cel mai ocupat al procesului. Un senzor sau o mostră lipsă apare ca **—**, inclusiv la prima citire.

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
- **Sessions (⌘8):** înregistrări de telemetrie cu grafice Swift Charts, statistici min/medie/max și export CSV. Cardul **This Month** (Orbit Pro, ca toată pagina) arată costul estimat al curentului, kWh, timpul de joc și jocul de top, cu **Price…** pentru prețul pe kWh și **Monthly Summary** (luna la alegere, **Share**). **Stream (⌘9):** aplicațiile Sunshine cu box art, asociere prin PIN cu Sunshine și **Stream** în fereastra proprie a aplicației (⇧⌘S pentru desktop): clic pe video capturează mouse-ul și tastatura, ⌃⌥⇧Z le eliberează; controllerele sunt redirecționate automat. Aplicația Moonlight separată rămâne opțională (**Open in Moonlight App**). **Unlock PC…** cere întâi parola de Windows, ca pe iPhone. Cardul **Second Screen** (Orbit Pro, Labs; și **PC → Use This Mac as a Second Screen…**) folosește Mac-ul ca monitor în plus, pe tot ecranul, iar **Fill Screen** din Stream Settings funcționează și pe Mac.
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
4. Pornește jocul și agentul **4.5.2**, apoi deschide Orbit. Datele sunt citite automat, prin memoria partajată locală; nu trebuie să conectezi telefonul direct la Afterburner sau să introduci o cheie suplimentară. În **Tools → Settings → Set up FPS** ai aceiași pași.

**FPS:** RTSS are prioritate și nu cere `ORBIT_PRESENTMON_CSV`. Jocurile care blochează RTSS sau unele sisteme anti-cheat pot rămâne incompatibile. Valoarea descrie cadrele aplicației, fără garanția FPS-ului afișat după generarea cadrelor sau streaming. Pentru un joc nerecunoscut, se poate configura executabilul prin `ORBIT_GAME_PROCESSES`.

**Senzori:** Orbit poate citi doar graficele și unitățile pe care Afterburner le expune; consumul CPU/GPU în wați, capacitatea VRAM și ventilatoarele nu sunt garantate pe orice PC. Dacă lipsește un senzor, LibreHardwareMonitor rămâne opțional: în versiunile **0.9.5+**, activează **Options → Remote Web Server → Run**, port **8085**. Orbit citește `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` permite alt port local. Versiunile vechi pot folosi WMI. Schimbarea interfeței este [confirmată de dezvoltatorii LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Alternativă avansată FPS:** captura PresentMon CSV rămâne acceptată, dacă RTSS nu oferă date recente. Configurează `ORBIT_PRESENTMON_CSV` și pornește captura separat; formatele v1, implicit actual și v2 sunt suportate. `ORBIT_PRESENTATION_CSV` rămâne alias de compatibilitate. Consultă [pașii RTSS și alternativa PresentMon](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Actualizare și diagnosticare

Agentul din această versiune raportează **4.5.2**. Oprește vechiul agent, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește cu `start_agent.bat`. Păstrează fișierele locale `.orbit-token`, `.orbit-widget-token` și folderul `%LOCALAPPDATA%\Orbit` cu identitatea TLS și istoricul; nu copia mediul `.venv` de pe alt calculator. Pentru asociere automată, folosește **Find my PC**; profilurile manuale existente rămân disponibile. Actualizează și aplicația din Xcode. Schimbările din proiect nu actualizează automat copia care rulează pe PC.

În **Tools → Monitoring sources**, verifică versiunea raportată și sursele datelor. Pe PC, `check_monitoring.bat` sau `.venv\Scripts\python.exe check_monitoring.py` verifică sursele disponibile și configurarea FPS fără să trimită comenzi de control. Păstrează Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS; dacă folosești o sursă alternativă, las-o pornită și pe aceea. Senzorii, cadrele jocului și comenzile Windows trebuie validate pe PC-ul tău; verificările automate folosesc și surse simulate.

### Ramuri: `main` (stabil) și `beta`

- **`main` este linia stabilă.** Din ea se fac build-urile pentru App Store și din ea se actualizează toate PC Companion-urile cu **Beta updates** oprit. Arhiva `Orbit-Windows-Agent.zip` din rădăcină se reface numai pe `main`.
- **`beta` primește întâi funcțiile noi**, pentru toate aplicațiile (iPhone/iPad, Apple Watch, Apple TV, Mac) și pentru agentul Windows. Build-urile TestFlight se fac din `beta`; pe dispozitivele Apple, TestFlight este canalul beta, așa că aplicațiile nu au comutator separat. PC-urile primesc build-urile din `beta` numai cu **Beta updates** pornit în meniul din tray ([detalii](Orbit-Windows-Agent/README.md#actualizări-beta)).
- **Ce merge bine în beta trece în `main`** printr-un merge `beta → main`. Pe `main`, versiunea agentului devine stabilă (de exemplu 4.6.0b3 → 4.6.0) și se reface zip-ul: `git archive --format=zip -o Orbit-Windows-Agent.zip HEAD Orbit-Windows-Agent`.
- **Reparațiile urgente se fac direct pe `main`** (versiune patch, de exemplu 4.5.3), apoi `main` se unește în `beta`. La un conflict pe `AGENT_VERSION`, păstrează versiunea din `beta`, care trebuie să rămână mai mare decât cea stabilă.
- **Versiunile agentului** urmează PEP 440: `4.6.0b1` = 4.6.0 beta 1, iar 4.5.2 < 4.6.0a1 < 4.6.0b1 < 4.6.0b2 < 4.6.0rc1 < 4.6.0. Crește numărul beta (`b1` → `b2`) la fiecare schimbare din `beta` care trebuie să ajungă pe PC-uri. Opțional, publică un GitHub Release cu tag-ul `pc-v4.6.0b1` bifat ca **pre-release**.
- GitHub Actions rulează testele agentului la fiecare push pe `main` și pe `beta`.

### Widgeturi și Dynamic Island

WidgetKit oferă **PC Overview**, **Gaming Snapshot**, **CPU & GPU Power**, **Temperatures**, **PC Cooling**, **Storage Activity**, **Network Activity** și **Single PC Metric**, plus **Buttons** (butoanele tale Orbit), **Orbit Power & Quick Controls** (Power On, Sleep, Shut Down; Orbit Pro) și, pe iOS 18+, butoane în Control Center. Poți adăuga mai multe instanțe și alege PC-uri, indicatori și teme diferite.

După asocierea PC-ului, Orbit pregătește automat accesul widgeturilor. Adaugă widgetul pe Home Screen și alege un PC din **Edit Widget → PC**; **nu introduci IP, port sau token**. Aplicația și extensia au nevoie de același **App Group configurat și semnat în Xcode**. Widgeturile de monitorizare folosesc tokenul **read-only**; butoanele care trimit comenzi (alimentare și **Buttons**) folosesc tokenul principal, pe care aplicația îl păstrează pentru ele în Keychain-ul App Group-ului. Widgeturile folosesc HTTPS și verifică certificatul PC-ului. Dacă partajarea nu este disponibilă, verifică semnarea și **Tools → Widgets & Siri → Sync Widget Credentials**.

Widgeturile arată capturi periodice cu ora măsurătorii. De fiecare dată când aplicația citește telemetria, salvează ultima citire în App Group și reîmprospătează widgeturile, astfel încât un widget redă imediat ce a văzut aplicația (citiri mai noi de două minute), fără o conexiune proprie. Altfel widgetul întreabă singur PC-ul, la adresa lui și apoi la Secondary IP, și cere următoarea actualizare după **10 minute**, dar iOS decide programarea. O citire mai veche de **3 minute** rămâne afișată estompat, cu ora ei; dacă PC-ul nu răspunde, widgetul păstrează ultima citire, estompată, până la **24 de ore**, în loc să arate liniuțe.

În **Tools → Live Activity**, alege profilul **Overview / Gaming / Power**, stilul Lock Screen **Standard / Minimal / Detailed**, indicatorul compact, accentul și intervalul **5 / 10 / 15 secunde**. Pe Lock Screen, Standard arată trei metrici ale profilului, Minimal una singură, mare, iar Detailed adaugă temperaturile CPU/GPU și butoanele **Sleep** și **Shut Down** (Orbit Pro), deschiderea aplicației și ✕, care oprește activitatea; insula extinsă are aceleași trei metrici și butoane. Cât PC-ul e oprit sau nu răspunde, activitatea arată ora ultimei citiri și **Power On** (Orbit Pro). Pe iOS 18+ apare și în Smart Stack pe Apple Watch și în CarPlay. Când aplicația trece în fundal, ultimele valori rămân afișate; după trei intervale fără o citire nouă rămân estompate, cu ora lor (**Last reading · open Orbit to refresh**). Orbit cere iOS-ului un refresh în fundal (Background App Refresh) care, atunci când sistemul îl acordă, actualizează activitatea și widgeturile. iOS decide când rulează acest refresh: nu există actualizări continue garantate în fundal. Vezi [configurarea și semnarea iOS](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Conectează PC-ul măcar o dată pentru detectarea adresei MAC și a rețelei sau completează-le manual în Settings. Activează Wake-on-LAN în BIOS/UEFI și în proprietățile adaptorului Ethernet din Windows. PC-ul trebuie să rămână alimentat. Un pachet trimis nu garantează pornirea: Orbit așteaptă răspunsul agentului înainte să afișeze PC-ul drept conectat.

Broadcastul UDP poate avea restricții suplimentare pe iPhone; verifică nota din [ghidul de testare](Orbit-iOS/WIDGETS.md). Testarea pe simulator nu garantează funcționarea Wake-on-LAN pe telefonul fizic.

### Icon

Iconul este deja inclus în `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. Pentru a-l schimba, deschide **Assets → AppIcon** în Xcode și înlocuiește imaginea universală de 1024 × 1024 cu un PNG pătrat, opac. iOS aplică forma colțurilor.

Generat cu instrumentul integrat imagegen. Promptul folosit: „Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Publicare Apple TV

Selectează schema **OrbitTV**, destinația **Any tvOS Device**, apoi **Product → Archive**. Buildul curent este **10**. După actualizarea proiectului creează o arhivă nouă; arhivele vechi din Organizer păstrează configurația veche.

Catalogul `OrbitTV/Assets.xcassets/AppIcon.brandassets` include iconuri pe straturi pentru Home Screen și App Store, plus Top Shelf normal și Wide în variante 1x/2x. Ambele configurații folosesc **AppIcon**. Cheile `CFBundleIcons.CFBundlePrimaryIcon` și `TVTopShelfImage.TVTopShelfPrimaryImageWide` trebuie să existe și în `Info.plist` din aplicația arhivată, împreună cu imaginile compilate. Verificare locală: `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /cale/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. Toate iconurile (iPhone/iPad, Watch, Mac, straturile Apple TV, Top Shelf și logo-ul `OrbitMark`) se regenerează cu `python3 Orbit-iOS/Tools/generate_app_icons.py` (necesită numpy, scipy și Pillow); iconurile Orbit Pro alternative nu sunt atinse.

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

Ordinea mixerului audio și iconurile aplicațiilor, de la agent la modelele Swift de pe iPhone, Mac și Apple TV, plus încărcarea iconurilor în loturi:

```sh
python Orbit-iOS/Tests/check_app_icons.py
```

Costul curentului și rezumatul lunar: un registru de energie umplut prin trackerele reale ale agentului, răspunsurile rutelor `/api/energy/*`, `/api/summary` și ale detaliilor de sesiune decodate de modelele Swift și comparate cheie cu cheie, formatarea costurilor, datele demo și imaginea de distribuire 1080 × 1350 (Python cu dependențele agentului și Swift instalat):

```sh
python Orbit-iOS/Tests/check_energy_summary.py
```

Telecomanda de prezentare: modelele Swift (cronometrul, coada de atingeri, mementourile de pe Apple Watch, decodarea tolerantă) față de routerul real din `orbit_presentation.py`, cu un PowerPoint simulat și refuzurile 409/422/503, plus numele acțiunilor trimise de iPhone, Apple Watch și Shortcuts. Nu apasă nicio tastă și nu contactează niciun PC:

```sh
python Orbit-iOS/Tests/check_presentation.py
```

Fill Screen și Second Screen: modelele aplicației față de un PC simulat (pornire, oprire, erori, schimbarea PC-ului în timpul citirilor, modul demo), apoi cererile clientului Swift real, prin TLS fixat, către routerul `/api/stream/display` al agentului, cu Sunshine, Virtual Display Driver și Windows simulate:

```sh
python Orbit-iOS/Tests/check_stream_display.py
```

Webcamul, fără PC, cameră sau simulator: stările, instalarea și eliminarea date de `orbit_webcam.py`, mesajele `WS /ws/camera` decodate de aplicație, iar JPEG-urile aplicației trecute prin decodorul agentului (mărimea, imaginea dreaptă și neoglindită, benzi laterale când telefonul stă vertical):

```sh
python Orbit-iOS/Tests/check_webcam_contract.py
```

Canalul de actualizări al companionului: `/api/status` și `/api/update/check` pe canalele stabil și beta (fără downgrade), decodate de modelele iPhone și Mac, plus afișarea versiunilor beta („4.6.0 beta 1”) identică în agent și în aplicații:

```sh
python Orbit-iOS/Tests/check_companion_channel.py
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

#### GitHub Actions

Două workflow-uri rulează pe GitHub. Le poți porni și manual din tabul **Actions**, cu **Run workflow**.

- **Companion tests** (`.github/workflows/companion-tests.yml`) rulează testele unitare ale agentului cu Python 3.12 și dependențele din `Orbit-Windows-Agent/requirements-dev.txt`, pe `windows-latest` și pe `ubuntu-latest` (aceeași comandă ca mai sus). Pornește la fiecare push pe `main` care modifică `Orbit-Windows-Agent/`.
- **Softcam DLLs** (`.github/workflows/softcam.yml`) compilează [Softcam](https://github.com/tshino/softcam) (MIT) de la un commit fixat (tag `v1.8.1`): Release pentru x64 și Win32 cu MSBuild, apoi testele proiectului. Publică artefactul `orbit-softcam` cu `softcam64.dll`, `softcam32.dll`, licența Softcam (`LICENSE`), licența MIT a Microsoft pentru DirectShow BaseClasses incluse în DLL-uri (`LICENSE-BaseClasses`), commitul exact (`UPSTREAM_COMMIT`), `BUILD-INFO.txt` (cu versiunea minimă de Visual C++ Redistributable) și `SHA256SUMS`. Pornește la cerere și la push-uri pe `main` care modifică workflow-ul sau `tools/softcam/`. Înainte să pui DLL-urile în `Orbit-Windows-Agent/webcam/`, verifică artefactul descărcat cu `python3 tools/softcam/softcam_artifact.py verify <folder>`. Copiază ambele licențe lângă DLL-uri și trece Softcam și DirectShow BaseClasses (Microsoft, MIT) în `THIRD_PARTY_NOTICES.md` (detalii în `tools/softcam/README.md`).

---

## English

Orbit has two parts: the Apple apps in `Orbit-iOS` (iPhone/iPad, Apple Watch, Apple TV and Mac) and the Windows agent in `Orbit-Windows-Agent`. Update both together.

### Getting started

1. Copy the entire `Orbit-Windows-Agent` **4.5.2** folder to your PC and run `start_agent.bat`. Python 3.11 or later is required. The agent installs dependencies, preserves this PC's identity, and runs in the Windows **System Tray** (bottom-right **Hidden icons** area) with the Orbit icon and a menu for **Run at Windows startup**, connection details, and **Stop Orbit Companion**.
2. Allow Python through Windows Firewall on **Private** networks, including HTTPS **8766** and Bonjour/mDNS discovery over **UDP 5353**. Use the same local network for initial pairing.
3. Open `Orbit-iOS/Orbit.xcodeproj` in Xcode. Choose the same team for **Orbit** and **OrbitWidgets**, using unique bundle identifiers if required. Configure the same **App Group** on both targets and `ORBIT_APP_GROUP_IDENTIFIER` for automatic widget setup; see the [signing instructions (Romanian)](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Run Orbit, grant local network access, and choose **Find my PC** during onboarding. Select your PC and enter the **six-digit code shown by the agent and its Windows dialog**. The code expires after **120 seconds** and works once. Orbit automatically fills in the address, tokens, certificate, and Wake-on-LAN details and saves the profile. The profile stores the PC's **plain IPv4 address** (for example `192.168.1.196`) rather than the Bonjour name `orbit-….local`, so it also works through Tailscale and other VPNs and for Wake-on-LAN. The `.local` name is kept as a fallback: if the PC's address changes, Orbit finds it again over Bonjour and moves the profile. Older `.local` profiles are migrated on the next connection.
5. Add another computer through **Tools → My PCs → Find a PC nearby**. **Explore with sample data** lets you try the interface without connecting and clearly marks simulated readings.

Pairing uses SRP and an encrypted response to verify the PC and transfer credentials; the normal flow needs no IP, MAC, or token copying. Each PC's main token stays separately in Keychain. Monitoring and controls use **HTTPS with verification of that PC's certificate**, without falling back to HTTP on a certificate error. Files, Clipboard, Audio mixer, and Sessions require encryption. HTTP port **8765** remains for legacy local clients. Do not expose the agent ports to the Internet.

**Advanced manual setup** remains under **Manual configuration** in onboarding and **My PCs → Add manually**. Enter the address, advanced access token, and SHA-256 fingerprint printed by the agent, then test the connection. This helps when the network blocks discovery; Bonjour does not automatically cross every VPN or guest network.

### Inside the app

- **Overview:** a customizable dashboard for CPU, GPU, RAM, VRAM, CPU/GPU power, temperatures, CPU clock, fans, network traffic, disk activity, uptime, and FPS. Missing readings are shown as unavailable.
- **Full PC specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. Open this screen from Overview or Settings. You can customize component names for each PC; leave a field empty to use the detected name.
- **Stream:** full in-app PC streaming through Sunshine with a native Moonlight protocol implementation (the GPLv3 `moonlight-common-c` library, vendored in `Orbit-iOS/Packages/MoonlightCore`). **Stream Desktop** or tapping a library app launches it on the PC and opens the full-screen stream: hardware-decoded H.264/HEVC video (VideoToolbox), HDR on capable displays, Opus stereo/5.1/7.1 audio, game controllers (GameController, with rumble), hardware and software keyboards, trackpad or touchscreen input. On iPhone and iPad the software keyboard carries a row of PC keys: Win, Ctrl, Alt and Shift apply to the next key (also to letters typed on the keyboard, so Ctrl + c is Ctrl+C) or stay locked after a double tap, plus Esc, Tab, Del, arrows, Home/End/PgUp/PgDn, F1–F12 and one-tap shortcuts (Alt+Tab, Task View, Show Desktop, Game Bar, Task Manager, Print Screen; Alt+F4 asks first). **Stream Settings** holds the Moonlight options: resolution (720p…4K or native), 30–120 fps, recommended or manual bitrate, codec, HDR, frame pacing, audio on the PC, optimize game settings, quit on disconnect, a smaller packet size for streaming away from home (**Remote network**) and a statistics overlay. **Pair** associates with Sunshine once by PIN; with agent 4.3 the agent can type the PIN itself (**Pair automatically**, after saving Sunshine's web UI login on the PC once) and start Sunshine. Sunshine 2026 needs agent 4.3.1, which picks this device's waiting pairing request. Every pairing uses a new certificate for that PC (Sunshine 2026 refuses a certificate that was paired twice), so older “Orbit on …” entries in Sunshine → Clients can be removed.
- **Full-screen streams (Fill Screen):** in **Stream Settings → Picture**, **Fill Screen** asks the PC for a picture in this screen's shape instead of **16:9**. It only fills the screen edge to edge when the PC can output exactly that size, which usually takes a virtual display. The row under **Picture** shows whether the PC is ready and opens **Fill the Screen**: the checks (Sunshine, Sunshine's web UI login, the [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) with its `winget` command to copy, this screen's size, the virtual display selected in Sunshine) and **Set Up This PC**, which adds the size to the virtual display and points Sunshine at it; Windows may ask once to approve a PowerShell prompt. The same page has **Turn off the PC's monitor while streaming**, **Turn Off Fill Screen on …** and **Undo Orbit's Changes…**. It needs **Optimize game settings** on. Works on iPhone, iPad and Mac; Apple TV stays 16:9. See [the PC side (Romanian)](Orbit-Windows-Agent/README.md#stream-pe-tot-ecranul-și-al-doilea-ecran-virtual-display-driver).
- **Second Screen** (Orbit Pro, Labs): **Tools → Second Screen** on iPhone and iPad; on the Mac, the **Second Screen** card in Stream or **PC → Use This Mac as a Second Screen…**. The device becomes an extra monitor for Windows: Orbit adds a virtual display at the screen's exact size, to the left or right of the main monitor (**Side**, which can also change while it is on), and opens Sunshine's **Desktop** app full screen. On iPhone and iPad, touch lands directly on the virtual display, and the sound stays on the PC. The page checks each requirement in turn: Sunshine paired in Orbit, a **Desktop** app in Sunshine, the Sunshine login saved on the PC, the Virtual Display Driver, and nothing running in Sunshine. **Start Second Screen** turns it on; **Turn Off** ends the stream, turns the virtual display off and puts Sunshine's settings back; **Undo Orbit's Changes…** restores Sunshine's display settings from before Orbit changed them. If it stays on (for example after Orbit was closed), Stream shows a warning with **Turn Off**.
- **Files:** drives and folders available to the Windows account, transfers in both directions, previews, favorites, and organization.
- **Wake-on-LAN from anywhere:** the magic packet goes to the subnet broadcast, to the PC's own address and, optionally, to a **relay** (My PCs → Wake-on-LAN: the Tailscale address or MagicDNS name of your router or of an always-on device, optional `:port`), so waking works over Tailscale too, not only from home Wi-Fi. Overview shows **Locked** while the PC sits at the sign-in or lock screen, and Stream offers **Unlock PC** (**Unlock PC…** on the Mac): Orbit first asks for your Windows password in a secure field, then opens the stream and types it at the lock screen through the encrypted stream (Enter, a short wait, the password, Enter; Sunshine accepts keyboard input on the sign-in screen). The password is kept in memory only and cleared once it is typed or if the stream fails; it is never saved and never sent through the agent's keyboard API. The agent can start **before sign-in** (tray menu → “Start before Windows sign-in”).
- **Your PCs in iCloud:** PC profiles (address, Secondary IP, ports, certificate fingerprint, MAC, token) sync through iCloud Key-Value Storage between iPhone, Apple TV and Mac signed in to the same Apple Account; a PC paired on one device shows up on the others, newer edits win, and a PC removed anywhere disappears everywhere. The stored address is always the numeric IPv4 (the Bonjour `orbit-….local` name is kept only as a fallback).
- **Secondary IP (for example Tailscale):** in **My PCs**, each PC can have a **Secondary IP**: its Tailscale (or other VPN) address or MagicDNS name. The agent reports the PC's Tailscale addresses (`tailscaleAddresses` in `/api/network-info`), and Orbit offers one of them with a single tap. When the local address doesn't answer, the app, widgets, Shortcuts, Apple Watch, Sunshine streaming and the Mac and Apple TV apps use the secondary address, over the same HTTPS with the PC's certificate checked; Overview then shows **Link** as **Remote**. Orbit tries the local address again every 30 seconds and after any network change, and goes back to it as soon as it answers. Wake-on-LAN always stays on the local address (a powered-off PC isn't on Tailscale), and the webcam uses the local network only.
- **Remote:** trackpad, clicks, scrolling, keyboard, and media controls. **Desktop Preview** (from Stream or Overview) shows the JPEG frames sent by the agent, without audio; use **Stream** for games.
- **Presentation:** a presentation remote in **Tools → Presentation** or in the Remote tab's menu (**Presentation Remote**): a large **Next** area (or swipe left/right), **Back**, slide x of y, the elapsed time and the clock, **Start Slide Show** (**From the Beginning** / **From the Current Slide**), **Black**, **White**, **Go to** and **End** (asks first). While a PowerPoint for desktop slide show runs, Orbit controls it directly and shows the slide's picture and the speaker notes, with adjustable text size; for Google Slides, a PDF or another program, the agent presses keys in the window in front ([details, Romanian](Orbit-Windows-Agent/README.md#mod-prezentare)). On Apple Watch, the **Present** page: tap for the next slide, the Digital Crown goes forward or back, plus the elapsed time and an optional tap on the wrist every few minutes (**Tap reminders**); it works through the iPhone or straight over the Watch's Wi-Fi. Shortcuts and Siri get the **Control Slide Show** action and the phrase “Next slide with Orbit”.
- **Webcam** (Orbit Pro, Labs): in **Tools → Webcam**, the iPhone or iPad becomes the PC's webcam for apps that use DirectShow cameras (Chrome, Edge, Teams, Discord, Zoom, OBS), where it shows up as “DirectShow Softcam”. The Windows Camera app and Microsoft Store apps can't see it; sound stays on the PC's microphone. **Set Up on PC** installs the [Softcam](https://github.com/tshino/softcam) (MIT) virtual camera once, with a single Windows administrator prompt; the PC needs the Microsoft Visual C++ 2015–2022 Redistributable (x64 and x86), which Orbit checks first. Then **Start Streaming**: front or back camera, 720p or 1080p, 30 or 15 fps; held sideways, the device gives a full 16:9 picture. The picture travels encrypted, over the local network only, straight to the PC (never over the Secondary IP). Orbit has to stay open on the Webcam screen: while it sends, the screen stays on (**Dim Screen** darkens it), and the camera stops when you leave the screen or Orbit. To remove it from the PC: **Webcam Options → Remove Webcam from PC…**. See [the PC side (Romanian)](Orbit-Windows-Agent/README.md#webcam-din-iphone).
- **Electricity Cost** (Orbit Pro): in **Tools → Electricity Cost**, the estimated cost and energy for the chosen month: the total, today, the daily average and gaming hours, a day-by-day chart (cost or kWh), energy per game and **Desktop & everything else**. The estimate adds the CPU and GPU power the PC reports, the rest of the PC (**Rest of the PC**, 60 W by default) and power supply losses (**Power supply efficiency**, 88 % by default), then multiplies by the price per kWh. The price is the published household average for the country set in Windows (taxes included; from Eurostat in Europe) or your own (**Set Your Price** / **Change Price**; **Use the Published Average** goes back to the average). Your bill will be higher: monitors, other devices and the time the PC sleeps or is off are not counted. A recorded session's details also show **Estimated energy**. See [how it is worked out and the API (Romanian)](Orbit-Windows-Agent/README.md#costul-curentului-și-rezumatul-lunar).
- **Monthly Summary** (Orbit Pro): in **Tools → Monthly Summary**, your month in games: play time, days and sessions, the top game, every game with its average FPS and peak GPU temperature, the longest session and the busiest day, peak temperatures, energy and cost, and a comparison with last month. On iPhone it comes as story pages, on iPad as a grid of cards. The share button makes a 1080 × 1350 picture with the month, games and totals, without the PC's name or address. At the start of a month you get a notification if **My monthly summary is ready** is on in **Notifications**. On the Mac, cost and summary are in the **This Month** card in Sessions.
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

In **Tools → Audio mixer**, application sessions have individual volume and mute controls, and **Output** chooses an active device or **System default** for that application. The list follows Windows Task Manager: **Apps** (applications with a window) first, then **Background processes**, then **Windows** (System sounds); inside each group, apps playing right now come first and are marked **Playing**. Each app shows its Windows name and icon (agent 4.4+). Start playback if an app is missing. Slider updates are combined and sent in order through Windows Core Audio. Windows or the app may require playback to restart before an output change takes effect; see [mixer compatibility and limits (Romanian)](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

In **Tools → Sessions & graphs**, detected games start sessions automatically; **+** starts a manual recording for desktop work. Stop recording when finished. The agent saves a reading every **5 seconds**, keeps at most **100 sessions / 30 days**, and allows completed sessions to be deleted. Interactive graphs include FPS, CPU/GPU load and temperatures, power, RAM, VRAM, and traffic. Averages and peaks use available measurements; missing sensors remain gaps without invented zeros. Sessions stay on the PC and continue if the phone disconnects. These are periodic samples, not a complete capture of every frame.

In **Tools → My PCs**, add and select multiple computers. Each has its own address, Secondary IP, token, certificate, and Wake-on-LAN settings, including automatic broadcast calculation; dashboard configuration and file favorites are separate. Pairing through **Find a PC nearby** automatically saves the profile and prepares widgets. Existing manual profiles can be edited or paired again with a new code. Profiles are stored on the phone and sync through iCloud between your devices (see **Your PCs in iCloud**); each PC's token is kept in Keychain. Switching PCs clears the previous operation context.

### Your dashboard

Open **Customize dashboard** from Overview or Settings. Show, hide, and reorder **17 card types**, choose one or two columns, and independently hide the game, volume, and quick controls sections. Start with **Balanced**, **Gaming**, or **Everything**, then tap **Done** to save. Each PC keeps its own configuration. Larger accessibility text automatically uses one column.

CPU power is the **CPU package** reading; GPU power comes from the graphics card sensor. These readings do not measure the PC's total wall power. CPU clock shows its source; when live sensors are unavailable, the nominal Windows clock is explicitly labeled. Fan speeds are never estimated. Network and disk rates use differences between samples. A newly connected or reset device only primes its own counter; other devices keep reporting. Low network traffic also displays in B/s or KB/s. Active interfaces are selected automatically; set `ORBIT_NETWORK_INTERFACE` to choose one explicitly.

### Task Manager

Open **Tools → Task Manager**, search by name/PID, and sort descending by **CPU, GPU, RAM, or VRAM**, or alphabetically. Processes that have an icon in Windows show it in Orbit too (agent 4.4+). Dedicated GPU memory and shared GPU memory from RAM appear separately. GPU readings use driver-provided Windows counters; the percentage represents the process's busiest GPU engine. Missing sensors or samples show **—**, including the first reading.

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
- **Sessions (⌘8):** telemetry recordings with Swift Charts graphs, min/average/max statistics and CSV export. The **This Month** card (Orbit Pro, like the whole page) shows the estimated electricity cost, kWh, play time and top game, with **Price…** for the price per kWh and **Monthly Summary** (any month, **Share**). **Stream (⌘9):** Sunshine apps with box art, PIN pairing with Sunshine and **Stream** in the app's own window (⇧⌘S for the desktop): click the video to capture mouse and keyboard, ⌃⌥⇧Z releases them; controllers are forwarded automatically. The separate Moonlight app stays optional (**Open in Moonlight App**). **Unlock PC…** asks for the Windows password first, as on iPhone. The **Second Screen** card (Orbit Pro, Labs; also **PC → Use This Mac as a Second Screen…**) uses the Mac as an extra monitor, full screen, and **Fill Screen** in Stream Settings works on the Mac too.
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
4. Start the game and agent **4.5.2**, then open Orbit. Readings are detected through local shared memory; there is no direct phone connection to Afterburner or extra pairing key. **Tools → Settings → Set up FPS** includes the same steps.

**FPS:** RTSS has priority and does not need `ORBIT_PRESENTMON_CSV`. Games that block RTSS and some anti-cheat systems may be incompatible. The reading describes application frames and does not guarantee displayed FPS after frame generation or streaming. Set `ORBIT_GAME_PROCESSES` to the executable if a game is not recognized.

**Sensors:** Orbit can read only the graphs and units exposed by Afterburner. CPU/GPU watts, VRAM capacity and fan readings are not guaranteed on every PC. LibreHardwareMonitor remains optional for missing sensors: on **0.9.5+**, enable **Options → Remote Web Server → Run**, port **8085**. Orbit reads `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` supports another local port. Older versions can still use WMI. The interface change is [confirmed by the LibreHardwareMonitor maintainers](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Advanced FPS fallback:** PresentMon CSV captures remain supported when RTSS has no recent reading. Configure `ORBIT_PRESENTMON_CSV` and start the capture separately; v1, current default and v2 formats are supported. `ORBIT_PRESENTATION_CSV` remains a compatibility alias. See the [RTSS setup and PresentMon fallback (Romanian)](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Updating and troubleshooting

The agent in this version reports **4.5.2**. Stop the old agent, copy the updated **entire `Orbit-Windows-Agent` folder** to your PC, and restart with `start_agent.bat`. Keep the local `.orbit-token`, `.orbit-widget-token`, and `%LOCALAPPDATA%\Orbit` folder containing TLS identity and history; do not copy another computer's `.venv`. Use **Find my PC** for automatic pairing; existing manual profiles remain available. Update the app through Xcode too. Editing the project does not automatically update the copy running on your PC.

Open **Tools → Monitoring sources** to check the reported version and providers. On the PC, `check_monitoring.bat` or `.venv\Scripts\python.exe check_monitoring.py` checks available sources and FPS configuration without sending control commands. Keep Afterburner and RTSS running and open a game to check FPS; keep any fallback source you use running as well. Actual sensors, game frames, and Windows controls still need validation on your PC; automated checks also use mocked sources.

### Branches: `main` (stable) and `beta`

- **`main` is the stable line.** App Store builds come from it, and every PC Companion with **Beta updates** turned off updates from it. The root `Orbit-Windows-Agent.zip` is refreshed on `main` only.
- **`beta` gets new features first**, for all apps (iPhone/iPad, Apple Watch, Apple TV, Mac) and the Windows agent. TestFlight builds come from `beta`; on Apple devices TestFlight is the beta channel, so the apps have no separate switch. PCs get `beta` builds only with **Beta updates** turned on in the tray menu ([details, Romanian](Orbit-Windows-Agent/README.md#actualizări-beta)).
- **What works in beta moves to `main`** with a `beta → main` merge. On `main`, the agent version becomes stable (for example 4.6.0b3 → 4.6.0) and the zip is rebuilt: `git archive --format=zip -o Orbit-Windows-Agent.zip HEAD Orbit-Windows-Agent`.
- **Urgent fixes go to `main` first** (a patch version, for example 4.5.3), then `main` is merged into `beta`. On an `AGENT_VERSION` conflict, keep the `beta` version, which must stay above the stable one.
- **Agent versions** follow PEP 440: `4.6.0b1` = 4.6.0 beta 1, and 4.5.2 < 4.6.0a1 < 4.6.0b1 < 4.6.0b2 < 4.6.0rc1 < 4.6.0. Raise the beta number (`b1` → `b2`) with every `beta` change that should reach PCs. Optionally publish a GitHub Release tagged `pc-v4.6.0b1` and marked **pre-release**.
- GitHub Actions runs the agent tests on every push to `main` and `beta`.

### Widgets and Dynamic Island

WidgetKit includes **PC Overview**, **Gaming Snapshot**, **CPU & GPU Power**, **Temperatures**, **PC Cooling**, **Storage Activity**, **Network Activity**, and **Single PC Metric**, plus **Buttons** (your Orbit buttons), **Orbit Power & Quick Controls** (Power On, Sleep, Shut Down; Orbit Pro) and, on iOS 18+, Control Center buttons. Add multiple instances and choose different PCs, metrics, and themes.

Pairing the PC automatically prepares widget access. Add a Home Screen widget and select a PC under **Edit Widget → PC**; **no IP, port, or token entry is needed**. The app and extension require the same **App Group registered and signed in Xcode**. Monitoring widgets use the **read-only** token; the buttons that send commands (power and **Buttons**) use the main token, which the app keeps for them in the App Group's Keychain. Widgets use HTTPS and verify the PC certificate. If sharing is unavailable, check signing and **Tools → Widgets & Siri → Sync Widget Credentials**.

Widgets show periodic snapshots with the measurement timestamp. Every time the app reads telemetry it stores the latest reading in the App Group and reloads the widgets, so a widget renders immediately from what the app just saw (readings under two minutes old) without opening its own connection. Otherwise the widget asks the PC itself, at its address and then at its Secondary IP, and requests the next update after **10 minutes**, but iOS controls scheduling. A reading older than **3 minutes** stays on screen dimmed, with its time; when the PC doesn't answer, the widget keeps the last reading, dimmed, for up to **24 hours** instead of showing dashes.

Under **Tools → Live Activity**, choose **Overview / Gaming / Power**, a **Standard / Minimal / Detailed** Lock Screen style, compact metric, accent, and **5 / 10 / 15-second** interval. On the Lock Screen, Standard shows three metrics for the profile, Minimal one large one, and Detailed adds CPU/GPU temperatures plus **Sleep** and **Shut Down** (Orbit Pro), an open-the-app button and ✕, which ends the activity; the expanded island has the same three metrics and buttons. While the PC is off or not answering, the activity shows the time of the last reading and **Power On** (Orbit Pro). On iOS 18+ it also appears in the Smart Stack on Apple Watch and in CarPlay. When the app goes to the background the last values stay visible; after three intervals without a new reading they stay dimmed, with their time (**Last reading · open Orbit to refresh**). Orbit asks iOS for a Background App Refresh which, when the system grants it, updates the activity and the widgets. iOS decides when that runs, so continuous background updates are not guaranteed. See the [iOS setup and signing guide (Romanian)](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Connect to your PC at least once to detect its MAC address and network settings, or enter them manually in Settings. Enable Wake-on-LAN in BIOS/UEFI and in the Windows Ethernet adapter properties. The PC must remain connected to power. Sending a packet does not guarantee a successful wake: Orbit waits for the agent to respond before showing the PC as connected.

UDP broadcast may face additional restrictions on iPhone; see the note in the [testing guide (Romanian)](Orbit-iOS/WIDGETS.md). A successful simulator test does not guarantee Wake-on-LAN will work on a physical phone.

### App icon

The icon is already included at `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. To change it, open **Assets → AppIcon** in Xcode and replace the universal 1024 × 1024 image with a square, opaque PNG. iOS applies the rounded corners.

Generated with the built-in imagegen tool. Prompt: “Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

### Apple TV submission

Choose **OrbitTV**, destination **Any tvOS Device**, then **Product → Archive**. The current build is **10**. Create a fresh archive after updating the project; existing archives in Organizer retain their old configuration.

`OrbitTV/Assets.xcassets/AppIcon.brandassets` contains layered Home Screen/App Store icons and standard/Wide Top Shelf images at 1x/2x. Both configurations select **AppIcon**. The archived app must contain `CFBundleIcons.CFBundlePrimaryIcon` and `TVTopShelfImage.TVTopShelfPrimaryImageWide` as well as the compiled images. Verify locally with `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /path/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. All icons (iPhone/iPad, Watch, Mac, the Apple TV layers, Top Shelf and the in-app `OrbitMark`) are regenerated with `python3 Orbit-iOS/Tools/generate_app_icons.py` (needs numpy, scipy and Pillow); the Orbit Pro alternate icons are left alone.

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

Audio mixer order and app icons, from the agent to the Swift models on iPhone, Mac and Apple TV, plus batched icon loading:

```sh
python Orbit-iOS/Tests/check_app_icons.py
```

Electricity cost and the monthly summary: an energy ledger filled through the agent's own trackers, the replies of `/api/energy/*`, `/api/summary` and session details decoded by the Swift models and compared key by key, cost formatting, the demo data and the 1080 × 1350 share picture (requires Python with the agent dependencies and an installed Swift toolchain):

```sh
python Orbit-iOS/Tests/check_energy_summary.py
```

The presentation remote: the Swift models (talk timer, tap queue, Apple Watch reminders, lenient decoding) against the real `orbit_presentation.py` router with a mocked PowerPoint and the 409/422/503 refusals, plus the action names the iPhone, Apple Watch and Shortcuts send. Nothing is pressed and no PC is contacted:

```sh
python Orbit-iOS/Tests/check_presentation.py
```

Fill Screen and Second Screen: the app's models against a scripted PC (start, stop, failures, PC switches during reads, demo mode), then the production Swift client over pinned TLS against the agent's `/api/stream/display` router, with Sunshine, the Virtual Display Driver and Windows mocked:

```sh
python Orbit-iOS/Tests/check_stream_display.py
```

The webcam, without a PC, a camera or a simulator: status, setup and removal replies from `orbit_webcam.py` and the `WS /ws/camera` messages decoded by the app, and the app's JPEGs run through the agent's own decoder (size, upright and unmirrored, pillarboxed when the phone is held upright):

```sh
python Orbit-iOS/Tests/check_webcam_contract.py
```

The companion's update channel: `/api/status` and `/api/update/check` on the stable and beta channels (no downgrade), decoded by the iPhone and Mac models, and beta versions ("4.6.0 beta 1") read the same way by the agent and the apps:

```sh
python Orbit-iOS/Tests/check_companion_channel.py
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

#### GitHub Actions

Two workflows run on GitHub. You can also start them by hand from the **Actions** tab with **Run workflow**.

- **Companion tests** (`.github/workflows/companion-tests.yml`) runs the agent's unit tests with Python 3.12 and `Orbit-Windows-Agent/requirements-dev.txt` on `windows-latest` and `ubuntu-latest` (the same command as above). It runs on every push to `main` that changes `Orbit-Windows-Agent/`.
- **Softcam DLLs** (`.github/workflows/softcam.yml`) builds [Softcam](https://github.com/tshino/softcam) (MIT) at a pinned commit (tag `v1.8.1`): Release for x64 and Win32 with MSBuild, then the project's own tests. It uploads the `orbit-softcam` artifact with `softcam64.dll`, `softcam32.dll`, Softcam's license (`LICENSE`), Microsoft's MIT license for the DirectShow BaseClasses linked into the DLLs (`LICENSE-BaseClasses`), the exact commit (`UPSTREAM_COMMIT`), `BUILD-INFO.txt` (with the minimum Visual C++ Redistributable version) and `SHA256SUMS`. It runs on demand and on pushes to `main` that change the workflow or `tools/softcam/`. Before the DLLs go into `Orbit-Windows-Agent/webcam/`, check the downloaded artifact with `python3 tools/softcam/softcam_artifact.py verify <folder>`. Copy both licenses next to the DLLs and list Softcam and DirectShow BaseClasses (Microsoft, MIT) in `THIRD_PARTY_NOTICES.md` (details in `tools/softcam/README.md`).

## Licență / License

Orbit este software liber: aplicațiile Apple sunt distribuite sub **GNU GPLv3 cu App Store Distribution Exception** (vezi `LICENSE`), pentru că includ motorul de streaming Moonlight (`moonlight-common-c`, GPLv3). Codul scris pentru Orbit este disponibil și sub MIT. Lista completă a componentelor terțe și licențele lor: `THIRD_PARTY_NOTICES.md`. Streaming-ul are nevoie de [Sunshine](https://app.lizardbyte.dev/Sunshine/) (LizardByte, GPLv3) pe PC.

Orbit is free software: the Apple apps are distributed under the **GNU GPLv3 with the App Store Distribution Exception** (see `LICENSE`) because they bundle the Moonlight streaming engine (`moonlight-common-c`, GPLv3). Code written for Orbit is also available under MIT. The full list of third-party components and licenses is in `THIRD_PARTY_NOTICES.md`. Streaming requires [Sunshine](https://app.lizardbyte.dev/Sunshine/) (LizardByte, GPLv3) on the PC.
