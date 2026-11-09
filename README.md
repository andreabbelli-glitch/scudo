# Scudo — adblocker per Safari su iPhone

Scudo è un'app iOS con **quattro estensioni di blocco contenuti per Safari**
(pubblicità, privacy, fastidi, sicurezza) pensata per essere distribuita solo a
te stesso tramite **AltStore PAL**.

- Liste di AdGuard ed EasyList, compresi i filtri **italiani**, scaricate e
  convertite direttamente sull'iPhone, con aggiornamento automatico in background.
- Scelta delle liste, **siti consentiti** e **regole personali** (sintassi AdBlock/AdGuard).
- Nessun dato raccolto: è Safari ad applicare le regole, l'app non vede la navigazione.

```
           scarica (ETag/304)                      converte (AdGuard SafariConverterLib)
App Scudo ───────────────────▶ filters.adtidy.org      │
    │                                                  ▼
    └──scrive──▶ App Group: Scudo/Blockers/{ads,privacy,annoyances,security}.json
                                    ▲ legge
4 estensioni Content Blocker ───────┘──▶ Safari compila e applica le regole
```

## Contenuto del progetto

| Percorso | Cosa contiene |
| --- | --- |
| `App/` | App SwiftUI (stato, liste, siti consentiti, regole personali, guida) |
| `Extensions/ContentBlocker/` | Codice e Info.plist condivisi dalle 4 estensioni |
| `Packages/ScudoKit/` | Motore: catalogo liste, download, conversione, test |
| `Tools/RuleCheck/` | Verifica sul Mac: liste reali → conversione → compilatore WebKit → test in WKWebView |
| `Tools/altstore/` | Script per registrarsi ad AltStore PAL e pubblicare gli ADP |
| `docs/` | Sito statico da pubblicare: `source.json`, informativa privacy, pagina di supporto |
| `Config/Scudo.xcconfig` | **L'unico file da personalizzare**: Team ID, prefisso bundle, versione |
| `project.yml` | Definizione del progetto per XcodeGen (`make project` rigenera `Scudo.xcodeproj`) |

## Requisiti

- **Mac con Xcode 26.2 o successivo** (Mac App Store). Su questo Mac al momento
  ci sono solo i Command Line Tools: installa Xcode e aprilo una volta.
