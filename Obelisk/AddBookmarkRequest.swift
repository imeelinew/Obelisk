import Foundation
import Observation

/// Cross-component channel for "open the manage window's add sheet, here are
/// the values to prefill". Wave 5's global hotkey populates this with browser
/// tab data; the manage window's view watches `seq` to know when to act.
///
/// `seq` is monotonically incremented on every request, so two requests with
/// identical prefill values still trigger an update (idempotent identity).
@MainActor
@Observable
final class AddBookmarkRequest {
    private(set) var url: String?
    private(set) var title: String?
    private(set) var isHidden: Bool = false
    private(set) var seq: Int = 0
    private var consumedSeq: Int = 0

    func request(url: String?, title: String?, isHidden: Bool = false) {
        self.url = url
        self.title = title
        self.isHidden = isHidden
        self.seq &+= 1
    }

    func consumePending() -> (seq: Int, url: String?, title: String?, isHidden: Bool)? {
        guard seq > consumedSeq else {
            return nil
        }
        consumedSeq = seq
        return (seq, url, title, isHidden)
    }
}
