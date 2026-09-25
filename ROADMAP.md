# 7-Mac — Roadmap di sviluppo

GUI nativa macOS per 7-Zip, con il motore 7-Zip **incorporato nell'app** come framework.

- **Stato:** M0–M5 completi e verificati, tranne la notarizzazione (rinviata)
- **Ultimo aggiornamento:** 2026-09-25
- **Upstream:** [ip7z/7zip](https://github.com/ip7z/7zip) 26.03 (2026-09-03)

---

## 1. Obiettivo

Un'app Mac che faccia per 7-Zip quello che manca oggi: lettura di ~60 formati di archivio,
scrittura dei 7 supportati, con un'interfaccia che non sia un wrapper attorno a un terminale.
Nessuna dipendenza esterna, nessun Homebrew, nessun binario da installare a parte.

Non obiettivi (almeno per ora): sincronizzazione cloud, editing di contenuti, backup incrementali.

---

## 2. Decisione architetturale

> **Incorporare la libreria, non il binario.**

Il motore viene compilato dal sorgente upstream e distribuito dentro l'app come
`SevenZipKit.framework`. L'app non lancia sottoprocessi.

```
7-Mac.app
├─ Contents/MacOS/7-Mac                     ← Swift / SwiftUI, la UI
└─ Contents/Frameworks/
   └─ SevenZipKit.framework                 ← dylib universale, LGPL
      ├─ Format7zF          (codec + 60 handler di formato)
      ├─ CPP/7zip/UI/Common (Extract, Update, EnumDirItems, HashCalc…)
      └─ Shim Obj-C++       (implementa i callback COM, espone API a Swift)
```

### Perché non il sottoprocesso `7zz`

Tre limiti strutturali della CLI, tutti verificati sperimentalmente:

| Limite della CLI | Soluzione via libreria |
|---|---|
| Le password **non si possono passare su stdin** (con stdin non-tty stampa `Enter password` e poi `Break signaled`). Restano solo `-p<pw>` in argv, visibile a ogni processo dell'utente in `ps`, oppure un PTY | `ICryptoGetTextPassword2` → callback in-process. La password non tocca né il disco né la command line |
| Il progresso è **solo una percentuale** (`-bsp1`), intercalata a backspace da filtrare. Niente byte, niente throughput | `IProgress::SetTotal` / `SetCompleted` → conteggio byte esatto, per file e complessivo |
| Il listato va ottenuto con `l -slt` e **parsato da testo** | `IInArchive::GetProperty` → `PROPVARIANT` tipizzati |

### Perché lo shim deve essere Obj-C++

L'API di 7-Zip è COM-style: vtable C++ astratte con refcount proprio (`IInArchive`,
`IArchiveExtractCallback`, `ICryptoGetTextPassword2`). Swift non può implementare quelle
interfacce, nemmeno con l'interop C++ di Swift 6 — è precisamente il caso in cui l'interop
è fragile. Lo strato Obj-C++ implementa i callback e li espone a Swift come closure e
`AsyncStream`.

### Cosa NON va riscritto

Il sorgente upstream contiene già la logica di alto livello che `7zz` usa sopra la libreria.
Si compila dentro lo shim invece di reimplementarla:

| File | Righe | Cosa fa |
|---|---|---|
| `UI/Common/ArchiveExtractCallback.cpp` | 3242 | Estrazione: path, collisioni, attributi, timestamp |
| `UI/Common/Update.cpp` | 1931 | Creazione e aggiornamento archivi |
| `UI/Common/Extract.cpp` | 583 | Orchestrazione dell'estrazione |
| `UI/Common/EnumDirItems.cpp` | — | Scansione ricorsiva, wildcard, esclusioni |
| `UI/Common/OpenArchive.cpp` | — | Apertura, sniffing del tipo, archivi annidati |
| `UI/Common/HashCalc.cpp` | — | Calcolo hash |
| `UI/Common/LoadCodecs.cpp` | — | Registrazione codec |

---

## 3. Fattibilità: verificato, non ipotizzato

Prove eseguite il 2026-09-21 su macOS 26.5.1, Xcode 26.6, Apple Swift 6.3.3.

| Verifica | Esito |
|---|---|
| Build `Format7zF` arm64 (`make -j -f ../../cmpl_mac_arm64.mak`) | ✅ 12 s, zero warning (compila con `-Weverything -Werror`) |
| Build `Format7zF` x86_64 (`cmpl_mac_x64.mak`) | ✅ makefile macOS **ufficiali** per entrambe le architetture |
| `lipo` → dylib universale | ✅ 5,0 MB, `x86_64 arm64` |
| Dipendenze dinamiche | ✅ solo `libSystem.B.dylib` e `libc++.1.dylib` |
| `dlopen` + `dlsym` | ✅ `CreateObject`, `GetNumberOfFormats`, `GetHandlerProperty2`, `GetHashers`, `GetModuleProp` |
| Enumerazione a runtime | ✅ **60 formati**, di cui **7 scrivibili** |
| `CreateObject(&clsid, &IID_IInArchive, …)` | ✅ `hr = 0x00000000`, oggetto istanziato |

### Formati

**Lettura (60):** 7z, zip, rar, rar5, tar, gz, bz2, xz, zstd, lzma, cab, msi/compound, chm,
dmg, hfs, apfs, iso, udf, squashfs, cramfs, ext2/3/4, fat, ntfs, gpt, mbr, apm,
vhd, vhdx, vmdk, vdi, qcow2, wim, deb/ar, rpm, xar/pkg/xip, cpio, arj, lzh, nsis,
pe/exe, elf, macho, swf, flv, base64, uuencode, split, z, …

