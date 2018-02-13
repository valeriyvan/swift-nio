//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// The result of an ALPN negotiation.
///
/// In a system expecting an ALPN negotiation to occur, a wide range of
/// possible things can happen. In the best case scenario it is possible for
/// the server and client to agree on a protocol to speak, in which case this
/// will be `.negotiated` with the relevant protocol provided as the associated
/// value. However, if for any reason it was not possible to negotiate a
/// protocol, whether because one peer didn't support ALPN or because there was no
/// protocol overlap, we should `fallback` to a default choice of some kind.
///
/// Exactly what to do when falling back is the responsibility of a specific
/// implementation.
public enum ALPNResult: Equatable {
    /// ALPN negotiation succeeded. The associated value is the ALPN token that
    /// was negotiated.
    case negotiated(String)

    /// ALPN negotiation either failed, or never took place. The application
    /// should fall back to a default protocol choice or close the connection.
    case fallback

    public static func ==(lhs: ALPNResult, rhs: ALPNResult) -> Bool {
        switch (lhs, rhs) {
        case (.negotiated(let p1), .negotiated(let p2)):
            return p1 == p2
        case (.fallback, .fallback):
            return true
        default:
            return false
        }
    }
}

/// A helper `ChannelInboundHandler` that makes it easy to swap channel pipelines
/// based on the result of an ALPN negotiation.
///
/// The standard pattern used by applications that want to use ALPN is to select
/// an application protocol based on the result, optionally falling back to some
/// default protocol. To do this in SwiftNIO requires that the channel pipeline be
/// reconfigured based on the result of the ALPN negotiation. This channel handler
/// encapsulates that logic in a generic form that doesn't depend on the specific
/// TLS implementation in use by using `TLSUserEvent`
///
/// The user of this channel handler provides a single closure that is called with
/// an `ALPNResult` when the ALPN negotiation is complete. Based on that result
/// the user is free to reconfigure the `ChannelPipeline` as required, and should
/// return an `EventLoopFuture` that will complete when the pipeline is reconfigured.
///
/// Until the `EventLoopFuture` completes, this channel handler will buffer inbound
/// data. When the `EventLoopFuture` completes, the buffered data will be replayed
/// down the channel. Then, finally, this channel handler will automatically remove
/// itself from the channel pipeline, leaving the pipeline in its final
/// configuration.
public class ApplicationProtocolNegotiationHandler: ChannelInboundHandler {
    public typealias InboundIn = Any
    public typealias InboundOut = Any

    private let completionHandler: (ALPNResult) -> EventLoopFuture<Void>
    private var waitingForUser: Bool
    private var eventBuffer: [NIOAny]

    /// Create an `ApplicationProtocolNegotiationHandler` with the given completion
    /// callback.
    ///
    /// - Parameter alpnCompleteHandler: The closure that will fire when ALPN
    ///   negotiation has completed.
    public init(alpnCompleteHandler: @escaping (ALPNResult) -> EventLoopFuture<Void>) {
        self.completionHandler = alpnCompleteHandler
        self.waitingForUser = false
        self.eventBuffer = []
    }

    public func userInboundEventTriggered(ctx: ChannelHandlerContext, event: Any) {
        guard let tlsEvent = event as? TLSUserEvent else {
            ctx.fireUserInboundEventTriggered(event)
            return
        }

        switch tlsEvent {
        case .handshakeCompleted(let p):
            handshakeCompleted(context: ctx, negotiatedProtocol: p)
        default:
            ctx.fireUserInboundEventTriggered(event)
        }
    }

    public func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        if waitingForUser {
            eventBuffer.append(data)
        } else {
            ctx.fireChannelRead(data)
        }
    }

    private func handshakeCompleted(context: ChannelHandlerContext, negotiatedProtocol: String?) {
        waitingForUser = true

        let result: ALPNResult
        if let negotiatedProtocol = negotiatedProtocol {
            result = .negotiated(negotiatedProtocol)
        } else {
            result = .fallback
        }

        let switchFuture = completionHandler(result)
        switchFuture.whenComplete { _ in
            self.unbuffer(context: context)
            _ = context.pipeline.remove(handler: self)
        }
    }

    private func unbuffer(context: ChannelHandlerContext) {
        for datum in eventBuffer {
            context.fireChannelRead(datum)
        }
        let buffer = eventBuffer
        eventBuffer = []
        waitingForUser = false
        if buffer.count > 0 {
            context.fireChannelReadComplete()
        }
    }
}
