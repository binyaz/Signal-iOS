//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

// Code generated by Wire protocol buffer compiler, do not edit.
// Source: BackupProto.BackupProtoSendStatus in Backup.proto
import Wire

public struct BackupProtoSendStatus {

    public var recipientId: UInt64
    @ProtoDefaulted
    public var deliveryStatus: BackupProtoSendStatus.BackupProtoStatus?
    public var networkFailure: Bool
    public var identityKeyMismatch: Bool
    public var sealedSender: Bool
    /**
     * the time the status was last updated -- if from a receipt, it should be the sentTime of the receipt
     */
    public var lastStatusUpdateTimestamp: UInt64
    public var unknownFields: UnknownFields = .init()

    public init(
        recipientId: UInt64,
        networkFailure: Bool,
        identityKeyMismatch: Bool,
        sealedSender: Bool,
        lastStatusUpdateTimestamp: UInt64,
        configure: (inout Self) -> Swift.Void = { _ in }
    ) {
        self.recipientId = recipientId
        self.networkFailure = networkFailure
        self.identityKeyMismatch = identityKeyMismatch
        self.sealedSender = sealedSender
        self.lastStatusUpdateTimestamp = lastStatusUpdateTimestamp
        configure(&self)
    }

}

#if !WIRE_REMOVE_EQUATABLE
extension BackupProtoSendStatus : Equatable {
}
#endif

#if !WIRE_REMOVE_HASHABLE
extension BackupProtoSendStatus : Hashable {
}
#endif

extension BackupProtoSendStatus : Sendable {
}

extension BackupProtoSendStatus : ProtoMessage {

    public static func protoMessageTypeURL() -> String {
        return "type.googleapis.com/BackupProto.BackupProtoSendStatus"
    }

}

extension BackupProtoSendStatus : Proto3Codable {

    public init(from protoReader: ProtoReader) throws {
        var recipientId: UInt64 = 0
        var deliveryStatus: BackupProtoSendStatus.BackupProtoStatus? = nil
        var networkFailure: Bool = false
        var identityKeyMismatch: Bool = false
        var sealedSender: Bool = false
        var lastStatusUpdateTimestamp: UInt64 = 0

        let token = try protoReader.beginMessage()
        while let tag = try protoReader.nextTag(token: token) {
            switch tag {
            case 1: recipientId = try protoReader.decode(UInt64.self)
            case 2: deliveryStatus = try protoReader.decode(BackupProtoSendStatus.BackupProtoStatus.self)
            case 3: networkFailure = try protoReader.decode(Bool.self)
            case 4: identityKeyMismatch = try protoReader.decode(Bool.self)
            case 5: sealedSender = try protoReader.decode(Bool.self)
            case 6: lastStatusUpdateTimestamp = try protoReader.decode(UInt64.self)
            default: try protoReader.readUnknownField(tag: tag)
            }
        }
        self.unknownFields = try protoReader.endMessage(token: token)

        self.recipientId = recipientId
        self._deliveryStatus.wrappedValue = try BackupProtoSendStatus.BackupProtoStatus.defaultIfMissing(deliveryStatus)
        self.networkFailure = networkFailure
        self.identityKeyMismatch = identityKeyMismatch
        self.sealedSender = sealedSender
        self.lastStatusUpdateTimestamp = lastStatusUpdateTimestamp
    }

    public func encode(to protoWriter: ProtoWriter) throws {
        try protoWriter.encode(tag: 1, value: self.recipientId)
        try protoWriter.encode(tag: 2, value: self.deliveryStatus)
        try protoWriter.encode(tag: 3, value: self.networkFailure)
        try protoWriter.encode(tag: 4, value: self.identityKeyMismatch)
        try protoWriter.encode(tag: 5, value: self.sealedSender)
        try protoWriter.encode(tag: 6, value: self.lastStatusUpdateTimestamp)
        try protoWriter.writeUnknownFields(unknownFields)
    }

}

#if !WIRE_REMOVE_CODABLE
extension BackupProtoSendStatus : Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringLiteralCodingKeys.self)
        self.recipientId = try container.decode(stringEncoded: UInt64.self, forKey: "recipientId")
        self._deliveryStatus.wrappedValue = try container.decodeIfPresent(BackupProtoSendStatus.BackupProtoStatus.self, forKey: "deliveryStatus")
        self.networkFailure = try container.decode(Bool.self, forKey: "networkFailure")
        self.identityKeyMismatch = try container.decode(Bool.self, forKey: "identityKeyMismatch")
        self.sealedSender = try container.decode(Bool.self, forKey: "sealedSender")
        self.lastStatusUpdateTimestamp = try container.decode(stringEncoded: UInt64.self, forKey: "lastStatusUpdateTimestamp")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringLiteralCodingKeys.self)
        let includeDefaults = encoder.protoDefaultValuesEncodingStrategy == .include

        if includeDefaults || self.recipientId != 0 {
            try container.encode(stringEncoded: self.recipientId, forKey: "recipientId")
        }
        try container.encodeIfPresent(self.deliveryStatus, forKey: "deliveryStatus")
        if includeDefaults || self.networkFailure != false {
            try container.encode(self.networkFailure, forKey: "networkFailure")
        }
        if includeDefaults || self.identityKeyMismatch != false {
            try container.encode(self.identityKeyMismatch, forKey: "identityKeyMismatch")
        }
        if includeDefaults || self.sealedSender != false {
            try container.encode(self.sealedSender, forKey: "sealedSender")
        }
        if includeDefaults || self.lastStatusUpdateTimestamp != 0 {
            try container.encode(stringEncoded: self.lastStatusUpdateTimestamp, forKey: "lastStatusUpdateTimestamp")
        }
    }

}
#endif

/**
 * Subtypes within BackupProtoSendStatus
 */
extension BackupProtoSendStatus {

    public enum BackupProtoStatus : Int32, CaseIterable, ProtoEnum, ProtoDefaultedValue {

        case UNKNOWN = 0
        case FAILED = 1
        case PENDING = 2
        case SENT = 3
        case DELIVERED = 4
        case READ = 5
        case VIEWED = 6
        /**
         * e.g. user in group was blocked, so we skipped sending to them
         */
        case SKIPPED = 7

        public static var defaultedValue: BackupProtoSendStatus.BackupProtoStatus {
            BackupProtoSendStatus.BackupProtoStatus.UNKNOWN
        }
        public var description: String {
            switch self {
            case .UNKNOWN: return "UNKNOWN"
            case .FAILED: return "FAILED"
            case .PENDING: return "PENDING"
            case .SENT: return "SENT"
            case .DELIVERED: return "DELIVERED"
            case .READ: return "READ"
            case .VIEWED: return "VIEWED"
            case .SKIPPED: return "SKIPPED"
            }
        }

    }

}

extension BackupProtoSendStatus.BackupProtoStatus : Sendable {
}
