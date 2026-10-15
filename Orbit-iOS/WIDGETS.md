# Widgeturi și Dynamic Island

Orbit include o extensie reală WidgetKit (`OrbitWidgets`) și o Live Activity ActivityKit. Nu folosește App Groups, notificări push sau entitlements care cer un abonament Apple Developer plătit.

## Testare gratuită

1. Deschide `Orbit.xcodeproj` în Xcode.
2. În **Signing & Capabilities**, alege același **Personal Team** pentru țintele **Orbit** și **OrbitWidgets**. Păstrează **Automatically manage signing** activ.
3. Dacă identificatorii existenți nu sunt disponibili pentru contul tău, schimbă-i în ambele ținte: de exemplu `com.nume.orbit` și `com.nume.orbit.widgets`. Identificatorul extensiei trebuie să înceapă cu identificatorul aplicației.
4. Rulează aplicația pe simulator sau pe iPhone. Pentru telefonul personal, activează Developer Mode dacă iOS îl solicită și acordă acces la rețeaua locală.
5. Pentru widget: ține apăsat pe Home Screen, alege **Edit → Add Widget → Orbit**. Widgetul mic deschide dashboardul; cel mediu oferă scurtături către Monitor, Remote și Wake PC. Există și versiuni pentru Lock Screen.
6. Pentru Live Activity: conectează PC-ul și pornește funcția din Orbit. Verifică Lock Screen; Dynamic Island apare numai pe modelele de iPhone care au acest hardware. Extinde insula prin apăsare lungă. Permisiunea pentru Live Activities trebuie activată în setările iOS ale aplicației.

Personal Team are limite de instalare și semnare; aplicația trebuie de regulă reconstruită și reinstalată după șapte zile. Un abonament plătit este necesar pentru distribuirea prin App Store/TestFlight, nu pentru implementarea locală a widgeturilor și Live Activities.

## Ce afișează

- Widgeturile sunt scurtături: deschid aplicația în locul potrivit. **Wake PC** deschide controalele și nu trimite automat o comandă. Widgeturile nu pretind că oferă valori PC în timp real.
- Live Activity afișează CPU, GPU, RAM și FPS când agentul oferă un FPS măsurat. Nu estimează FPS din profilul de streaming.
- Aplicația actualizează Live Activity cel mult o dată la cinci secunde, cât timp poate rula și primi date. Ora ultimei actualizări rămâne vizibilă.
- iOS poate suspenda aplicația în fundal. După 15 secunde fără actualizare, Live Activity arată **Open to refresh** și ascunde valorile expirate. La o deconectare cunoscută arată **Offline**.
- Nu există monitorizare continuă garantată în fundal. Aceasta ar necesita o arhitectură suplimentară, de exemplu server și APNs; nu este inclusă în varianta gratuită.

## Limitare separată: Wake-on-LAN pe iPhone

Permisiunea **Local Network** și semnarea gratuită nu garantează trimiterea de pachete broadcast. Apple cere entitlement-ul gestionat `com.apple.developer.networking.multicast` pentru UDP broadcast pe iOS, inclusiv când aplicația folosește BSD sockets. Proiectul nu adaugă acest entitlement restricționat; simpla adăugare manuală nu acordă autorizarea Apple.

Orbit încearcă și trimiterea UDP unicast direct la adresa IPv4 a PC-ului, operație care nu cere entitlement-ul multicast. Această variantă poate depinde de placa de rețea, configurația routerului și păstrarea asocierii IP–MAC în rețea când PC-ul doarme; nu înlocuiește garantat broadcastul. Confirmarea că un pachet a fost acceptat de sistem nu confirmă că PC-ul s-a trezit. Aplicația așteaptă răspunsul agentului pentru confirmare.

Pentru WoL broadcast fiabil pe dispozitiv fizic trebuie evaluată aprobarea Apple pentru Multicast Networking sau o soluție de releu WoL deja disponibilă pe router/un dispozitiv permanent pornit. Acestea nu sunt incluse în proiect. Testarea în simulator nu dovedește că broadcastul va funcționa pe iPhone. Această limitare nu afectează widgeturile, Live Activity locală sau monitorizarea și controlul prin conexiune directă la agent.

## Surse Apple

- [Food Truck: Building a SwiftUI multiplatform app](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app) — exemplul Apple explică instalarea cu Personal Team atât pentru aplicație, cât și pentru ținta Widgets.
- [Displaying live data with Live Activities](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities) — extensia WidgetKit, pornirea locală în foreground, actualizarea și încetarea prin ActivityKit; push este o opțiune separată.
- [Developer account overview](https://developer.apple.com/help/account/basics/about-your-developer-account) — limitele Personal Team și profilurile valabile șapte zile.
- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios) — disponibilitatea serviciilor după tipul contului.
- [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — UDP unicast nu cere entitlement multicast; UDP broadcast îl cere pe iOS.
- [TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) — cerința se aplică indiferent de API, inclusiv BSD sockets.

Semnarea și afișarea pe un iPhone real depind de contul și permisiunile dispozitivului; buildul pentru simulator nu înlocuiește această verificare.
