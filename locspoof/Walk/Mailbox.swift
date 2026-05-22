import Foundation

/// Single-slot latest-wins mailbox。
/// post 第二次會覆蓋第一個未取出的值；take 等到有值才回。
/// 用 cruise 中切換目標（FR6.2 latest-wins）。
actor Mailbox<T: Sendable> {
    private var slot: T?
    private var waiters: [CheckedContinuation<T, Never>] = []

    func post(_ item: T) {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: item)
            return
        }
        slot = item   // 覆蓋舊未取出值（latest-wins）
    }

    func take() async -> T {
        if let item = slot {
            slot = nil
            return item
        }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func peek() -> T? { slot }

    func clear() {
        slot = nil
        // 喚醒 waiters 避免卡死、用 sentinel 不容易；先讓 take 繼續 wait
        // 實際用法：clear 通常跟 cancel Task 配對、由 task cancellation 收尾
    }
}