**Scrittura (7):** `7z`, `zip`, `tar`, `wim`, `gzip`, `bzip2`, `xz`

### Limiti accertati — da non promettere in UI

- **zstd è read-only.** Nessuna scrittura, né via CLI (`-tzstd` → errore) né via libreria
  (non compare tra i 7 formati scrivibili). Vale anche per `.tar.zst`.
- **SFX non esiste su macOS.** Manca `7zCon.sfx` nella distribuzione; `-sfx` fallisce con
  `errno=2`. Da rimuovere dallo scope.
- **RAR è solo in lettura**, per licenza oltre che per implementazione.

---

## 4. Milestone

### M0 — Fondamenta di build  ✅ fatto

- [x] `Vendor/7zip/` con il tarball sorgente pinnato + SHA-256 verificato in fase di build
- [x] Aggregate target che compila arm64 + x86_64 e fa `lipo`
- [x] Target `SevenZipKit.framework` (Obj-C++), `install_name` = `@rpath/…`
- [x] Embed & Sign nel target app; build pulita da albero pristino
- [x] Test di fumo: il framework carica ed elenca i 60 formati

**Criterio di uscita: raggiunto.** `Scripts/smoke-test.sh Release` parte da un albero
pulito e verifica 14 asserzioni: `.app` universale e firmata, framework incorporato con
`install_name` `@rpath`, nessuna dipendenza fuori da `/usr/lib` e `/System`, motore che
riporta `26.03`, **60 formati**, i **7 scrivibili** attesi, zstd read-only, e che a
caricarsi sia davvero la copia dentro il bundle.

Struttura prodotta:

```
Scripts/upstream-pin.sh          versione, nome file e SHA-256: l'unico posto da toccare per un bump
Scripts/build-7zip-engine.sh     verifica l'hash, estrae, compila per $ARCHS, lipo, stampa le licenze
Scripts/smoke-test.sh            il criterio di uscita in forma eseguibile
SevenZipKit/Internal/SZKEngineCore.{hpp,cpp}   C++ puro: l'unica TU che vede gli header 7-Zip
SevenZipKit/SZK{Engine,Format}.{h,mm}          facciata Obj-C
```

Tre cose emerse implementando, non previste dalla progettazione:

1. **La libreria statica va linkata con `-force_load`.** 7-Zip registra i suoi handler da
   costruttori globali in TU che non esportano simboli referenziati: con un link normale il
   linker le scarta tutte. Il framework compila, linka e si carica senza un errore — e
   riporta **zero** formati. Verificato in entrambi i sensi prima di scrivere il target.
2. **Obj-C++ non basta come confine: serve un `.cpp` puro.** 7-Zip dichiara `typedef int
   BOOL`, il runtime Obj-C `typedef bool BOOL`. I due set di header non stanno nella stessa
   translation unit. `SZKEngineCore.cpp` è il muro, ed è anche dove andranno i callback COM
   di M1.
3. **`MyInitGuid.h` non va incluso nello shim.** È l'header che *definisce* le costanti
   IID/CLSID, già presenti nell'archivio del motore: includerlo costa 31 simboli duplicati.

E una trappola di build da ricordare: **`xcodebuild -scheme` senza `-destination` risolve
sul Mac corrente e restringe `ARCHS` alla sua sola architettura.** Un Release così è
arm64-only nonostante `ARCHS = arm64 x86_64`. L'universale richiede
`-destination 'generic/platform=macOS'`.

### M1 — Nucleo del motore  ✅ fatto

- [x] Shim: apertura archivio, enumerazione voci, proprietà tipizzate
- [x] Callback di progresso (byte) e di password
- [x] Callback di estrazione con politica collisioni
- [x] Facciata Swift: `open`, `list`, `extract(indices:to:)`, `create`, `test`
- [x] Cancellazione cooperativa
- [x] Test unitari su archivi campione, inclusi cifrati e multi-volume

**Criterio di uscita: raggiunto.** 28 test XCTest, tutti verdi, che fanno il giro
completo — creano con il nostro codice, rileggono con il nostro codice, e confrontano
byte per byte con l'albero di partenza: 7z, zip, tar, contenuti cifrati, header cifrato,
multi-volume, path non-ASCII, symlink, estrazione parziale per indice, `test` su archivio
sano e su archivio corrotto, cancellazione, e i limiti che rifiutiamo (zstd in scrittura,
xz su una cartella). `Scripts/smoke-test.sh` li esegue insieme ai controlli di M0.

Struttura aggiunta:

```
Scripts/engine/                  bundle di build: makefile + TU di init (vedi il suo README)
SevenZipKit/Internal/SZKArchiveCore.{hpp,cpp}   apertura, enumerazione, estrazione, test
SevenZipKit/Internal/SZKUpdateCore.{hpp,cpp}    creazione
SevenZipKit/Internal/SZKBridging.{h,mm}         ponte Obj-C++ (blocchi ⇄ std::function, NSError)
SevenZipKit/SZK{Archive,ArchiveEntry,Options,Progress,Error}.*   API Obj-C
7-Mac/SevenZip/{SevenZip,Archive}.swift         facciata Swift async
7-MacTests/                                     i test
```

