# Orbit Agent pentru Windows

Agentul **4.0.0** citește componentele PC-ului și oferă monitorizare, control, fișiere și transfer, clipboard text, mixer audio și istoric de sesiuni. Nu presupune un anumit procesor, GPU, cooler sau capacitate de memorie. Aplicația are taburile **Overview / Library / Files / Remote / Tools**; setările sunt în **Tools → Settings**.

## Pornire și conectare

1. Instalează **Python 3.11 sau mai nou** de la [python.org](https://www.python.org/downloads/windows/), cu opțiunea **Add Python to PATH**.
2. Deschide `start_agent.bat`. Creează automat un mediu Python separat și instalează dependențele. Lasă fereastra deschisă cât timp folosești Orbit.
3. La solicitarea Windows Firewall, permite Python în rețeaua **Private**, inclusiv portul HTTPS **8766**. Telefonul și PC-ul trebuie să fie în aceeași rețea de încredere sau accesibile prin VPN privat.
4. În onboarding-ul Orbit, introdu **PC address**, **Agent access token** și **PC certificate fingerprint**, copiate din fereastra agentului. Nu include `https://` sau portul în câmpul adresei. Portul securizat este implicit **8766**; **Custom agent port** permite schimbarea lui și a portului legacy 8765. **Test connection** devine disponibil după completarea unei amprente valide.
5. Apasă **Test connection → Continue to my PC**. Prima conexiune reușită salvează automat profilul, cu numele detectat al PC-ului. Așteaptă inventarul și prima măsurătoare. Pentru alt PC sau editarea unui profil existent, folosește **Tools → My PCs**. Tokenurile profilurilor sunt păstrate separat în Keychain; etichetele componentelor și dashboardul se personalizează pentru fiecare PC.

Onboarding-ul verifică certificatul înainte de trimiterea tokenului; fără o amprentă validă nu pornește testul conexiunii. Cu amprenta configurată, aplicația folosește **HTTPS/WSS pe 8766** pentru monitorizare și control. Nu revine la HTTP dacă verificarea certificatului eșuează. **Files, Clipboard, Audio mixer și Sessions & graphs cer HTTPS** și refuză accesul pe HTTP. Portul **8765** păstrează API-ul HTTP și WebSocket pentru clienți locali vechi și widgeturile numai pentru citire; traficul pe acest port nu este criptat. Nu publica porturile agentului pe Internet.

`GET /api/discover` este singura rută publică și returnează doar identitatea/versionarea serviciului. Datele și comenzile cer `Authorization: Bearer <token>`, inclusiv WebSocket. Tokenurile în URL nu sunt acceptate. Widgeturile folosesc un token separat, fără drepturi asupra fișierelor, clipboardului, mixerului sau istoricului.

Certificatul și cheia se generează automat în **`%LOCALAPPDATA%\Orbit\tls\server-cert.pem`** și **`server-key.pem`**. Aceste fișiere persistă între actualizări și nu trebuie copiate în arhive sau pe alte PC-uri. O identitate existentă incompletă sau invalidă produce o eroare explicită; schimbarea intenționată a certificatului cere asociere din nou pe telefon. Dacă adresa IP se schimbă prin DHCP, actualizează adresa din profil; amprenta aceluiași certificat rămâne valabilă și nu trebuie regenerată doar pentru noul IP. O amprentă diferită este refuzată înainte de trimiterea tokenului; verifică identitatea pe PC înainte de reasociere.

Pentru regenerarea tokenului, oprește agentul, șterge `.orbit-token` și repornește. Introdu tokenul nou pe telefon. Nu distribui fișierul sau capturi ale tokenului.

## Actualizare și diagnosticare

Această versiune a agentului raportează **4.0.0**. Oprește copia veche cu **Ctrl+C**, copiază **întregul folder `Orbit-Windows-Agent`** actualizat pe PC și repornește `start_agent.bat`. Toate modulele `orbit_*.py` trebuie actualizate împreună cu `orbit_agent.py`; copierea unui singur fișier lasă funcții vechi sau poate împiedica pornirea. Păstrează fișierele locale `.orbit-token`, `.orbit-widget-token` și folderul **`%LOCALAPPDATA%\Orbit`** cu certificatul și istoricul. Nu copia `.venv` de pe alt calculator; `start_agent.bat` pregătește mediul local. Actualizarea proiectului sau a aplicației iOS nu actualizează automat agentul Windows.

În Orbit, **Tools → Monitoring sources** afișează versiunea raportată de agent, sursa senzorilor CPU/GPU, interfețele de rețea și motivul pentru care FPS este indisponibil. Dacă versiunea este veche, actualizează copia de pe PC și verifică IP-ul la care te conectezi.

Pe PC, după pregătirea dependențelor prin `start_agent.bat`, rulează `check_monitoring.bat` sau:

```powershell
.venv\Scripts\python.exe check_monitoring.py
```

Verificarea citește sursele de monitorizare Afterburner/RTSS și alternativele configurate, fără comenzi de control. Lasă Afterburner și RTSS pornite și deschide jocul pentru verificarea FPS. Dacă folosești LibreHardwareMonitor sau PresentMon, lasă și acea sursă pornită. Nu distribuie tokenurile agentului. Rezultatul ajută la distingerea unui senzor lipsă, a unei aplicații de monitorizare oprite sau a unui joc nedetectat.

## Fișiere și transfer

Tabul **Files** listează discurile locale și folderele rapide ale utilizatorului Windows. Poți naviga, căuta după nume în folderul curent, sorta, salva favorite pentru fiecare PC și selecta mai multe intrări. Căutarea nu scanează recursiv întregul disc.

- **Download / Save to Files** descarcă fișiere pe telefon pentru distribuire sau salvare. **Preview** folosește Quick Look pentru tipurile acceptate.
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
| Transfer de directoare | Fișierele se selectează individual; nu creează automat arhive de foldere |
| Listare foarte mare | Paginată; maximum 100.000 de intrări scanate într-un folder |

API: `GET /api/files/roots`, `GET /api/files/list`, `GET /api/files/download`, `POST /api/files/upload`, `/mkdir`, `/rename`, `/move`, `/trash`. Toate cer tokenul principal și HTTPS; tokenul de widget nu acordă acces. Transferurile cer ca PC-ul și agentul să rămână pornite și accesibile. Fișierele descărcate sunt temporare până le salvezi prin meniul de distribuire al telefonului.

## Clipboard și mixer audio

În **Tools → Clipboard**, folosește **Paste from iPhone → Send text to PC** sau **Read PC clipboard → Copy to iPhone**. Sunt acceptate text și linkuri, până la **1 MiB în reprezentarea Unicode Windows**, fără caractere null. Trimiterea înlocuiește textul curent din clipboardul PC-ului; textul gol îl golește. Nu există sincronizare automată sau istoric al clipboardului. Textul afișat pe telefon este șters la ieșirea din ecran sau la schimbarea PC-ului.

În **Tools → Audio mixer**, glisează volumul sau schimbă mute pentru fiecare sesiune Windows Core Audio a **ieșirii audio implicite**. O aplicație poate avea mai multe sesiuni; pornește redarea dacă nu apare. Sesiunile dispărute produc o eroare explicită, fără a schimba volumul master. Comenzile sliderului sunt grupate și trimise în ordine; nu coboară întâi volumul la zero. Lista se actualizează cât ecranul este deschis. Ieșirile audio alternative nu sunt mixate împreună.

API-urile `GET/PUT /api/clipboard`, `GET /api/audio/sessions` și `POST /api/audio/session` cer tokenul principal, HTTPS și o sesiune Windows disponibilă. Nu salvează textul clipboardului pe disc.

## Sesiuni, grafice și mai multe PC-uri

**Tools → Sessions & graphs** înregistrează automat jocurile detectate; **+** începe o sesiune manuală pentru desktop. Înregistrarea manuală are prioritate și trebuie oprită din ecran sau prin închiderea agentului. Înregistrarea continuă dacă telefonul se deconectează. **Stop recording** nu repornește imediat o sesiune pentru același joc încă activ; o nouă pornire/detectare de joc permite o sesiune nouă.

Agentul salvează o mostră la **5 secunde**, până la **30 de zile / 100 de sesiuni**. Graficele interactive includ FPS, încărcare CPU/GPU, temperaturi, putere, RAM, VRAM și trafic. Mediile și vârfurile folosesc toate mostrele reținute și numai senzorii disponibili; graficele lungi afișează o selecție de puncte reale. Întreruperile și senzorii lipsă rămân goluri. Nu se calculează 1% low sau distribuția tuturor cadrelor din aceste mostre periodice. După o oprire neprevăzută, sesiunea veche este marcată **Interrupted**, cu durata până la ultima mostră salvată.

Istoricul rămâne în **`%LOCALAPPDATA%\Orbit\history.sqlite3`**. Reține metrici de monitorizare, nume de sesiune și procesul jocului, fără conținut clipboard, fișiere sau tokenuri. Sesiunile încheiate pot fi șterse cu confirmare de pe telefon. API-ul HTTPS cu tokenul principal: `GET /api/history/sessions`, `POST /api/history/start`, `POST /api/history/stop`, `GET/DELETE /api/history/sessions/{id}`.

**Tools → My PCs** păstrează mai multe profiluri pe telefon: nume, adresă, porturi, certificat și setări Wake-on-LAN, inclusiv calculul automat al broadcastului. Tokenul fiecărui PC este separat în Keychain. Prima conectare reușită salvează automat profilul. Conexiunea existentă este migrată automat la primul profil când lista este goală; completează amprenta din butonul de editare. Dashboardul și favoritele sunt separate între PC-uri. Ștergerea unui profil nu șterge fișierele sau istoricul de pe calculator.

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
4. Actualizează agentul complet la **4.0.0**, pornește `start_agent.bat` și deschide jocul. Nu seta `ORBIT_PRESENTMON_CSV` pentru această metodă. Păstrează Afterburner și RTSS pornite pe durata sesiunii.
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

1. Actualizează agentul și aplicația iOS împreună, apoi conectează PC-ul în Orbit.
2. Deschide **Tools → Settings → Widgets → Prepare widget access** și copiază **read-only widget token**.
3. Adaugă un widget Orbit pe iPhone. Ține-l apăsat, alege **Edit Widget** și introdu **PC address**, **Agent port** (implicit `8765`) și tokenul copiat. Nu folosi tokenul principal de control.

Agentul generează automat `.orbit-widget-token`, un secret diferit de `.orbit-token`. `POST /api/widget/pairing` necesită **tokenul principal de control** și returnează tokenul pentru widgeturi. `GET /api/widget/status` acceptă **numai tokenul de widget**, prin antet Bearer, și oferă un rezumat de telemetrie fără comenzi sau inventar complet. Tokenul de widget nu autorizează controlul PC-ului sau accesul la Task Manager.

Widgeturile citesc direct acest endpoint, fără App Groups. Sunt disponibile Overview, Gaming, Power, Temperatures și un singur indicator la alegere. Afișează ora capturii și expiră după **15 minute**. Solicită o actualizare după 15 minute, dar iOS stabilește programarea efectivă; nu oferă monitorizare continuă. Live Activity are alt mecanism și marchează datele expirate după 15 secunde fără actualizare. Vezi [ghidul iOS](../Orbit-iOS/WIDGETS.md).

Pentru revocarea widgeturilor, oprește agentul, șterge `.orbit-widget-token` și repornește. Repetă asocierea pentru fiecare widget. Tokenul principal al aplicației rămâne separat. Nu distribui niciunul dintre fișierele tokenurilor.

## Task Manager de pe telefon

În Orbit, deschide **Task Manager** pentru lista proceselor, caută după nume/PID, sortează după CPU sau RAM și reîmprospătează lista când este nevoie. Un proces nou poate avea CPU indisponibil până la o măsurătoare ulterioară; consumul nu este inventat dintr-o singură citire.

**End task** necesită confirmare. Pe Windows, terminarea unui proces este forțată și nu garantează salvarea documentelor sau închiderea ordonată a aplicației. Procesele critice de sistem și agentul Orbit sunt protejate. Nu există terminare automată sau comandă de închidere a tuturor proceselor.

API-ul folosește `GET /api/processes` și `POST /api/processes/{pid}/terminate`, ambele cu tokenul principal de control. Cererea de terminare transmite și momentul creării procesului (`createTime` din lista primită) și acceptă opțiunea `force`. Agentul verifică PID-ul împreună cu momentul creării înainte de terminare; un PID reutilizat nu este suficient pentru a autoriza închiderea noului proces. Lipsa permisiunilor, procesele protejate sau o listă devenită veche produc o eroare explicită; reîmprospătează lista și verifică procesul. Nu trimite comenzi de terminare cu tokenul de widget.

## Wake-on-LAN și comenzi

Activează Wake-on-LAN în BIOS/UEFI și opțiunea **Wake on Magic Packet** a adaptorului de rețea în Windows. De obicei funcționează cel mai bine prin Ethernet. În funcție de placă, alimentare, Fast Startup și setările de economisire a energiei, pornirea din shutdown poate să nu fie posibilă; testează întâi din sleep. Agentul sincronizează IP, MAC și broadcast pentru adaptorul activ. Dacă VPN-ul schimbă adaptorul implicit, verifică manual că MAC-ul configurat în aplicație aparține adaptorului fizic Ethernet.

Comenzile Windows raportează erori când nu se pot executa. HDR trimite scurtătura Win+Alt+B, dar starea HDR nu poate fi verificată de această versiune și rămâne necunoscută. „Close game” trimite o cerere de închidere numai jocului detectat și aflat în prim-plan. Butoanele gamepad sunt mapări de tastatură, nu un controller XInput virtual. Tastatura suportă caracterele din layout-ul Windows activ; caracterele nereprezentabile sunt respinse explicit.

Biblioteca Sunshine este citită din fișierele locale de configurare. Orbit poate solicita pornirea comenzii definite într-o intrare, dar nu execută întregul ciclu Sunshine de pregătire/undo. Pentru intrări fără comandă (de exemplu Desktop), streaming de jocuri, audio, HDR sau rate mari de cadre, folosește Moonlight/Sunshine. Fluxul `/ws/stream` din Orbit este o **previzualizare JPEG a ecranului**, fără audio.

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

API-ul de status include `agentVersion`, `sensorSource`, `sensorStatus`, `gpuSource` și `networkInterface`, păstrează câmpurile istorice și include `fps`, `fpsSource`, `fpsUnavailableReason`, `activeGameProcess`, `lastUpdated`, `volumeAvailable` și `telemetryAvailable`. Metricile extinse includ `cpuPowerWatts`, `gpuPowerWatts`, `vramUsedGB`, `vramTotalGB`, `cpuClockMHz`, `cpuClockSource`, `cpuFanRPM`, `gpuFanPercent`, `networkUploadMBps`, `networkDownloadMBps`, `diskReadMBps` și `diskWriteMBps`. Senzorii necunoscuți sunt `null`; clienții trebuie să respecte indicatorii de disponibilitate pentru câmpurile numerice păstrate pentru compatibilitate. `/api/specs` oferă inventarul structurat separat de măsurătorile live.

## Verificări pentru dezvoltare

```powershell
.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.venv\Scripts\python.exe -m unittest discover -p "test_*.py" -v
```

Testele folosesc fișiere temporare și adaptoare Windows simulate; nu trimit comenzi PC reale. Verifică autentificarea și separarea tokenurilor, cerința HTTPS pentru noile funcții, identitatea TLS persistentă, accesul și mutările fișierelor, transferurile întrerupte și coliziunile, clipboardul Unicode, sesiunile audio/cleanup COM, retenția/golurile/reluarea istoricului și regresiile de monitorizare, FPS, Task Manager și volum. Comenzile native, transferurile pe volume Windows reale, Recycle Bin, mixerul, senzorii și FPS-ul trebuie validate separat pe un PC Windows real. Buildul iOS și compatibilitatea JSON se verifică prin comenzile din [README-ul principal](../README.md#verificări-de-dezvoltare).
