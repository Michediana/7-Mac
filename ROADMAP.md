# 7-Mac — Roadmap di sviluppo

GUI nativa macOS per 7-Zip, con il motore 7-Zip **incorporato nell'app** come framework.

- **Stato:** M0 e M1 completi e verificati; M2 da iniziare
- **Ultimo aggiornamento:** 2026-09-21
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

### M2 — App minima utile  ⏱ 1–2 settimane  ← prossimo

- [ ] Drag & drop: estrai in cartella accanto all'archivio
- [ ] Comprimi la selezione in 7z/zip con preset Veloce / Normale / Massima
- [ ] Finestra progresso con byte, ETA, annulla; coda di più operazioni
- [ ] Prompt password + salvataggio opzionale in Keychain; cifratura header 7z
- [ ] Registrazione handler dei tipi file (doppio clic su `.7z`, `.rar`, …)
- [ ] Quick Action / servizio Finder

**Criterio di uscita:** prima build usabile quotidianamente.

### M3 — Browser dell'archivio  ⏱ 2 settimane

Qui l'app smette di essere un wrapper.

- [ ] Vista ad albero delle voci con dimensioni, ratio, metodo, CRC, attributi POSIX
- [ ] Estrazione parziale nativa (array di indici, non wildcard)
- [ ] Anteprima in-place dei file dentro l'archivio
- [ ] **Archivi annidati**: `.tar.gz` navigato come un albero unico (`IInArchiveGetStream`)
- [ ] Ordinamento, ricerca, filtri

### M4 — Modifica in-place  ⏱ 1–2 settimane

Il differenziatore vero: Keka non lo fa.

- [ ] Aggiungi file a un archivio esistente (drag nella finestra)
- [ ] Elimina e rinomina voci
- [ ] Aggiorna solo i file più recenti
- [ ] Annulla/ripristina a livello di operazione

### M5 — Rifinitura  ⏱ a seguire

- [ ] Preset salvabili: formato, livello, dizionario, metodo (LZMA2/PPMd/BZip2), solid block, thread, con **stima memoria**
- [ ] Archivi multi-volume in creazione
- [ ] Pannello hash (SHA-256/512/3, MD5, BLAKE2sp, CRC32/64, xxh64) con confronto checksum
- [ ] Test integrità con report
- [ ] Esclusioni predefinite (`.DS_Store`), gestione symlink e hard link
- [ ] **Estensione Quick Look**: anteprima e thumbnail degli archivi — possibile solo grazie
      alla scelta del framework, un appex non può lanciare sottoprocessi comodamente
- [ ] Localizzazione, accessibilità, dark mode
- [ ] Notarizzazione e distribuzione

---

## 5. Rischi e cose da sistemare

| # | Questione | Impatto | Azione |
|---|---|---|---|
| 1 | `ENABLE_USER_SCRIPT_SANDBOXING = YES` è attivo nel progetto e **blocca le Run Script phase** che leggono o scrivono fuori dai path dichiarati | Build rotta a M0 | ✅ **chiuso.** `SevenZipEngine` è l'unico target con la sandbox disattivata; la copia delle licenze resta sandboxata dichiarando input e output |
| 1b | Xcode valida gli input del linker **in fase di pianificazione**: `-force_load` su un file non ancora prodotto fa fallire il link prima che l'aggregate target giri | Build rotta a M0, e in modo ingannevole — passa se un build precedente ha già lasciato il `.a` sul disco | ✅ **chiuso.** La script phase dichiara `lib7zip.a` come output, così Xcode ne conosce il produttore |
| 2 | `install_name` della dylib nasce come `b/m_arm64/7z.so` | L'app non carica | ✅ **chiuso.** `DYLIB_INSTALL_NAME_BASE = @rpath`; verificato dal test di fumo |
| 3 | App Sandbox attivo: i percorsi vanno da security-scoped bookmark | Accesso file | Mitigato dall'architettura: la libreria apre **stream**, non percorsi passati a un figlio |
| 4 | Un bug su archivio malformato fa crashare l'app, non un sottoprocesso | Stabilità | Se emerge, isolare il motore in un **XPC service**; l'API Swift resta identica |
| 5 | Tempo di build del motore in CI | Attrito | Mitigato: lo script salta tutto tramite uno stamp su hash + archi + deployment target. Da freddo sono ~8 s per arch, ~16 s per l'universale |
| 6 | Il binario prebuilt `7zz` upstream **non è firmato** | — | ✅ **confermato sul campo.** L'app parte con App Sandbox e Hardened Runtime attivi e i soli entitlement `app-sandbox` + `files.user-selected.read-only`: nessun `disable-library-validation` |

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