**Il codice upstream è compilato, non riscritto.** `ArchiveExtractCallback.cpp` (3242 righe),
`Update.cpp` (1931), `Extract.cpp`, `EnumDirItems.cpp`, `OpenArchive.cpp`, `LoadCodecs.cpp`
sono nel framework e fanno il lavoro vero: path di output, collisioni, attributi POSIX,
timestamp, symlink e hard link, blocchi solidi, volumi. Il nostro codice risponde alle loro
domande, non le rifà.

### Una decisione di licenza presa qui

**La facciata Swift sta nel target app, non nel framework.** SevenZipKit è LGPL perché porta
il motore; la facciata è codice nostro e resta MIT. Chiamare una libreria LGPL attraverso un
link dinamico è esattamente l'assetto per cui la licenza è scritta — metterla dentro il
framework l'avrebbe resa LGPL senza alcun motivo.

### Sei cose emerse implementando

1. **`Z7_EXTERNAL_CODECS` va tolto.** Lo definisce `Format7zF` (il plugin `7z.so`), non
   `Alone2` (il `7zz` standalone), e noi siamo il secondo caso. Con quel flag
   `CCodecs::Load()` si mette a cercare un `7z.so` e le cartelle `Codecs/` e `Formats/`
   accanto all'eseguibile: dentro un'app sandboxata può solo fallire. Cambia anche il layout
   delle classi (`CreateCoder.h`), quindi motore e framework devono essere d'accordo.
2. **Esattamente una TU può definire i GUID.** Upstream dà il ruolo a
   `UI/Console/Main.cpp`, che noi non compiliamo. `Scripts/engine/SevenZipKitInit.cpp` lo
   prende, ed è per questo che `DllExports2.o` resta fuori: definirebbe gli stessi GUID una
   seconda volta. Persa la via C (`GetNumberOfFormats` e compagnia), l'enumerazione passa da
   `CCodecs` — che è comunque la porta d'ingresso di `OpenArchive` ed `Extract`.
3. **`COpenOptions::props` non è inizializzato.** Il costruttore azzera ogni altro
   puntatore ma non quello; tutti i chiamanti upstream lo assegnano. Leggerlo non inizializzato
   è un crash dentro `Open`, non un controllo nullo.
4. **`Extract()` da solo non finisce il lavoro.** Serve `CloseArc()`: crea i symlink e gli
   hard link rimasti in sospeso e mette i timestamp sulle cartelle. Senza, i symlink
   atterrano come file regolari vuoti — e nient'altro segnala l'errore.
5. **I contatori di `CArchiveExtractCallback` contano gli elementi *processati*.** In un
   archivio solido il motore attraversa tutto il blocco per arrivare a una voce e riporta
   `kOK` anche per quelle che ha solo decodificato. Il discriminante è `askExtractMode`:
   `kSkip` distingue le voci di passaggio da quelle richieste.
6. **`GetModuleDirPrefix()` non esiste fuori da Windows** se non si compila
   `ArchiveCommandLine.cpp` — il parser della CLI, dove upstream la definisce a partire da
   `argv[0]`, che un framework non ha. La forniamo via `dladdr`; serve solo al percorso SFX,
   fuori scope su macOS.

### M2 — App minima utile  ✅ fatto

- [x] Drag & drop: estrai in cartella accanto all'archivio
- [x] Comprimi la selezione in 7z/zip con preset Veloce / Normale / Massima
- [x] Finestra progresso con byte, ETA, annulla; coda di più operazioni
- [x] Prompt password + salvataggio opzionale in Keychain; cifratura header 7z
- [x] Registrazione handler dei tipi file (doppio clic su `.7z`, `.rar`, …)
- [x] Quick Action / servizio Finder

**Criterio di uscita: raggiunto.** L'app si usa. `Scripts/smoke-test.sh` verifica
**22 asserzioni** — le 14 di M0 più cinque sull'integrazione col Finder e tre sul
sandbox — ed esegue **71 test** unitari, tutti verdi: le 28 di M1 sul motore, più la
coda (estrazione, compressione, password giusta e sbagliata, rifiuto, annullamento,
ordine dei job), la denominazione delle destinazioni, la decodifica di un drop, la
stima di throughput e il Keychain — quest'ultimo dentro l'app host, quindi firmato e
sandboxato come in produzione.

Verificato anche sul campo, non solo in test: `open -a 7-Mac sample.zip` da
`~/Downloads` estrae senza chiedere nulla e senza doppia cartella; se il nome è già
occupato ne crea una intitolata all'archivio; `sample.tar.gz` scarta un livello per
volta come fa 7-Zip; `pbs -dump_pboard` elenca entrambi i servizi;
`NSWorkspace.urlsForApplications(toOpen:)` ci elenca per `.7z`, `.xz` e `.zst`.

Struttura aggiunta:

```
7-Mac/App/AppDelegate.swift                apertura dal Finder e provider dei servizi
7-Mac/Model/AppModel.swift                 coordinatore: preferenze, coda, le due domande
7-Mac/Model/Job.swift                      un'operazione e il suo stato osservabile
7-Mac/Model/JobQueue.swift                 la coda e il lavoro vero
7-Mac/Model/ArchiveNaming.swift            dove atterra un'estrazione, come si chiama un archivio
7-Mac/Model/FolderAccess.swift             permessi di scrittura sotto App Sandbox
7-Mac/Model/PasswordStore.swift            Keychain, opt-in
7-Mac/Model/Preferences.swift              preferenze + preset
7-Mac/Support/{Display,RateEstimate}.swift formattazione e stima del tempo residuo
7-Mac/UI/                                  finestra, riga di coda, fogli, impostazioni
7-Mac/Info.plist                           tipi documento, UTI importate, NSServices
7-Mac/7-Mac.entitlements                   il sandbox, adesso esplicito
```

