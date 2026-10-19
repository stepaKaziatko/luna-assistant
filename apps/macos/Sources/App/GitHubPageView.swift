import SwiftUI

// MARK: - GitHub page
//
// The page that the GitHub integration brings to the island while it is connected (the pill is
// on in Settings → Active pills and the token is saved; see `IntegrationPages`). Three columns
// over the full width: my pull requests, those waiting for my review, the CI of the default
// branches. The data is what `GithubPoller` already fetches (`AppState.githubPulse`): the page
// makes no requests of its own, has no timer and no endless animation. It only asks the poller
// for a fresh pulse when it comes on screen, and the poller skips that if the data is fresh.
//
// All island pages are mounted at once, so nothing happens in `onAppear`: the page reacts to
// `state.view` becoming `.github`.

struct GitHubPageView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GitHubPageHeader(pulse: state.githubPulse, stats: state.githubStats)
                .padding(.horizontal, 4)
            if let pulse = state.githubPulse {
                HStack(alignment: .top, spacing: 8) {
                    GitHubColumn(title: String(localized: "My PRs"), count: pulse.myPRs.count) {
                        ForEach(pulse.myPRs, id: \.id) { GitHubPageRow(pr: $0, showCI: true) }
                    }
                    GitHubColumn(title: String(localized: "To review"), count: pulse.toReview.count) {
                        ForEach(pulse.toReview, id: \.id) { GitHubPageRow(pr: $0, showCI: false) }
                    }
                    GitHubColumn(title: String(localized: "github.page.main-ci", defaultValue: "Default branch CI"),
                                 count: pulse.mainCI.count) {
                        ForEach(pulse.mainCI, id: \.repo) { GitHubPageRepoRow(repo: $0) }
                    }
                }
            } else {
                Text(String(localized: "Loading…"))
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.top, 2)
        .padding(.horizontal, 2)
        // The poller keeps the data fresh on its own; here only a page opened after a long
        // time gets the news without waiting for the next turn of its timer.
        .onChange(of: state.view) { _, v in
            if v == .github { GithubPoller.shared.refreshIfStale() }
        }
        .onChange(of: state.mode) { _, m in
            if m == .expanded && state.view == .github { GithubPoller.shared.refreshIfStale() }
        }
    }
}

// MARK: - Header

private struct GitHubPageHeader: View {
    let pulse: GitHubPulse?
    let stats: GitHubStats?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: "#F4505E"))
                .frame(width: 7, height: 7)
            Text("GitHub")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#F5F6F8"))
            if let login = pulse?.login, !login.isEmpty {
                Text(login)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            if let stats {
                Text("★ \(stats.totalStars)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let at = pulse?.fetchedAt {
                Text(String(format: String(localized: "github.page.updated", defaultValue: "Updated %@"),
                            at.formatted(date: .omitted, time: .shortened)))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1)
            }
        }
        .frame(height: 20)
    }
}

// MARK: - Column

private struct GitHubColumn<Rows: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD"))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundColor(Color(hex: count > 0 ? "#8E939C" : "#4B4F57"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            if count == 0 {
                Text(String(localized: "Nothing here"))
                    .font(.system(size: 10.5))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 1) { rows() }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(hex: "#141518"))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.035), lineWidth: 1))
        )
    }
}

// MARK: - Rows

/// Opens a page of github.com in the browser; anything else is ignored.
private func openGitHubLink(_ string: String) {
    if let url = safeWebURL(string), url.host == "github.com" { NSWorkspace.shared.open(url) }
}

private struct GitHubPageRow: View {
    let pr: GitHubPR
    let showCI: Bool
    @State private var hovered = false

    private var shortRepo: String { pr.repo.components(separatedBy: "/").last ?? pr.repo }

    var body: some View {
        Button(action: { openGitHubLink(pr.url) }) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(ghCIDot(pr.ci))
                    .frame(width: 6, height: 6)
                    .opacity(showCI && pr.ci != .unknown ? 1 : 0)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text("\(shortRepo)#\(pr.number)")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if pr.isDraft {
                            Text(String(localized: "Draft"))
                                .font(.system(size: 9.5))
                                .foregroundColor(Color(hex: "#6B7079"))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 2)
                if showCI, let review = reviewMark {
                    Image(systemName: review.symbol)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: review.hex))
                        .help(review.text)
                        .accessibilityLabel(review.text)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var reviewMark: (symbol: String, hex: String, text: String)? {
        switch pr.review {
        case .approved:
            return ("checkmark.circle.fill", "#22C55E",
                    String(localized: "github.review.approved", defaultValue: "Approved"))
        case .changesRequested:
            return ("exclamationmark.circle.fill", "#F5A524",
                    String(localized: "github.review.changes", defaultValue: "Changes requested"))
        case .pending, .unknown:
            return nil
        }
    }
}

private struct GitHubPageRepoRow: View {
    let repo: GitHubRepoCI
    @State private var hovered = false

    private var shortRepo: String { repo.repo.components(separatedBy: "/").last ?? repo.repo }

    private var word: String? {
        switch repo.ci {
        case .failure: return String(localized: "github.ci.failing", defaultValue: "failing")
        case .pending: return String(localized: "github.ci.running", defaultValue: "running")
        case .success: return String(localized: "github.ci.passing", defaultValue: "passing")
        case .unknown: return nil
        }
    }

    var body: some View {
        Button(action: { openGitHubLink(repo.url.hasSuffix("/") ? repo.url + "actions" : repo.url + "/actions") }) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(ghCIDot(repo.ci))
                    .frame(width: 6, height: 6)
                    .opacity(repo.ci == .unknown ? 0 : 1)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortRepo)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(repo.branch)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if let word {
                    Text(word)
                        .font(.system(size: 10))
                        .foregroundColor(ghCIDot(repo.ci))
                        .lineLimit(1)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(hovered ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
