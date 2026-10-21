# Orbit Agent pentru Windows

Agentul **4.1.0** citește componentele PC-ului și oferă asociere automată prin cod, monitorizare, control, fișiere și transfer, clipboard text, mixer audio și istoric de sesiuni. Nu presupune un anumit procesor, GPU, cooler sau capacitate de memorie. Aplicația are taburile **Overview / Library / Files / Remote / Tools**; setările sunt în **Tools → Settings**.

## Pornire, instalare și conectare

1. Instalează **Python 3.11 sau mai nou** de la [python.org](https://www.python.org/downloads/windows/), cu opțiunea **Add Python to PATH**.
2. **Instalare rapidă (recomandat):** deschide `install_orbit.bat`. Acesta creează mediul Python, instalează dependențele, compilează automat executabilul nativ `OrbitCompanion.exe` (fără fereastră de consolă, cu pictograma `orbit.ico`), creează scurtături pe **Desktop** și în **Start Menu** și pornește companionul în System Tray.
   - Alternativ, poți rula direct `start_agent.bat` sau poți construi un executabil complet independent (`dist\OrbitCompanion.exe`, fără să necesite Python pe alte PC-uri) rulând `build_exe.bat`.
3. Apasă click sau click-dreapta pe pictograma Orbit din **System Tray** (dreapta-jos / **Hidden icons**) pentru meniul rapid:
   - **Run at Windows startup**: activează sau dezactivează pornirea automată în fundal la autentificarea în Windows (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`).
   - **Check for updates...**: verifică pe GitHub (`https://github.com/AceDimi2005/Orbit`) dacă a apărut o versiune publică nouă a companionului de PC și permite descărcarea și instalarea automată a actualizării (sau deschiderea paginii de release).
   - **Connection details...** și **Copy manual pairing token**: afișează IP-ul, portul HTTPS, amprenta SHA-256 a certificatului sau copiază tokenul manual în clipboard.
   - **Show console window** / **Open agent log**: afișează consola (dacă a fost pornit cu `start_agent.bat --console`) sau deschide jurnalul `%LOCALAPPDATA%\Orbit\agent.log`.
   - **Stop Orbit Companion**: oprește curat serverul, anunțul Bonjour și pictograma din tray.
4. La solicitarea Windows Firewall, permite Python / `OrbitCompanion.exe` în rețeaua **Private**, inclusiv HTTPS **8766** și Bonjour/mDNS **UDP 5353**. Pentru descoperirea inițială, telefonul și PC-ul trebuie să fie în aceeași rețea locală. Permite și **Local Network** pentru Orbit pe iPhone.
5. În onboarding, apasă **Find my PC**, alege PC-ul descoperit și introdu **codul de șase cifre** afișat în dialogul Windows. Codul este valabil **120 de secunde**, pentru o singură încercare de confirmare. După un cod greșit sau expirat, solicită unul nou.
6. Orbit completează automat IP/hostname, tokenurile, certificatul și datele Wake-on-LAN și salvează profilul. Așteaptă inventarul și prima măsurătoare. Pentru alt PC, folosește **Tools → My PCs → Find a PC nearby**. Tokenul fiecărui profil rămâne separat în Keychain, iar dashboardul și favoritele se păstrează per PC.

PC-ul este anunțat prin Bonjour ca serviciu `_orbit._tcp.local.`. Asocierea folosește **SRP-6a, SHA-256 și grupul de 2048 de biți**; răspunsul cu credențiale este criptat cu **AES-GCM** sub o cheie derivată din sesiunea SRP și verifică amprenta certificatului. PIN-ul nu este transmis serverului ca text. Sunt permise cel mult un cod activ, cinci cereri acceptate pe adresă și zece în total în zece minute. Codurile ignorate sunt închise automat la expirare.

După asociere, aplicația folosește **HTTPS/WSS pe 8766** și verifică certificatul exact al PC-ului. Nu revine la HTTP dacă verificarea eșuează. **Files, Clipboard, Audio mixer și Sessions & graphs cer HTTPS**. Widgeturile noi folosesc tot HTTPS, cu acces separat numai pentru citire. Portul **8765** păstrează API-ul HTTP/WebSocket pentru clienți locali vechi; traficul pe acest port nu este criptat. Nu publica porturile agentului pe Internet.

Rutele publice sunt `GET /api/discover` (metadate publice de descoperire) și `POST /api/pair/start`, `POST /api/pair/finish` (asociere numai prin HTTPS). Datele și comenzile cer `Authorization: Bearer <token>`, inclusiv WebSocket. Tokenurile în URL nu sunt acceptate. Widgeturile folosesc un token separat, fără drepturi asupra fișierelor, clipboardului, mixerului sau istoricului.

**Configurare manuală avansată:** în **Manual configuration** din onboarding sau **My PCs → Add manually**, introdu adresa PC-ului, tokenul **Advanced manual pairing token** și **Certificate SHA-256**, afișate de agent, apoi testează conexiunea. Adresa se introduce fără `https://` și fără port. Portul securizat implicit este **8766**, configurabil din **Custom agent port**. Această variantă rămâne disponibilă când Bonjour este blocat sau nu traversează rețeaua/VPN-ul.

Certificatul și cheia se generează automat în **`%LOCALAPPDATA%\Orbit\tls\server-cert.pem`** și **`server-key.pem`**. Aceste fișiere persistă între actualizări și nu trebuie copiate în arhive sau pe alte PC-uri. O identitate existentă incompletă sau invalidă produce o eroare explicită; schimbarea intenționată a certificatului cere asociere din nou pe telefon. Dacă adresa IP se schimbă prin DHCP, actualizează adresa din profil; amprenta aceluiași certificat rămâne valabilă și nu trebuie regenerată doar pentru noul IP. O amprentă diferită este refuzată înainte de trimiterea tokenului; verifică identitatea pe PC înainte de reasociere.

Pentru regenerarea tokenului, oprește agentul, șterge `.orbit-token` și repornește. Reasociază PC-ul cu un cod nou sau actualizează configurația manuală. Nu distribui fișierul sau capturi ale tokenului.

## Actualizare și diagnosticare

Această versiune a agentului raportează **4.1.0**. Poți verifica și aplica actualizări direct din:
- **System Tray pe PC** → click pe pictograma Orbit → **Check for updates...**
- **Aplicația iOS** → **Tools → Settings → PC Companion Update → Check for Updates on GitHub**
- **Linie de comandă:** `OrbitCompanion.exe --check-updates` sau `python orbit_agent.py --check-updates`

Actualizarea automată descarcă ultima versiune publică din `https://github.com/AceDimi2005/Orbit`, actualizează fișierele companionului și păstrează intacte `.orbit-token`, `.orbit-widget-token` și folderul **`%LOCALAPPDATA%\Orbit`** cu certificatul și istoricul.

În Orbit, **Tools → Monitoring Sources** afișează versiunea raportată de agent, sursa senzorilor CPU/GPU, interfețele de rețea și sursa FPS.

Pe PC, după pregătirea dependențelor prin `start_agent.bat`, rulează `check_monitoring.bat` sau:

```powershell
.venv\Scripts\python.exe check_monitoring.py
```

Verificarea citește sursele de monitorizare Afterburner/RTSS și alternativele configurate, fără comenzi de control. Lasă Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS. Dacă folosești LibreHardwareMonitor sau PresentMon, lasă și acea sursă pornită. Nu distribuie tokenurile agentului. Rezultatul ajută la distingerea unui senzor lipsă, a unei aplicații de monitorizare oprite sau a unui joc nedetectat.

## Fișiere și transfer

Tabul **Files** listează discurile locale și folderele rapide ale utilizatorului Windows. **Back / Forward** urmează locurile vizitate și restaurează căutarea/sortarea; **Up** deschide părintele și **Home** revine la locații. Poți căuta după nume în folderul curent, sorta, salva favorite per PC și selecta mai multe intrări. Fiecare rând are un meniu vizibil cu acțiuni. Căutarea nu scanează recursiv întregul disc.

- **Download / Save to Files** descarcă fișiere pe telefon pentru distribuire sau salvare. **Preview** folosește Quick Look pentru tipurile acceptate.
- **Download this folder as ZIP / Download folder as ZIP** pregătește și descarcă întregul folder, inclusiv subfolderele, numele Unicode și directoarele goale. Poți selecta mai multe foldere împreună cu fișiere; fiecare folder devine propriul ZIP. Pregătirea și descărcarea au progres separat și pot fi anulate; originalele nu sunt mutate sau șterse.
- **Upload from Files / Upload photos or videos** trimite fișiere selectate din aplicația Fișiere sau poze/video în folderul deschis pe PC. Progresul, viteza și anularea sunt vizibile în aplicație.
- **New folder**, redenumirea, mutarea și **Recycle** organizează fișierele. Trimiterea în Recycle Bin cere confirmare; Windows poate refuza volumele sau intrările care nu suportă reciclarea. Orbit nu recurge automat la ștergere definitivă.

Agentul folosește permisiunile contului Windows care îl rulează. Nu escaladează la administrator pentru acces la foldere. Tokenurile, identitatea TLS, istoricul privat și modificarea folderului agentului sunt protejate. Linkurile simbolice/junctions, hard linkurile, căile de rețea UNC, căile de dispozitiv și alternate data streams sunt refuzate; deschide direct folderul local original.

| Limită actuală | Valoare / comportament |
| --- | --- |
| Upload | Cel mult **2 GiB/fișier**; scriere temporară și publicare după finalizare |
| Download | Cel mult **16 GiB/fișier** |
| Previzualizare pe telefon | Cel mult **64 MiB/fișier** |
| Coliziune de nume | Eroare; fișierul existent nu este suprascris automat |
| Mutare | Pe același disc; între discuri răspunde **409**, fără modificări |
| Download folder ca ZIP | Cel mult **2 GiB surse / 2 GiB ZIP**, **10.000 intrări** inclusiv directoare, **32 niveluri sub folderul ales** |
| Pregătire ZIP | Cel mult **120 secunde**, două operații active; date temporare expirate după **10 minute** |
| Upload directoare | Nu este inclus; selectează fișierele individual |
| Listare foarte mare | Paginată; maximum 100.000 de intrări scanate într-un folder |

Arhivarea verifică fiecare intrare. Fișierele protejate/inaccesibile, linkurile sau modificările sursei în timpul pregătirii produc eroare pentru întreaga operație; nu sunt omise în tăcere. ZIP-ul temporar este păstrat în stocarea privată Orbit, cu limită de dimensiune și verificarea spațiului liber, și este curățat după transfer/anulare sau expirare. La repornire sunt curățate și arhivele abandonate mai vechi decât intervalul de expirare. PC-ul trebuie să rămână accesibil; salvarea finală pe iPhone se face din meniul de distribuire.

API: `GET /api/files/roots`, `GET /api/files/list`, `GET /api/files/download`, `POST /api/files/upload`, `/mkdir`, `/rename`, `/move`, `/trash`. Pentru foldere: `POST /api/files/archive` cu `{path}` creează o operație; `GET /api/files/archive/{id}` oferă starea/progresul; `GET /api/files/archive/{id}/download` descarcă ZIP-ul gata; `DELETE /api/files/archive/{id}` anulează/curăță operația. Toate cer tokenul principal și HTTPS; tokenul de widget nu acordă acces. Descărcările acceptă intervale de octeți, dar aplicația nu implementează reluarea automată a unui transfer întrerupt. Fișierele de pe telefon sunt temporare până le salvezi prin meniul de distribuire.

## Clipboard și mixer audio

În **Tools → Clipboard**, folosește **Paste from iPhone → Send text to PC** sau **Read PC clipboard → Copy to iPhone**. Sunt acceptate text și linkuri, până la **1 MiB în reprezentarea Unicode Windows**, fără caractere null. Trimiterea înlocuiește textul curent din clipboardul PC-ului; textul gol îl golește. Nu există sincronizare automată sau istoric al clipboardului. Textul afișat pe telefon este șters la ieșirea din ecran sau la schimbarea PC-ului.

În **Tools → Audio mixer**, glisează volumul sau schimbă mute pentru fiecare sesiune Windows Core Audio, inclusiv sesiunile de pe alte ieșiri audio active. O aplicație poate avea mai multe sesiuni; pornește redarea dacă nu apare. Sesiunile dispărute produc o eroare explicită, fără a schimba volumul master. Comenzile sliderului sunt grupate și trimise în ordine; nu coboară întâi volumul la zero. Lista se actualizează cât ecranul este deschis și indică ieșirea curentă.

**Output** permite alegerea unei ieșiri active sau **System default** pentru aplicația respectivă. Agentul verifică sesiunea și momentul creării procesului înainte de fiecare modificare, apoi solicită preferința Windows pentru rolurile console, multimedia și communications. Nu schimbă ieșirea implicită a întregului PC. Windows poate păstra preferința; unele aplicații schimbă dispozitivul numai după repornirea redării sau aplicației, iar cele care aleg explicit propriul dispozitiv o pot ignora. Interfața confirmă salvarea preferinței, nu pretinde că sunetul s-a mutat deja. Dacă o modificare parțială eșuează, agentul încearcă restabilirea rolurilor modificate fără a atinge un PID reutilizat.

Rutarea cere **Windows 10 versiunea 2004/build 19041 sau mai nou ori Windows 11**, plus un vtable oferit printr-unul dintre cele două IID-uri cunoscute. Folosește interfața internă Windows `AudioPolicyConfig`, care nu este un API public Microsoft stabil; activarea și rezultatele sunt verificate, iar versiunile nesuportate afișează motivul. Volumul și mute pot rămâne disponibile fără rutare; alternativ folosește **Windows Settings → System → Sound → Volume mixer**. ABI-ul factual este verificat față de [definițiile originale EarTrumpet](https://github.com/File-New-Project/EarTrumpet/tree/master/EarTrumpet/Interop/MMDeviceAPI), cu [notificarea completă de licență](THIRD_PARTY_NOTICES.md); mecanismul de activare folosește [RoGetActivationFactory documentat de Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/roapi/nf-roapi-rogetactivationfactory). Nu există înlocuire cu o comandă de schimbare a dispozitivului global.

API-urile `GET/PUT /api/clipboard`, `GET /api/audio/sessions`, `POST /api/audio/session`, `GET /api/audio/outputs` și `POST /api/audio/route` cer tokenul principal, HTTPS și o sesiune Windows disponibilă. Rutarea trimite `id`, `expectedCreateTime` și `deviceID`; `deviceID` gol înseamnă revenire la preferința System default a aplicației. Nu salvează textul clipboardului pe disc.

## Sesiuni, grafice și mai multe PC-uri

**Tools → Sessions & graphs** înregistrează automat jocurile detectate; **+** începe o sesiune manuală pentru desktop. Înregistrarea manuală are prioritate și trebuie oprită din ecran sau prin închiderea agentului. Înregistrarea continuă dacă telefonul se deconectează. **Stop recording** nu repornește imediat o sesiune pentru același joc încă activ; o nouă pornire/detectare de joc permite o sesiune nouă.

Agentul salvează o mostră la **5 secunde**, până la **30 de zile / 100 de sesiuni**. Graficele interactive includ FPS, încărcare CPU/GPU, temperaturi, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc toate mostrele reținute și numai senzorii disponibili; graficele lungi afișează o selecție de puncte reale. Întreruperile și senzorii lipsă rămân goluri. Nu se calculează 1% low sau distribuția tuturor cadrelor din aceste mostre periodice. După o oprire neprevăzută, sesiunea veche este marcată **Interrupted**, cu durata până la ultima mostră salvată.

Istoricul rămâne în **`%LOCALAPPDATA%\Orbit\history.sqlite3`**. Reține metrici de monitorizare, nume de sesiune și procesul jocului, fără conținut clipboard, fișiere sau tokenuri. Sesiunile încheiate pot fi șterse cu confirmare de pe telefon. API-ul HTTPS cu tokenul principal: `GET /api/history/sessions`, `POST /api/history/start`, `POST /api/history/stop`, `GET/DELETE /api/history/sessions/{id}`.

**Tools → My PCs** păstrează mai multe profiluri pe telefon: nume, adresă, porturi, certificat și setări Wake-on-LAN, inclusiv calculul automat al broadcastului. **Find a PC nearby** asociază automat un calculator cu PIN-ul afișat pe Windows; **Add manually** păstrează configurarea avansată. Tokenul fiecărui PC este separat în Keychain. Profilurile manuale existente pot fi editate sau reasociate prin cod. Dashboardul și favoritele sunt separate între PC-uri. Ștergerea unui profil nu șterge fișierele sau istoricul de pe calculator.

## Ce se detectează

- Windows CIM: procesor și număr de nuclee/thread-uri, placă de bază și BIOS, module RAM, plăci video și drivere, discuri fizice, sistem de operare.
- psutil: utilizare CPU, RAM, spațiul volumului de sistem, uptime, volume, adaptoare, trafic download/upload și activitate read/write a discurilor.
- NVIDIA `nvidia-smi`, când este disponibil în PATH: temperatură, încărcare, putere, VRAM utilizată/totală și ventilator în procente, când sunt suportate. Cu mai multe GPU-uri, dashboard-ul monitorizează primul GPU NVIDIA; inventarul listează toate plăcile detectate.
- MSI Afterburner, prin memoria partajată locală: senzori CPU/GPU activați în **Monitoring**, când numele, unitatea și componenta pot fi identificate. Nu necesită server web sau export CSV. RTSS oferă separat FPS pentru jocurile detectate.
- [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), alternativă opțională: temperatură CPU package/Tctl/Tdie sau cel mai cald nucleu măsurat când lipsește package, putere CPU package, media frecvențelor nucleelor, CPU fan identificat explicit și lichid/coolant. Poate oferi și temperatură, încărcare, putere, ventilator și VRAM GPU AMD/Intel/NVIDIA, când placa și senzorii le expun.

### MSI Afterburner + RTSS (recomandat)

Conexiunea este **locală și automată**, prin memoria partajată a programelor Windows. Telefonul comunică doar cu Orbit Agent, prin IP-ul, portul și tokenul deja configurate. Nu există o cheie MSI de introdus în Orbit și nu trebuie exportat un CSV pentru RTSS.

1. Descarcă [MSI Afterburner de pe pagina oficială MSI](https://www.msi.com/Landing/afterburner/graphics-cards). La instalare, include **RivaTuner Statistics Server (RTSS)**. Pornește ambele programe în aceeași sesiune Windows ca agentul.
2. În **Afterburner → Settings → Monitoring**, bifează graficele dorite în **Active hardware monitoring graphs**, de exemplu **CPU temperature**, **GPU temperature**, **GPU usage**, **Memory usage**, **Framerate** și **Frametime**, în funcție de ce apare pe PC-ul tău. Apasă **Apply**. Graficul trebuie să aibă o valoare curentă în Afterburner. **Show in On-Screen Display** este opțional pentru afișarea pe PC. Vezi [ghidul MSI pentru monitorizare](https://www.msi.com/blog/msi-afterburner-on-screen-display/).
3. Deschide RTSS din system tray și setează **Application detection level → Low** pentru joc. Pentru o verificare vizuală, poți activa temporar **Show own statistics**; nu este nevoie să lași overlay-ul vizibil pe ecran pentru Orbit.
4. Actualizează agentul complet la **4.1.0**, pornește `start_agent.bat` și deschide jocul. Nu seta `ORBIT_PRESENTMON_CSV` pentru această metodă. Păstrează Afterburner și RTSS pornite pe durata sesiunii.
5. În Orbit, verifică **Tools → Monitoring sources**: sursa senzorilor poate indica MSI Afterburner, iar sursa FPS trebuie să indice RTSS când există cadre recente. GPU NVIDIA poate continua să folosească `nvidia-smi`, care are prioritate. Adaugă cardul **Game frame rate** din **Customize dashboard**. **Tools → Settings → Set up FPS** include acești pași.

**Dacă nu apare o valoare:** verifică întâi că ea există în Afterburner sau în statisticile RTSS. Unele jocuri, API-uri grafice ori sisteme anti-cheat blochează detectarea RTSS; integrarea nu garantează compatibilitatea cu fiecare joc. Pentru un executabil nerecunoscut, setează `ORBIT_GAME_PROCESSES` înainte de pornirea agentului. Datele vechi nu sunt afișate ca măsurători noi după oprirea sursei sau a jocului. PresentMon rămâne o alternativă pentru FPS, descrisă mai jos.

**Limite senzori:** Orbit preia numai senzori identificați și unități compatibile. O citire **Power** în **%** nu devine consum în wați. VRAM utilizată nu dovedește capacitatea totală, iar un ventilator generic nu devine automat CPU fan. Senzorii dezactivați, lipsă sau incompatibili rămân indisponibili. Pentru senzori suplimentari poți porni și LibreHardwareMonitor. Nu este necesară modificarea frecvențelor sau voltajelor în Afterburner pentru monitorizare.

### Alternativă: temperaturi cu LibreHardwareMonitor

**LibreHardwareMonitor 0.9.5+ a eliminat WMI** odată cu trecerea la .NET 10; comanda veche `Get-CimInstance` nu mai este suficientă. Dezvoltatorii recomandă integrarea bibliotecii sau endpoint-ul HTTP în [explicația oficială](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/issues/2143). Orbit folosește HTTP local.

1. Pornește LibreHardwareMonitor și verifică dacă temperaturile apar în fereastra lui. Dacă lipsesc și acolo, pornește-l ca administrator și verifică suportul pentru componente.
2. Activează **Options → Remote Web Server → Run**, pe portul **8085**. Păstrează LibreHardwareMonitor deschis. Pentru acest acces local, nu este nevoie să expui serverul pe Internet.
3. În browserul **PC-ului**, deschide `http://127.0.0.1:8085/data.json`; trebuie să apară date JSON. Orbit cere acces HTTP local fără autentificare suplimentară. Dacă ai activat autentificare în serverul LibreHardwareMonitor, accesul agentului va fi refuzat.
4. Repornește agentul și verifică **Tools → Monitoring sources** pe telefon. Dacă folosești alt port, setează înainte de pornire, de exemplu `$env:ORBIT_LHM_URL = 'http://127.0.0.1:8086/data.json'`.

`ORBIT_LHM_URL` acceptă numai HTTP pe `127.0.0.1`, `localhost` sau `::1`. Agentul citește valorile curente din `data.json`, inclusiv schema veche cu valori formatate. Folosește grade Celsius în API, chiar dacă LibreHardwareMonitor afișează Fahrenheit. Pentru versiunile vechi, este păstrată citirea WMI din `root/LibreHardwareMonitor` sau `root/OpenHardwareMonitor` când sursa HTTP nu este disponibilă. Agentul nu instalează drivere de senzori.

Senzorii necunoscuți rămân **indisponibili**, fără estimări din încărcare. `nvidia-smi` are prioritate pentru GPU; când nu returnează o placă, se poate folosi un singur GPU din MSI Afterburner sau LibreHardwareMonitor. Datele a două plăci sau două surse GPU nu se combină. Temperatura GPU folosește senzorul core, fără a-l înlocui cu temperatura memoriei sau hotspot. VRAM din `Win32_VideoController.AdapterRAM` nu este folosită deoarece câmpul de 32 de biți poate trunchia capacitățile mari. Modelul coolerului, sursa și carcasa pot necesita completare manuală.

**Consum:** `cpuPowerWatts` folosește un singur senzor CPU package pentru un singur procesor; nu însumează package, nuclee și platformă. `gpuPowerWatts` provine din sursa GPU afișată. Niciuna dintre valori, nici suma lor, nu reprezintă consumul întregului PC la priză.

**Frecvență și ventilatoare:** sursa frecvenței live este afișată; media nucleelor măsurată de LibreHardwareMonitor include sursa `LibreHardwareMonitor · core average`. Dacă lipsește, frecvența nominală Windows este etichetată `System · nominal clock`. Un senzor generic „Fan #1” sau o pompă nu este atribuit automat procesorului. Ventilatorul CPU este în RPM, cel GPU în procente când există un senzor potrivit.

**Debite:** traficul de rețea și activitatea discurilor sunt diferențe între contoarele dispozitivelor, în MB/s zecimali. Interfețele active sunt selectate automat, excluzând loopback-ul și adaptoarele virtuale/tunel identificate pentru a reduce dublarea traficului. Nu reprezintă un test de viteză Internet. Conectarea sau resetarea unui dispozitiv reinițializează doar contorul său; celelalte continuă să raporteze. Calculele păstrează precizia contoarelor mari, iar aplicația afișează traficul mic în B/s sau KB/s. Prima citire a unui contor rămâne indisponibilă până la următoarea măsurătoare.

Pentru alegerea exactă a adaptorului, rulează de exemplu `$env:ORBIT_NETWORK_INTERFACE = 'Ethernet'` înainte de `start_agent.bat`. Folosește numele real din Windows (`Get-NetAdapter`); potrivirea ignoră majusculele. Poți selecta explicit și un VPN dacă dorești să măsori acea interfață. Un nume greșit produce trafic indisponibil; adaptorul ales apare în **Monitoring sources**.

Capacitățile folosesc puteri de 1024 (GiB/TiB), chiar dacă numele istorice ale câmpurilor API conțin `GB`/`TB`. `ssdUsedTB` și `ssdTotalTB` descriu **volumul de sistem**. Inventarul static se recitește la repornirea agentului.

În iOS, **Customize dashboard** permite alegerea și reordonarea celor 17 carduri în una sau două coloane. Configurația se păstrează separat pentru fiecare PC.

## Volum fluid

Sliderul folosește direct Windows Core Audio (`SetMasterVolumeLevelScalar`), la nivelul solicitat. Nu mai trimite o serie de taste care coborau mai întâi volumul la zero. COM este inițializat pe firul cererii și eliberat după utilizare; sunt suportate obiectele moderne și vechi pycaw.

Dacă PC-ul nu are un dispozitiv audio activ sau pycaw nu poate comunica cu el, agentul anunță `volumeAvailable: false`, iar comanda răspunde cu eroare 503. Nu simulează că volumul a fost schimbat. Selectează ieșirea audio corectă în Windows și repornește agentul dacă este necesar.

## FPS real cu PresentMon (opțional)

Orbit nu estimează FPS din utilizarea GPU. RTSS are prioritate; dacă nu există o citire RTSS recentă pentru joc, agentul poate citi capturi CSV realizate de [PresentMon Console](https://github.com/GameTechDev/PresentMon/releases), un instrument separat și gratuit. Pentru instalare și opțiuni, vezi [documentația oficială Console](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md).

Variabila recomandată este **`ORBIT_PRESENTMON_CSV`**. Numele folosit anterior din greșeală, `ORBIT_PRESENTATION_CSV`, este acceptat ca alias de compatibilitate dacă variabila recomandată nu este setată. Aceasta îi spune agentului unde să citească; **PresentMon trebuie pornit separat** ca să creeze și să actualizeze CSV-ul. Agentul nu îl descarcă și nu pornește automat captura.

1. Descarcă executabilul **Console x64** potrivit PC-ului din pagina de releases. În File Explorer, deschide folderul descărcării și alege **Open in Terminal**; folosește PowerShell.
2. Pornește jocul și găsește executabilul său în **Task Manager → Details**, de exemplu `example.exe`. Creează folderul pentru captură:

   ```powershell
   New-Item -ItemType Directory -Force -Path 'C:\Orbit' | Out-Null
   ```

3. Pornește captura în aceeași fereastră PowerShell. Înlocuiește numele executabilului PresentMon cu fișierul descărcat și `example.exe` cu **procesul real al jocului**:

   ```powershell
   .\PresentMon-2.3.1-x64.exe --process_name example.exe --output_file C:\Orbit\presentmon.csv --v1_metrics --no_console_stats
   ```

   Numele `PresentMon-2.3.1-x64.exe` este un exemplu, nu o versiune obligatorie. Opțiunile `--process_name`, `--output_file`, `--v1_metrics` și `--no_console_stats` sunt descrise în [documentația oficială](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md). Lasă captura activă. Exemplul folosește `--v1_metrics` pentru o schemă ușor de verificat; sunt acceptate și formatul implicit actual sau `--v2_metrics`, descrise mai jos. Evită `--qpc_time`, `--date_time`, `--multi_csv` și exporturile unor sesiuni vechi. Dacă PresentMon refuză accesul la ETW, pornește doar PresentMon ca administrator sau configurează grupul Windows Performance Log Users conform documentației sale.
4. Dacă agentul rulează deja, oprește-l cu **Ctrl+C**. Deschide un **al doilea PowerShell** în folderul `Orbit-Windows-Agent`, apoi rulează:

   ```powershell
   $env:ORBIT_PRESENTMON_CSV = 'C:\Orbit\presentmon.csv'
   $env:ORBIT_GAME_PROCESSES = 'example.exe;another-game.exe'
   .\start_agent.bat
   ```

5. Revino în Orbit pe telefon. Cardul FPS apare când jocul este detectat și fișierul conține cadre recente pentru procesul său. Pentru verificare rapidă în PowerShell, `Get-Item 'C:\Orbit\presentmon.csv'` trebuie să arate un fișier care continuă să fie actualizat. Închide captura cu **Ctrl+C** la finalul sesiunii.

Variabilele `$env:` se aplică numai acelei ferestre PowerShell și proceselor pornite din ea. La următoarea sesiune, repetă pasul 4. Dacă vrei configurare permanentă, adaugă `ORBIT_PRESENTMON_CSV` și, dacă este necesar, `ORBIT_GAME_PROCESSES` în **Windows → Edit environment variables for your account → User variables**, apoi deschide o fereastră nouă și repornește agentul. Calea trebuie să coincidă exact cu `--output_file`.

`ORBIT_GAME_PROCESSES` este o listă de executabile separate prin `;`. Jocurile din directoare `steamapps/common`, `Epic Games` și `GOG Games` sunt recunoscute și automat. Aceasta este o euristică: pentru jocuri instalate în alte directoare sau procese cu nume neobișnuite, configurează lista explicit. Dintre mai multe jocuri active este preferat cel din prim-plan, apoi cel pornit cel mai recent. Un joc nu este considerat pornit doar pentru că ai apăsat Launch.

**Formate CSV acceptate**, fără diferențiere între majuscule și minuscule; toate cer `Application`, `ProcessID` și `SwapChainAddress`:

| Format | Timp și interval | Sursa afișată |
| --- | --- | --- |
| v1 (`--v1_metrics`) | `TimeInSeconds` sau `TimeInMs`, cu `MsBetweenPresents` | `PresentMon · application FPS` |
| Formatul implicit actual | `CPUStartTime` în milisecunde, cu `MsBetweenPresents` | `PresentMon · application FPS` |
| v2 (`--v2_metrics`) | `CPUStartTime` în milisecunde, cu `FrameTime` | `PresentMon · CPU frame FPS` |

Sunt recunoscute și variante explicite ale coloanei de timp în secunde/milisecunde. Timpii QPC brut (`CPUStartQPC`) și datele calendaristice (`CPUStartDateTime`) nu sunt acceptate; folosește exportul normal fără `--qpc_time`/`--date_time`. Opțiunile și semnificația coloanelor sunt descrise în [documentația PresentMon Console](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md).

Valoarea se calculează ca `1000 / media intervalelor în milisecunde`, pe aproximativ ultimele două secunde. `MsBetweenPresents` măsoară intervalele dintre prezentările aplicației; `FrameTime` din v2 descrie ritmul cadrelor CPU, de aceea are o etichetă distinctă. Niciuna nu garantează FPS-ul ecranului, al streamingului sau numărul total de cadre generate prin DLSS/FSR.

Citirea izolează procesul, PID-ul și swap chain-ul cu cele mai multe cadre, ignoră înregistrările parțiale/invalide și cadrele marcate ca generate/repetate. Un joc în prim-plan aflat în captura live poate fi recunoscut și când nu este instalat într-o bibliotecă uzuală. Pentru procese neobișnuite, folosește `ORBIT_GAME_PROCESSES`. Aplicațiile desktop obișnuite, launcherele și browserele nu sunt alese automat drept jocuri.

Dacă nu mai avansează cadrele procesului timp de peste cinci secunde, FPS devine indisponibil chiar dacă alte aplicații continuă să scrie în același CSV. **Tools → Monitoring sources** și pagina **Set up FPS** arată motivul: cale lipsă, fișier necitibil, format incompatibil, joc nedetectat sau captură oprită. Capturile pot crește pe disc; oprește PresentMon după sesiune și șterge/rotește CSV-ul înainte de următoarea.

## Widgeturi cu acces numai pentru citire

1. Actualizează agentul și aplicația iOS împreună, apoi asociază PC-ul prin **Find my PC**. Accesul pentru widgeturi este pregătit automat.
2. În Xcode, aplicația și extensia **OrbitWidgets** trebuie să aibă același **App Group înregistrat și semnat**, cu `ORBIT_APP_GROUP_IDENTIFIER` configurat corect; vezi [ghidul de semnare](../Orbit-iOS/WIDGETS.md#testare-gratuită).
3. Adaugă un widget Orbit pe iPhone. Prin **Edit Widget → PC**, alege unul dintre calculatoarele asociate. Nu introduci adresa, portul sau tokenul. Dacă accesul necesită refacere, folosește **Tools → Widgets → Refresh widget access** în timp ce PC-ul este conectat.

Agentul generează automat `.orbit-widget-token`, un secret diferit de `.orbit-token`. `POST /api/widget/pairing` necesită **tokenul principal de control** și returnează tokenul pentru widgeturi. `GET /api/widget/status` acceptă **numai tokenul de widget**, prin antet Bearer, și oferă un rezumat de telemetrie fără comenzi sau inventar complet. Tokenul de widget nu autorizează controlul PC-ului sau accesul la Task Manager.

Widgeturile citesc direct agentul prin **HTTPS** și verifică certificatul PC-ului. App Group partajează profilurile și exclusiv tokenul read-only, în Keychain-ul grupului; tokenul principal rămâne privat aplicației. Sunt disponibile Overview, Gaming, Power, Temperatures, Cooling, Storage, Network și un singur indicator la alegere, cu teme proprii. Afișează ora capturii și expiră după **15 minute**. Solicită o actualizare după 15 minute, dar iOS stabilește programarea efectivă; nu oferă monitorizare continuă.

**Tools → Live Activity** configurează separat profilul Overview/Gaming/Power, stilul Standard/Minimal/Detailed, indicatorul compact, accentul și intervalul **5/10/15 secunde**. Actualizările locale depind de aplicația activă; în fundal se poate afișa starea de pauză, iar după trei intervale fără date valorile sunt ascunse. iOS poate suspenda aplicația; intervalul ales nu îi acordă rulare permanentă în fundal. Butonul **Stop** din prezentarea extinsă sau stilul Detailed oprește activitatea. Vezi [ghidul iOS](../Orbit-iOS/WIDGETS.md).

Pentru revocarea widgeturilor, oprește agentul, șterge `.orbit-widget-token` și repornește. În aplicație, refă accesul widgeturilor pentru PC-ul respectiv; instanțele care îl selectează vor folosi accesul reînnoit. Tokenul principal rămâne separat. Nu distribui fișierele tokenurilor.

**Tools → Appearance** oferă stilurile **Improved / Classic**, temele Ocean, Aurora, Violet, Ember și Graphite, un accent comun pentru cardurile de metrici și reducerea luminii de fundal. Aspectul se configurează pe iPhone; nu schimbă senzorii sau serviciile Windows.

## Task Manager de pe telefon

În Orbit, deschide **Task Manager** pentru lista proceselor, caută după nume/PID și sortează numeric descrescător după **CPU, GPU, RAM sau VRAM**, ori alfabetic după nume. Apar separat memoria GPU dedicată (**VRAM**) și memoria GPU partajată din RAM. Un proces nou poate avea CPU/GPU indisponibil până la o măsurătoare ulterioară; consumul nu este inventat dintr-o singură citire. Reîmprospătarea se face cât ecranul este deschis.

Citirile GPU folosesc direct Windows **PDH**, fără Afterburner sau PresentMon: `GPU Engine(*)\Utilization Percentage` și `GPU Process Memory(*)\Dedicated Usage` / `Shared Usage`. Sunt necesare contoarele disponibile în driver și **WDDM 2.0 sau mai nou**. Procentul afișat este cel al celui mai ocupat motor GPU al procesului, conform [metodei explicate de echipa Microsoft DirectX](https://devblogs.microsoft.com/directx/gpus-in-the-task-manager/), nu suma motoarelor. Căile sunt neutre față de limba Windows prin [PdhAddEnglishCounterW](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhaddenglishcounterw), iar mostrele folosesc [PdhGetFormattedCounterArrayW](https://learn.microsoft.com/en-us/windows/win32/api/pdh/nf-pdh-pdhgetformattedcounterarrayw), cu dimensiuni și stări validate.

`—` înseamnă că nu există o mostră validă pentru proces/driver, nu un zero estimat. Contoarele sunt amorsate pentru fiecare identitate PID + createTime, iar identitatea este reverificată înainte de atașarea datelor GPU. Memoria per proces poate include alocări partajate între aplicații, deci suma rândurilor poate depăși memoria fizică folosită. Microsoft documentează și [o problemă a contoarelor GPU Process Memory pe anumite sisteme Windows 10](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/gpu-process-memory-counters-report-wrong-value); aceste citiri sunt valorile Windows, nu o măsurare independentă a VRAM.

**End task** necesită confirmare. Pe Windows, terminarea unui proces este forțată și nu garantează salvarea documentelor sau închiderea ordonată a aplicației. Procesele critice de sistem și agentul Orbit sunt protejate. Nu există terminare automată sau comandă de închidere a tuturor proceselor.

API-ul folosește `GET /api/processes` și `POST /api/processes/{pid}/terminate`, ambele cu tokenul principal de control. Cererea de terminare transmite și momentul creării procesului (`createTime` din lista primită) și acceptă opțiunea `force`. Agentul verifică PID-ul împreună cu momentul creării înainte de terminare; un PID reutilizat nu este suficient pentru a autoriza închiderea noului proces. Lipsa permisiunilor, procesele protejate sau o listă devenită veche produc o eroare explicită; reîmprospătează lista și verifică procesul. Nu trimite comenzi de terminare cu tokenul de widget.

## Wake-on-LAN și comenzi

Activează Wake-on-LAN în BIOS/UEFI și opțiunea **Wake on Magic Packet** a adaptorului de rețea în Windows. De obicei funcționează cel mai bine prin Ethernet. În funcție de placă, alimentare, Fast Startup și setările de economisire a energiei, pornirea din shutdown poate să nu fie posibilă; testează întâi din sleep. Agentul sincronizează IP, MAC și broadcast pentru adaptorul activ. Dacă VPN-ul schimbă adaptorul implicit, verifică manual că MAC-ul configurat în aplicație aparține adaptorului fizic Ethernet.

Comenzile Windows raportează erori când nu se pot executa. HDR trimite scurtătura Win+Alt+B, dar starea HDR nu poate fi verificată de această versiune și rămâne necunoscută. „Close game” trimite o cerere de închidere numai jocului detectat și aflat în prim-plan. Butoanele gamepad sunt mapări de tastatură, nu un controller XInput virtual. Tastatura suportă caracterele din layout-ul Windows activ; caracterele nereprezentabile sunt respinse explicit.

Biblioteca Sunshine este citită din fișierele locale de configurare. Streaming-ul propriu-zis (video, audio, controller) se face direct între aplicație și Sunshine, prin protocolul Moonlight; agentul ajută doar la asociere și la pornire: `GET /api/sunshine/info` raportează porturile, dacă Sunshine rulează, `canSubmitPin` și `canStart`; `POST /api/sunshine/credentials` (JSON `username`/`password`) salvează login-ul web UI al Sunshine în `.orbit-sunshine-login`, lângă token, iar `DELETE` îl șterge; `POST /api/sunshine/pin?pin=1234&name=…` introduce PIN-ul de asociere prin API-ul local al Sunshine (`https://127.0.0.1:<port+1>/api/pin`, Basic auth cu login-ul salvat); `POST /api/sunshine/start` pornește `sunshine.exe` din Program Files când nu rulează. `POST /api/sunshine/launch` rămâne pentru pornirea comenzii unei intrări fără stream. Fluxul `/ws/stream` din Orbit este o **previzualizare JPEG a ecranului**, fără audio.

## Pornire înainte de autentificarea în Windows

Din meniul pictogramei din tray, **Start before Windows sign-in (boot task)** creează (cu drepturi de administrator, prin UAC) un task programat care pornește companionul la boot, în contul tău, fără parolă salvată (tip de logon S4U, deci aceleași fișiere `%LOCALAPPDATA%\Orbit`, aceeași identitate TLS). Instanța de boot rulează cu `--boot`: fără pictogramă în tray, iar funcțiile care au nevoie de desktop (mouse, tastatură, previzualizare, clipboard) nu sunt disponibile până te autentifici. Când te autentifici, instanța normală din tray pornește, îi cere celei de boot să se oprească (`POST /api/internal/handover`, doar de pe loopback, cu token) și preia porturile. Astfel telefonul se poate conecta imediat după pornirea PC-ului (stare, Wake-on-LAN, fișiere, stream prin Sunshine, care rulează oricum ca serviciu). Dacă task-ul nu pornește (contul nu are dreptul „Log on as a batch job”), rulează manual, ca administrator: `schtasks /Create /F /SC ONSTART /RU SYSTEM /RL HIGHEST /TN "Orbit PC Companion (boot)" /TR "\"<cale>\pythonw.exe\" \"<cale>\orbit_agent.py\" --boot"`; în acest caz instanța de boot folosește identitatea TLS a contului SYSTEM, deci telefonul trebuie asociat o dată și cu ea.

`/api/status` raportează `sessionLocked`: `true` cât timp Windows afișează ecranul de autentificare sau de blocare (procesul LogonUI), `false` când sesiunea este deschisă, `null` în afara Windows. Aplicațiile arată „Locked” în locul lui „Online”.

## Configurare avansată

Variabilele de mediu trebuie setate înainte de pornirea agentului:

| Variabilă | Rol |
| --- | --- |
| `ORBIT_API_TOKEN` | Token propriu de minimum 24 de caractere; înlocuiește tokenul din fișier |
| `ORBIT_TOKEN_FILE` | Altă locație pentru fișierul tokenului |
| `ORBIT_HOST` | Adresa de ascultare, implicit `0.0.0.0` pentru acces LAN |
| `ORBIT_PORT` | Portul HTTP/WebSocket, implicit `8765` |
| `ORBIT_TLS_PORT` | Portul HTTPS/WSS, implicit `8766`; trebuie să difere de portul HTTP |
| `ORBIT_HISTORY_FILE` | Altă locație pentru baza SQLite a istoricului; implicit `%LOCALAPPDATA%\Orbit\history.sqlite3` |
| `ORBIT_PRESENTMON_CSV` | Calea completă a CSV-ului PresentMon activ; numele recomandat |
| `ORBIT_PRESENTATION_CSV` | Alias de compatibilitate, folosit numai dacă `ORBIT_PRESENTMON_CSV` lipsește |
| `ORBIT_LHM_URL` | Endpoint HTTP local LibreHardwareMonitor; implicit `http://127.0.0.1:8085/data.json` |
| `ORBIT_NETWORK_INTERFACE` | Numele exact al adaptorului de trafic; implicit selecție automată |
| `ORBIT_GAME_PROCESSES` | Executabilele de jocuri suplimentare, separate prin `;` |
| `ORBIT_SUNSHINE_APPS` | Calea explicită spre Sunshine `apps.json` |
| `ORBIT_SUNSHINE_CONF` | Calea explicită spre `sunshine.conf` (porturi, nume) |
| `ORBIT_SUNSHINE_LOGIN_FILE` | Altă locație pentru login-ul web UI Sunshine salvat (`.orbit-sunshine-login`) |

API-ul de status include `agentVersion`, `sensorSource`, `sensorStatus`, `gpuSource` și `networkInterface`, păstrează câmpurile istorice și include `fps`, `fpsSource`, `fpsUnavailableReason`, `activeGameProcess`, `lastUpdated`, `volumeAvailable` și `telemetryAvailable`. Metricile extinse includ `cpuPowerWatts`, `gpuPowerWatts`, `vramUsedGB`, `vramTotalGB`, `cpuClockMHz`, `cpuClockSource`, `cpuFanRPM`, `gpuFanPercent`, `networkUploadMBps`, `networkDownloadMBps`, `diskReadMBps` și `diskWriteMBps`. Senzorii necunoscuți sunt `null`; clienții trebuie să respecte indicatorii de disponibilitate pentru câmpurile numerice păstrate pentru compatibilitate. `/api/specs` oferă inventarul structurat separat de măsurătorile live.

## Verificări pentru dezvoltare

```powershell
.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.venv\Scripts\python.exe -m unittest discover -p "test_*.py" -v
```

Testele folosesc fișiere temporare și adaptoare Windows simulate; nu trimit comenzi PC reale. Verifică autentificarea și separarea tokenurilor, cerința HTTPS pentru noile funcții, identitatea TLS persistentă, accesul și mutările fișierelor, transferurile întrerupte și coliziunile, clipboardul Unicode, sesiunile audio/cleanup COM, retenția/golurile/reluarea istoricului și regresiile de monitorizare, FPS, Task Manager și volum. Comenzile native, transferurile pe volume Windows reale, Recycle Bin, mixerul, senzorii și FPS-ul trebuie validate separat pe un PC Windows real. Buildul iOS și compatibilitatea JSON se verifică prin comenzile din [README-ul principal](../README.md#verificări-de-dezvoltare).
