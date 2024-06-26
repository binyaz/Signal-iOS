//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Foundation

public protocol MessageBackupManager {

    /// Outputs file url the backup proto is located at.
    func createBackup(localIdentifiers: LocalIdentifiers) async throws -> URL

    func importBackup(localIdentifiers: LocalIdentifiers, fileUrl: URL) async throws
}
