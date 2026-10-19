import Foundation
import QuotaCore

enum Copy {
    static let projectURL = URL(string: "https://github.com/mindtheflo/juice-bar")!
    static var language: String { UserDefaults.standard.string(forKey: "language") ?? "auto" }
    static var isFrench: Bool {
        language == "fr" || (language == "auto" && (Locale.preferredLanguages.first ?? "en").hasPrefix("fr"))
    }
    static var locale: Locale { Locale(identifier: isFrench ? "fr_FR" : "en_US") }
    static func text(_ key: String) -> String { (isFrench ? fr[key] : en[key]) ?? en[key] ?? key }
    static func text(_ key: String, _ value: String) -> String { text(key).replacingOccurrences(of: "%@", with: value) }
    /// A branch Juice Bar can update from, by its name in Settings.
    static func branch(_ name: String) -> String { text(name + "Branch") }
    /// A pace, as it follows an amount left: “62% left, on track”.
    static func pace(_ pace: Pace) -> String { text("pace" + pace.rawValue.capitalized) }
    static func menuBarForecast(snapshot: QuotaSnapshot?, forecasts: [Provider: PaceForecast], now: Date) -> String {
        let accounts = snapshot?.accounts.filter { !$0.disabled } ?? []
        guard !accounts.isEmpty else { return text("tooltipLearning") }
        let providers = Set(accounts.map(\.provider))
        if let exhausted = providers.sorted(by: { $0.rawValue < $1.rawValue }).first(where: { provider in
            accounts.filter { $0.provider == provider }.allSatisfy { $0.freshLeft(at: now) == 0 }
        }) { return String(format: text("tooltipExhausted"), exhausted.title) }
        // Describe the earliest predicted deficit, using the next renewal AFTER it.
        // Earlier renewals have already been included in the modeled supply.
        var gaps: [(provider: Provider, kind: String, date: Date)] = []
        for (provider, forecast) in forecasts {
            for (kind, date) in forecast.predictionDeficits { gaps.append((provider, kind, date)) }
        }
        gaps.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.provider.rawValue + a.kind < b.provider.rawValue + b.kind
        }
        if let gap = gaps.first {
            let kind = text(gap.kind == "seven_day" ? "tooltipWeekly" : "tooltipSession")
            let prefix = String(format: text("tooltipGap"), kind, gap.provider.title)
            let renewal = accounts.filter { $0.provider == gap.provider }.flatMap(\.windows)
                .filter { !$0.modelScoped && $0.id == gap.kind }
                .compactMap(\.resetsAt).filter { $0 > gap.date }.min()
            let f = DateFormatter(); f.locale = locale; f.dateFormat = "EEEE"
            guard let renewal else { return prefix + String(format: text("tooltipFrom"), f.string(from: gap.date)) }
            let calendar = Calendar.current
            if calendar.isDate(gap.date, inSameDayAs: renewal) {
                return prefix + String(format: text("tooltipOn"), f.string(from: gap.date))
            }
            if calendar.component(.weekday, from: gap.date) == calendar.component(.weekday, from: renewal) {
                f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
            }
            return prefix + String(format: text("tooltipBetween"), f.string(from: gap.date), f.string(from: renewal))
        }
        guard providers.allSatisfy({ forecasts[$0]?.displayPrediction != nil }) else { return text("tooltipLearning") }
        return text("tooltipOnTrack")
    }
    static func forecast(_ forecast: PaceForecast?, now: Date) -> String {
        guard let forecast, let prediction = forecast.displayPrediction else { return text("forecastUnknown") }
        let agreement = prediction.agreement < 0.6 ? "forecastTentative" : prediction.agreement < 1 ? "forecastModerate" : "forecastStrong"
        var lines = [pace(prediction.pace) + " (" + text(agreement) + ")"]
        for (kind, date) in forecast.predictionDeficits.sorted(by: { $0.value < $1.value }) {
            lines.append(text(kind) + ": " + text("forecastShortageAt", moment(date, now: now)))
        }
        if let points = forecast.projectedDemand["seven_day"] {
            let amount = String(format: "%.1f", locale: locale, points / 100)
            lines.append(text("forecastWeeklyUse", amount) + " · " + text("forecastThrough", moment(forecast.horizon, now: now)))
        }
        return lines.joined(separator: "\n")
    }
    static let en = [
        "tooltipGap": "Potential %@-quota gap on %@", "tooltipWeekly": "weekly", "tooltipSession": "session",
        "tooltipBetween": " between %@ and %@.", "tooltipOn": " on %@.", "tooltipFrom": " from %@.",
        "tooltipExhausted": "%@ quota is currently exhausted.", "tooltipLearning": "Quota forecast is not available yet.",
        "tooltipOnTrack": "No quota gap predicted at the current pace.", "tooltipOffline": "Quota forecast is unavailable while the proxy is offline.",
        "moreInfo": "More information", "project": "Project on GitHub ↗",
        "forecastHelp": "Colours forecast enabled accounts together, using the last 24 comparable hours, recent bursts and both session and weekly renewals. Weekdays and weekends are modelled separately. Muted colours mean less scenario agreement; grey means no supported estimate. A new forecast needs at least six observed hours; learning continues in the background.",
        "accountDetails": "Account details",
        "on": "On", "in": "In",
        "timeHint": "Click to switch between time remaining and the exact renewal date and time.",
        "percentageHint": "Hover to see the percentage remaining. Click an account to open its details.",
        "iconSettings": "Menu bar icon", "iconPreview": "Icon preview",
        "iconShows": "Bars show",
        "iconProviders": "OpenAI + Claude", "iconWindows": "Session + weekly", "provider": "Provider",
        "openai": "OpenAI", "claude": "Claude",
        "providersHint": "OpenAI is on top, Claude underneath. Each bar shows the pooled weekly capacity of that provider’s enabled accounts, out of 100%. For five licences, 86 points left out of 500 fills 17.2% of the bar. Colours still forecast both session and weekly limits.",
        "notReportedOne": "1 account not reported", "notReportedMany": "%@ accounts not reported",
        "windowsHint": "Session is on the left, weekly on the right. Each bar is the session or weekly allowance of every enabled account together, out of 100%, each account counting the same. An account without a reading counts as empty, so the bar shows at least what’s left (≥).",
        "paceLegend": "Global forecast: green on track, orange a shortage before renewal, blue ample headroom. Muted colours mean a tentative prediction; vivid colours mean stronger scenario agreement. Grey means no supported estimate. Red means quota is already exhausted. Individual accounts show measured levels only.",
        "forecastUnknown": "Forecast uncertain",
        "forecastHistory": "Learning recent demand",
        "forecastReadings": "Forecast needs fresh quota readings",
        "forecastCapacity": "Forecast needs comparable plan capacities",
        "forecastActivity": "Not enough measured activity",
        "forecastUncertainty": "Forecast uncertain",
        "forecastHint": "Colour shows the central forecast. Muted colours mean less agreement across demand scenarios; stronger colours mean more agreement. This is not a probability of accuracy. Grey means no supported estimate yet.",
        "forecastTentative": "tentative forecast", "forecastModerate": "mixed scenario agreement", "forecastStrong": "strong scenario agreement",
        "forecastShortageAt": "possible shortage %@", "forecastWeeklyUse": "Projected use: %@ weekly plan allowances",
        "forecastThrough": "through %@",
        "paceOver": "global quota shortage predicted", "paceSteady": "on track", "paceUnder": "ample global headroom",
        "accountEnabled": "Use this account", "accountToggleHint": "Allow this account to handle new requests.",
        "accountUpdateFailed": "The change could not be confirmed. Refresh to check the current state.",
        "accountUpdating": "Updating…",
        "session": "Session", "weekly": "Weekly",
        "sessionIdle": "5h after first use", "renewalUnknown": "Renewal not reported",
        "sessionIdleHint": "Your five-hour allowance is full and Claude reports no active renewal time. The five-hour window starts when you next use this account.",
        "launchAtLogin": "Launch at login", "loginApproval": "Allow in System Settings…",
        "loginError": "Could not update login settings. Check System Settings → Login Items.",
        "proxyStatus": "Proxy", "connected": "Connected", "notConnected": "Not connected",
        "serviceStopped": "Stopped", "start": "Start", "stop": "Stop",
        "stopNote": "Stopping disconnects agents using this proxy.",
        "serviceUnavailable": "Start/Stop is unavailable for this installation.",
        "serviceError": "Could not change the proxy service. Check its installation.",
        "test": "Test connection", "testing": "Testing…", "testPassed": "Connected — accounts readable",
        "testFailed": "Connection failed. Check the URL and key file.",
        "title": "Subscriptions", "back": "Back",
        "loading": "Reading your subscriptions…", "empty": "No Claude or Codex accounts connected",
        "limit": "Limit reached", "noReading": "No reading", "lastKnown": "Last known",
        "left": "% left", "disabled": "Disabled", "renews": "Renews", "renewsIn": "Renews in %@",
        "cooldown": "Proxy cooldown until", "awaiting": "Awaiting a fresh reading",
        "refresh": "Refresh", "refreshing": "Refreshing…", "updated": "Updated",
        "dashboard": "Open CPAMC", "settings": "Settings…", "quit": "Quit Juice Bar",
        "five_hour": "Five-hour allowance", "seven_day": "Weekly allowance",
        "seven_day_opus": "Opus weekly allowance", "seven_day_sonnet": "Sonnet weekly allowance",
        "seven_day_oauth_apps": "OAuth apps weekly", "seven_day_cowork": "Cowork weekly",
        "primary": "Primary allowance", "secondary": "Secondary allowance",
        "extraOn": "Extra usage enabled", "extraOff": "Extra usage disabled",
        "credits": "Paid credits", "unlimited": "Unlimited", "resetGrant": "Unused promotional resets",
        "readOnly": "Read-only · No reset or billing actions", "connection": "Connection",
        "proxyURL": "Local proxy URL", "keyFile": "Management-key file", "choose": "Choose…",
        "save": "Save connection", "privacy": "Hide account names", "language": "Language",
        "auto": "System", "interval": "Provider reads every 5 minutes; local status every 30 seconds",
        "keyNote": "The key stays in its existing file. It is never copied into this app or sent outside your Mac.",
        "connecting": "Connecting…", "offline": "Proxy unavailable", "demo": "Demo · No accounts accessed",
        "lastChecked": "Provider checked", "unknownError": "Check the local connection in Settings.",
        "hideDisabled": "Hide disabled", "showDisabled": "Show disabled", "settingsTitle": "Settings", "general": "General",
        "updates": "Updates", "autoUpdate": "Update automatically", "checkNow": "Check now", "checking": "Checking…",
        "updateBranch": "Branch", "stableBranch": "Stable", "nightlyBranch": "Nightly",
        "upToDate": "Up to date", "updateAvailable": "Update available", "installUpdate": "Install",
        "installing": "Installing update…", "updateReady": "Ready, restarts when the menu closes", "restartNow": "Restart now",
        "devBuild": "Waiting for %@ to include this version",
        "modifiedBuild": "Built with local changes, not updated automatically",
        "unknownBuild": "Built without version information", "unsupportedLocation": "Updates need Juice Bar in an Applications folder",
        "noTools": "Install the Xcode Command Line Tools to update", "noBranch": "Nothing published on %@ yet",
        "downloadFailed": "Couldn’t reach GitHub. Trying again later.",
        "buildFailed": "The update couldn’t be built. Juice Bar keeps this version.",
        "installFailed": "The update couldn’t be installed.", "updateBusy": "Another update is in progress.",
        "updatesFooter": "Once a day, Juice Bar checks its branch on GitHub, then builds and installs new versions on this Mac. Stable gets releases; Nightly gets every change as soon as it’s merged.",
        "version": "Version", "lastCheckedAt": "Checked", "updateMenu": "Install update", "restartMenu": "Restart to update",
    ]
    static let fr = [
        "tooltipGap": "Manque potentiel de quota %@ sur %@", "tooltipWeekly": "hebdomadaire", "tooltipSession": "de session",
        "tooltipBetween": " entre %@ et %@.", "tooltipOn": " %@.", "tooltipFrom": " à partir de %@.",
        "tooltipExhausted": "Le quota %@ est actuellement épuisé.", "tooltipLearning": "La prévision de quota n’est pas encore disponible.",
        "tooltipOnTrack": "Aucun manque de quota prévu au rythme actuel.", "tooltipOffline": "La prévision de quota est indisponible quand le proxy est hors ligne.",
        "moreInfo": "Plus d’informations", "project": "Projet sur GitHub ↗",
        "forecastHelp": "Les couleurs prévoient tous les comptes activés, avec les dernières 24 heures comparables, les accélérations et les renouvellements de session et de semaine. Jours ouvrés et week-ends sont modélisés séparément. Couleur pâle : accord limité entre scénarios. Gris : pas d’estimation étayée. Il faut au moins six heures observées au départ ; l’apprentissage continue en arrière-plan.",
        "accountDetails": "Détails du compte",
        "on": "Le", "in": "Dans",
        "timeHint": "Clique pour alterner entre le temps restant et la date et l’heure exactes du renouvellement.",
        "percentageHint": "Survole pour voir le pourcentage restant. Clique sur un compte pour ouvrir ses détails.",
        "iconSettings": "Icône de la barre des menus", "iconPreview": "Aperçu de l’icône",
        "iconShows": "Les barres indiquent",
        "iconProviders": "OpenAI + Claude", "iconWindows": "Session + semaine", "provider": "Fournisseur",
        "openai": "OpenAI", "claude": "Claude",
        "providersHint": "OpenAI en haut, Claude en dessous. Chaque barre indique la capacité hebdomadaire cumulée des comptes activés d’un fournisseur, sur 100 %. Avec cinq licences, 86 points sur 500 remplissent 17,2 % de la barre. Les couleurs prévoient toujours les limites de session et de semaine.",
        "notReportedOne": "1 compte non communiqué", "notReportedMany": "%@ comptes non communiqués",
        "windowsHint": "Session à gauche, semaine à droite. Chaque barre réunit la session ou la semaine de tous les comptes activés, sur 100 %, chaque compte pesant autant. Un compte sans valeur compte pour vide : la barre indique alors au moins ce qui reste (≥).",
        "paceLegend": "Prévision globale : vert dans le rythme, orange manque de quota avant renouvellement, bleu marge importante. Couleurs pâles : prévision provisoire ; couleurs vives : accord plus fort entre scénarios. Gris : pas d’estimation étayée. Rouge : quota déjà épuisé. Les comptes individuels affichent uniquement les niveaux mesurés.",
        "forecastUnknown": "Prévision incertaine",
        "forecastHistory": "Apprentissage de l’activité récente",
        "forecastReadings": "Des quotas récents sont nécessaires",
        "forecastCapacity": "Des capacités comparables sont nécessaires",
        "forecastActivity": "Pas assez d’activité mesurée",
        "forecastUncertainty": "Prévision incertaine",
        "forecastHint": "La couleur indique la prévision centrale. Une couleur pâle signifie moins d’accord entre les scénarios ; une couleur vive, davantage d’accord. Ce n’est pas une probabilité d’exactitude. Gris : pas encore d’estimation étayée.",
        "forecastTentative": "prévision provisoire", "forecastModerate": "accord partiel des scénarios", "forecastStrong": "accord fort des scénarios",
        "forecastShortageAt": "manque possible le %@", "forecastWeeklyUse": "Consommation prévue : %@ quotas hebdomadaires",
        "forecastThrough": "jusqu’au %@",
        "paceOver": "manque de quota global prévu", "paceSteady": "dans le rythme", "paceUnder": "marge globale importante",
        "accountEnabled": "Utiliser ce compte", "accountToggleHint": "Autoriser de nouvelles requêtes sur ce compte.",
        "accountUpdateFailed": "La modification n’a pas pu être confirmée. Actualise pour vérifier l’état actuel.",
        "accountUpdating": "Mise à jour…",
        "session": "Session", "weekly": "Semaine",
        "sessionIdle": "5h après utilisation", "renewalUnknown": "Renouvellement inconnu",
        "sessionIdleHint": "Ton quota de cinq heures est plein et Claude n’indique aucun renouvellement actif. La fenêtre de cinq heures commence à la prochaine utilisation de ce compte.",
        "launchAtLogin": "Lancer à l’ouverture de session", "loginApproval": "Autoriser dans les Réglages Système…",
        "loginError": "Impossible de modifier le démarrage. Vérifie Réglages Système → Ouverture.",
        "proxyStatus": "Proxy", "connected": "Connecté", "notConnected": "Non connecté",
        "serviceStopped": "Arrêté", "start": "Démarrer", "stop": "Arrêter",
        "stopNote": "L’arrêt déconnecte les agents qui utilisent ce proxy.",
        "serviceUnavailable": "Démarrer/Arrêter est indisponible pour cette installation.",
        "serviceError": "Impossible de modifier le service du proxy. Vérifie son installation.",
        "test": "Tester la connexion", "testing": "Test en cours…", "testPassed": "Connecté — comptes accessibles",
        "testFailed": "Connexion impossible. Vérifie l’adresse et le fichier de clé.",
        "title": "Abonnements", "back": "Retour",
        "loading": "Lecture de tes abonnements…", "empty": "Aucun compte Claude ou Codex connecté",
        "limit": "Limite atteinte", "noReading": "Aucune lecture", "lastKnown": "Dernière valeur",
        "left": "% restants", "disabled": "Désactivé", "renews": "Renouvellement", "renewsIn": "Renouvellement dans %@",
        "cooldown": "Pause du proxy jusqu’au", "awaiting": "En attente d’une nouvelle lecture",
        "refresh": "Actualiser", "refreshing": "Actualisation…", "updated": "Actualisé à",
        "dashboard": "Ouvrir CPAMC", "settings": "Réglages…", "quit": "Quitter Juice Bar",
        "five_hour": "Quota sur cinq heures", "seven_day": "Quota hebdomadaire",
        "seven_day_opus": "Quota Opus hebdomadaire", "seven_day_sonnet": "Quota Sonnet hebdomadaire",
        "seven_day_oauth_apps": "Quota OAuth hebdomadaire", "seven_day_cowork": "Quota Cowork hebdomadaire",
        "primary": "Quota principal", "secondary": "Quota secondaire",
        "extraOn": "Usage supplémentaire activé", "extraOff": "Usage supplémentaire désactivé",
        "credits": "Crédits payants", "unlimited": "Illimités", "resetGrant": "Réinitialisations promotionnelles restantes",
        "readOnly": "Lecture seule · Aucun changement de quota ou de facturation", "connection": "Connexion",
        "proxyURL": "Adresse du proxy local", "keyFile": "Fichier de clé de gestion", "choose": "Choisir…",
        "save": "Enregistrer la connexion", "privacy": "Masquer les noms des comptes", "language": "Langue",
        "auto": "Système", "interval": "Quotas toutes les 5 minutes ; état local toutes les 30 secondes",
        "keyNote": "La clé reste dans son fichier actuel. Elle n’est ni copiée dans cette app ni envoyée hors de ton Mac.",
        "connecting": "Connexion…", "offline": "Proxy indisponible", "demo": "Démo · Aucun accès aux comptes",
        "lastChecked": "Quota vérifié à", "unknownError": "Vérifie la connexion locale dans les réglages.",
        "hideDisabled": "Masquer les désactivés", "showDisabled": "Afficher les désactivés", "settingsTitle": "Réglages", "general": "Général",
        "updates": "Mises à jour", "autoUpdate": "Mettre à jour automatiquement", "checkNow": "Vérifier", "checking": "Vérification…",
        "updateBranch": "Branche", "stableBranch": "Stable", "nightlyBranch": "Nightly",
        "upToDate": "À jour", "updateAvailable": "Mise à jour disponible", "installUpdate": "Installer",
        "installing": "Installation…", "updateReady": "Prête, redémarre à la fermeture du menu", "restartNow": "Redémarrer",
        "devBuild": "En attente de cette version sur %@",
        "modifiedBuild": "Compilée avec des modifications locales, pas de mise à jour automatique",
        "unknownBuild": "Compilée sans information de version", "unsupportedLocation": "Les mises à jour nécessitent Juice Bar dans un dossier Applications",
        "noTools": "Installe les Command Line Tools de Xcode pour mettre à jour", "noBranch": "Rien de publié sur %@ pour l’instant",
        "downloadFailed": "GitHub est injoignable. Nouvel essai plus tard.",
        "buildFailed": "La mise à jour n’a pas pu être compilée. Juice Bar garde cette version.",
        "installFailed": "La mise à jour n’a pas pu être installée.", "updateBusy": "Une autre mise à jour est en cours.",
        "updatesFooter": "Une fois par jour, Juice Bar vérifie sa branche sur GitHub, puis compile et installe les nouvelles versions sur ce Mac. Stable reçoit les versions publiées ; Nightly, chaque changement dès qu’il est intégré.",
        "version": "Version", "lastCheckedAt": "Vérifié à", "updateMenu": "Installer la mise à jour", "restartMenu": "Redémarrer pour mettre à jour",
    ]
    static func percent(_ left: Double?) -> String {
        guard let left else { return text("noReading") }
        return left <= 0 ? text("limit") : "\(Int(left.rounded()))\(text("left"))"
    }
    static func duration(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let m = Int(ceil(date.timeIntervalSince(now) / 60))
        if m >= 1440 { return "\(m / 1440)\(isFrench ? "j" : "d") \((m % 1440) / 60)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m)m"
    }
    /// An absolute renewal always includes its day, date and time, even when it is today.
    static func moment(_ date: Date, now: Date) -> String {
        let f = DateFormatter(); f.locale = locale
        f.setLocalizedDateFormatFromTemplate("EEEMMMdjmm")
        return f.string(from: date)
    }
    static func timestamp(_ date: Date, now: Date, includeDate: Bool = false) -> String {
        let f = DateFormatter(); f.locale = locale
        f.dateStyle = includeDate || !Calendar.current.isDate(date, inSameDayAs: now) ? .medium : .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}
