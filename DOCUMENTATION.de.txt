Klickifax
=========

Klickifax ist der Browser von R4OS. Die erste Ausbaustufe stellt die
Browseroberflaeche, URL-Verarbeitung, einen begrenzten Verlauf und interne
Seiten bereit. Sie wird ueber Start -> Programs -> Internet -> Klickifax
gestartet.

Interne Seiten:

- about:klickifax       Start- und Informationsseite
- about:blank           leere Seite
- about:fixture-one     lokale Navigationsseite
- about:fixture-two     zweite lokale Navigationsseite
- about:search          lokale HTML-GET-Suchfixture
- about:search-results  lokale Ergebnisliste mit anklickbaren Links
- about:error           deterministische Fehlerseite

HTTP- und HTTPS-Adressen werden normalisiert, in den Verlauf aufgenommen und
ueber die gemeinsame SDK-Webtransport-Fassade geladen. DNS und TCP bleiben
bei R4NET, HTTP/1.1 bei `r4os.http`/R4HTTP und TLS 1.2 samt Zertifikatspruefung
bei R4TLS.

Geladene HTML-Antworten verarbeitet der gemeinsame `r4os.html`-/R4HTML-Kern
als dokumenteigenen, begrenzten DOM-Baum. `r4os.css` und R4CSS verarbeiten
den benoetigten CSS-Zielbestand mit Selektoren, Kaskade, Vererbung und
Variablen. `r4os.web_layout` erzeugt daraus bei jedem Laden und Resize eine
begrenzte strukturelle Renderliste fuer Block-/Inlinefluss, Boxmodell,
Positionierung sowie den benoetigten Flex- und Grid-Grundbestand. Der
allgemeine Layoutpfad wertet Prozent-, Viewport- und lineare CALC-Groessen,
MIN-/MAX-Groessen, BOX-SIZING, automatische Margins und Flexausrichtung aus.
Vertikale Flex-Seitenschalen koennen den Hauptbereich bis zur Clienthoehe
wachsen lassen und einen mehrzeiligen Footer am unteren Rand halten. Dieser
Pfad kennt keine Webseiten- oder Hostnamen. Die allgemeine HTML-Darstellung
behandelt CENTER als zentrierenden Block und INLINE-BLOCK als atomaren
Formatierungskontext, sodass Bilder, Suchfelder und mehrere Aktionen ihrer
gelieferten Dokumentstruktur folgen. Intrinsische Flexbreiten beziehen auch
verschachtelte Inline-Blöcke, deren Innenabstaende, Symbolbreiten und GAPs
ein, damit Kopfzeilengruppen nicht in zu schmale Teilboxen umbrechen.

Seit 0.62.35 transportiert die Renderliste fuer Webseitencontrols deren
berechnete Content-, Padding- und Rahmenbox, Hintergrund, Textausrichtung,
Eckradien, ersten Box-Schatten und Interaktionszustand bis zum Klickifax-
Zeichenpass. Text-, Search-, Select- und Button-Controls verwenden damit
dieselben CSS-Metriken fuer Layout, Darstellung und Treffregion. Ein
zusammengesetztes Suchfeld bleibt normale HTML-/CSS-Struktur; innere Symbole
und Controls werden weder anhand einer Webseite erkannt noch nachgebaut.
Pixelgenaue Rundungskonturen fassen gleiche Scanlines zusammen; weichere
Schatten verwenden wenige Kurvenbaender und gerundete Controls eine
kombinierte Rahmen-/Innenflaeche. So bleiben auch grosse Pillenformen samt
nachfolgenden Beschriftungen im bisherigen GUI-Kommandopuffer vollstaendig.

Die Dokumentflaeche rendert Hintergruende, Rahmen und Text per R4DRAW,
waehlt installierte Fontfamilien samt Unicode-Fallback und besitzt eine
dauerhaft sichtbare Scrollbar. Pfeile, Seitenspruenge sowie Up, Down,
Page Up, Page Down, Home und End bedienen den Ausschnitt.

`r4os.web_navigation` ist das gemeinsame URL-, Redirect- und Verlaufsmodell.
Die Webruntime stellt darauf echte `URL`- und `URLSearchParams`-Konstruktoren
mit gemeinsamen Prototypen bereit. HTTP-, HTTPS- und About-Adressen besitzen
Komponentenansichten, relative Aufloesung, Urspruenge und lebend gekoppelte
Suchparameter. URLSearchParams behaelt Duplikatreihenfolge, verwendet die
Formkodierung, akzeptiert Strings, Records, Sequenzen und Kopien und bietet
Iteratoren, ForEach, Sort, Set, Append, Delete, Has, Get und GetAll. Der
Objektzustand liegt in markengeprueften internen R4JS-Host-Slots und ist fuer
Seitenskripte nicht als Scheinproperty manipulierbar.
`r4os.web_forms` verbindet Textfelder, Schaltflaechen und Links mit Fokus,
Tastaturbedienung und begrenzten DOM-Ereignissen. GET-Formulare werden als
UTF-8 in `application/x-www-form-urlencoded` kodiert. Die internen
Suchseiten pruefen Eingabe, Absenden, Ergebnisdarstellung und erneute
Dokumentnavigation ohne Netzwerk oder Seitensonderparser.

