# Orbit Agent pentru Windows

Agentul citește componentele PC-ului și permite aplicației de iPhone să vadă telemetria, să trimită comenzi și să afișeze o previzualizare a desktopului. Nu presupune un anumit procesor, GPU, cooler sau capacitate de memorie.

## Pornire și conectare

1. Instalează **Python 3.11 sau mai nou** de la [python.org](https://www.python.org/downloads/windows/), cu opțiunea **Add Python to PATH**.
2. Deschide `start_agent.bat`. Creează automat un mediu Python separat și instalează dependențele. Lasă fereastra deschisă cât timp folosești Orbit.
3. La solicitarea Windows Firewall, permite Python numai în rețeaua **Private**. Telefonul și PC-ul trebuie să fie în aceeași rețea de încredere.
4. Copiază în onboarding-ul Orbit adresa **PC IP**, portul **8765** și **Pairing token** afișate în fereastră. Tokenul nou este unic și persistă în fișierul local `.orbit-token`; vechiul token comun nu mai este acceptat.
5. Așteaptă câteva secunde pentru inventarul complet și prima măsurătoare. Etichetele componentelor pot fi personalizate în aplicație; acest lucru nu modifică senzorii PC-ului.

Traficul HTTP și previzualizarea WebSocket nu sunt criptate. Folosește o rețea de acasă de încredere sau un VPN; nu publica portul agentului pe Internet. `GET /api/discover` este singura rută publică și returnează doar identitatea/versionarea serviciului. Toate datele și comenzile cer `Authorization: Bearer <token>`, inclusiv WebSocket. Tokenurile în URL nu sunt acceptate.

Pentru regenerarea tokenului, oprește agentul, șterge `.orbit-token` și repornește. Introdu tokenul nou pe telefon. Nu distribui fișierul sau capturi ale tokenului.

## Ce se detectează

- Windows CIM: procesor și număr de nuclee/thread-uri, placă de bază și BIOS, module RAM, plăci video și drivere, discuri fizice, sistem de operare.
- psutil: utilizare CPU, RAM, spațiul volumului de sistem, uptime, volumele montate și adaptoarele de rețea.
- NVIDIA `nvidia-smi`, când este disponibil în PATH: temperatură, încărcare, putere și VRAM. La sisteme cu mai multe GPU-uri, dashboard-ul monitorizează primul GPU NVIDIA; pagina de specificații listează toate GPU-urile detectate.
- [Libre Hardware Monitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor), opțional: temperatură CPU package/Tctl/Tdie și lichid/coolant, dacă senzorii sunt publicați în WMI (`root/LibreHardwareMonitor`). Pornește Libre Hardware Monitor și lasă-l deschis; unele plăci cer drepturi de administrator pentru citirea senzorilor. Poți verifica publicarea senzorilor cu `Get-CimInstance -Namespace root/LibreHardwareMonitor -ClassName Sensor` în PowerShell. Agentul nu instalează drivere pentru senzori.

O temperatură necunoscută rămâne **indisponibilă**, fără estimări din încărcare. Fără driverul NVIDIA, încărcarea/puterea/VRAM GPU rămân indisponibile; numele și driverul AMD/Intel se pot detecta în continuare. VRAM din `Win32_VideoController.AdapterRAM` nu este folosit deoarece câmpul de 32 de biți poate trunchia capacitățile mari. Modelul coolerului, sursa și carcasa nu au o interfață universală de detectare; completează-le manual în aplicație unde este disponibil.

Valorile de capacitate folosesc puteri de 1024 (GiB/TiB), chiar dacă numele istorice ale câmpurilor API conțin `GB`/`TB`. `ssdUsedTB` și `ssdTotalTB` descriu **volumul de sistem**, fără să presupună că discul este SSD. Inventarul static se recitește la repornirea agentului.

## Volum fluid

Sliderul folosește direct Windows Core Audio (`SetMasterVolumeLevelScalar`), la nivelul solicitat. Nu mai trimite o serie de taste care coborau mai întâi volumul la zero. COM este inițializat pe firul cererii și eliberat după utilizare; sunt suportate obiectele moderne și vechi pycaw.

Dacă PC-ul nu are un dispozitiv audio activ sau pycaw nu poate comunica cu el, agentul anunță `volumeAvailable: false`, iar comanda răspunde cu eroare 503. Nu simulează că volumul a fost schimbat. Selectează ieșirea audio corectă în Windows și repornește agentul dacă este necesar.

## FPS real cu PresentMon (opțional)

Orbit nu estimează FPS din utilizarea GPU. Citește capturi CSV realizate de [PresentMon Console](https://github.com/GameTechDev/PresentMon/releases), un instrument separat și gratuit. Pentru instalare și opțiuni, vezi [documentația oficială Console](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md).

1. Descarcă executabilul Console x64 potrivit PC-ului și deschide un terminal în directorul lui. În exemplul următor, înlocuiește numele executabilului PresentMon cu fișierul descărcat, iar `example.exe` cu **procesul real al jocului**, vizibil în Task Manager → Details.
2. Pornește captura într-un terminal separat:

   ```powershell
   .\PresentMon-2.3.1-x64.exe --process_name example.exe --output_file C:\Orbit\presentmon.csv --v1_metrics --no_console_stats
   ```

   Creează în prealabil directorul `C:\Orbit`. Folosește `--v1_metrics` pentru un format verificabil și stabil. Lasă captura activă și evită opțiunile `--qpc_time`, `--multi_csv` sau exporturile de sesiuni vechi. Dacă PresentMon refuză accesul la ETW, pornește doar PresentMon ca administrator sau configurează grupul Windows Performance Log Users conform documentației sale.
3. Într-un al doilea terminal PowerShell, în directorul agentului:

   ```powershell
   $env:ORBIT_PRESENTMON_CSV = 'C:\Orbit\presentmon.csv'
   $env:ORBIT_GAME_PROCESSES = 'example.exe;another-game.exe'
   .\start_agent.bat
   ```

`ORBIT_GAME_PROCESSES` este o listă de executabile separate prin `;`. Jocurile din directoare `steamapps/common`, `Epic Games` și `GOG Games` sunt recunoscute și automat. Aceasta este o euristică: pentru jocuri instalate în alte directoare sau procese cu nume neobișnuite, configurează lista explicit. Dintre mai multe jocuri active este preferat cel din prim-plan, apoi cel pornit cel mai recent. Un joc nu este considerat pornit doar pentru că ai apăsat Launch.

**Schema CSV acceptată**, fără diferențiere între litere mari/mici: `Application`, `ProcessID`, `SwapChainAddress`, `TimeInSeconds` **sau** `TimeInMs`, `MsBetweenPresents`. Alte coloane sunt ignorate. Exporturile care conțin doar `FrameTime`/`CPUStartTime` nu sunt acceptate; folosește `--v1_metrics`.

Valoarea afișată este **application FPS**: `1000 / media intervalelor dintre prezentări`, pe ultimele aproximativ două secunde. Nu este FPS-ul desktopului transmis, FPS-ul display-ului sau numărul garantat de cadre generate de DLSS/FSR. Citirea izolează procesul, PID-ul și swap chain-ul cu cele mai multe cadre, ignoră înregistrările parțiale/invalide și nu amestecă jocul cu browserul. Dacă fișierul nu a fost actualizat de peste cinci secunde sau nu mai conține cadre recente ale jocului, FPS devine indisponibil. Capturile pot crește pe disc; oprește PresentMon după sesiune și șterge/rotește CSV-ul înainte de următoarea.

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
| `ORBIT_PRESENTMON_CSV` | Calea completă a CSV-ului activ |
| `ORBIT_GAME_PROCESSES` | Executabilele de jocuri suplimentare, separate prin `;` |
| `ORBIT_SUNSHINE_APPS` | Calea explicită spre Sunshine `apps.json` |

API-ul de status păstrează câmpurile istorice, adaugă `fps`, `fpsSource`, `fpsUnavailableReason`, `activeGameProcess`, `lastUpdated`, `volumeAvailable` și `telemetryAvailable`. Senzorii necunoscuți sunt `null`; clienții trebuie să respecte indicatorii de disponibilitate pentru câmpurile numerice păstrate pentru compatibilitate. `/api/specs` oferă inventarul structurat separat de măsurătorile live.

## Verificări pentru dezvoltare

```powershell
.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.venv\Scripts\python.exe -m unittest discover -p "test_*.py" -v
```

Testele nu trimit comenzi PC reale: verifică autentificarea, tokenurile, discovery, schema goală, parsarea GPU și PresentMon, expirarea capturilor, selectarea procesului, inițializarea/închiderea agentului, cleanup COM și regresia sliderului (un singur apel scalar, fără taste de volum). Comenzile native, senzorii și FPS-ul trebuie validate separat pe un PC Windows real.
