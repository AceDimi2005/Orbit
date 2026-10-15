# Orbit — PC companion

Orbit are două părți: aplicația iPhone/iPad din `Orbit-iOS` și agentul Windows din `Orbit-Windows-Agent`. Actualizează-le împreună.

## Pornire

1. Copiază întregul folder `Orbit-Windows-Agent` pe PC și rulează `start_agent.bat`. Ai nevoie de Python 3.11 sau mai nou. La prima pornire se instalează dependențele și se generează un token privat pentru acel PC.
2. Păstrează fereastra agentului deschisă. Notează IP-ul și tokenul afișate. Permite accesul agentului în Windows Firewall pentru rețeaua privată de acasă.
3. Deschide `Orbit-iOS/Orbit.xcodeproj` în Xcode. Alege echipa ta la **Signing & Capabilities**, atât pentru **Orbit**, cât și pentru **OrbitWidgets**. Pentru iPhone personal poți folosi Personal Team. Dacă Xcode cere, schimbă bundle identifiers în două valori proprii, păstrând prefixul comun.
4. Rulează Orbit. În onboarding, introdu IP-ul și tokenul, apoi **Test connection → Continue to my PC**. Telefonul și PC-ul trebuie să fie în aceeași rețea. Acordă permisiunea iOS pentru rețeaua locală.
5. **Explore with sample data** permite explorarea interfeței înainte de conectare. Modul este marcat vizibil; valorile lui sunt simulate.

Tokenul vechi comun a fost eliminat. Copiază tokenul nou din agent; aplicația îl păstrează în Keychain. Folosește agentul numai într-o rețea de încredere sau printr-un VPN privat; transportul local este HTTP, fără criptare proprie.

## Ce găsești în aplicație

- **Overview:** CPU, GPU, memorie, utilizarea discului sistemului, jocul detectat, FPS disponibil, volum și comenzi rapide. Valorile care lipsesc sunt afișate ca indisponibile.
- **Full PC specifications:** procesor și nuclee, GPU și driver, module RAM, placă de bază, BIOS, Windows, discuri, volume și adaptoare de rețea. Ecranul este accesibil din Overview și Settings. Denumirile pot fi personalizate pentru fiecare PC; câmpul gol revine la detectare.
- **Library:** aplicațiile configurate în Sunshine pe PC. Lansarea cere un răspuns reușit de la agent. Moonlight gestionează streamingul pentru jocuri și propriile setări de calitate.
- **Remote:** trackpad, clickuri, scroll, tastatură și media. Desktop preview primește capturi JPEG, fără audio; pentru jocuri folosește Moonlight.
- **Settings:** conexiune, Wake-on-LAN, reluarea onboardingului, mod preview și Live Activity. Parametrii avansați sunt strânși într-un meniu separat.

Sliderul de volum actualizează direct nivelul audio Windows în timpul glisării. Comenzile sunt trimise în ordine, iar pozițiile intermediare sunt grupate pentru a păstra cea mai recentă valoare. Metoda veche care cobora la zero înainte de fiecare ajustare a fost eliminată. Dacă serviciul audio Windows nu este disponibil, controlul apare indisponibil.

## Senzori și FPS

Inventarul folosește Windows CIM și API-urile sistemului. Monitorizarea GPU NVIDIA folosește `nvidia-smi`; alte plăci pot avea inventarul disponibil fără toate valorile live. Temperatura CPU și a lichidului necesită senzori expuși de LibreHardwareMonitor. Windows nu raportează universal modelul coolerului sau al sursei: completează manual denumirea coolerului când este nevoie.

FPS necesită o captură PresentMon compatibilă și configurarea variabilei `ORBIT_PRESENTMON_CSV`. Este măsurată rata cadrelor prezentate de aplicație; nu este dedusă din profilul de streaming. Agentul recunoaște jocuri din bibliotecile uzuale și permite declararea executabilelor suplimentare prin `ORBIT_GAME_PROCESSES`. Pașii și limitările sunt în [ghidul agentului](Orbit-Windows-Agent/README.md).

## Widgeturi și Dynamic Island

Sunt implementate o extensie WidgetKit reală și o Live Activity locală ActivityKit. Widgeturile sunt scurtături către Overview, Remote și Wake PC. Live Activity afișează măsurătorile recente pe Lock Screen și, pe iPhone compatibil, în Dynamic Island.

Actualizarea funcționează cât timp aplicația poate rula. iOS poate suspenda Orbit în fundal; după 15 secunde fără actualizare valorile sunt marcate ca expirate. Nu există monitorizare permanentă în fundal în această versiune. Implementarea nu cere App Groups sau notificări push. Vezi [testarea gratuită și sursele Apple](Orbit-iOS/WIDGETS.md).

## Wake-on-LAN

Conectează PC-ul măcar o dată pentru detectarea adresei MAC și a rețelei sau completează-le manual în Settings. Activează Wake-on-LAN în BIOS/UEFI și în proprietățile adaptorului Ethernet din Windows. PC-ul trebuie să rămână alimentat. Un pachet trimis nu garantează pornirea: Orbit așteaptă răspunsul agentului înainte să afișeze PC-ul drept conectat.

Broadcastul UDP poate avea restricții suplimentare pe iPhone; verifică nota din [ghidul de testare](Orbit-iOS/WIDGETS.md). Testarea pe simulator nu garantează funcționarea Wake-on-LAN pe telefonul fizic.

## Icon

Iconul este deja inclus în `Orbit-iOS/Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png`. Pentru a-l schimba, deschide **Assets → AppIcon** în Xcode și înlocuiește imaginea universală de 1024 × 1024 cu un PNG pătrat, opac. iOS aplică forma colțurilor.

Generat cu instrumentul integrat imagegen. Promptul folosit: „Create a finished square iOS app icon image for Orbit, a refined PC companion app for monitoring and remote control. Deep midnight navy full-bleed opaque background. A single striking luminous cyan and ice-blue orbital ring around a small central polished dark sphere, subtle 3D glass and satin-metal depth, one bright satellite point. Elegant restrained premium technology aesthetic, strong recognizable silhouette at small size, centered composition occupying 70% of square. No text, letters, computer drawing, mockup, border, rounded square mask, or external padding. The entire 1024 by 1024 image IS the icon artwork, corners opaque navy.”

## Verificări de dezvoltare

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