### Il problema vero di M2 non era la UI

**Sotto App Sandbox, un file trascinato concede l'accesso al file, non alla cartella
che lo contiene.** "Estrai accanto all'archivio" quindi non è gratis: è esattamente
l'operazione che il sandbox nega. Tre mosse, in quest'ordine:

1. `com.apple.security.files.downloads.read-write`, perché il caso di gran lunga più
   comune — uno zip appena scaricato — cade tutto lì dentro e deve funzionare senza
   chiedere niente.
2. Altrove: **un pannello, una volta per cartella**, e poi un bookmark app-scoped
   (`FolderAccess`) che sopravvive ai riavvii. Il job si mette in pausa con la nota
   "Waiting for a destination" invece di fallire.
3. Il pannello di salvataggio del foglio di compressione *è* già una concessione:
   la cartella scelta lì viene registrata come le altre.

Gli entitlement passano quindi da due a quattro. Restano tutti letti e scritti di
file: **nessun `disable-library-validation`**, che incorporare il motore non ha mai
richiesto. Il test di fumo li confronta uno per uno.

### Cinque cose emerse implementando

1. **`Settings` è il nome di una scena SwiftUI.** Un modello chiamato `Settings`
   rompe il `SceneBuilder` con un errore che parla di conformanza a `Scene` e non
   nomina il conflitto. Si chiama `Preferences`.
2. **La password si chiede *prima* della corsa, non dentro il callback.** Il
   `SZKPasswordProvider` è sincrono e gira sul thread del motore: chiedere lì
   significherebbe bloccarlo su un semaforo in attesa di un foglio. Invece si guarda
   `hasEncryptedHeader` e `entry.isEncrypted`, si chiede, e solo poi si parte — così
   una password sbagliata non lascia mezzo albero estratto. Il *ritentativo* passa a
   `SZKOverwritePolicyOverwrite`, altrimenti la politica normale ("tieni entrambi")
   lascerebbe una copia fantasma di ogni file scritto prima dell'errore.
3. **`LSHandlerRank = Owner` non ti rende il predefinito.** Su macOS 26 Archive
   Utility rivendica già `org.7-zip.7-zip-archive`. Ci registriamo come candidati —
   `NSWorkspace.urlsForApplications(toOpen:)` ci elenca — e il predefinito resta una
   scelta dell'utente. Per `.rar` e `.zst`, che nessun altro rivendica, siamo noi.
4. **Per decidere cosa fa un drop non si può chiedere al motore.** Il motore apre
   davvero `.exe`, `.swf`, `.dat` e `.bin`: chiederglielo significa proporre di
   scompattare un eseguibile trascinato per comprimerlo. Il gesto usa una lista
   ristretta e dichiarata (`droppedArchiveExtensions`); il comando Extract no — lì
   decide il motore.
5. **`INFOPLIST_FILE` e `GENERATE_INFOPLIST_FILE` convivono**, e Xcode fonde le
   chiavi generate dentro il file. Ma la cartella sincronizzata copierebbe anche
   `Info.plist` e `.entitlements` in `Resources/`: serve un
   `PBXFileSystemSynchronizedBuildFileExceptionSet`. Il test di fumo controlla che
   non siano finiti lì.

### Due decisioni prese qui

**La coda esegue un job alla volta.** La compressione già satura tutti i core, e due
estrazioni che si contendono lo stesso disco finiscono più tardi delle stesse due in
sequenza. Una coda è il modello onesto, non un limite da aggirare.

**Non c'è la politica "chiedi" sulle collisioni.** Un modale per file in mezzo a un
archivio da quarantamila voci non è una funzione. Le tre offerte sono "tieni entrambi"
(predefinita, l'unica che non può perdere dati), "salta" e "sostituisci"; il callback
`SZKOverwriteHandler` resta nel framework per quando M3 avrà una vista da cui
rispondere sensatamente.

### M3 — Browser dell'archivio  ✅ fatto

Qui l'app smette di essere un wrapper.

- [x] Vista ad albero delle voci con dimensioni, ratio, metodo, CRC, attributi POSIX
- [x] Estrazione parziale nativa (array di indici, non wildcard)
- [x] Anteprima in-place dei file dentro l'archivio (Quick Look, barra spaziatrice)
- [x] **Archivi annidati**: `.tar.gz` navigato come un albero unico (`IInArchiveGetStream`)
- [x] Ordinamento, ricerca, filtri

**Criterio di uscita: raggiunto.** `Scripts/smoke-test.sh` resta a 22 asserzioni ed
esegue ora **93 test**, tutti verdi: i 71 di M2 più 12 sull'albero (cartelle implicite,
`./`, percorsi duplicati, totali, ordinamento, ricerca, filtri) e 10 sul browser e sulle
due primitive nuove del motore — estrazione relativa alla cartella comune, tar dentro tar
aperto in place, 7z che rifiuta di farlo, `.tar.gz` che scende da solo nel tar, zip dentro
7z scompattato e aperto, anteprima (anche cifrata, con password sbagliata e ritentativo),
estrazione di una selezione e di un archivio annidato attraverso la coda.

Verificato anche dal vivo: `outer.zip` con dentro uno zip e un `.tar.gz` mostra le due
voci con dimensioni, metodo (`Store`, `Deflate`) e data; `project.tar.gz` si apre dritto
su `project.tar`, con la barra del percorso per risalire e "Unpacked to a temporary file"
nella barra di stato.

