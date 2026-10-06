import Foundation

extension NativeMailEngine {
    public func repairSentCopy(_ receipt: MailSendReceipt) async throws -> MailSendReceipt {
        try await accountSync(receipt.accountID).repairSentCopy(receipt)
    }
}
