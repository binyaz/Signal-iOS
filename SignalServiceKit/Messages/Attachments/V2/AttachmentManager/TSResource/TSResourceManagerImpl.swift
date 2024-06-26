//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation
import SignalCoreKit

public class TSResourceManagerImpl: TSResourceManager {

    private let attachmentManager: AttachmentManagerImpl
    private let attachmentStore: AttachmentStore
    private let tsAttachmentManager: TSAttachmentManager
    private let tsResourceStore: TSResourceStore

    public init(
        attachmentManager: AttachmentManagerImpl,
        attachmentStore: AttachmentStore,
        tsResourceStore: TSResourceStore
    ) {
        self.attachmentManager = attachmentManager
        self.attachmentStore = attachmentStore
        self.tsAttachmentManager = TSAttachmentManager()
        self.tsResourceStore = tsResourceStore
    }

    // MARK: - Creating Attachments from source

    // MARK: Body Attachments (special treatment)

    public func createBodyAttachmentPointers(
        from protos: [SSKProtoAttachmentPointer],
        message: TSMessage,
        tx: DBWriteTransaction
    ) throws {
        if FeatureFlags.newAttachmentsUseV2 {
            guard let messageRowId = message.sqliteRowId else {
                owsFailDebug("Adding attachments to an uninserted message!")
                return
            }
            try attachmentManager.createAttachmentPointers(
                from: protos,
                owner: .messageBodyAttachment(messageRowId: messageRowId),
                tx: tx
            )
        } else {
            tsAttachmentManager.createBodyAttachmentPointers(
                from: protos,
                message: message,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        }
    }

    public func createBodyAttachmentStreams(
        consuming dataSources: [TSResourceDataSource],
        message: TSOutgoingMessage,
        tx: DBWriteTransaction
    ) throws {
        var legacyDataSources = [TSAttachmentDataSource]()
        var v2DataSources = [AttachmentDataSource]()
        for dataSource in dataSources {
            switch dataSource.concreteType {
            case .legacy(let tsAttachmentDataSource):
                legacyDataSources.append(tsAttachmentDataSource)
            case .v2(let attachmentDataSource):
                v2DataSources.append(attachmentDataSource)
            }
        }
        if !v2DataSources.isEmpty {
            guard let messageRowId = message.sqliteRowId else {
                owsFailDebug("Adding attachments to an uninserted message!")
                return
            }
            try attachmentManager.createAttachmentStreams(
                consuming: v2DataSources,
                owner: .messageBodyAttachment(messageRowId: messageRowId),
                tx: tx
            )
        }
        if !legacyDataSources.isEmpty {
            try tsAttachmentManager.createBodyAttachmentStreams(
                consuming: legacyDataSources,
                message: message,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        }
    }

    // MARK: Other Attachments

    public func createAttachmentPointerBuilder(
        from proto: SSKProtoAttachmentPointer,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<TSResourceRetrievalInfo> {
        if FeatureFlags.newAttachmentsUseV2 {
            return OwnedAttachmentBuilder<TSResourceRetrievalInfo>(
                info: .v2,
                finalize: { [attachmentManager] owner, innerTx in
                    return try attachmentManager.createAttachmentPointer(
                        from: proto,
                        owner: owner,
                        tx: innerTx
                    )
                }
            )
        } else {
            let attachment = try tsAttachmentManager.createAttachmentPointer(
                from: proto,
                tx: SDSDB.shimOnlyBridge(tx)
            )
            return .withoutFinalizer(.legacy(uniqueId: attachment.uniqueId))
        }
    }

    public func createAttachmentStreamBuilder(
        from dataSource: TSResourceDataSource,
        tx: DBWriteTransaction
    ) throws -> OwnedAttachmentBuilder<TSResourceRetrievalInfo> {
        switch dataSource.concreteType {
        case .v2(let attachmentDataSource):
            return OwnedAttachmentBuilder<TSResourceRetrievalInfo>(
                info: .v2,
                finalize: { [attachmentManager] owner, innerTx in
                    return try attachmentManager.createAttachmentStream(
                        consuming: attachmentDataSource,
                        owner: owner,
                        tx: innerTx
                    )
                }
            )
        case .legacy(let tsAttachmentDataSource):
            let attachmentId = try tsAttachmentManager.createAttachmentStream(
                from: tsAttachmentDataSource,
                tx: SDSDB.shimOnlyBridge(tx)
            )
            return .withoutFinalizer(.legacy(uniqueId: attachmentId))
        }
    }

    // MARK: - Outgoing Proto Creation

    public func buildProtoForSending(
        from reference: TSResourceReference,
        pointer: TSResourcePointer
    ) -> SSKProtoAttachmentPointer? {
        switch pointer.resource.concreteType {
        case .legacy(let tsAttachment):
            guard let stream = tsAttachment as? TSAttachmentStream else {
                return nil
            }
            return stream.buildProto()
        case .v2(let attachment):
            switch reference.concreteType {
            case .legacy:
                owsFailDebug("Invalid attachment type combination!")
                return nil
            case .v2(let attachmentReference):
                guard let attachmentPointer = AttachmentTransitPointer(attachment: attachment) else {
                    owsFailDebug("Invalid attachment type combination!")
                    return nil
                }
                return attachmentManager.buildProtoForSending(
                    from: attachmentReference,
                    pointer: attachmentPointer
                )
            }
        }
    }

    // MARK: - Removes and Deletes

    public func removeBodyAttachment(
        _ attachment: TSResource,
        from message: TSMessage,
        tx: DBWriteTransaction
    ) {
        switch attachment.concreteType {
        case .legacy(let legacyAttachment):
            tsAttachmentManager.removeBodyAttachment(legacyAttachment, from: message, tx: SDSDB.shimOnlyBridge(tx))
        case .v2(let attachment):
            guard let messageRowId = message.sqliteRowId else {
                owsFailDebug("Removing attachment from uninserted message!")
                return
            }
            attachmentManager.removeAttachment(
                attachment,
                from: .messageBodyAttachment(messageRowId: messageRowId),
                tx: tx
            )
        }
    }

    public func removeAttachments(
        from message: TSMessage,
        with types: TSMessageAttachmentReferenceType,
        tx: DBWriteTransaction
    ) {
        message.anyReload(transaction: SDSDB.shimOnlyBridge(tx), ignoreMissing: true)

        var v2Owners = [AttachmentReference.OwnerTypeRaw]()

        if types.contains(.bodyAttachment) || types.contains(.oversizeText) {
            if message.attachmentIds.count > 0 {
                tsAttachmentManager.removeBodyAttachments(
                    from: message,
                    removeMedia: types.contains(.bodyAttachment),
                    removeOversizeText: types.contains(.oversizeText),
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            } else {
                if types.contains(.bodyAttachment) {
                    v2Owners.append(.messageBodyAttachment)
                }
                if types.contains(.oversizeText) {
                    v2Owners.append(.messageOversizeText)
                }
            }
        }

        if types.contains(.linkPreview), let linkPreview = message.linkPreview {
            if linkPreview.usesV2AttachmentReference {
                v2Owners.append(.messageLinkPreview)
            } else if let attachmentId = linkPreview.legacyImageAttachmentId?.nilIfEmpty {
                tsAttachmentManager.removeAttachment(
                    attachmentId: attachmentId,
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            }
        }

        if types.contains(.sticker), let messageSticker = message.messageSticker {
            if let legacyAttachmentId = messageSticker.legacyAttachmentId {
                tsAttachmentManager.removeAttachment(attachmentId: legacyAttachmentId, tx: SDSDB.shimOnlyBridge(tx))
            } else {
                v2Owners.append(.messageSticker)
            }
        }

        if
            types.contains(.quotedReply),
            let quoteAttachmentInfo = message.quotedMessage?.attachmentInfo()
        {
            if quoteAttachmentInfo.attachmentType == OWSAttachmentInfoReference.V2 {
                v2Owners.append(.quotedReplyAttachment)
            } else if let id = quoteAttachmentInfo.attachmentId {
                tsAttachmentManager.removeAttachment(attachmentId: id, tx: SDSDB.shimOnlyBridge(tx))
            }
        }

        if
            types.contains(.contactAvatar),
            let contactShare = message.contactShare
        {
            if let legacyAvatarAttachmentId = contactShare.legacyAvatarAttachmentId {
                tsAttachmentManager.removeAttachment(
                    attachmentId: legacyAvatarAttachmentId,
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            } else {
                v2Owners.append(.messageContactAvatar)
            }
        }

        if FeatureFlags.readV2Attachments {
            guard let messageRowId = message.sqliteRowId else {
                owsFailDebug("Removing attachments from un-inserted message.")
                return
            }
            attachmentManager.removeAllAttachments(
                from: v2Owners.map { $0.with(ownerId: messageRowId) },
                tx: tx
            )
        }
    }

    public func removeAttachments(from storyMessage: StoryMessage, tx: DBWriteTransaction) {
        switch storyMessage.attachment {
        case .file(let storyMessageFileAttachment):
            tsAttachmentManager.removeAttachment(
                attachmentId: storyMessageFileAttachment.attachmentId,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        case .text(let textAttachment):
            if let attachmentId = textAttachment.preview?.legacyImageAttachmentId {
                tsAttachmentManager.removeAttachment(
                    attachmentId: attachmentId,
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            }
        case .foreignReferenceAttachment:
            break
        }
        if FeatureFlags.readV2Attachments {
            guard let storyMessageRowId = storyMessage.id else {
                owsFailDebug("Removing attachments from an un-inserted message")
                return
            }
            attachmentManager.removeAllAttachments(
                from: [
                    .storyMessageMedia(storyMessageRowId: storyMessageRowId),
                    .storyMessageLinkPreview(storyMessageRowId: storyMessageRowId)
                ],
                tx: tx
            )
        }
    }

    // MARK: - Quoted reply thumbnails

    public func createThumbnailAndUpdateMessageIfNecessary(
        quotedMessage: TSQuotedMessage,
        parentMessage: TSMessage,
        tx: DBWriteTransaction
    ) -> TSResourceStream? {
        switch quotedMessage.attachmentInfo()?.attachmentType {
        case nil:
            return nil
        case .V2:
            guard let messageRowId = parentMessage.sqliteRowId else {
                owsFailDebug("Cloning thumbnail attachment from un-inserted message.")
                return nil
            }
            let attachment = attachmentStore.fetchFirst(owner: .quotedReplyAttachment(messageRowId: messageRowId), tx: tx)

            // If its a stream, its the thumbnail (we do cloning and resizing at download time).
            // If its not a stream, that's because its undownloaded and we should return nil.
            return attachment?.asStream()
        case
                .unset,
                .originalForSend,
                .original,
                .thumbnail,
                .untrustedPointer:
            fallthrough
        @unknown default:
            return tsAttachmentManager.createThumbnailAndUpdateMessageIfNecessary(
                parentMessage: parentMessage,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        }
    }

    public func newQuotedReplyMessageThumbnailBuilder(
        originalMessage: TSMessage,
        tx: DBWriteTransaction
    ) -> OwnedAttachmentBuilder<OWSAttachmentInfo>? {
        // Normally, we decide whether to create a v1 or v2 attachment based on
        // FeatureFlags.newAttachmentsUseV2. Here, though, we re-use whatever type
        // v1 or v2 that the original message was using.
        // This does mean we could end up creating v1 attachments even after starting creating
        // v2 ones, but the migration should eventually catch up.
        // Remember that both this code and any migrations use write transactions, so
        // that serves as a global lock that ensures there aren't races; new quotes create
        // new v1 attachments but not while the migration is running.
        let originalAttachmentRef = tsResourceStore.attachmentToUseInQuote(
            originalMessage: originalMessage,
            tx: tx
        )
        switch originalAttachmentRef?.concreteType {
        case nil:
            return nil
        case .legacy(let tSAttachmentReference):
            guard let attachment = tSAttachmentReference.attachment else {
                return nil
            }
            guard
                let info = tsAttachmentManager.cloneThumbnailForNewQuotedReplyMessage(
                    originalAttachment: attachment,
                    tx: SDSDB.shimOnlyBridge(tx)
                )
            else {
                return nil
            }
            return .withoutFinalizer(info)
        case .v2:
            guard
                let info = attachmentManager.quotedReplyAttachmentInfo(
                    originalMessage: originalMessage,
                    tx: tx
                )
            else {
                return nil
            }
            return OwnedAttachmentBuilder<OWSAttachmentInfo>(
                info: info,
                finalize: { [attachmentManager, originalMessage] ownerId, tx in
                    let quotedReplyMessageId: Int64
                    switch ownerId {
                    case .quotedReplyAttachment(let messageRowId):
                        quotedReplyMessageId = messageRowId
                    default:
                        owsFailDebug("Invalid owner sent to quoted reply builder!")
                        return
                    }
                    try attachmentManager.createQuotedReplyMessageThumbnail(
                        originalMessage: originalMessage,
                        quotedReplyMessageId: quotedReplyMessageId,
                        tx: tx
                    )
                }
            )
        }
    }

    public func thumbnailImage(
        attachment: TSResource,
        parentMessage: TSMessage,
        tx: DBReadTransaction
    ) -> UIImage? {
        switch attachment.concreteType {
        case .v2(let attachment):
            guard let stream = attachment.asStream() else {
                return nil
            }
            // If it is an attachment stream, it should already be pointing at the resized
            // thumbnail image, no copying needed.
            return stream.thumbnailImageSync(quality: .small)
        case .legacy(let tsAttachment):
            guard let info = parentMessage.quotedMessage?.attachmentInfo() else {
                return nil
            }
            return tsAttachmentManager.thumbnailImage(
                attachment: tsAttachment,
                info: info,
                parentMessage: parentMessage,
                tx: SDSDB.shimOnlyBridge(tx)
            )
        }
    }
}