Struttura aggiunta:

```
SevenZipKit/Internal/SZKArchiveCore.cpp   OpenEntry (IInArchiveGetStream) e removePathParts
7-Mac/Model/ArchiveTree.swift             voci piatte → albero; ordinamento, ricerca, filtri
7-Mac/Model/ArchiveBrowser.swift          lo stato di una finestra: pila di livelli, anteprima
7-Mac/UI/BrowserView.swift                Table ad albero, barra percorso, barra di stato
7-MacTests/{ArchiveTree,Browser}Tests.swift
```

### Come si arriva al browser

File › Open… (⌘O), il pulsante "Open…" nella finestra principale, "Show Contents" nel
menu contestuale di un job. Il doppio clic dal Finder **estrae ancora**, come in M2: è una
preferenza ("Opening an archive from the Finder"), e il predefinito non cambia sotto i
piedi di chi c'era già. Il drop sulla finestra estrae sempre — quel gesto dice già cosa
vuole.

### Cinque cose emerse implementando

1. **Gli archivi non contengono un albero.** Contengono percorsi, spesso senza le cartelle
   intermedie. L'albero sintetizza le cartelle mancanti e le sostituisce se l'archivio le
   nomina più tardi; una cartella sintetica non ha indice, quindi selezionarla significa
   selezionare ciò che contiene. Lo stesso percorso due volte (un tar accodato) resta due
   file: sono diversi.
2. **`CArchiveLink` scende già da solo, ma non in un `.tar.gz`.** Segue
   `kpidMainSubfile` — per questo un `.dmg` si apre direttamente su HFS — però pretende un
   `IInStream`, e lo stream decompresso di gzip va solo avanti. Il browser fa lo stesso
   gesto a mano: prova `IInArchiveGetStream` (tar, iso, dmg, cpio, ar: costo zero) e,
   se il contenitore comprime, scompatta la voce in una cartella temporanea e apre quella.
   È ciò che fa anche il file manager di 7-Zip. Il salto automatico vale solo per i
   compressori (gzip, bzip2, xz, zstd, lzma, Z) con una sola voce: uno zip che contiene uno
   zip resta uno zip che si vuole vedere.
3. **"Estrai questi" non vuole il percorso completo.** Chi estrae `docs/2026/report.pdf`
   vuole `report.pdf`. `CArchiveExtractCallback` ha già `removePathParts`, ma rifiuta con
   `E_FAIL` qualunque voce fuori dal prefisso: il prefisso lo calcola il framework dagli
   stessi `PathParts` che il callback confronta, non l'app dalla sua normalizzazione, così
   un `./` in testa non può farli divergere.
4. **Un archivio annidato non ha un file da riaprire.** Il job della coda quindi riceve
   l'`Archive` già aperto (`EntrySelection`), non un URL. Un archivio aperto in place legge
   attraverso lo stream del genitore: condivide la sua coda seriale e lo tiene in vita.
5. **La password si chiede nella finestra che serve.** Il browser ha il suo foglio, e la
   chiede *prima* di accodare un'estrazione cifrata: il foglio della coda sta nella
   finestra principale, che può essere chiusa.

### Limiti accettati

- Il doppio clic su una cartella non la espande: in `Table` l'espansione di `OutlineGroup`
  non è pilotabile; c'è il triangolo.
- Niente trascinamento di voci verso il Finder: richiede `NSFilePromiseProvider` e una
  sorgente di drag AppKit. Candidato per M5.
- Un annidato dentro un contenitore compresso costa una copia su disco temporanea, grande
  quanto la voce. Viene cancellata alla chiusura della finestra, e all'avvio se l'app non ha
  fatto in tempo.

### M4 — Modifica in-place  ✅ fatto

Il differenziatore vero: Keka non lo fa.

