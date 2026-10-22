# Orbit — PC companion

[Română](#romana) · [English](#english)

<a id="romana"></a>

## Română

Orbit are două părți: aplicațiile Apple din `Orbit-iOS` (iPhone/iPad, Apple Watch, Apple TV și Mac) și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

### Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` **5.0.0** pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. Agentul instalează dependențele, păstrează identitatea PC-ului și pornește în fundal în **System Tray** (zona **Hidden icons** din dreapta-jos), cu pictograma Orbit și meniu pentru **Run at Windows startup**, detalii de conectare și **Stop Orbit Companion**.
2. Permite Python în Windows Firewall pe rețeaua **Private**, inclusiv HTTPS **8766** și descoperirea Bonjour/mDNS **UDP 5353**. Pentru prima asociere, telefonul și PC-ul trebuie să fie în aceeași rețea locală.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege aceeași echipă pentru **Orbit** și **OrbitWidgets** și identificatori proprii dacă Xcode îi cere. Configurează același **App Group** în ambele ținte și `ORBIT_APP_GROUP_IDENTIFIER` pentru asocierea automată a widgeturilor; vezi [pașii de semnare](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Rulează Orbit, acordă acces la rețeaua locală și apasă **Find My PC** pe ecranul de bun venit. Alege PC-ul găsit, apoi introdu pe iPhone **codul de șase cifre afișat de agent și în dialogul Windows**. Codul expiră după **120 de secunde** și funcționează o singură dată. Orbit completează automat adresa, tokenurile, certificatul și datele Wake-on-LAN și salvează profilul. Profilul reține **adresa IPv4 reală** a PC-ului (de exemplu `192.168.1.196`), nu numele Bonjour `orbit-….local`: adresa simplă funcționează și prin Tailscale sau alte VPN-uri și pentru Wake-on-LAN. Numele `.local` rămâne salvat ca rezervă: dacă PC-ul primește alt IP, Orbit îl regăsește prin Bonjour și mută profilul automat. Profilurile vechi cu adresă `.local` sunt migrate la prima conectare.
5. Pentru alt calculator, atinge numele PC-ului din bara de sus a filei **PC** și alege **Add PC…**. **Try the Demo** (pe ecranul de bun venit sau **Settings → Demo Mode**) permite explorarea interfeței fără conectare și afișează explicit valori simulate.

Asocierea folosește SRP și un răspuns criptat pentru a verifica PC-ul și a transfera credențialele; nu copiezi IP, MAC sau tokenuri în fluxul obișnuit. Tokenul principal al fiecărui PC rămâne separat în Keychain. Monitorizarea și comenzile folosesc **HTTPS cu verificarea certificatului acelui PC**, fără revenire la HTTP când verificarea eșuează. Files, Clipboard, Audio mixer și Sessions cer conexiunea criptată. Portul HTTP **8765** rămâne pentru clienți locali vechi. Nu publica porturile agentului pe Internet.

**Configurarea manuală avansată** rămâne în **Settings → Manage PCs → Add by Address** (pe Mac: **PCs → By Address**). Folosește adresa, tokenul avansat și amprenta SHA-256 afișate de agent, apoi testează conexiunea. Este utilă dacă rețeaua blochează descoperirea; Bonjour nu traversează automat orice VPN sau rețea de oaspeți.

### Ce găsești în aplicație

Pe iPhone și iPad, Orbit are trei file, numite după ce găsești în ele: **PC**, **Play** și **Files**. Numele PC-ului din bara de sus a filei PC schimbă PC-ul sau adaugă unul nou, iar rotița de lângă el deschide **Settings**. Trackpadul, ecranul, clipboardul și mixerul se deschid din fila PC, acolo unde sunt folosite. Bara de file se micșorează când derulezi, iar jocul care rulează sau stream-ul activ rămâne deasupra ei.

- **PC:** o propoziție despre cum se descurcă PC-ul, apoi **Right Now**, citirile alese de tine (CPU, GPU, RAM, VRAM, consum CPU/GPU, temperaturi, frecvență CPU, ventilatoare, rețea, disc, uptime și FPS), fiecare cu graficul ultimelor citiri reale. Urmează **Control** (**Trackpad**, **Screen**, **Clipboard** și meniul **Power**), **Sound** (volum, media și **Apps** pentru mixer), **Using the Most** (procesele cele mai ocupate și **Task Manager**) și **This PC** (componente, **Specifications**, **Sessions**, **Monitoring Sources**). Un joc pornit apare primul, cu FPS-ul lui. Valorile care lipsesc sunt afișate ca indisponibile, niciodată inventate.
- **Specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Play:** jocurile tale cu coperți. Cu Orbit Companion 5 apar jocurile instalate prin Steam, Epic și GOG (coperțile vin de pe PC, nu de pe internet), iar aplicațiile din Sunshine sunt sub **More in Sunshine**. Un joc se deschide cu **Stream to iPhone** și **Start on PC**. Streamingul rulează în aplicație, prin Sunshine, cu protocolul Moonlight implementat nativ (biblioteca `moonlight-common-c`, GPLv3, în `Orbit-iOS/Packages/MoonlightCore`): video H.264/HEVC decodat hardware (VideoToolbox), HDR pe ecrane compatibile, audio Opus stereo/5.1/7.1, controllere (GameController, cu vibrații), tastatură hardware și software, trackpad sau touchscreen. **Stream Settings** (dreapta-sus) cuprinde setările Moonlight: rezoluție (720p…4K sau nativă), 30–120 fps, bitrate recomandat sau manual, codec, HDR, frame pacing, audio pe PC, optimizarea setărilor jocului, închiderea aplicației la deconectare, pachete mai mici pentru rețele din afara casei (**Remote network**) și statistici în timpul stream-ului. **Pair with Sunshine…** din meniul **…** asociază o dată cu Sunshine prin PIN; agentul poate introduce PIN-ul singur (**Pair automatically**, după ce salvezi o dată login-ul web UI al Sunshine pe PC) și poate porni Sunshine. Sunshine 2026 are nevoie de agentul 4.3.1 sau mai nou, care alege cererea de asociere a dispozitivului tău. Fiecare asociere folosește un certificat nou pentru acel PC (Sunshine 2026 respinge un certificat asociat de două ori), așa că intrările vechi „Orbit on …” din Sunshine → Clients pot fi șterse.
- **Files:** discuri și foldere accesibile contului Windows, deschise ca în aplicația Fișiere, cu transfer în ambele sensuri, previzualizare, favorite și organizare.
- **Trackpad:** tot ecranul devine trackpadul PC-ului: un deget mută cursorul, două degete derulează, atingerea face click. Bara de jos are click stânga și dreapta, tastatura, media și **More** (Middle Click, Double Click, viteza cursorului, Show Desktop, Task View, Switch Window, Full Screen, Screenshot, See the Screen, Close Game). **Screen** afișează cadrele JPEG trimise de agent, fără audio; pentru jocuri folosește **Play**.
- **Wake-on-LAN de oriunde:** pachetul magic pleacă spre broadcast-ul rețelei, spre adresa PC-ului și, opțional, spre un **releu** (**Settings → Manage PCs**, apoi **Edit** pe PC → **Wake Relay**: adresa Tailscale sau numele MagicDNS al routerului ori al unui dispozitiv mereu pornit, cu `:port` opțional), ca să funcționeze și prin Tailscale, nu doar din Wi-Fi-ul de acasă. Fila PC arată **Locked** cât timp PC-ul este la ecranul de autentificare sau blocat, cu butonul **Unlock**: Orbit deschide stream-ul la ecranul de login, apasă Enter și îți cere parola de Windows într-un câmp securizat; ce tastezi pleacă pe moment ca apăsări de taste prin stream-ul criptat (Sunshine acceptă tastatura pe ecranul de login) și nu se salvează nicăieri. Agentul poate porni **înainte de login** (meniul tray → „Start before Windows sign-in”).
- **PC-urile tale în iCloud:** profilurile de PC (adresă, porturi, amprenta certificatului, MAC, token) se sincronizează prin iCloud Key-Value Storage între iPhone, Apple TV și Mac cu același Apple Account; asocierea făcută pe un dispozitiv apare pe celelalte, modificările mai noi câștigă, iar un PC șters dispare peste tot. Adresa păstrată este mereu IPv4 numeric (numele Bonjour `orbit-….local` rămâne doar ca rezervă).

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

### Cu Orbit Companion 5

Agentul **5.0** adaugă funcții pe care aplicațiile le oferă numai când PC-ul le raportează (`/api/capabilities`); cu un agent mai vechi, restul aplicației funcționează ca înainte.

- **Alimentare:** meniul **Power** (pe iPhone în **Control**, pe Mac în bara de instrumente) are și **Sleep Later** și **Shut Down Later** (peste 15 sau 30 de minute, 1 sau 2 ore, ori **când se închide jocul**), **Keep Awake** (o oră, patru ore sau până îl oprești) și **Power Plan** (planurile de alimentare Windows). Un temporizator apare sus pe pagina PC-ului, cu timpul rămas, dispozitivul care l-a cerut și **Cancel**; pe Mac apare și în meniul din bara de meniu. După **Shut Down** sau **Restart**, Windows mai așteaptă 30 de secunde: Orbit numără invers cu **Cancel**, iar PC-ul apare oprit abia când nu mai răspunde.
- **Dispozitive:** fiecare iPhone, iPad, Mac și Apple TV asociat are propria cheie. **Settings → Devices** (pe Mac, pagina **PCs**) arată cine poate folosi PC-ul, când l-a folosit ultima dată și ce are voie să facă, cu **Remove…** pentru un dispozitiv pierdut sau vândut. Aplicațiile asociate înainte de 5.0 apar împreună ca **Older Orbit Apps** și funcționează în continuare; după ce reasociezi fiecare dispozitiv, scoate-le, ca fiecare să rămână cu cheia lui.
- **Activitate:** **Settings → Activity on the PC** (pe Mac, pagina **PCs**) arată ce s-a schimbat pe PC din Orbit (alimentare, fișiere, sunet, ecran, dispozitive), cine a cerut și dacă a reușit.
- **Sunet:** în **Sound** alegi ieșirea implicită a Windows (**Output**) și oprești microfonul PC-ului (**Microphone**).
- **Jocuri:** fila **Play** listează jocurile instalate prin Steam, Epic și GOG, cu coperțile de pe PC, și le pornește cu **Start on PC**.
- **Fereastra Orbit pe PC:** un clic pe pictograma din tray deschide fereastra companionului (**Overview**, **Devices**, **Activity**, **Settings**, **Diagnostics**), cu codul de asociere afișat mare, dispozitivele, jurnalul și reparații pentru rețea și Windows Firewall. Vezi [ghidul agentului](Orbit-Windows-Agent/README.md#fereastra-orbit).

### Fișiere și transfer

Deschide fila **Files** și alege un disc din **Drives** sau un folder din **Quick Access**: Desktop, Downloads, Documents, Pictures, Videos, Music. Folderele se deschid ca în aplicația Fișiere: butonul înapoi sau glisarea de la margine revin la folderul anterior, iar **Search this folder** caută în folderul deschis. Favoritele sunt separate pentru fiecare PC; ține apăsat pe o intrare pentru acțiunile ei.

- **PC → iPhone:** **Save to iPhone** descarcă fișierul, iar **Preview** îl deschide în Quick Look; de acolo îl distribui sau îl salvezi în Fișiere.
- **Foldere întregi:** alege **Save Folder as ZIP** din meniul **More** al folderului deschis sau **Save as ZIP** din meniul unui folder. Sunt păstrate structura, numele Unicode și directoarele goale. Pregătirea și descărcarea au progres separat și pot fi anulate; ZIP-ul se salvează prin meniul de distribuire. **Select** permite selecția multiplă de fișiere și foldere.
- **iPhone → PC:** **Add → Upload Files** sau **Upload Photos or Videos** trimit fișiere în folderul deschis, cu progres, viteză și anulare.
- **Organizare:** **Add → New Folder**, **Rename**, **Move** (pe același disc) și **Move to Recycle Bin**, cu confirmare. Fișierele existente nu sunt suprascrise automat.

Limitele pentru fișiere sunt **2 GiB/upload**, **16 GiB/download** și **64 MiB/previzualizare**. Arhiva unui folder permite **2 GiB de fișiere sursă și 2 GiB ZIP**, **10.000 de intrări**, **32 de niveluri sub folderul ales** și cel mult **120 de secunde de pregătire**. Agentul păstrează cel mult două operații de arhivare și șterge datele temporare la anulare sau după **10 minute**. Un fișier inaccesibil, protejat sau modificat în timpul pregătirii produce eroare pentru întreaga arhivă; nu se livrează un ZIP incomplet fără avertizare. Originalele rămân pe PC.

Accesul respectă permisiunile contului Windows; tokenurile și stocarea internă Orbit sunt protejate. Linkurile/junctions și căile de rețea UNC nu sunt disponibile. Uploadul de directoare și mutarea între discuri nu sunt incluse; mutarea între discuri este refuzată fără modificări. PC-ul și agentul trebuie să rămână pornite.

### Clipboard, mixer și sesiuni

În **PC → Control → Clipboard**, scrie sau lipește text și apasă **Send to PC**, ori apasă **Get from PC** și apoi **Copy**. Se transferă numai text și linkuri, la cerere, până la **1 MiB**. Orbit nu urmărește clipboardul în fundal și nu salvează un istoric; textul ecranului este șters la ieșire sau la schimbarea PC-ului.

În **PC → Sound → Apps**, sesiunile aplicațiilor au volum și mute proprii, iar **Output** permite alegerea unei ieșiri active sau **System default** pentru aplicația respectivă. Lista e ordonată ca în Windows Task Manager: întâi **Apps** (aplicațiile cu fereastră), apoi **Background processes**, la final **Windows** (System sounds); în fiecare grup, aplicațiile care redau acum apar primele și sunt marcate cu **Playing**. Fiecare aplicație are numele și iconul ei din Windows (agent 4.4+). Pornește redarea dacă o aplicație nu apare. Glisările sunt grupate și livrate în ordine prin Windows Core Audio. Windows sau aplicația pot cere repornirea redării pentru schimbarea ieșirii; vezi [compatibilitatea și limitele mixerului](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

În **PC → This PC → Sessions** (Orbit Pro), jocurile detectate pornesc automat o sesiune; **Record** pornește o înregistrare manuală pentru activitatea desktopului. Oprește înregistrarea când ai terminat. Agentul salvează o măsurătoare la **5 secunde**, păstrează cel mult **100 de sesiuni / 30 de zile** și permite ștergerea sesiunilor încheiate. Graficele interactive includ FPS, încărcare și temperaturi CPU/GPU, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc citirile disponibile; senzorii lipsă rămân goluri, fără valori zero inventate. Sesiunile se păstrează pe PC, inclusiv dacă telefonul se deconectează. Acestea sunt mostre periodice, nu o captură completă a fiecărui cadru.

În **Settings → Manage PCs**, adaugă și editează mai multe calculatoare (mai mult de unul cu Orbit Pro); treci de la unul la altul din numele PC-ului de pe fila PC. Fiecare are adresă, token, certificat și setări Wake-on-LAN proprii, inclusiv calcularea automată a broadcastului; configurația dashboardului și favoritele sunt separate. Asocierea prin **Find a PC Nearby** salvează automat profilul și pregătește widgeturile. Profilurile manuale existente pot fi editate sau reasociate cu un cod nou. Datele profilurilor rămân pe telefon, iar secretele în Keychain. Schimbarea PC-ului închide contextul operațiilor vechi.

### Citirile de pe fila PC

Apasă **Edit** lângă **Right Now** (sau **Settings → Readings on the PC Tab…**). Alegi care dintre cele **17 citiri** apar și le ordonezi prin tragere; **Start From** oferă punctele de pornire **Balanced**, **Gaming**, **Work**, **Cooling** și **Everything**. Configurația se păstrează separat pentru fiecare PC, iar o citire pe care PC-ul nu o raportează rămâne ascunsă. Atinge o citire pentru valoarea live, graficul ultimelor minute și, la încărcare, procesele responsabile. Textul de accesibilitate mare folosește automat o singură coloană.

Puterea CPU este valoarea **CPU package**, iar puterea GPU provine din senzorul plăcii video. Ele nu reprezintă consumul total al PC-ului la priză. Frecvența CPU indică sursa citirii; dacă nu există senzori live, valoarea nominală raportată de Windows este etichetată explicit. Turațiile ventilatoarelor nu sunt estimate. Debitele de rețea și disc folosesc diferențe între măsurători. Conectarea sau resetarea unui dispozitiv reinițializează numai contorul lui; celelalte continuă să fie măsurate. Traficul mic se afișează și în B/s sau KB/s. Adaptoarele active sunt selectate automat; `ORBIT_NETWORK_INTERFACE` permite alegerea explicită a unuia.

### Task Manager

Deschide **PC → Using the Most → Task Manager**, caută numele/PID-ul și sortează descrescător după **CPU, GPU, RAM sau VRAM**, ori alfabetic. Procesele care au icon în Windows îl afișează și în Orbit (agent 4.4+). Memoria GPU dedicată și cea partajată din RAM sunt afișate separat. Citirile GPU folosesc contoarele Windows disponibile în driver; procentul reprezintă motorul cel mai ocupat al procesului. Un senzor sau o mostră lipsă apare ca **—**, inclusiv la prima citire.

**End task** cere confirmare și verifică identitatea PID + momentul creării procesului pentru a evita închiderea unui PID reutilizat. Pe Windows, terminarea este forțată și nu garantează salvarea lucrului. Procesele critice și agentul Orbit sunt protejate; aplicațiile nu sunt închise automat. Vezi [detaliile și limitele Windows](Orbit-Windows-Agent/README.md#task-manager-de-pe-telefon).

### Aspect

Redesignul folosește **Liquid Glass** din iOS, iPadOS, macOS, tvOS și watchOS 26 și un singur sistem de design pentru toate aplicațiile (`Orbit-iOS/Shared/Design`): fundal negru, suprafețe calme, o singură culoare de accent pentru ce poți atinge și pentru citiri, text San Francisco și animații scurte. Fiecare ecran începe cu o propoziție despre starea PC-ului („Quiet right now”, „Processor is hot · 92°”), apoi cu citirile care contează; sticla rămâne pentru bare, butoane și controale, nu pentru conținut. Reduce Motion, Reduce Transparency și textul mare sunt respectate.

În **Settings → Appearance**:

- **Accent Color:** Orbit Blue (implicit), Teal, Mint, Indigo, Orange și Graphite; cu Orbit Pro și Pink, Gold, Red, Green, Ice și Rose. Accentul se aplică aplicației, widgeturilor, Live Activity, Apple Watch și, prin iCloud, Apple TV. Temele vechi devin accentul corespunzător (Noir → Orbit Blue, Ocean → Teal și așa mai departe).
- **App Icon:** Graphite (implicit); cu Orbit Pro și Blue, Gold, Red, Green și Light.
- **Readings on the PC Tab…** și **Haptics**.

Pe Mac, culoarea se alege în **Settings → Accent Color**.

### Aplicația pentru Mac

`Orbit-iOS/OrbitMac` este o aplicație **nativă macOS 26** (SwiftUI + AppKit), ținta **OrbitMac** din același `Orbit.xcodeproj`. Nu este un port Catalyst: are fereastră cu bară laterală, meniuri, scurtături, element în bara de meniu și fereastră de Setări. Se conectează **doar** prin canalul HTTPS criptat cu amprenta PC-ului (fără HTTP vechi).

Bara laterală are trei grupuri, cu scurtăturile din meniul **View**: **PC** (⌘1), **Play** (⌘2) și **Files** (⌘3); **Remote** (⌘4), **Screen** (⌘5), **Sound** (⌘6) și **Clipboard** (⌘7); **Activity** (⌘8) și **History** (⌘9); plus **PCs** (⌘0). PC-ul curent se schimbă din partea de sus a barei laterale.

- **Prima conectare:** deschide **PCs** (⌘0). PC-urile din rețea apar prin Bonjour; apasă **Pair** și introdu codul de șase cifre afișat de agent. Alternativ, **Import from iPhone** (⇧⌘I) preia PC-urile deja asociate pe telefon prin iCloud sau prin rețeaua locală, iar **By Address** acceptă o adresă IP. Tokenul fiecărui PC stă în Keychain-ul Mac-ului. Cu Orbit Companion 5, pagina arată și cine poate folosi PC-ul și activitatea recentă.
- **PC (⌘1):** propoziția despre stare, **Right Now** cu citirile alese (**Edit** le alege și le ordonează), **Using the Most** și **This PC** cu specificațiile. Bara de instrumente are meniul de alimentare: Lock, Turn On Display, Toggle HDR, Sleep, Restart și Shut Down cu confirmare, iar cu Orbit Companion 5 și Sleep Later, Shut Down Later, Keep Awake și Power Plan.
- **Play (⌘2):** cardul de sus spune dacă streamingul e gata și oferă pasul următor (asociere prin PIN cu Sunshine, pornirea Sunshine); dedesubt, jocurile instalate prin Steam, Epic și GOG cu coperțile de pe PC și aplicațiile Sunshine (**More in Sunshine**). Pe un joc apar **Stream** și **Start on PC**; dublu clic pornește stream-ul în fereastra proprie a aplicației (⇧⌘S pentru desktop): clic pe video capturează mouse-ul și tastatura, ⌃⌥⇧Z le eliberează; controllerele sunt redirecționate automat. Aplicația Moonlight separată rămâne opțională (**Open in Moonlight App**).
- **Files (⌘3):** browser cu tabel sortabil, breadcrumb, căutare, favorite, descărcare în Finder, upload prin **drag & drop** din Finder, folder nou, redenumire, mutare și coș de reciclare, cu bară de progres pentru transferuri.
- **Remote (⌘4):** pad de mouse cu captură a cursorului (⎋ eliberează), clickuri, scroll precis, drag, tastatură cu taste speciale, media, acțiuni rapide (Show desktop, Task view, Alt-Tab, Fullscreen) și gamepad.
- **Screen (⌘5):** previzualizarea desktopului în fereastra principală sau într-o fereastră separată (⌥⌘D) care poate sta deasupra celorlalte; modul **Control** trimite clickuri, drag, scroll și tastatură în coordonate normalizate; **Snapshot** copiază sau salvează cadrul curent.
- **Sound (⌘6) și Clipboard (⌘7):** volumul, ieșirile (cu **Make Default** și microfonul PC-ului pe Orbit Companion 5) și mixerul pe aplicații cu rutare pe ieșiri; clipboard bidirecțional (**Pull from PC** / **Push to PC** / **Copy to Mac** / **Paste from Mac**).
- **Activity (⌘8) și History (⌘9):** Task Manager cu sortare pe coloane, filtrare și **End Task** cu confirmare; sesiunile înregistrate, cu grafice Swift Charts, statistici min/medie/max și export CSV.
- **Bara de meniu:** pictograma Orbit (monocromă, ca pictogramele sistemului) și, la alegere, CPU/GPU/RAM/FPS/temperatură lângă ea. Meniul arată starea și citirile, un temporizator sau numărătoarea Windows cu **Cancel**, Mute, Lock, Sleep, Restart și Shut Down (sau **Wake PC** când PC-ul e oprit) și **Switch PC**.
- **Setări (⌘,):** **General** (pornire la login, bara de meniu, intervalul de actualizare, notificări când PC-ul revine online, ecranul și streamingul), **Accent Color**, **Connection** (Wake-on-LAN, verificarea și instalarea actualizării agentului) și **About**.

Cerințe: macOS 26 sau mai nou; aceeași rețea locală pentru asociere; permisiunea **Local Network** la prima pornire. Dacă senzorul lipsește, aplicația afișează **—**, niciodată valori inventate.

### Apple TV și Apple Watch

**Apple TV** are cinci file în bara de sus: **PC** (propoziția despre stare, citirile ca plăci și acțiunea de care are nevoie starea curentă; o citire selectată se deschide pe tot ecranul, cu graficul ultimului minut și procesele responsabile), **Play** (stream pe televizor și jocurile ca postere; un joc are **Stream to TV** și **Start on PC**), **Sound** (volum, taste media și aplicațiile care redau sunet, grupate ca în mixerul Windows), **Activity** (procesele care consumă cel mai mult; unul selectat poate fi închis, după confirmare) și **Settings** (PC-urile, streamingul și Orbit Pro; un PC nou se adaugă de pe iPhone, din rețea sau după adresă).

**Apple Watch** are patru pagini, parcurse cu Digital Crown sau prin glisare verticală: **Glance** (semnul Orbit, numele PC-ului, o propoziție și cele două citiri importante; când PC-ul doarme, e blocat sau nu e configurat, apare acțiunea care ajută), **Power** (Wake când doarme, Unlock când e blocat, Lock, Sleep, Restart și Shut Down cu confirmare; la Unlock, iPhone-ul tastează parola o singură dată printr-un stream scurt și niciunul nu o păstrează), **Control** (glisezi pe pad pentru cursor și atingi pentru click; Right, Double și drag; mișcarea încheieturii mută cursorul, cu **Recenter**; Digital Crown derulează pe PC) și **Media** (jocul pornit, cu FPS și **Quit Game**, play/pause, înainte/înapoi și volumul PC-ului, reglabil cu Crown). Complicațiile arată starea, CPU, GPU sau FPS ori deschid Control. Ceasul trimite comenzile prin iPhone-ul apropiat sau direct prin HTTP(S), cu confirmare de la PC; Wake-on-LAN de pe ceas trece prin iPhone. Datele expirate nu sunt afișate ca live.

### Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. NVIDIA `nvidia-smi` rămâne sursa prioritară pentru încărcare, temperatură, VRAM, consum și ventilator GPU, când sunt suportate. Pentru ceilalți senzori, agentul detectează **MSI Afterburner**, apoi LibreHardwareMonitor ca alternativă. Citirile mai multor plăci nu se amestecă, iar un senzor lipsă rămâne indisponibil. Modelul coolerului sau al sursei poate necesita completare manuală.

**Configurarea recomandată, fără CSV:**

1. Instalează [MSI Afterburner de pe site-ul MSI](https://www.msi.com/Landing/afterburner/graphics-cards), inclusiv **RivaTuner Statistics Server (RTSS)**, și lasă ambele programe pornite pe PC.
2. În **Afterburner → Settings → Monitoring**, bifează senzorii doriți din **Active hardware monitoring graphs**, inclusiv CPU/GPU temperature și Framerate, când există. Apasă **Apply**. **Show in On-Screen Display** este opțional pentru verificarea pe ecran; [ghidul MSI](https://www.msi.com/blog/msi-afterburner-on-screen-display/) arată opțiunile.
3. În RTSS, alege **Application detection level → Low** pentru joc. Poți activa temporar **Show own statistics** ca să verifici detectarea.
4. Pornește jocul și agentul **5.0.0**, apoi deschide Orbit. Datele sunt citite automat, prin memoria partajată locală; nu trebuie să conectezi telefonul direct la Afterburner sau să introduci o cheie suplimentară. În **Settings → Readings → Frame Rate Counter** ai aceiași pași.

**FPS:** RTSS are prioritate și nu cere `ORBIT_PRESENTMON_CSV`. Jocurile care blochează RTSS sau unele sisteme anti-cheat pot rămâne incompatibile. Valoarea descrie cadrele aplicației, fără garanția FPS-ului afișat după generarea cadrelor sau streaming. Pentru un joc nerecunoscut, se poate configura executabilul prin `ORBIT_GAME_PROCESSES`.

**Senzori:** Orbit poate citi doar graficele și unitățile pe care Afterburner le expune; consumul CPU/GPU în wați, capacitatea VRAM și ventilatoarele nu sunt garantate pe orice PC. Dacă lipsește un senzor, LibreHardwareMonitor rămâne opțional: în versiunile **0.9.5+**, activează **Options → Remote Web Server → Run**, port **8085**. Orbit citește `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` permite alt port local. Versiunile vechi pot folosi WMI. Schimbarea interfeței este [confirmată de dezvoltatorii LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Alternativă avansată FPS:** captura PresentMon CSV rămâne acceptată, dacă RTSS nu oferă date recente. Configurează `ORBIT_PRESENTMON_CSV` și pornește captura separat; formatele v1, implicit actual și v2 sunt suportate. `ORBIT_PRESENTATION_CSV` rămâne alias de compatibilitate. Consultă [pașii RTSS și alternativa PresentMon](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Actualizare și diagnosticare

Agentul din această versiune raportează **5.0.0**. Oprește vechiul agent, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește cu `start_agent.bat`. Păstrează fișierele locale `.orbit-token`, `.orbit-widget-token` și folderul `%LOCALAPPDATA%\Orbit` cu identitatea TLS și istoricul; nu copia mediul `.venv` de pe alt calculator. Pentru asociere automată, folosește **Find My PC**; profilurile manuale existente rămân disponibile. Actualizează și aplicația din Xcode. Schimbările din proiect nu actualizează automat copia care rulează pe PC.

În **PC → This PC → Monitoring Sources** (sau **Settings → Readings → Sensor Sources**), verifică versiunea raportată și sursele datelor. Pe PC, `check_monitoring.bat` sau `.venv\Scripts\python.exe check_monitoring.py` verifică sursele disponibile și configurarea FPS fără să trimită comenzi de control. Păstrează Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS; dacă folosești o sursă alternativă, las-o pornită și pe aceea. Senzorii, cadrele jocului și comenzile Windows trebuie validate pe PC-ul tău; verificările automate folosesc și surse simulate.

### Widgeturi și Dynamic Island

WidgetKit oferă **Status**, **Frame Rate**, **Power Draw**, **Temperatures**, **Fans**, **Disk Activity**, **Network** și **Reading** (o citire la alegere), plus **Power Buttons** (Orbit Pro), comenzile din Control Center **Wake PC**, **Sleep PC** și **Shut Down PC** și scurtăturile Siri. Poți adăuga mai multe instanțe și alege pentru fiecare PC-ul, citirea și culoarea de accent.

După asocierea PC-ului, Orbit pregătește automat accesul widgeturilor. Adaugă widgetul pe Home Screen și alege un PC din **Edit Widget → PC**; **nu introduci IP, port sau token**. Aplicația și extensia au nevoie de același **App Group configurat și semnat în Xcode**. Este partajat exclusiv tokenul de monitorizare **read-only**, separat de tokenul principal privat. Widgeturile folosesc HTTPS și verifică certificatul PC-ului. Dacă partajarea nu este disponibilă, verifică semnarea și **Settings → Widgets, Controls and Siri → Refresh Widget Access**.

Widgeturile arată capturi periodice cu ora măsurătorii. De fiecare dată când aplicația citește telemetria, salvează ultima citire în App Group și reîmprospătează widgeturile, astfel încât un widget redă imediat ce a văzut aplicația (citiri mai noi de două minute), fără o conexiune proprie. Altfel, widgetul solicită singur o actualizare după **15 minute**, dar iOS decide programarea; citirile mai vechi de 15 minute sunt ascunse. PC-ul trebuie să fie accesibil în rețea.

Live Activity pornește și se oprește din **Show on Lock Screen** (meniul cu numele PC-ului de pe fila PC sau **Settings → Outside the App**). În **Settings → Live Activity** alegi stilul **Minimal / Standard / Detailed**, citirile (**Load and Memory**, **Frame Rate and Graphics** sau **Power Draw**), ce arată Dynamic Island (**Automatic** arată cele două temperaturi, iar cât joci FPS-ul), culoarea, dacă apar jocul și ora actualizării și intervalul **5 / 10 / 15 secunde**. Când aplicația trece în fundal, ultimele valori rămân afișate până la expirarea lor (trei intervale), apoi activitatea este marcată ca învechită; Orbit cere iOS-ului un refresh în fundal (Background App Refresh) care, atunci când sistemul îl acordă, actualizează activitatea și widgeturile. iOS decide când rulează acest refresh: nu există actualizări continue garantate în fundal. Vezi [configurarea și semnarea iOS](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Conectează PC-ul măcar o dată pentru detectarea adresei MAC și a rețelei sau completează-le în **Settings → Connection & Wake**. Activează Wake-on-LAN în BIOS/UEFI și în proprietățile adaptorului Ethernet din Windows. PC-ul trebuie să rămână alimentat. Un pachet trimis nu garantează pornirea: Orbit așteaptă răspunsul agentului înainte să afișeze PC-ul drept conectat.

Broadcastul UDP poate avea restricții suplimentare pe iPhone; verifică nota din [ghidul de testare](Orbit-iOS/WIDGETS.md). Testarea pe simulator nu garantează funcționarea Wake-on-LAN pe telefonul fizic.

### Icon

Iconul este marca Orbit: un inel deschis sus pentru satelitul lui. Pe iPhone, iPad, Mac și Apple Watch e un fișier Liquid Glass din Icon Composer (`Orbit-iOS/Shared/Icons/AppIcon.icon`), cu variantele Orbit Pro alături (`AppIcon-Neon.icon`, `-Gold`, `-Crimson`, `-Matrix`, `-Minimal`). Sistemul face singur aspectele întunecat, colorat și transparent.

Toate iconurile, inclusiv straturile pentru Apple TV și imaginile Top Shelf, se generează din aceeași geometrie: `python3 Orbit-iOS/Tools/generate_orbit_icons.py` (are nevoie de Pillow). Fișierele `.icon` se pot deschide și ajusta în Icon Composer.

### Publicare Apple TV

Selectează schema **OrbitTV**, destinația **Any tvOS Device**, apoi **Product → Archive**. Buildul curent este **10**. După actualizarea proiectului creează o arhivă nouă; arhivele vechi din Organizer păstrează configurația veche.

Catalogul `OrbitTV/Assets.xcassets/AppIcon.brandassets` include iconuri pe straturi pentru Home Screen și App Store, plus Top Shelf normal și Wide în variante 1x/2x. Ambele configurații folosesc **AppIcon**. Cheile `CFBundleIcons.CFBundlePrimaryIcon` și `TVTopShelfImage.TVTopShelfPrimaryImageWide` trebuie să existe și în `Info.plist` din aplicația arhivată, împreună cu imaginile compilate. Verificare locală: `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /cale/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. Grafica se regenerează cu `python3 Orbit-iOS/Tools/generate_orbit_icons.py`.

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

1. Copy the entire `Orbit-Windows-Agent` **5.0.0** folder to your PC and run `start_agent.bat`. Python 3.11 or later is required. The agent installs dependencies, preserves this PC's identity, and runs in the Windows **System Tray** (bottom-right **Hidden icons** area) with the Orbit icon and a menu for **Run at Windows startup**, connection details, and **Stop Orbit Companion**.
2. Allow Python through Windows Firewall on **Private** networks, including HTTPS **8766** and Bonjour/mDNS discovery over **UDP 5353**. Use the same local network for initial pairing.
3. Open `Orbit-iOS/Orbit.xcodeproj` in Xcode. Choose the same team for **Orbit** and **OrbitWidgets**, using unique bundle identifiers if required. Configure the same **App Group** on both targets and `ORBIT_APP_GROUP_IDENTIFIER` for automatic widget setup; see the [signing instructions (Romanian)](Orbit-iOS/WIDGETS.md#testare-gratuită).
4. Run Orbit, grant local network access, and choose **Find My PC** on the welcome screen. Select your PC and enter the **six-digit code shown by the agent and its Windows dialog**. The code expires after **120 seconds** and works once. Orbit automatically fills in the address, tokens, certificate, and Wake-on-LAN details and saves the profile. The profile stores the PC's **plain IPv4 address** (for example `192.168.1.196`) rather than the Bonjour name `orbit-….local`, so it also works through Tailscale and other VPNs and for Wake-on-LAN. The `.local` name is kept as a fallback: if the PC's address changes, Orbit finds it again over Bonjour and moves the profile. Older `.local` profiles are migrated on the next connection.
5. To add another computer, tap the PC's name at the top of the **PC** tab and choose **Add PC…**. **Try the Demo** (on the welcome screen, or **Settings → Demo Mode**) lets you try the interface without connecting and clearly marks simulated readings.

Pairing uses SRP and an encrypted response to verify the PC and transfer credentials; the normal flow needs no IP, MAC, or token copying. Each PC's main token stays separately in Keychain. Monitoring and controls use **HTTPS with verification of that PC's certificate**, without falling back to HTTP on a certificate error. Files, Clipboard, Audio mixer, and Sessions require encryption. HTTP port **8765** remains for legacy local clients. Do not expose the agent ports to the Internet.

**Advanced manual setup** remains under **Settings → Manage PCs → Add by Address** (on Mac: **PCs → By Address**). Enter the address, advanced access token, and SHA-256 fingerprint printed by the agent, then test the connection. This helps when the network blocks discovery; Bonjour does not automatically cross every VPN or guest network.

### Inside the app

On iPhone and iPad, Orbit has three tabs, named for what is in them: **PC**, **Play**, and **Files**. The PC's name at the top of the PC tab switches PCs or adds one, and the gear next to it opens **Settings**. The trackpad, screen, clipboard, and mixer open from the PC tab, where you use them. The tab bar shrinks while you scroll, and a running game or an active stream stays just above it.

- **PC:** one sentence on how the PC is doing, then **Right Now**, the readings you choose (CPU, GPU, RAM, VRAM, CPU/GPU power, temperatures, CPU clock, fans, network, disk, uptime, and FPS), each with a graph of its latest real readings. Then **Control** (**Trackpad**, **Screen**, **Clipboard**, and the **Power** menu), **Sound** (volume, media, and **Apps** for the mixer), **Using the Most** (the busiest processes and **Task Manager**), and **This PC** (components, **Specifications**, **Sessions**, **Monitoring Sources**). A running game comes first, with its frame rate. Missing readings are shown as unavailable, never invented.
- **Specifications:** processor and cores, GPU and driver, RAM modules, motherboard, BIOS, Windows, disks, volumes, and network adapters. You can customize component names for each PC; leave a field empty to use the detected name.
- **Play:** your games with their art. With Orbit Companion 5 it lists the games installed with Steam, Epic, and GOG (covers come from the PC, never from the internet), and Sunshine's apps sit under **More in Sunshine**. A game opens with **Stream to iPhone** and **Start on PC**. Streaming runs in the app through Sunshine with a native Moonlight protocol implementation (the GPLv3 `moonlight-common-c` library, vendored in `Orbit-iOS/Packages/MoonlightCore`): hardware-decoded H.264/HEVC video (VideoToolbox), HDR on capable displays, Opus stereo/5.1/7.1 audio, game controllers (GameController, with rumble), hardware and software keyboards, trackpad or touchscreen input. **Stream Settings** (top right) holds the Moonlight options: resolution (720p…4K or native), 30–120 fps, recommended or manual bitrate, codec, HDR, frame pacing, audio on the PC, optimize game settings, quit on disconnect, a smaller packet size for streaming away from home (**Remote network**), and a statistics overlay. **Pair with Sunshine…** in the **…** menu pairs with Sunshine once by PIN; the agent can type the PIN itself (**Pair automatically**, after saving Sunshine's web UI login on the PC once) and start Sunshine. Sunshine 2026 needs agent 4.3.1 or later, which picks this device's waiting pairing request. Every pairing uses a new certificate for that PC (Sunshine 2026 refuses a certificate that was paired twice), so older “Orbit on …” entries in Sunshine → Clients can be removed.
- **Files:** drives and folders available to the Windows account, opened like in the Files app, with transfers in both directions, previews, favorites, and organization.
- **Trackpad:** the whole screen becomes the PC's trackpad: one finger moves the pointer, two fingers scroll, a tap clicks. The bar at the bottom has left and right click, the keyboard, media, and **More** (Middle Click, Double Click, pointer speed, Show Desktop, Task View, Switch Window, Full Screen, Screenshot, See the Screen, Close Game). **Screen** shows the JPEG frames sent by the agent, without audio; use **Play** for games.
- **Wake-on-LAN from anywhere:** the magic packet goes to the subnet broadcast, to the PC's own address and, optionally, to a **relay** (**Settings → Manage PCs**, then **Edit** on the PC → **Wake Relay**: the Tailscale address or MagicDNS name of your router or of an always-on device, optional `:port`), so waking works over Tailscale too, not only from home Wi-Fi. The PC tab shows **Locked** while the PC sits at the sign-in or lock screen, with an **Unlock** button: Orbit opens the stream at the sign-in screen, presses Enter and asks for your Windows password in a secure field; what you type is sent right then as keystrokes over the encrypted stream (Sunshine accepts keyboard input on the sign-in screen) and is saved nowhere. The agent can start **before sign-in** (tray menu → “Start before Windows sign-in”).
- **Your PCs in iCloud:** PC profiles (address, ports, certificate fingerprint, MAC, token) sync through iCloud Key-Value Storage between iPhone, Apple TV and Mac signed in to the same Apple Account; a PC paired on one device shows up on the others, newer edits win, and a PC removed anywhere disappears everywhere. The stored address is always the numeric IPv4 (the Bonjour `orbit-….local` name is kept only as a fallback).

The volume slider directly updates the Windows audio level while you drag. Commands are sent in order, and intermediate positions are combined to keep the latest value. The old method that lowered the volume to zero before each adjustment has been removed. If the Windows audio service is unavailable, the control is shown as unavailable.

### With Orbit Companion 5

Agent **5.0** adds features the apps offer only when the PC reports them (`/api/capabilities`); with an older agent the rest of the app works as before.

- **Power:** the **Power** menu (on iPhone under **Control**, on Mac in the toolbar) also has **Sleep Later** and **Shut Down Later** (in 15 or 30 minutes, 1 or 2 hours, or **when the game exits**), **Keep Awake** (one hour, four hours, or until you turn it off), and **Power Plan** (Windows power plans). A pending timer shows at the top of the PC page with the time left, the device that asked for it, and **Cancel**; on Mac it also appears in the menu bar menu. After **Shut Down** or **Restart**, Windows waits 30 seconds: Orbit counts down with **Cancel**, and only shows the PC as off once it stops answering.
- **Devices:** every paired iPhone, iPad, Mac, and Apple TV has its own key. **Settings → Devices** (on Mac, the **PCs** page) shows who can use the PC, when each device last used it, and what it may do, with **Remove…** for a lost or sold device. Apps paired before 5.0 appear together as **Older Orbit Apps** and keep working; once every device is paired again, remove them so each device keeps its own key.
- **Activity:** **Settings → Activity on the PC** (on Mac, the **PCs** page) shows what Orbit changed on the PC (power, files, sound, screen, devices), who asked, and whether it worked.
- **Sound:** under **Sound**, choose Windows' default output (**Output**) and mute the PC's microphone (**Microphone**).
- **Games:** the **Play** tab lists games installed with Steam, Epic, and GOG with covers from the PC, and starts them with **Start on PC**.
- **Orbit window on the PC:** clicking the tray icon opens the companion's window (**Overview**, **Devices**, **Activity**, **Settings**, **Diagnostics**) with a large pairing code, your devices, the activity log, and fixes for the network profile and Windows Firewall. See the [agent guide (Romanian)](Orbit-Windows-Agent/README.md#fereastra-orbit).

### Files and transfers

Open the **Files** tab and choose a drive under **Drives** or a folder under **Quick Access**: Desktop, Downloads, Documents, Pictures, Videos, or Music. Folders open like in the Files app: the back button or a swipe from the edge returns to the previous folder, and **Search this folder** searches the open folder. Favorites are saved per PC; touch and hold an entry for its actions.

- **PC → iPhone:** **Save to iPhone** downloads a file and **Preview** opens it in Quick Look, where you can share it or save it to Files.
- **Entire folders:** choose **Save Folder as ZIP** in the open folder's **More** menu, or **Save as ZIP** in a folder's menu. Structure, Unicode names, and empty directories are preserved. Preparation and download show separate progress and support cancellation; save the ZIP through the share sheet. **Select** picks several files and folders at once.
- **iPhone → PC:** **Add → Upload Files** or **Upload Photos or Videos** sends files into the open folder, with progress, speed, and cancellation.
- **Organization:** **Add → New Folder**, **Rename**, **Move** (on the same drive), and **Move to Recycle Bin**, with confirmation. Existing files are never overwritten automatically.

File limits are **2 GiB/upload**, **16 GiB/download**, and **64 MiB/preview**. A folder archive allows **2 GiB of source files and a 2 GiB ZIP**, **10,000 entries**, **32 levels below the selected folder**, and **120 seconds of preparation**. The agent keeps at most two archive jobs and removes temporary data on cancellation or after **10 minutes**. Inaccessible, protected, or changing entries fail the complete archive rather than silently producing an incomplete ZIP. Originals remain on the PC.

Access follows the Windows account's permissions; Orbit tokens and private internal storage are protected. Links/junctions and UNC network paths are unavailable. Folder upload and moves between drives are not included; cross-drive moves are rejected without changes. The PC and agent must stay running.

### Clipboard, mixer, and sessions

In **PC → Control → Clipboard**, type or paste text and tap **Send to PC**, or tap **Get from PC** and then **Copy**. Only text and links are transferred, on request, up to **1 MiB**. Orbit does not watch the clipboard in the background or save clipboard history. Text on this screen is cleared when you leave or change PCs.

In **PC → Sound → Apps**, application sessions have individual volume and mute controls, and **Output** chooses an active device or **System default** for that application. The list follows Windows Task Manager: **Apps** (applications with a window) first, then **Background processes**, then **Windows** (System sounds); inside each group, apps playing right now come first and are marked **Playing**. Each app shows its Windows name and icon (agent 4.4+). Start playback if an app is missing. Slider updates are combined and sent in order through Windows Core Audio. Windows or the app may require playback to restart before an output change takes effect; see [mixer compatibility and limits (Romanian)](Orbit-Windows-Agent/README.md#clipboard-și-mixer-audio).

In **PC → This PC → Sessions** (Orbit Pro), detected games start sessions automatically; **Record** starts a manual recording for desktop work. Stop recording when finished. The agent saves a reading every **5 seconds**, keeps at most **100 sessions / 30 days**, and allows completed sessions to be deleted. Interactive graphs include FPS, CPU/GPU load and temperatures, power, RAM, VRAM, and traffic. Averages and peaks use available measurements; missing sensors remain gaps without invented zeros. Sessions stay on the PC and continue if the phone disconnects. These are periodic samples, not a complete capture of every frame.

In **Settings → Manage PCs**, add and edit multiple computers (more than one with Orbit Pro); switch between them from the PC's name on the PC tab. Each has its own address, token, certificate, and Wake-on-LAN settings, including automatic broadcast calculation; dashboard configuration and file favorites are separate. Pairing through **Find a PC Nearby** automatically saves the profile and prepares widgets. Existing manual profiles can be edited or paired again with a new code. Profile metadata stays on the phone and secrets stay in Keychain. Switching PCs clears the previous operation context.

### Readings on the PC tab

Tap **Edit** next to **Right Now** (or **Settings → Readings on the PC Tab…**). Choose which of the **17 readings** appear and drag to order them; **Start From** offers **Balanced**, **Gaming**, **Work**, **Cooling**, and **Everything** as starting points. Each PC keeps its own choice, and a reading your PC doesn't report stays hidden. Tap a reading for its live value, a graph of the last minutes and, for load readings, the processes responsible. Larger accessibility text automatically uses one column.

CPU power is the **CPU package** reading; GPU power comes from the graphics card sensor. These readings do not measure the PC's total wall power. CPU clock shows its source; when live sensors are unavailable, the nominal Windows clock is explicitly labeled. Fan speeds are never estimated. Network and disk rates use differences between samples. A newly connected or reset device only primes its own counter; other devices keep reporting. Low network traffic also displays in B/s or KB/s. Active interfaces are selected automatically; set `ORBIT_NETWORK_INTERFACE` to choose one explicitly.

### Task Manager

Open **PC → Using the Most → Task Manager**, search by name/PID, and sort descending by **CPU, GPU, RAM, or VRAM**, or alphabetically. Processes that have an icon in Windows show it in Orbit too (agent 4.4+). Dedicated GPU memory and shared GPU memory from RAM appear separately. GPU readings use driver-provided Windows counters; the percentage represents the process's busiest GPU engine. Missing sensors or samples show **—**, including the first reading.

**End task** asks for confirmation and verifies PID + process creation time to avoid closing a reused PID. Termination on Windows is forceful and does not guarantee saved work. Critical processes and Orbit Agent are protected; applications are never ended automatically. See the [Windows details and limitations (Romanian)](Orbit-Windows-Agent/README.md#task-manager-de-pe-telefon).

### Appearance

The redesign uses **Liquid Glass** from iOS, iPadOS, macOS, tvOS, and watchOS 26 and one design system for every app (`Orbit-iOS/Shared/Design`): a black canvas, calm surfaces, one accent colour for what you can touch and for readings, San Francisco text, and short animations. Every screen starts with one sentence about the PC (“Quiet right now”, “Processor is hot · 92°”), then the readings that matter; glass is kept for bars, buttons, and controls, not for content. Reduce Motion, Reduce Transparency, and larger text are respected.

Under **Settings → Appearance**:

- **Accent Color:** Orbit Blue (default), Teal, Mint, Indigo, Orange, and Graphite; with Orbit Pro also Pink, Gold, Red, Green, Ice, and Rose. The accent applies to the app, widgets, the Live Activity, Apple Watch and, through iCloud, Apple TV. Old themes become the matching accent (Noir → Orbit Blue, Ocean → Teal, and so on).
- **App Icon:** Graphite (default); with Orbit Pro also Blue, Gold, Red, Green, and Light.
- **Readings on the PC Tab…** and **Haptics**.

On Mac, choose the colour under **Settings → Accent Color**.

### Mac app

`Orbit-iOS/OrbitMac` is a **native macOS 26** app (SwiftUI + AppKit), the **OrbitMac** target in the same `Orbit.xcodeproj`. It is not a Catalyst port: it has a sidebar window, menus, keyboard shortcuts, a menu bar item, and a Settings window. It connects **only** over the encrypted, fingerprint-pinned HTTPS channel (no legacy HTTP).

The sidebar has three groups, with shortcuts in the **View** menu: **PC** (⌘1), **Play** (⌘2), and **Files** (⌘3); **Remote** (⌘4), **Screen** (⌘5), **Sound** (⌘6), and **Clipboard** (⌘7); **Activity** (⌘8) and **History** (⌘9); plus **PCs** (⌘0). Switch the current PC at the top of the sidebar.

- **First connection:** open **PCs** (⌘0). PCs on the network appear via Bonjour; press **Pair** and enter the six-digit code shown by the agent. Alternatively, **Import from iPhone** (⇧⌘I) fetches the PCs already paired on your phone over iCloud or the local network, and **By Address** accepts an IP address. Each PC's token lives in the Mac Keychain. With Orbit Companion 5 the page also shows who can use the PC and its recent activity.
- **PC (⌘1):** the status sentence, **Right Now** with your readings (**Edit** chooses and orders them), **Using the Most**, and **This PC** with the specifications. The toolbar has the power menu: Lock, Turn On Display, Toggle HDR, Sleep, Restart, and Shut Down with confirmation, plus Sleep Later, Shut Down Later, Keep Awake, and Power Plan with Orbit Companion 5.
- **Play (⌘2):** the card at the top says whether streaming is ready and offers the next step (PIN pairing with Sunshine, starting Sunshine); below it, games installed with Steam, Epic, and GOG with covers from the PC, and Sunshine's apps (**More in Sunshine**). Pointing at a game offers **Stream** and **Start on PC**; a double-click streams it in the app's own window (⇧⌘S for the desktop): click the video to capture mouse and keyboard, ⌃⌥⇧Z releases them; controllers are forwarded automatically. The separate Moonlight app stays optional (**Open in Moonlight App**).
- **Files (⌘3):** a browser with a sortable table, breadcrumbs, search, favorites, download to Finder, upload by **drag & drop** from Finder, new folder, rename, move, and recycle bin, with a transfer progress bar.
- **Remote (⌘4):** a mouse pad with pointer capture (⎋ releases), clicks, precise scrolling, drag, keyboard with special keys, media, quick actions (Show desktop, Task view, Alt-Tab, Fullscreen), and a gamepad.
- **Screen (⌘5):** the desktop preview in the main window or in a separate window (⌥⌘D) that can float above others; **Control** mode sends clicks, drags, scrolling, and typing in normalized coordinates; **Snapshot** copies or saves the current frame.
- **Sound (⌘6) and Clipboard (⌘7):** volume, outputs (with **Make Default** and the PC's microphone on Orbit Companion 5), and the per-app mixer with output routing; a two-way clipboard (**Pull from PC** / **Push to PC** / **Copy to Mac** / **Paste from Mac**).
- **Activity (⌘8) and History (⌘9):** Task Manager with column sorting, filtering, and **End Task** with confirmation; recorded sessions with Swift Charts graphs, min/average/max statistics, and CSV export.
- **Menu bar:** the Orbit mark (monochrome, like the system's own icons) and, if you like, CPU/GPU/RAM/FPS/temperature next to it. The menu shows the status and readings, a timer or Windows' countdown with **Cancel**, Mute, Lock, Sleep, Restart, and Shut Down (or **Wake PC** while the PC is off), and **Switch PC**.
- **Settings (⌘,):** **General** (launch at login, menu bar, refresh interval, notifications when the PC comes back online, screen and streaming), **Accent Color**, **Connection** (Wake-on-LAN, agent update check and install), and **About**.

Requirements: macOS 26 or later; the same local network for pairing; the **Local Network** permission on first launch. When a sensor is missing the app shows **—**, never invented values.

### Apple TV and Apple Watch

**Apple TV** has five tabs in the top bar: **PC** (the status sentence, readings as tiles, and the action the current state needs; a selected reading opens full screen with a chart of the last minute and the processes responsible), **Play** (stream to the TV and games as posters; a game has **Stream to TV** and **Start on PC**), **Sound** (volume, media keys, and the apps playing sound, grouped like Windows' mixer), **Activity** (the processes using the most; a selected one can be ended after a confirmation), and **Settings** (PCs, streaming, and Orbit Pro; add a PC from the iPhone, from the network, or by address).

**Apple Watch** has four pages, moved with the Digital Crown or a vertical swipe: **Glance** (the Orbit mark, the PC's name, one sentence and the two readings that matter; when the PC is asleep, locked, or not set up, the action that helps takes their place), **Power** (Wake when asleep, Unlock when locked, Lock, Sleep, Restart, and Shut Down with confirmation; for Unlock the iPhone types the password once through a short stream and neither device keeps it), **Control** (swipe the pad to move, tap to click; Right, Double, and drag; wrist motion moves the pointer, with **Recenter**; the Digital Crown scrolls the PC), and **Media** (the running game with its frame rate and **Quit Game**, play/pause, skipping, and the PC's volume on the Crown). Complications show the status, CPU, GPU, or FPS, or open Control. The watch sends commands through the nearby iPhone or directly over HTTP(S), with the PC's acknowledgement; Wake-on-LAN from the watch goes through the iPhone. Stale readings are not shown as live.

### Sensors and FPS

Hardware inventory uses Windows CIM and system APIs. NVIDIA `nvidia-smi` remains the preferred GPU source for load, temperature, VRAM, power and fan readings where supported. For other sensors, the agent detects **MSI Afterburner**, with LibreHardwareMonitor as a fallback. Readings from different adapters are kept separate and missing sensors stay unavailable. Cooler and power supply names may require manual entry.

**Recommended setup, without CSV:**

1. Install [MSI Afterburner from MSI](https://www.msi.com/Landing/afterburner/graphics-cards), including **RivaTuner Statistics Server (RTSS)**, and keep both running on the PC.
2. In **Afterburner → Settings → Monitoring**, tick the desired **Active hardware monitoring graphs**, including CPU/GPU temperature and Framerate when present. Click **Apply**. **Show in On-Screen Display** is optional for checking readings on the PC; see the [MSI monitoring guide](https://www.msi.com/support/technical_details/VGA_MSI_Utility_AfterBurner).
3. In RTSS, set **Application detection level → Low** for the game. Enable **Show own statistics** temporarily if you want to check detection.
4. Start the game and agent **5.0.0**, then open Orbit. Readings are detected through local shared memory; there is no direct phone connection to Afterburner or extra pairing key. **Settings → Readings → Frame Rate Counter** includes the same steps.

**FPS:** RTSS has priority and does not need `ORBIT_PRESENTMON_CSV`. Games that block RTSS and some anti-cheat systems may be incompatible. The reading describes application frames and does not guarantee displayed FPS after frame generation or streaming. Set `ORBIT_GAME_PROCESSES` to the executable if a game is not recognized.

**Sensors:** Orbit can read only the graphs and units exposed by Afterburner. CPU/GPU watts, VRAM capacity and fan readings are not guaranteed on every PC. LibreHardwareMonitor remains optional for missing sensors: on **0.9.5+**, enable **Options → Remote Web Server → Run**, port **8085**. Orbit reads `http://127.0.0.1:8085/data.json`; `ORBIT_LHM_URL` supports another local port. Older versions can still use WMI. The interface change is [confirmed by the LibreHardwareMonitor maintainers](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143).

**Advanced FPS fallback:** PresentMon CSV captures remain supported when RTSS has no recent reading. Configure `ORBIT_PRESENTMON_CSV` and start the capture separately; v1, current default and v2 formats are supported. `ORBIT_PRESENTATION_CSV` remains a compatibility alias. See the [RTSS setup and PresentMon fallback (Romanian)](Orbit-Windows-Agent/README.md#msi-afterburner--rtss-recomandat).

### Updating and troubleshooting

The agent in this version reports **5.0.0**. Stop the old agent, copy the updated **entire `Orbit-Windows-Agent` folder** to your PC, and restart with `start_agent.bat`. Keep the local `.orbit-token`, `.orbit-widget-token`, and `%LOCALAPPDATA%\Orbit` folder containing TLS identity and history; do not copy another computer's `.venv`. Use **Find My PC** for automatic pairing; existing manual profiles remain available. Update the app through Xcode too. Editing the project does not automatically update the copy running on your PC.

Open **PC → This PC → Monitoring Sources** (or **Settings → Readings → Sensor Sources**) to check the reported version and providers. On the PC, `check_monitoring.bat` or `.venv\Scripts\python.exe check_monitoring.py` checks available sources and FPS configuration without sending control commands. Keep Afterburner and RTSS running and open a game to check FPS; keep any fallback source you use running as well. Actual sensors, game frames, and Windows controls still need validation on your PC; automated checks also use mocked sources.

### Widgets and Dynamic Island

WidgetKit includes **Status**, **Frame Rate**, **Power Draw**, **Temperatures**, **Fans**, **Disk Activity**, **Network**, and **Reading** (one reading of your choice), plus **Power Buttons** (Orbit Pro), the **Wake PC**, **Sleep PC**, and **Shut Down PC** Control Center controls, and Siri shortcuts. Add multiple instances and choose the PC, reading, and accent colour for each.

Pairing the PC automatically prepares widget access. Add a Home Screen widget and select a PC under **Edit Widget → PC**; **no IP, port, or token entry is needed**. The app and extension require the same **App Group registered and signed in Xcode**. Only the **read-only** monitoring token is shared; the main control token remains private. Widgets use HTTPS and verify the PC certificate. If sharing is unavailable, check signing and **Settings → Widgets, Controls and Siri → Refresh Widget Access**.

Widgets show periodic snapshots with the measurement timestamp. Every time the app reads telemetry it stores the latest reading in the App Group and reloads the widgets, so a widget renders immediately from what the app just saw (readings under two minutes old) without opening its own connection. Otherwise the widget requests an update after **15 minutes**, but iOS controls scheduling; readings older than 15 minutes are hidden. The PC must be reachable on your network.

Start and stop the Live Activity with **Show on Lock Screen** (in the PC's name menu on the PC tab, or **Settings → Outside the App**). **Settings → Live Activity** chooses the **Minimal / Standard / Detailed** style, the readings (**Load and Memory**, **Frame Rate and Graphics**, or **Power Draw**), what the Dynamic Island shows (**Automatic** shows both temperatures, or the frame rate while you play), the colour, whether the game and update time appear, and the **5 / 10 / 15-second** interval. When the app goes to the background the last values stay visible until they expire (three intervals), then the activity is marked stale; Orbit asks iOS for a Background App Refresh which, when the system grants it, updates the activity and the widgets. iOS decides when that runs, so continuous background updates are not guaranteed. See the [iOS setup and signing guide (Romanian)](Orbit-iOS/WIDGETS.md).

### Wake-on-LAN

Connect to your PC at least once to detect its MAC address and network settings, or enter them under **Settings → Connection & Wake**. Enable Wake-on-LAN in BIOS/UEFI and in the Windows Ethernet adapter properties. The PC must remain connected to power. Sending a packet does not guarantee a successful wake: Orbit waits for the agent to respond before showing the PC as connected.

UDP broadcast may face additional restrictions on iPhone; see the note in the [testing guide (Romanian)](Orbit-iOS/WIDGETS.md). A successful simulator test does not guarantee Wake-on-LAN will work on a physical phone.

### App icon

The icon is Orbit's mark: a ring that opens at the top for its satellite. On iPhone, iPad, Mac and Apple Watch it is a Liquid Glass Icon Composer document (`Orbit-iOS/Shared/Icons/AppIcon.icon`), with the Orbit Pro alternates beside it (`AppIcon-Neon.icon`, `-Gold`, `-Crimson`, `-Matrix`, `-Minimal`). The system renders the dark, tinted and clear looks.

Every icon, including the Apple TV layers and Top Shelf images, comes from one geometry: `python3 Orbit-iOS/Tools/generate_orbit_icons.py` (needs Pillow). The `.icon` documents also open in Icon Composer for fine-tuning.

### Apple TV submission

Choose **OrbitTV**, destination **Any tvOS Device**, then **Product → Archive**. The current build is **10**. Create a fresh archive after updating the project; existing archives in Organizer retain their old configuration.

`OrbitTV/Assets.xcassets/AppIcon.brandassets` contains layered Home Screen/App Store icons and standard/Wide Top Shelf images at 1x/2x. Both configurations select **AppIcon**. The archived app must contain `CFBundleIcons.CFBundlePrimaryIcon` and `TVTopShelfImage.TVTopShelfPrimaryImageWide` as well as the compiled images. Verify locally with `python3 Orbit-iOS/Tests/check_tvos_assets.py --app /path/OrbitTV.xcarchive/Products/Applications/OrbitTV.app`. Regenerate them with `python3 Orbit-iOS/Tools/generate_orbit_icons.py`.

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
