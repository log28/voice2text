import Foundation

final class ConfigStore {
    private enum DefaultsKey {
        static let dashScopeBaseURL = "dashScopeBaseURL"
        static let asrModel = "asrModel"
        static let llmModel = "llmModel"
        static let shouldOrganize = "shouldOrganize"
        static let organizeMode = "organizeMode"
        static let ossEndpoint = "ossEndpoint"
        static let ossBucket = "ossBucket"
        static let ossPrefix = "ossPrefix"
        static let signedURLTTLSeconds = "signedURLTTLSeconds"
        static let deleteOSSObjectAfterASR = "deleteOSSObjectAfterASR"
    }

    private enum SecretKey {
        static let dashScopeAPIKey = "dashScopeAPIKey"
        static let ossAccessKeyId = "ossAccessKeyId"
        static let ossAccessKeySecret = "ossAccessKeySecret"
        static let ossSecurityToken = "ossSecurityToken"
    }

    static func load() -> AppConfig {
        let defaults = UserDefaults.standard
        var config = AppConfig()

        config.dashScopeAPIKey = KeychainStore.load(SecretKey.dashScopeAPIKey)
        config.ossAccessKeyId = KeychainStore.load(SecretKey.ossAccessKeyId)
        config.ossAccessKeySecret = KeychainStore.load(SecretKey.ossAccessKeySecret)
        config.ossSecurityToken = KeychainStore.load(SecretKey.ossSecurityToken)

        config.dashScopeBaseURL = defaults.string(forKey: DefaultsKey.dashScopeBaseURL) ?? config.dashScopeBaseURL
        config.asrModel = defaults.string(forKey: DefaultsKey.asrModel) ?? config.asrModel
        config.llmModel = defaults.string(forKey: DefaultsKey.llmModel) ?? config.llmModel
        if let rawMode = defaults.string(forKey: DefaultsKey.organizeMode), let mode = OrganizeMode(rawValue: rawMode) {
            config.organizeMode = mode
        }
        config.ossEndpoint = defaults.string(forKey: DefaultsKey.ossEndpoint) ?? config.ossEndpoint
        config.ossBucket = defaults.string(forKey: DefaultsKey.ossBucket) ?? config.ossBucket
        config.ossPrefix = defaults.string(forKey: DefaultsKey.ossPrefix) ?? config.ossPrefix

        if defaults.object(forKey: DefaultsKey.shouldOrganize) != nil {
            config.shouldOrganize = defaults.bool(forKey: DefaultsKey.shouldOrganize)
        }
        if defaults.object(forKey: DefaultsKey.deleteOSSObjectAfterASR) != nil {
            config.deleteOSSObjectAfterASR = defaults.bool(forKey: DefaultsKey.deleteOSSObjectAfterASR)
        }
        if defaults.object(forKey: DefaultsKey.signedURLTTLSeconds) != nil {
            config.signedURLTTLSeconds = max(60, defaults.integer(forKey: DefaultsKey.signedURLTTLSeconds))
        }

        return config
    }

    static func save(_ config: AppConfig) throws {
        let defaults = UserDefaults.standard
        defaults.set(config.dashScopeBaseURL, forKey: DefaultsKey.dashScopeBaseURL)
        defaults.set(config.asrModel, forKey: DefaultsKey.asrModel)
        defaults.set(config.llmModel, forKey: DefaultsKey.llmModel)
        defaults.set(config.shouldOrganize, forKey: DefaultsKey.shouldOrganize)
        defaults.set(config.organizeMode.rawValue, forKey: DefaultsKey.organizeMode)
        defaults.set(config.ossEndpoint, forKey: DefaultsKey.ossEndpoint)
        defaults.set(config.ossBucket, forKey: DefaultsKey.ossBucket)
        defaults.set(config.ossPrefix, forKey: DefaultsKey.ossPrefix)
        defaults.set(config.signedURLTTLSeconds, forKey: DefaultsKey.signedURLTTLSeconds)
        defaults.set(config.deleteOSSObjectAfterASR, forKey: DefaultsKey.deleteOSSObjectAfterASR)

        try KeychainStore.save(config.dashScopeAPIKey, account: SecretKey.dashScopeAPIKey)
        try KeychainStore.save(config.ossAccessKeyId, account: SecretKey.ossAccessKeyId)
        try KeychainStore.save(config.ossAccessKeySecret, account: SecretKey.ossAccessKeySecret)
        try KeychainStore.save(config.ossSecurityToken, account: SecretKey.ossSecurityToken)
    }
}
