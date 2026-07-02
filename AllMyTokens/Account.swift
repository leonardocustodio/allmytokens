//
//  Account.swift
//  AllMyTokens
//
//  A connected Claude account. Tokens live in the Keychain keyed by `id`; this
//  lightweight record (id + display name) is persisted in UserDefaults so the
//  app knows which accounts exist across launches.
//

import Foundation

struct Account: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
}
