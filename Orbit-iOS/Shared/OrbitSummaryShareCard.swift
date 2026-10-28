import CoreTransferable
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The picture "Share" makes from a monthly summary: a 1080 × 1350 card (Instagram's 4:5) drawn with
/// plain SwiftUI so the iPhone, iPad and Mac apps render the same image with `ImageRenderer`.
/// It never shows the PC's name or address: only the month, games and totals.
struct OrbitSummaryShareCard: View {
    let summary: OrbitMonthSummary
    var accent: Color = Color(red: 0.36, green: 0.86, blue: 1.0)
    var secondary: Color = Color(red: 0.42, green: 0.52, blue: 1.0)

    static let size = CGSize(width: 360, height: 450)

    private var monthTitle: String { summary.monthID?.title() ?? summary.month }
    private var topGames: [OrbitMonthSummary.Game] { Array(summary.games.prefix(3)) }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.09), Color(red: 0.02, green: 0.02, blue: 0.04)],
                           startPoint: .top, endPoint: .bottom)
            Circle()
                .fill(accent.opacity(0.35))
                .frame(width: 300, height: 300)
                .blur(radius: 70)
                .offset(x: 130, y: -190)
            Circle()
                .fill(secondary.opacity(0.28))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -150, y: 210)
            content
                .padding(24)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .large)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(accent)
                Text("MY MONTH IN GAMES")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.6)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
            }
            Text(monthTitle)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.top, 8)

            Text(OrbitEnergyFormat.duration(summary.playSeconds))
                .font(.system(size: 50, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [accent, secondary], startPoint: .leading, endPoint: .trailing))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(.top, 14)
            Text("of play on \(summary.daysPlayed) day\(summary.daysPlayed == 1 ? "" : "s") · \(summary.sessions) session\(summary.sessions == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))

            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(topGames.enumerated()), id: \.element.id) { index, game in
                    gameRow(rank: index + 1, game: game)
                }
            }
            .padding(.top, 20)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let longest = summary.longestSession {
                    stat("Longest session", OrbitEnergyFormat.duration(longest.seconds))
                }
                if let peak = summary.peakGPUTemp {
                    stat("Hottest GPU", OrbitEnergyFormat.temperature(peak))
                }
                if let energy = summary.energy, energy.kWh > 0 {
                    stat("Energy (est.)", OrbitEnergyFormat.energy(energy.kWh))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                Text("Made with Orbit")
                    .font(.system(size: 10, weight: .bold))
                Spacer(minLength: 0)
                if let change = summary.playChange, let previous = summary.previous.flatMap({ OrbitMonthID($0.month) }) {
                    Text("\(change.percentText()) vs \(previous.name())")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(change.isUp ? accent : .white.opacity(0.6))
                }
            }
            .foregroundStyle(.white.opacity(0.55))
            .padding(.top, 14)
        }
    }

    private func gameRow(rank: Int, game: OrbitMonthSummary.Game) -> some View {
        let share = summary.playSeconds > 0 ? min(1, game.playSeconds / summary.playSeconds) : 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(rank == 1 ? .black : .white)
                    .frame(width: 20, height: 20)
                    .background(rank == 1 ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.12)), in: Circle())
                Text(game.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(OrbitEnergyFormat.duration(game.playSeconds))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [accent, secondary], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, proxy.size.width * share))
                }
            }
            .frame(height: 5)
            .padding(.leading, 28)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 7.5, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// What `ShareLink` shares for a monthly summary: the month and the theme's colours, plus a small preview
/// for the share sheet. The full 1080 × 1350 PNG ("Orbit October 2026.png") is only drawn once the person
/// picks where it goes, not each time the month on screen changes.
struct OrbitSummaryPicture: Transferable {
    let summary: OrbitMonthSummary
    let accent: Color
    let secondary: Color
    /// The card drawn at 1× (360 × 450): enough for the share sheet's thumbnail, and cheap to draw.
    let preview: Image

    var fileName: String {
        "Orbit \(summary.monthID?.title(locale: Locale(identifier: "en_US")) ?? summary.month).png"
    }

    struct RenderError: LocalizedError {
        var errorDescription: String? { "Orbit couldn't draw the summary picture." }
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { picture in
            guard let data = await picture.pngData() else { throw RenderError() }
            return data
        }
        .suggestedFileName { $0.fileName }
    }

    /// The share picture at 3× (1080 × 1350 pixels), drawn now.
    @MainActor
    func pngData() -> Data? { Self.png(summary, accent: accent, secondary: secondary) }

    /// The item for `ShareLink`. Nil only if the system can't draw the card.
    @MainActor
    static func make(_ summary: OrbitMonthSummary, accent: Color, secondary: Color) -> OrbitSummaryPicture? {
        guard let preview = image(summary, accent: accent, secondary: secondary, scale: 1) else { return nil }
        return OrbitSummaryPicture(summary: summary, accent: accent, secondary: secondary, preview: Image(decorative: preview, scale: 1))
    }

    /// The card as PNG data (3×: 1080 × 1350 pixels). Nil only if the system can't render or encode it.
    @MainActor
    static func png(_ summary: OrbitMonthSummary, accent: Color, secondary: Color, scale: CGFloat = 3) -> Data? {
        guard let cgImage = image(summary, accent: accent, secondary: secondary, scale: scale) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @MainActor
    private static func image(_ summary: OrbitMonthSummary, accent: Color, secondary: Color, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: OrbitSummaryShareCard(summary: summary, accent: accent, secondary: secondary))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.cgImage
    }
}