- [x] Aggiungi file a un archivio esistente (drag nella finestra, o Add Files…)
- [x] Elimina e rinomina voci (anche cartelle, con tutto il contenuto)
- [x] Aggiorna solo i file più recenti ("Only replace entries older than the file")
- [x] Annulla/ripristina a livello di operazione (⌘Z / ⇧⌘Z, con il nome dell'operazione nel menu Edit)

**Criterio di uscita: raggiunto.** `Scripts/smoke-test.sh` resta a 22 asserzioni ed
esegue ora **106 test**, tutti verdi: i 93 di M3 più 13 sulla modifica — eliminare un file
e una cartella, rinominare un file (7z) e una cartella (tar), nomi rifiutati, aggiungere
dentro una sottocartella, "solo se più recente" in entrambi i sensi, aggiungere a un 7z
con lista cifrata (la voce nuova esce cifrata e la lista resta cifrata), eliminare da un
7z solido cifrato senza password (la chiede, perché deve ricomprimere il blocco), undo e
redo byte per byte, una modifica nuova che cancella il redo, gli archivi che non si possono
modificare, e una modifica fallita che lascia il file identico e niente accanto.

Struttura aggiunta:

```
SevenZipKit/Internal/SZKArchiveImpl.hpp   Archive::Impl, condiviso da lettura e riscrittura
SevenZipKit/Internal/SZKUpdateCore.cpp    DeleteEntries, RenameEntries, AddFiles, WhyNotModifiable
7-Mac/Model/ArchiveEditor.swift           scrivi accanto, fotografa, scambia; undo = scambio inverso
7-MacTests/EditTests.swift
```

### Come funziona una modifica

**Un archivio non si modifica dove sta.** Il motore scrive sempre un archivio nuovo
intero, copiando le voci invariate così come sono — ancora compresse, dove il formato lo
consente (7z fuori dai blocchi solidi toccati, zip, tar). Quindi ogni modifica è:

1. scrivere il nuovo archivio in un file nascosto **accanto** all'originale
   (`.nome.7-Mac-xxxx`), così lo scambio finale è una rename sullo stesso volume;
2. fotografare l'originale nella cartella temporanea della finestra — un clone APFS, che
   non costa spazio finché i due non divergono;
3. `replaceItemAt`: atomico, e il file resta lo stesso per il Finder (nome, posto, tag).

Finché non avviene il punto 3, il file della persona non è stato toccato: una modifica
fallita o annullata semplicemente non è successa. Undo è lo stesso scambio al contrario.

### Quattro cose emerse implementando

1. **La strada giusta è quella del file manager di 7-Zip, non quella della CLI.**
   `UpdateArchive` (quello di `7z a/d/rn`) seleziona per nome e wildcard; `AgentOut.cpp`
   costruisce la lista `CUpdatePair2` per indice e la passa a `IOutArchive::UpdateItems`
   con `CArchiveUpdateCallback`. È lo stesso codice upstream, compilato, non riscritto —
   e per indice vuol dire che due voci con lo stesso percorso restano distinguibili.
2. **7z tiene cifrata la lista da solo.** Senza proprietà, con una password in gioco,
   `encryptHeaders` segue `_passwordIsDefined` dell'archivio aperto. Passare proprietà
   esplicite l'avrebbe resa un'opzione da ricordare; non passarne nessuna la rende
   impossibile da dimenticare.
3. **Eliminare da un 7z solido può chiedere la password anche se l'archivio si apre
   senza.** Togliere una voce da un blocco solido significa decodificare e ricomprimere
   il resto del blocco. Il callback lo dice (`CryptoGetTextPassword`), noi rispondiamo
   `passwordRequired` e il browser chiede.
4. **Aggiungere a un archivio cifrato chiede la password prima.** Il motore non chiede
   con quale password cifrare le voci nuove: se non gliela dai, entrano in chiaro in un
   archivio che per il resto è cifrato.

### Cosa non si modifica, e perché

- Formati senza scrittore (rar, zstd e gli altri 50): lo dice il motore, non una lista.
- Archivi divisi in volumi: 7-Zip non li aggiorna.
- gzip, bzip2, xz: contengono un flusso, non voci.
- Un archivio dentro un altro (anche un `.tar.gz`, che si apre sul tar): riscriverlo
  produrrebbe una copia del tar, non del file. Si potrà fare riscrivendo anche il
  contenitore; non ora.
- La barra di stato dice "Read-only" con il motivo; aggiungi ed elimina sono disattivati.

### Limiti accettati

- La cronologia di undo vive con la finestra: chiusa la finestra, le fotografie vengono
  cancellate. Una cronologia che sopravvive a chi la mostra è un undo che nessuno raggiunge.
- Su un volume non APFS le fotografie sono copie vere: per un archivio grande su un disco
  esterno, ogni modifica costa il tempo e lo spazio di una copia.
- Modificare richiede di poter scrivere nella cartella dell'archivio. Fuori da
  `~/Downloads` il sandbox chiede la cartella una volta, come per l'estrazione.
- Il drop aggiunge nella cartella selezionata (o accanto al file selezionato, o in cima):
  una `Table` SwiftUI non dice su quale riga è caduto il drop senza perdere l'estensione
  sandbox del Finder.

### M5 — Rifinitura  ✅ fatto (notarizzazione rinviata)

- [x] Preset salvabili: formato, livello, dizionario, metodo (LZMA2/PPMd/BZip2…), solid block, thread, con **stima memoria**
- [x] Archivi multi-volume in creazione
- [x] Pannello hash (SHA-256/512/3, MD5, BLAKE2sp, CRC32/64, xxh64) con confronto checksum
- [x] Test integrità con report
- [x] Esclusioni predefinite (`.DS_Store`), gestione symlink e hard link
- [x] **Estensione Quick Look**: anteprima e thumbnail degli archivi
- [x] Localizzazione (italiano), accessibilità, dark mode
- [ ] Notarizzazione e distribuzione — rinviata per scelta

**Criterio di uscita: raggiunto.** `Scripts/smoke-test.sh` verifica ora **27 asserzioni**
(le 22 di M4 più quattro sulle estensioni Quick Look e una sull'italiano) ed esegue
**137 test**, tutti verdi: i 106 di M4 più 31 nuovi.
- **Motore (11):** gli hash coincidono con zlib, `shasum` e CryptoKit; un metodo sconosciuto
  viene rifiutato; gli hash delle voci coincidono con quelli dei file; un archivio cifrato
  li dà solo con la password; un archivio danneggiato produce comunque un report; e metodo,
  dizionario, solid, esclusioni e link arrivano davvero nell'archivio, non vengono solo
  accettati.
- **Profili (15):** proprietà passate al motore, dizionari predefiniti uguali a quelli di
  `LzmaEnc.c`, la formula della memoria di 7-Zip rifatta a mano, la riduzione automatica
  dei thread, salvataggio e migrazione del vecchio preset, un job con PPMd, volumi ed
  esclusioni.
- **Integrità (5):** un archivio sano, uno danneggiato, il test di una selezione nel
  browser, il confronto di un checksum incollato con le sue decorazioni, l'export nel
  formato di `shasum`.

I test girano in inglese: lo schema imposta `language = "en"` per la sola azione Test,
così il sistema in italiano non cambia i testi che i test confrontano.

Struttura aggiunta:

```
SevenZipKit/SZKHash.{h,mm}                     API hash: metodi, file, voci d'archivio
SevenZipKit/Internal/SZKHashCore.{hpp,cpp}     HashCalc upstream per i file su disco
SevenZipKit/Internal/SZKHashInternal.hpp       CHashBundle che ricorda il digest di ogni voce
7-Mac/Model/CompressionProfile.swift           profili, metodi, solid, stima memoria
7-Mac/Model/Checksums.swift                    pannello checksum, confronto, report di test
7-Mac/UI/ChecksumView.swift                    una colonna per metodo; report di integrità
7-Mac/Localizable.xcstrings                    309 stringhe, tutte in italiano
7-MacPreview/, 7-MacThumbnail/                 le due estensioni Quick Look
```

### Sei cose emerse implementando

1. **`HashCalc` vuole un censor già risolto.** `UpdateArchive` chiama da sé
   `AddPathsToCensor`; `HashCalc` lo lascia al chiamante, e senza non trova nulla — il
   report torna vuoto, senza un errore.
2. **Il digest di ogni file dura un istante.** `CHashBundle::Final` lo scrive nello slot 0
   e riavvia l'hasher; il file successivo lo sovrascrive. Per i file su disco lo si legge
   in `SetOperationResult`, che upstream chiama subito dopo; per le voci d'archivio serve
   un `IHashCalc` che avvolge il bundle e lo copia in `Final`. L'hash delle voci viaggia sul
   flusso di hash che `CArchiveExtractCallback` ha già (`SetHashMethods`): è un test che in
   più dice cosa ha visto.
3. **"Automatico" non vuol dire "tutti i core".** Con i thread lasciati al motore, 7z toglie
   thread LZMA2 finché la stima sta nell'80% della RAM (`7zHandlerOut.cpp`). La prima stima
   diceva 12 GB per Ultra; quella che fa lo stesso conto del motore dice 6,2 GB con 4
   thread. L'avviso scatta solo oltre quell'80%, cioè quando dizionario o thread li ha
   forzati la persona.
4. **7-Zip riduce il dizionario alla dimensione dei dati.** Un dizionario da 1 MB su 300 KB
   diventa `LZMA2:384k`: la stima è quella di 7-Zip, un tetto e non una misura.
5. **`-exportLocalizations` non compila il motore.** Non esegue lo script dell'aggregate
   target, quindi il C++ del framework non trova gli header. Il catalogo si aggiorna invece
   dagli `.stringsdata` che il build normale produce, con `xcstringstool sync`. Le frasi
   che arrivano dal motore a runtime ("this format cannot be written") sono chiavi
   `manual`, tradotte e cercate per valore.
6. **Quick Look non si prova da riga di comando se un'altra app rivendica gli stessi tipi.**
   `qlmanage` non lascia scegliere l'estensione, e su questo Mac BetterZip rivendica gli
   stessi UTI. Il codice delle estensioni è verificato da un eseguibile che chiama le stesse
   funzioni (HTML e PNG controllati a vista); la scelta tra le due estensioni la fa l'utente
   in Impostazioni di Sistema › Estensioni › Quick Look.

### Tre decisioni prese qui

**I profili sostituiscono i preset di M2, senza perderli.** Veloce, Normale e Massima sono
profili con il solo livello impostato: tutto il resto resta ai default del motore, che sono
buoni. Il vecchio valore salvato viene migrato al profilo corrispondente.

**Esclusioni e link sono preferenze globali, non del profilo.** "Non mettere `.DS_Store`
negli archivi" è un'abitudine di chi usa il Mac, non una proprietà di un tipo di archivio.

**Il report di test è un risultato, non un errore.** Un archivio danneggiato fa finire il
job come *finito*, con icona arancione e il report: la verifica è riuscita, è l'archivio
che non lo è. Fa eccezione la password sbagliata, che si presenta come "tutte le voci
cifrate falliscono" e viene chiesta di nuovo.

### Limiti accettati

- Accessibilità: etichette su tutti i controlli solo-icona, VoiceOver sulle righe e sulle
  barre di avanzamento, "Riduci movimento" rispettato. Non è stato fatto un giro completo
  con VoiceOver acceso.
- Nella UI solo l'italiano oltre all'inglese. Aggiungere una lingua è aggiungere una colonna
  al catalogo.
- Il trascinamento di voci verso il Finder (limite di M3) resta da fare.

---

## 5. Rischi e cose da sistemare

| # | Questione | Impatto | Azione |
|---|---|---|---|
| 1 | `ENABLE_USER_SCRIPT_SANDBOXING = YES` è attivo nel progetto e **blocca le Run Script phase** che leggono o scrivono fuori dai path dichiarati | Build rotta a M0 | ✅ **chiuso.** `SevenZipEngine` è l'unico target con la sandbox disattivata; la copia delle licenze resta sandboxata dichiarando input e output |
| 1b | Xcode valida gli input del linker **in fase di pianificazione**: `-force_load` su un file non ancora prodotto fa fallire il link prima che l'aggregate target giri | Build rotta a M0, e in modo ingannevole — passa se un build precedente ha già lasciato il `.a` sul disco | ✅ **chiuso.** La script phase dichiara `lib7zip.a` come output, così Xcode ne conosce il produttore |
| 2 | `install_name` della dylib nasce come `b/m_arm64/7z.so` | L'app non carica | ✅ **chiuso.** `DYLIB_INSTALL_NAME_BASE = @rpath`; verificato dal test di fumo |
| 3 | App Sandbox attivo: i percorsi vanno da security-scoped bookmark | Accesso file | ✅ **chiuso a M2.** In lettura non è mai stato un problema — la libreria apre **stream**, non percorsi passati a un figlio. In scrittura sì: un file trascinato concede il file, non la cartella. `FolderAccess` chiede un pannello una volta per cartella e tiene un bookmark app-scoped; `~/Downloads` ha il suo entitlement e non chiede mai |
| 4 | Un bug su archivio malformato fa crashare l'app, non un sottoprocesso | Stabilità | Se emerge, isolare il motore in un **XPC service**; l'API Swift resta identica |
| 5 | Tempo di build del motore in CI | Attrito | Mitigato: lo script salta tutto tramite uno stamp su hash + archi + deployment target. Da freddo sono ~8 s per arch, ~16 s per l'universale |
| 6 | Il binario prebuilt `7zz` upstream **non è firmato** | — | ✅ **confermato sul campo.** L'app parte con App Sandbox e Hardened Runtime attivi: nessun `disable-library-validation`. Gli entitlement a M2 sono quattro, tutti sui file — `app-sandbox`, `files.user-selected.read-write`, `files.downloads.read-write`, `files.bookmarks.app-scope` — e il test di fumo li confronta uno per uno |
| 7 | Su macOS 26 **Archive Utility rivendica già** `org.7-zip.7-zip-archive`, quindi `LSHandlerRank = Owner` non ci rende il predefinito per `.7z` | Il doppio clic può non arrivare a noi | Accettato: ci registriamo come candidati e il predefinito resta una scelta dell'utente. Per `.rar`, `.zst` e gli altri che nessun altro rivendica siamo noi. Da rivedere solo se M5 vuole proporre il cambio in modo esplicito |
| 8 | La password salvata in Keychain è **indicizzata dal percorso** dell'archivio | Spostare o rinominare il file la perde | Accettato, ed è il compromesso giusto: un inode sopravviverebbe allo spostamento e poi consegnerebbe la password a qualunque file lo riusi |

---

## 6. Licenze

L'app è **MIT**. Il motore è **LGPL**. La combinazione è pulita a una condizione precisa.

- **Tenere tutto il codice 7-Zip in una libreria dinamica separata.** L'utente deve poter
  rilinkare una versione diversa del motore. Il framework dinamico soddisfa il requisito;
  **linkarlo staticamente dentro l'app farebbe scattare** l'obbligo di distribuire gli
  oggetti per il relink.
- Nota: anche `UI/Common` è codice 7-Zip LGPL. Compilandolo nello shim, **l'intero
  `SevenZipKit.framework` è LGPL** — ed è esattamente il confine che vogliamo: app MIT che
  linka dinamicamente un framework LGPL. Da M1 `UI/Common` è effettivamente dentro.
- Corollario applicato in M1: **la facciata Swift vive nel target app**, non nel framework.
  È codice nostro e resta MIT; spostarla dentro il framework l'avrebbe resa LGPL per niente.
- Includere `License.txt` upstream nei crediti dell'app.
- **Clausola unRAR**, da riportare testualmente: il codice non può essere usato per
  ricreare l'algoritmo di compressione RAR.
- **Mac App Store:** LGPL e i termini del MAS hanno un attrito noto. Se la distribuzione sul
  MAS diventa un obiettivo, va valutata separatamente prima di investirci. Distribuzione
  Developer ID + notarizzazione non ha questo problema.

---

## 7. Versioning dell'upstream

Vendorizzare il **tarball di rilascio**, non un submodule: `ip7z/7zip` su GitHub è un mirror
dei rilasci, non il repository di sviluppo.

| Artefatto | SHA-256 |
|---|---|
| `7z2603-src.tar.xz` | `9cbde5099c6deb73691b0579063da5827522ccbbcba3f0020fd04e8c8c16c0d4` |
| `7z2603-mac.tar.xz` (solo riferimento) | `5ca87677072c59f5602e5c49baa27d4694bacd2259b4e507f0094249d4281480` |

L'hash va verificato in fase di build: un aggiornamento dell'upstream deve essere una
modifica esplicita e revisionata, mai silenziosa.

---

## Appendice — Comandi di build verificati

```sh
# dal root del sorgente estratto
cd CPP/7zip/Bundles/Format7zF

make -j8 -f ../../cmpl_mac_arm64.mak     # → b/m_arm64/7z.so
make -j8 -f ../../cmpl_mac_x64.mak       # → b/m_x64/7z.so

lipo -create b/m_arm64/7z.so b/m_x64/7z.so -output 7z.dylib
lipo -info 7z.dylib                      # x86_64 arm64
```

Entry point esportati dalla libreria (`CPP/7zip/Archive/Archive2.def`):
`CreateObject`, `GetNumberOfFormats`, `GetHandlerProperty`, `GetHandlerProperty2`, `GetIsArc`,
`GetNumberOfMethods`, `GetMethodProperty`, `CreateDecoder`, `CreateEncoder`, `GetHashers`,
`SetCodecs`, `SetLargePageMode`, `SetCaseSensitive`, `GetModuleProp`.
