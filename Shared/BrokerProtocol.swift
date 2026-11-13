import Foundation

@objc protocol RemoteBrokerProtocol {
    func execute(_ request: Data, operationID: UUID, progress: NSXPCListenerEndpoint?, reply: @escaping (Data) -> Void)
    func cancel(_ operationID: UUID)
}

@objc protocol TransferProgressProtocol {
    func update(completed: Int64, total: Int64)
}
