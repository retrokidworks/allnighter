import StoreKit

/// App Store 판의 팁 통. 소모성 인앱 상품을 App Store 에서 읽어 메뉴에 보여 주고 결제한다.
/// 직접 배포판은 이 파일을 빌드에서 빼고 후원 페이지 링크를 쓴다(project.yml).
///
/// 상품 이름·가격은 App Store Connect 가 SSOT 다 — 여기에는 상품 ID 만 둔다.
/// 팁은 아무것도 풀지 않는다. 결제가 끝나면 거래를 닫고(finish) 메뉴에 고맙다는 말만 보인다.
@MainActor
final class TipJar {
    static let productIDs = [
        "com.retrokidworks.allnighter.tip.coffee",
        "com.retrokidworks.allnighter.tip.lunch",
        "com.retrokidworks.allnighter.tip.round",
    ]

    enum Phase: Equatable {
        case loading
        case ready
        /// 상품을 못 읽었다(오프라인 등).
        case unavailable
        case purchasing
        case thanked
        case failed(String)
    }

    private(set) var products: [Product] = []
    private(set) var phase: Phase = .loading
    private var updates: Task<Void, Never>?

    init() {
        // 승인 대기(Ask to Buy)처럼 앱 밖에서 끝난 결제는 여기로 들어온다.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.finish(result)
            }
        }
        Task { await load() }
    }

    deinit {
        updates?.cancel()
    }

    func load() async {
        phase = .loading
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            guard !loaded.isEmpty else {
                phase = .unavailable
                return
            }
            products = loaded.sorted { $0.price < $1.price }
            phase = .ready
        } catch {
            phase = .unavailable
        }
    }

    func buy(_ product: Product) async {
        // 결제 중에 한 번 더 누르는 것을 막는다.
        guard phase == .ready || phase == .thanked else { return }
        phase = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let result):
                await finish(result)
            case .userCancelled, .pending:
                phase = .ready
            @unknown default:
                phase = .ready
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 검증된 거래만 닫는다. 검증에 실패한 거래는 닫지 않고 둔다 — StoreKit 이 다시 보낸다.
    private func finish(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else {
            phase = .failed("The purchase could not be verified.")
            return
        }
        await transaction.finish()
        phase = .thanked
    }
}
