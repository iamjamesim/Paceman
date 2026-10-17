import SwiftUI
import UIKit

enum CompanionSection: String, CaseIterable {
    case work = "Activity", devices = "Devices", settings = "Settings"

    var symbol: String {
        switch self {
        case .work: return "list.bullet.rectangle"
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
                    .allowsHitTesting(isPresented && !dragging)
                content
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(theme.canvas.ignoresSafeArea(.container))
                    .allowsHitTesting(!isPresented && !dragging)
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
            .gesture(SidebarPanGesture(
                enabled: phase == .active && (canReveal || isPresented),
                shouldBegin: { start, velocity in
                    SidebarGesturePolicy(canReveal: canReveal, isPresented: isPresented,
                        rightToLeft: direction == .rightToLeft, screenWidth: geometry.size.width)
                        .canBegin(start: start, velocity: velocity)
                },
                changed: { dx in
                    dragging = true
                    translation = sign * dx
                },
                ended: { projected in
                    guard dragging else { return }
                    let destination = (isPresented ? width : 0) + sign * projected
                    withAnimation(animation) {
                        isPresented = destination > width / 2
                        translation = 0
                        dragging = false
                    }
                },
                cancelled: {
                    guard dragging else { return }
                    withAnimation(animation) { translation = 0; dragging = false }
                }))
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

    private func close() {
        withAnimation(animation) { isPresented = false; translation = 0; dragging = false }
    }
}

struct SidebarGesturePolicy {
    let canReveal: Bool
    let isPresented: Bool
    let rightToLeft: Bool
    let screenWidth: CGFloat

    func canBegin(start: CGPoint, velocity: CGPoint) -> Bool {
        guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
        let dx = rightToLeft ? -velocity.x : velocity.x
        let leadingStart = rightToLeft ? screenWidth - start.x : start.x
        return isPresented ? dx < 0 : canReveal && leadingStart >= 0 && leadingStart <= 24 && dx > 0
    }
}

/// Reject unrelated pans before recognition. Once a sidebar pan begins, UIKit
/// cancels the touch delivered to any row beneath it instead of sharing the drag.
private struct SidebarPanGesture: UIGestureRecognizerRepresentable {
    var enabled: Bool
    var shouldBegin: (CGPoint, CGPoint) -> Bool
    var changed: (CGFloat) -> Void
    var ended: (CGFloat) -> Void
    var cancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(configuration: self, converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delegate = context.coordinator
        pan.isEnabled = enabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        context.coordinator.configuration = self
        pan.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        let dx = context.converter.localTranslation?.x ?? 0
        switch pan.state {
        case .began, .changed: changed(dx)
        case .ended: ended(dx + (context.converter.localVelocity?.x ?? 0) * 0.2)
        case .cancelled, .failed: cancelled()
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var configuration: SidebarPanGesture
        let converter: CoordinateSpaceConverter
        init(configuration: SidebarPanGesture, converter: CoordinateSpaceConverter) {
            self.configuration = configuration
            self.converter = converter
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let location = converter.localLocation
            let translation = converter.localTranslation ?? .zero
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            return configuration.enabled && configuration.shouldBegin(start, converter.localVelocity ?? .zero)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            false
        }
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
