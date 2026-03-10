import SwiftUI

/// Simulator-only touch targets that mimic volume button actions.
/// In landscape: left half = vol down, right half = vol up.
/// Tap = single press (cycle), long press = hold action (escape / dictation).
struct SimulatorControlsView: View {
    let volumeManager: VolumeButtonManager

    @State private var holdTimer: DispatchWorkItem?
    @State private var didStartDictation = false

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                // Left half — vol down actions
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        simulateAction(.cyclePrevious)
                    }
                    .highPriorityGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                simulateAction(.sendDoubleEscape)
                            }
                    )
                    .frame(width: geo.size.width / 2)

                // Right half — vol up actions
                // Touch-down starts 0.5s timer; release before = tap, release after = end dictation
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                if holdTimer == nil && !didStartDictation {
                                    let work = DispatchWorkItem { [self] in
                                        didStartDictation = true
                                        simulateAction(.dictationStarted)
                                    }
                                    holdTimer = work
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                                }
                            }
                            .onEnded { _ in
                                holdTimer?.cancel()
                                holdTimer = nil
                                if didStartDictation {
                                    didStartDictation = false
                                    simulateAction(.dictationEnded)
                                } else {
                                    simulateAction(.cycleNext)
                                }
                            }
                    )
                    .frame(width: geo.size.width / 2)
            }

        }
    }

    private func simulateAction(_ action: DispatchAction) {
        volumeManager.simulateAction(action)
    }
}
