import SwiftUI

/// Wrapper that mounts ConfirmGateView with the env-injected GateCoordinator.
/// Avoids a circular dependency by reading the coordinator from the
/// environment rather than constructing one.
struct ConfirmGateOverlay: View {
    @EnvironmentObject var gate: GateCoordinator

    var body: some View {
        ConfirmGateView(gate: gate)
    }
}
