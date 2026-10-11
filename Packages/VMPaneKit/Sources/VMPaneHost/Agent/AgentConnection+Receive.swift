import Foundation
import VMPaneControl
import VMPaneCore

/// Receiving: frames from the guest, `hello`, responses, notifications and stream data.
extension AgentConnection {
    func receive(_ bytes: Data) async {
        guard closeReason == nil, !refusing else { return }
        decoder.append(bytes)
        while closeReason == nil, !refusing {
            let frame: AgentFrame?
            do {
                frame = try decoder.next()
            } catch {
                return close(.violation("bad frame (\(error.rawValue))"))
            }
            guard let frame else { return }
            await handle(frame)
        }
    }

    func handle(_ frame: AgentFrame) async {
        switch frame {
        case .message(let data):
            switch AgentCodec.decode(data) {
            case .failure(let error): close(.violation("bad message (\(error.rawValue))"))
            case .success(let message): handle(message)
            }
        case .chunk(let stream, let data):
            guard let target = inbound[stream] else { return close(.violation("data on unknown stream \(stream)")) }
            if target.push(data) { await target.waitForRoom() }
        case .end(let stream, let status):
            guard let target = inbound.removeValue(forKey: stream) else {
                return close(.violation("end of unknown stream \(stream)"))
            }
            target.finish(status == .ok ? .success(()) : .failure(.ended(status)))
        }
    }

    func handle(_ message: RPCMessage) {
        switch message {
        case .request(let request) where peer == nil:
            acceptHello(request)
        case .request(let request)
        where request.isNotification && AgentMethod.fromGuest.contains(request.method)
            && request.method != AgentMethod.hello:
            if request.method == AgentMethod.clipboardChanged && !allowClipboardNotice() {
                return close(.violation("clipboard.changed faster than \(AgentLimits.maxClipboardChangedPerSecond)/s"))
            }
            if request.method != AgentMethod.agentHeartbeat { notificationContinuation.yield(request) }
        case .request(let request):
            close(.violation("the guest may not send \(request.method)"))
        case .response(let response):
            guard peer != nil, case .int(let id)? = response.id, let entry = pending.removeValue(forKey: id) else {
                return close(.violation("response to no request"))
            }
            settle(entry, id: id, with: response.outcome)
        }
    }

    func settle(_ entry: Pending, id: Int64, with outcome: Result<JSONValue, RPCError>) {
        let result: Result<CallResult, Error>
        switch outcome {
        case .failure(let error):
            result = .failure(ConnectionError.rpc(error))
        case .success(let value):
            let inboundIDs = entry.streams.inbound(value)
            let outboundIDs = entry.streams.outbound(value)
            let ids = inboundIDs + outboundIDs
            guard Set(ids).count == ids.count,
                ids.allSatisfy({ $0 != 0 && !AgentFrame.isHostStream($0) && inbound[$0] == nil && !outbound.contains($0) }),
                inbound.count + outbound.count + ids.count <= AgentLimits.maxOpenStreams
            else { return close(.violation("bad stream ids in a response")) }
            var streams: [UInt32: AgentInbound] = [:]
            for stream in inboundIDs {
                let queue = AgentInbound(id: stream)
                inbound[stream] = queue
                streams[stream] = queue
            }
            outbound.formUnion(outboundIDs)
            if entry.expired {
                // Nobody waits any more: drain what the guest sends and stop writing.
                for (_, stream) in streams { stream.discard() }
                outbound.subtract(outboundIDs)
                return
            }
            result = .success(CallResult(result: value, inbound: streams))
        }
        if let continuation = entry.continuation {
            continuation.resume(with: result)
        } else if !entry.expired {
            var early = entry
            early.early = result
            pending[id] = early
        }
    }

    func acceptHello(_ request: RPCRequest) {
        guard request.method == AgentMethod.hello, let id = request.id else {
            return close(.violation("expected hello first"))
        }
        let hello: AgentHelloParams
        switch RPCParams.decode(AgentHelloParams.self, from: request.params) {
        case .success(let value): hello = value
        case .failure: return close(.violation("malformed hello"))
        }
        if let token {
            guard let given = hello.token, Self.constantTimeEqual(given, token) else {
                return refuse(
                    id, RPCError(code: AgentErrorCode.unauthorized.rawValue, message: "bad token"),
                    .violation("hello with a wrong token"))
            }
        }
        guard let proto = AgentLimits.negotiate(host: hostRange, agentMin: hello.minProto, agentMax: hello.proto) else {
            let data: JSONValue = ["proto": .int(Int64(hostRange.upperBound)), "minProto": .int(Int64(hostRange.lowerBound))]
            let message = "the host speaks agent protocol \(hostRange.lowerBound)…\(hostRange.upperBound)"
            return refuse(
                id, RPCError(code: AgentErrorCode.protoUnsupported.rawValue, message: message, data: data),
                .closed("protocol \(hello.minProto)…\(hello.proto) unsupported"))
        }
        let peer = Peer(hello: hello, proto: proto)
        self.peer = peer
        reply(id, .success(["proto": .int(Int64(proto)), "hostVersion": .string(hostVersion)]))
        helloWaiter?.resume(returning: peer)
        helloWaiter = nil
    }

    /// Answers `hello` with `error`, then closes once the answer is written (the agent learns why).
    func refuse(_ id: RPCID, _ error: RPCError, _ reason: ConnectionError) {
        refusing = true
        helloWaiter?.resume(throwing: reason)
        helloWaiter = nil
        let response = RPCMessage.response(RPCResponse(id: id, error: error))
        guard let frame = try? encodeMessage(response) else { return close(reason) }
        socket.enqueue(frame) { [weak self] _ in
            Task { await self?.close(reason) }
        }
    }

    func reply(_ id: RPCID, _ outcome: Result<JSONValue, RPCError>) {
        let response =
            switch outcome {
            case .success(let value): RPCResponse(id: id, result: value)
            case .failure(let error): RPCResponse(id: id, error: error)
            }
        if let frame = try? encodeMessage(.response(response)) { enqueue(frame) }
    }

    func allowClipboardNotice() -> Bool {
        let now = ContinuousClock.now
        clipboardNotices.removeAll { now - $0 > .seconds(1) }
        clipboardNotices.append(now)
        return clipboardNotices.count <= AgentLimits.maxClipboardChangedPerSecond
    }
}
