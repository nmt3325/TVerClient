import SwiftUI
import UIKit

/// 予約済みの番組開始通知を一覧し、個別にもまとめても解除できるようにする。
///
/// 以前は番組詳細をもう一度開かないと解除できず、番組表から消えた番組は
/// 事実上解除不能だった。
@MainActor
final class ProgramNotificationListModel: ObservableObject {
    @Published private(set) var reservations: [ProgramNotificationReservation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?

    private let scheduler: ProgramNotificationScheduler

    init(scheduler: ProgramNotificationScheduler) {
        self.scheduler = scheduler
    }

    func reload() async {
        isLoading = true
        reservations = await scheduler.reservations()
        isLoading = false
    }

    func cancel(_ reservation: ProgramNotificationReservation) async {
        await scheduler.cancel(identifier: reservation.identifier)
        await reload()
        announce("通知を解除しました。")
    }

    /// スワイプと編集モードから来る、位置指定の解除。
    ///
    /// 位置は表示順（`reservations` の並び）で届く。まとめて消えることがあるので、
    /// 先に対象を取り出してから解除する。
    func cancel(at offsets: IndexSet) async {
        let targets = offsets.sorted().compactMap { index -> ProgramNotificationReservation? in
            reservations.indices.contains(index) ? reservations[index] : nil
        }
        guard !targets.isEmpty else { return }
        for target in targets {
            await scheduler.cancel(identifier: target.identifier)
        }
        await reload()
        announce(
            targets.count > 1
                ? "\(targets.count)件の通知を解除しました。"
                : "通知を解除しました。"
        )
    }

    func cancelAll() async {
        let count = await scheduler.cancelAll()
        await reload()
        announce(count > 0 ? "\(count)件の通知を解除しました。" : "解除できる通知はありませんでした。")
    }

    private func announce(_ message: String) {
        statusMessage = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

struct ProgramNotificationListView: View {
    @StateObject private var model: ProgramNotificationListModel
    @Environment(\.dismiss) private var dismiss
    @State private var pendingCancellation: ProgramNotificationReservation?
    @State private var isConfirmingCancelAll = false

    init(scheduler: ProgramNotificationScheduler) {
        _model = StateObject(wrappedValue: ProgramNotificationListModel(scheduler: scheduler))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading, model.reservations.isEmpty {
                    ProgressView("予約を読み込み中")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.reservations.isEmpty {
                    emptyState
                } else {
                    reservationList
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("通知の予約")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: ToolbarCompat.leading) {
                    Button("閉じる") { dismiss() }
                        .frame(
                            minWidth: ProgramGuideMetrics.minimumTapTarget,
                            minHeight: ProgramGuideMetrics.minimumTapTarget
                        )
                }
                ToolbarItem(placement: ToolbarCompat.trailing) {
                    EditButton()
                        .frame(minHeight: ProgramGuideMetrics.minimumTapTarget)
                        .disabled(model.reservations.isEmpty)
                        .accessibilityHint("行ごとに通知を解除できるようにします")
                }
                ToolbarItem(placement: ToolbarCompat.trailing) {
                    Button(role: .destructive) {
                        isConfirmingCancelAll = true
                    } label: {
                        Image(systemName: "bell.slash")
                            .frame(
                                width: ProgramGuideMetrics.minimumTapTarget,
                                height: ProgramGuideMetrics.minimumTapTarget
                            )
                    }
                    .disabled(model.reservations.isEmpty)
                    .accessibilityLabel("すべての通知を解除")
                    .accessibilityHint("確認してから、予約した通知をすべて解除します")
                }
            }
            .task { await model.reload() }
            .refreshable { await model.reload() }
            .confirmationDialog(
                "予約した通知をすべて解除しますか？",
                isPresented: $isConfirmingCancelAll,
                titleVisibility: .visible
            ) {
                Button("すべて解除", role: .destructive) {
                    Task { await model.cancelAll() }
                }
                Button("やめる", role: .cancel) {}
            } message: {
                Text("\(model.reservations.count)件の通知が解除されます。この操作は元に戻せません。")
            }
            .confirmationDialog(
                "この通知を解除しますか？",
                isPresented: cancellationBinding,
                titleVisibility: .visible,
                presenting: pendingCancellation
            ) { reservation in
                Button("解除", role: .destructive) {
                    pendingCancellation = nil
                    Task { await model.cancel(reservation) }
                }
                Button("やめる", role: .cancel) { pendingCancellation = nil }
            } message: { reservation in
                Text(summary(for: reservation))
            }
        }
    }

    private var cancellationBinding: Binding<Bool> {
        Binding(
            get: { pendingCancellation != nil },
            set: { isPresented in
                if !isPresented { pendingCancellation = nil }
            }
        )
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("予約中の通知はありません")
                .font(.headline)
            Text("番組表でこれからの番組を選ぶと、放送開始の通知を予約できます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var reservationList: some View {
        List {
            Section {
                ForEach(model.reservations) { reservation in
                    row(for: reservation)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingCancellation = reservation
                            } label: {
                                Label("解除", systemImage: "bell.slash")
                            }
                        }
                }
                // 編集モードとスワイプ削除は、確認を挟まず即座に解除する。
                // どちらも標準の取り消し操作で、押し間違いは通知を再予約すれば戻せる。
                .onDelete { offsets in
                    Task { await model.cancel(at: offsets) }
                }
            } header: {
                Text("\(model.reservations.count)件の予約")
            } footer: {
                if let statusMessage = model.statusMessage {
                    Text(statusMessage)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(for reservation: ProgramNotificationReservation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(GuideBroadcastAxis.dayAndTimeLabel(for: reservation.fireDate))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text(summary(for: reservation))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(role: .destructive) {
                pendingCancellation = reservation
            } label: {
                Image(systemName: "bell.slash")
                    .frame(
                        width: ProgramGuideMetrics.minimumTapTarget,
                        height: ProgramGuideMetrics.minimumTapTarget
                    )
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("\(summary(for: reservation))の通知を解除")
            .accessibilityHint("確認してから解除します")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func summary(for reservation: ProgramNotificationReservation) -> String {
        if !reservation.body.isEmpty { return reservation.body }
        if !reservation.title.isEmpty { return reservation.title }
        return "番組開始通知"
    }
}
