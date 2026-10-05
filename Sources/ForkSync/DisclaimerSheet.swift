import SwiftUI

/// Haftungsausschluss: beim ersten Start zu bestätigen, danach über das Info-Symbol in der Toolbar abrufbar.
struct DisclaimerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("forksync.disclaimerAccepted") private var accepted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(tr("Hinweis und Haftungsausschluss", "Notice and disclaimer"), systemImage: "exclamationmark.shield.fill")
                .font(.title3.bold())
            Text(tr("ForkSync verändert Repositories in deinem GitHub-Account: Es schreibt Workflow-Dateien, mergt Änderungen, erstellt Pull Requests und kann die Sichtbarkeit von Repos ändern.",
                    "ForkSync modifies repositories in your GitHub account: it writes workflow files, merges changes, opens pull requests and can change repo visibility."))
            VStack(alignment: .leading, spacing: 8) {
                bullet(tr("Die Nutzung erfolgt auf eigene Verantwortung.", "Use is at your own risk."))
                bullet(tr("Die Software wird in der vorliegenden Form und ohne Mängelgewähr bereitgestellt.", "The software is provided “as is”, without warranty of any kind."))
                bullet(tr("Der Autor übernimmt, soweit gesetzlich zulässig, keine Haftung für Schäden, Datenverlust, veränderte oder gelöschte Commits, Branches und Workflows, fehlgeschlagene Synchronisierungen oder versehentlich veröffentlichte Daten.",
                          "To the extent permitted by law, the author accepts no liability for damage, data loss, modified or deleted commits, branches and workflows, failed syncs or accidentally exposed data."))
                bullet(tr("Prüfe Änderungen vor dem Ausführen und sichere wichtige Repositories.", "Review changes before running them and back up important repositories."))
            }
            HStack {
                Spacer()
                Button(accepted ? tr("Schließen", "Close") : tr("Verstanden und akzeptiert", "Understood and accepted")) {
                    accepted = true
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
        .interactiveDismissDisabled(!accepted)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 6).foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