Geladene Antworten werden nur anhand ihres MIME-Typs an den HTML- oder
Klartextpfad gegeben. HTML-DOCTYPEs waehlen Standards-, Limited-Quirks- oder
Quirks-Modus. Redirects ersetzen den laufenden Verlaufseintrag mit ihrem
tatsaechlichen Ziel. Stop und Escape pumpen waehrend eines Abrufs weiter
GUI-Ereignisse und lassen bei Abbruch das vorherige Dokument aktiv.

`r4os.javascript` und R4JS stellen die wiederverwendbare, begrenzte
JavaScript-Laufzeit bereit. `r4os.web_runtime` bindet Window, Document,
Elemente, Ereignisse mit PreventDefault, Timer, URL, History, Fetch, XHR,
pull-basierte Response-Streams und Navigation Timing an jedes Dokument.
Requests gehen ausschliesslich ueber die gemeinsame SDK-Webtransport-
Fassade.

TextEncoder und TextDecoder sind echte markengepruefte Webinterfaces mit
gemeinsamen Prototypen. TextEncoder erzeugt immer UTF-8 und EncodeInto
schreibt nur vollstaendige Unicode-Skalare in ein echtes Uint8Array. Der
streamingfaehige TextDecoder akzeptiert ArrayBuffer, SharedArrayBuffer,
DataView und TypedArray-Ausschnitte. Er unterstuetzt UTF-8 sowie die fuer
Klickifax-HTML relevante Windows-1252-Labelgruppe, behandelt BOM, Ersatz-
und Fatalmodus und bewahrt unvollstaendige Bytesequenzen je Decoderinstanz.
Der begrenzte Zeichensatzumfang ist absichtlich sichtbar; unbekannte Labels
werden nicht geraten, sondern mit RangeError abgewiesen.

Das Headers-Webinterface besitzt validierte HTTP-Tokennamen, normalisierte
Werte, Append, Set, Delete, Get, Has und GetSetCookie. Es akzeptiert andere
Headers-Objekte, Records und iterierbare Name-/Wert-Sequenzen. Keys, Values,
Entries, ForEach und der Standarditerator liefern kleingeschriebene,
lexikografisch geordnete Namen und kombinierte Duplikatwerte; getrennte
Set-Cookie-Felder bleiben ueber GetSetCookie erhalten. Ungueltige Namen,
Zeilenumbrueche und feste Groessengrenzen scheitern sichtbar.

Response besitzt Konstruktor und Prototyp sowie Error-, Redirect- und JSON-
Fabriken. Status, StatusText, Ok, Type, URL, Redirected und Headers stammen
aus dem Antwortzustand. Text, JSON, Bytes und ArrayBuffer konsumieren einen
Body genau einmal und liefern echte Strings, Objekte, Uint8Arrays und
ArrayBuffer. Clone erzeugt vor dem Konsum einen unabhaengigen Body. Die
Body-Sicht liefert echte Uint8Array-Chunks, setzt BodyUsed, sperrt genau
einen Reader und unterstuetzt Cancel und ReleaseLock. Netzwerkantworten
uebernehmen Content-Type, finale Redirectadresse und Redirected aus dem
produktiven Transport.

Request besitzt Konstruktor, Kopierkonstruktion und Clone sowie Methode,
URL, Headers, Body, Mode, Credentials, Cache, Redirect, Referrer, Integritaet,
Keepalive und Signal. Text, JSON, Bytes, ArrayBuffer und Reader verwenden
denselben einmaligen Body-Vertrag wie Response. Fetch uebernimmt Methode,
validierte benutzerdefinierte Header und Body bis in App.web und R4HTTP.
Gefaehrliche Transportheader, GET-/HEAD-Bodies, unzulaessige No-Cors-
Kombinationen und zu grosse Keepalive-Bodies werden vor dem Netzpfad
abgewiesen. AbortController-Signale koennen wartende Requests mit ihrem
originalen Reason ablehnen und liefern Abort-Ereignis sowie ThrowIfAborted.

Seitenskripte besitzen ein festes Instruktionsbudget. Der R4JS-Checkpoint
gibt waehrend langer Ausfuehrungen regelmaessig an Scheduler und GUI zurueck;
Stop und Escape brechen dabei auch JavaScript kooperativ ab. Tasks und
Microtasks werden pro Klickifax-Runde nur in begrenzten Paketen abgearbeitet.
Inline-Skripte werden in R4JS-Diagnosen mit der Dokumentadresse bezeichnet;
extern geladene Skripte behalten ihre eigene aufgeloeste URL.

