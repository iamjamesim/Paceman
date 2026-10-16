import SwiftUI

enum CompanionSection: String, CaseIterable {
    case work = "Activity", devices = "Devices", settings = "Settings"

    var symbol: String {
        switch self {
        case .work: return "waveform.path.ecg"
        case .devices: return "laptopcomputer.and.iphone"
        case .settings: return "gearshape"
        }
    }
}

/// Navigation sits behind the current screen. A native stack still owns task and
/// settings navigation, including their interactive back gestures.
struct CompanionSidebar<Content: View>: View {
    @Binding var selection: CompanionSection
    @Binding var isPresented: Bool
    let canReveal: Bool
    let theme: CompanionTheme
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var translation: CGFloat = 0
    @State private var dragging = false

    private var animation: Animation? { reduceMotion ? nil : .snappy(duration: 0.28) }
    private var sign: CGFloat { direction == .rightToLeft ? -1 : 1 }

    var body: some View {
        GeometryReader { geometry in
            let width = min(320, max(0, geometry.size.width - 64))
            let offset = min(width, max(0, (isPresented ? width : 0) + translation))
            let progress = width > 0 ? offset / width : 0
            ZStack(alignment: .leading) {
                theme.canvas.ignoresSafeArea()
                theme.ink.opacity(0.035).ignoresSafeArea()
                sidebar
                    .frame(width: width)
                    .accessibilityHidden(!isPresented)
                    .allowsHitTesting(isPresented)
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(theme.canvas.ignoresSafeArea(.container))
                    .accessibilityHidden(isPresented)
                    .overlay {
                        if progress > 0 {
                            Button { close() } label: {
                                Color.clear.contentShape(Rectangle()).ignoresSafeArea(.container)
                            }.buttonStyle(.plain).accessibilityHidden(true)
                        }
                    }
                    // Extend only the drawing mask, not the navigation stack's
                    // layout. Native safe areas and keyboard avoidance stay intact.
                    .mask {
                        RoundedRectangle(cornerRadius: progress > 0 ? 56 : 0, style: .continuous)
                            .ignoresSafeArea(.container)
                    }
                    .shadow(color: .black.opacity(0.20 * progress), radius: 24, x: -8 * sign)
                    .offset(x: sign * offset)
            }
            .simultaneousGesture(revealGesture(width: width, screenWidth: geometry.size.width))
            .mask { Rectangle().ignoresSafeArea(.container) }
        }
        .background(theme.canvas.ignoresSafeArea())
        .onChange(of: isPresented) { _, shown in
            headingFocused = shown
        }
        .onChange(of: phase) { _, value in
            if value != .active { translation = 0; dragging = false }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    PacemanMark().foregroundStyle(theme.tint).frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                Text("Paceman").companionText(.sectionTitle, theme: theme)
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44, alignment: .leading)
            .padding(.horizontal, CompanionLayout.pageInset)
            ScrollView {
                VStack(spacing: 4) {
                    destination(.work)
                    destination(.devices)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button { select(.settings) } label: {
                    Image(systemName: CompanionSection.settings.symbol)
                        .font(.body.weight(.medium))
                        .padding(12)
                        .frame(minWidth: 48, minHeight: 48)
                        .background(theme.ink.opacity(0.06), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("Settings")
                    .accessibilityAddTraits(selection == .settings ? .isSelected : [])
            }.padding(.horizontal, CompanionLayout.pageInset)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .foregroundStyle(theme.ink)
        .accessibilityAction(.escape) { close() }
    }

    private func destination(_ section: CompanionSection) -> some View {
        Button {
            select(section)
        } label: {
            HStack(spacing: 12) {
                if !typeSize.isAccessibilitySize {
                    Image(systemName: section.symbol).font(.body).frame(width: 24)
                        .accessibilityHidden(true)
                }
                Text(section.rawValue).companionText(.label, theme: theme)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            .padding(.horizontal, CompanionLayout.pageInset).padding(.vertical, 12)
            .background(selection == section ? theme.ink.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    private func select(_ section: CompanionSection) {
        withAnimation(animation) {
            selection = section
            isPresented = false
            translation = 0
            dragging = false
        }
    }

    private func revealGesture(width: CGFloat, screenWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                let dx = sign * value.translation.width
                let start = direction == .rightToLeft ? screenWidth - value.startLocation.x : value.startLocation.x
                guard isPresented || (canReveal && start <= 24) else { return }
                guard dragging || abs(dx) > abs(value.translation.height) * 1.2 else { return }
                dragging = true
                translation = dx
            }
            .onEnded { value in
                guard dragging else { return }
                let projected = (isPresented ? width : 0) + sign * value.predictedEndTranslation.width
                withAnimation(animation) {
                    isPresented = projected > width / 2
                    translation = 0
                    dragging = false
                }
            }
    }

    private func close() {
        withAnimation(animation) { isPresented = false; translation = 0; dragging = false }
    }
}

struct SidebarMenuButton: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { isPresented = true }
        } label: {
            Image(systemName: "line.3.horizontal")
        }.accessibilityLabel("Open navigation")
    }
}