- **Apple Developer Program a pagamento**: AltStore PAL accetta solo app
  notarizzate da Apple tramite App Store Connect (l'account gratuito non basta).
- **AltStore PAL** sull'iPhone (UE).
- Un **hosting HTTPS statico** per la source: GitHub Pages, già configurato (vedi 3.1).

## 1. Prima configurazione

1. In `Config/Scudo.xcconfig` imposta `DEVELOPMENT_TEAM` con il tuo Team ID
   (developer.apple.com › Account › Membership). Il prefisso `BUNDLE_ID_PREFIX`
   (`com.abelli`) va bene così; se lo cambi, aggiorna anche `bundleIdentifier`
   e `featuredApps` in `docs/source.json`.
2. Apri `Scudo.xcodeproj`. Alla prima compilazione Xcode chiede di abilitare il
   plugin **GenerateVersion** della libreria AdGuard: scegli *Trust & Enable*.
3. Firma automatica: compilando, Xcode registra gli App ID dell'app e delle 4
   estensioni e l'App Group `group.com.abelli.scudo`. In *Signing & Capabilities*
   controlla che **App Groups** sia spuntato su tutti e 5 i target.

## 2. Prova sull'iPhone (consigliato)

1. Collega l'iPhone, attiva *Impostazioni › Privacy e sicurezza › Modalità sviluppatore*,
   selezionalo in Xcode e premi Run.
2. Apri Scudo: al primo avvio scarica e converte le liste (circa mezzo minuto).
3. *Impostazioni › App › Safari › Estensioni*: attiva **Scudo Pubblicità**,
   **Scudo Privacy**, **Scudo Fastidi**, **Scudo Sicurezza**. Su iOS 26.2+ il
   pulsante nell'app apre direttamente quella schermata.

Questa installazione dura un anno. AltStore PAL serve per averla permanente e
aggiornabile senza Mac.

## 3. Pubblicazione su AltStore PAL

### 3.1 Sito della source (GitHub Pages)

Già pronto: il repository è [andreabbelli-glitch/scudo](https://github.com/andreabbelli-glitch/scudo)
e GitHub Pages pubblica la cartella `docs/` del branch `main` (ogni push
aggiorna il sito in un paio di minuti). Gli indirizzi:

- source per AltStore PAL: `https://andreabbelli-glitch.github.io/scudo/source.json`
- supporto (per App Store Connect): `https://andreabbelli-glitch.github.io/scudo/`
- privacy (per App Store Connect): `https://andreabbelli-glitch.github.io/scudo/privacy.html`

In `docs/source.json` resta da sostituire `IL TUO NOME` in `developerName` con
il nome da mostrare in AltStore (`marketplaceID` si compila al punto 3.2).

### 3.2 App Store Connect

1. *App › + › Nuova app*: piattaforma iOS, nome **unico** su tutto l'App Store
   (es. «Scudo Adblock» seguito dalle tue iniziali: il nome sull'iPhone resta
   «Scudo»), lingua italiano, bundle ID `com.abelli.scudo`, SKU `scudo`.
2. Copia l'**ID Apple** dell'app (*Informazioni sull'app*) in `marketplaceID` di
   `docs/source.json`.
3. Compila i campi obbligatori anche per la sola notarizzazione: categoria
   (Utility), questionario sull'età, descrizione, URL di supporto e privacy,
   screenshot, informazioni per la revisione. In *Privacy dell'app* dichiara
   «Dati non raccolti».
4. **Screenshot**: fai 3-4 screenshot sull'iPhone 15, mettili in `Screenshots/`
   e lancia `make screenshots`: ottieni JPEG 1290×2796 accettati per lo schermo da 6,9".
5. In *Business* accetta gli accordi più recenti. L'API di AltStore indica che
   per elaborare l'ADP serve anche il **Paid Apps Agreement** firmato (richiede
   dati fiscali e bancari, anche per un'app gratuita). Se richiesto, dichiara lo
   stato di non operatore commerciale (DSA).

### 3.3 Collega AltStore PAL

1. Developer ID: in App Store Connect, il tuo nome in alto a destra › *Modifica profilo*.
2. `Tools/altstore/register.sh <DEVELOPER_ID> <TUA_EMAIL>` stampa un token.
3. *Utenti e accesso › Integrazioni › Marketplace › +*: incolla il token,
   seleziona Scudo, scegli *Yes, send notifications*.

### 3.4 Build e notarizzazione

1. Xcode: destinazione *Any iOS Device*, *Product › Archive › Distribute App ›
   App Store Connect › Upload*.
2. Nella pagina della versione: seleziona la build, poi *Informazioni per la
   revisione dell'app › Tipo di revisione › Modifica › Notarizzazione*.
3. *Aggiungi per la revisione › Invia*. La notarizzazione segue un sottoinsieme
   delle linee guida dell'App Store.

### 3.5 Pubblica l'ADP

1. Ad approvazione avvenuta: *App › Distribuzione › Cronologia* e copia
   l'**Alternative Distribution Package ID**.
2. `Tools/altstore/publish-adp.sh <ADP_ID> "Prima versione"`: scarica il
   pacchetto da AltStore, lo copia intatto in `docs/adp/<versione>-<build>/`,
   aggiorna `docs/source.json` (versione, dimensione, entitlement letti dall'app
   firmata da Apple).
3. `git add docs && git commit -m "Scudo 1.0 (1)" && git push`

### 3.6 Installa

AltStore PAL › *Sorgenti* › + › `https://andreabbelli-glitch.github.io/scudo/source.json`,
installa Scudo, aprilo una volta e attiva le estensioni in Safari.

## 4. Aggiornamenti

Le **liste** si aggiornano da sole: non serve pubblicare nulla. Per una nuova
versione dell'**app**: aumenta `CURRENT_PROJECT_VERSION` (e se vuoi
`MARKETING_VERSION`) in `Config/Scudo.xcconfig`, poi ripeti 3.4 e 3.5. AltStore
mostrerà l'aggiornamento.

## 5. Verifiche senza iPhone

| Comando | Cosa verifica |
| --- | --- |
| `make test` | 29 test del motore: download condizionali, conversione, siti consentiti, regole personali, errori, ricarica |
| `make rulecheck` | Scarica le liste reali, le converte come l'app e le compila con WebKit (lo stesso motore di Safari) |
| `make e2e` | Carica una pagina di prova in una WKWebView con le 4 estensioni: blocco di rete, elementi nascosti, regola personale, sito consentito |

## 6. Dettagli tecnici

- **Quattro estensioni** perché Safari compila e limita ogni content blocker da
  solo: massimo 150.000 regole e, da iOS 17, un JSON che l'estensione riesca a
  caricare nella sua memoria (~19 MB da iOS 17.2, ~10 MB prima: gli stessi limiti
  usati da AdGuard per iOS). Le liste attive di default stanno sotto i limiti
  (misure di novembre 2026: Pubblicità 49k regole / 7,7 MB, Privacy 113k / 12 MB,
  Fastidi 14k / 2,5 MB, Sicurezza 71k / 9 MB).
- Oltre i limiti il convertitore scarta le **ultime** regole, che sono proprio le
  eccezioni: per questo EasyPrivacy e Online Malicious URL Blocklist sono
  disattivate di default, e l'app segnala le regole scartate.
- I **siti consentiti** sono convertiti a parte e aggiunti in coda a ogni
  estensione: sopravvivono sempre e modificarli non richiede di riconvertire le
  liste. Se una categoria è già al limite di 150.000 regole, per far posto si
  scartano regole dall'inizio (nascondimento generico), mai le eccezioni.
- Le **regole personali** di blocco vanno nell'estensione Sicurezza; le
  eccezioni (`@@`, `#@#`) in tutte e quattro.
- Ogni estensione viene riconvertita e ricaricata solo se cambiano i suoi input
  (impronta SHA-256 di liste, regole e versioni).
- Aggiornamento in background con `BGAppRefreshTask` (iOS sceglie quando,
  al più ogni 12 ore) e all'apertura dell'app se sono passate più di 12 ore.

## 7. Limiti

- I content blocker non eseguono script: alcune pubblicità integrate nella pagina
  (es. i video di YouTube) possono passare.
- Il blocco vale in Safari e nelle app che usano le viste web di Safari
  (`SFSafariViewController`), non dentro le altre app.

## 8. Problemi comuni

| Sintomo | Soluzione |
| --- | --- |
| «GenerateVersion plugin must be enabled» | In Xcode: *Trust & Enable* (una volta sola) |
| Errore sull'App Group | *Signing & Capabilities*: App Groups spuntato su app ed estensioni con lo stesso gruppo |
| `SFErrorDomain 3` in un'estensione | Troppe regole in quella categoria: disattiva qualche lista |
| AltStore: «Undeclared Permissions» | Aggiungi l'entitlement indicato a `appPermissions.entitlements` in `docs/source.json` |
| `publish-adp.sh`: stato `failure` | Controlla gli accordi in *Business* (Paid Apps Agreement) e rilancia |

## Licenze

La conversione usa [AdGuard SafariConverterLib](https://github.com/AdguardTeam/SafariConverterLib)
(GPL-3.0): se distribuisci l'app ad altri, anche questo codice va reso disponibile
con licenza compatibile. Le liste di filtri appartengono ai rispettivi autori
(AdGuard, EasyList e altri) con le loro licenze.