`r4os.web_security` erzwingt Same-Origin Policy, CORS, CSP, Mixed-Content-
Schutz und Secure Contexts vor fremdem Skript- oder Antwortzugriff. Cookies,
Local Storage und Session Storage sind nach Ursprung getrennt. Persistente
Cookies und Local Storage liegen ausserhalb der Module unter
`C:\R4OS\APPDATA\KLICKIFAX\PROFILE\WEBSTORAGE.DAT`. Einstellungen liegen
unter `C:\R4OS\CONFIG\APPS\KLICKIFAX.R4S`, der unabhaengig loeschbare Cache
unter `C:\R4OS\Temp\Klickifax\Cache\` und kurzlebige Arbeitsdaten unter
`C:\R4OS\Temp\Klickifax\`. Sessiondaten enden mit dem Prozess. Ein alter
Bestand aus `C:\R4OS\CONFIG\KLICKIFAX.DAT` wird einmalig uebernommen und erst
nach bytegenauer Ruecklesepruefung entfernt.

`/SELFTEST` prueft denselben Vertrag sowie die R4HTTP-, R4TLS-, R4HTML-,
R4CSS-, R4JS- und Webruntime-Harnesses im R4OS-Image.

Webbildressourcen verwenden den gemeinsamen dokumentbezogenen Scheduler.
Klickifax waehlt IMG-SRC, SRCSET/SIZES und PICTURE-Kandidaten generisch,
loest sie gegen BASE auf und verarbeitet begrenzte Raster-, SVG- und Data-
URLs ueber R4IMG. Der Ressourcenstatus unterscheidet Laden, Antwort,
Terminalfehler, Abbruch und Ersatz; Alttext erscheint erst nach einem echten
Terminalfehler. Ein nicht verfuegbares IMAGE-Teilbild in einem gueltigen
Inline-SVG unterdrueckt dessen uebrige Vektorgeometrie nicht.

Einlagige CSS-URL- und IMAGE-SET-Hintergruende besitzen dieselbe
dokumentbezogene Ressourcenlebensdauer, bleiben aber als eigene Bildrolle
von einem IMG-Inhalt am selben DOM-Knoten getrennt. Die Stylesheetquelle
bewahrt ihre finale Redirectadresse als Basis relativer URLs. Groesse,
Position, Wiederholung, Alpha und gerundeter Clip werden allgemein geplant
und ohne Seiten- oder Hostnamen-Sonderfall komponiert. Ein Hintergrundfehler
erzeugt kein IMG-Alttext- oder DOM-Fehlerereignis. Trace meldet fuer den
letzten Bildfehler Ressourcen-ID, Rolle, Knoten, Phase, Fehlerklasse,
HTTP-Status, MIME, Bytelaenge sowie angeforderte und finale URL.

Der Gast-Selbsttest dekodiert ueber den ausgelieferten R4IMG-Kontext ein SVG
mit sichtbarer Vektorgeometrie und nicht verfuegbarem optionalem IMAGE-
Teilbild. Damit endet die Bildabnahme nicht bei einem Hostparser oder einem
reinen Quelltextgate.

CSS-AT-FONT-FACE-Regeln werden dokumentbezogen mit Familie, geordneten
LOCAL-/URL-/FORMAT-Quellen, Gewicht, Stil, Breite, Unicodebereich und
FONT-DISPLAY katalogisiert. Klickifax fordert nur Faces an, deren Familie und
Unicodebereich von tatsaechlich ausgegebenem Text benoetigt werden. Relative
Quellen verwenden die finale URL des Stylesheets; Laden, Redirect, CSP,
Abbruch und Navigation laufen ueber dieselbe Dokumentressourcen-Warteschlange
wie andere Webressourcen. AT-MEDIA-Bedingungen verwenden dieselbe
Viewportauswertung wie die Kaskade; bei einer Groessenaenderung werden nur
veraltete Fontquellen abgebrochen und aus der neu aktiven Regelmenge
synchronisiert.

Erfolgreiche Webfontantworten bleiben als unveraenderte Originalbytes im
eigenen, inhaltsadressierten Cache unter
`C:\R4OS\Temp\Klickifax\Cache\Fonts\`. Stagingdateien und Katalog werden
atomar veroeffentlicht; unvollstaendige Antworten sind keine Cachetreffer.
Persistente Objekte verteilen alle 64 SHA-256-Hexzeichen auf sieben
achtstellige Verzeichnisse und ein Blatt `XXXXXXXX.FNT`. Keine Kennung wird
gekuerzt, zugleich bleibt jede Digestkomponente fuer den create-only
FAT32-Publish 8.3-kompatibel. Rekursive, fest begrenzte Startbereinigung
entfernt Orphans, atomare Reste und danach leere Digestverzeichnisse.
Der Cache besitzt eigene Alters-, Groessen- und LRU-Grenzen und beruehrt weder
`C:\R4OS\FONTS\` noch den persistenten R4DRAW-Systemfontkatalog. Diese Stufe
installiert oder aktiviert noch keine Webschrift und startet FONTS.R4X nicht.
