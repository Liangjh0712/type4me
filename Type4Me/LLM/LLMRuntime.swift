import Foundation

enum LLMRuntime {
    static func currentClient(isCloudMode: Bool = false) -> any LLMClient {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return CloudLLMClient() }
        #endif

        return LLMClientFactory.make(for: CredentialStore.selectedLLMProvider)
    }

    static func currentConfig(isCloudMode: Bool = false) -> LLMConfig? {
        #if HAS_CLOUD_SUBSCRIPTION
        if isCloudMode { return LLMConfig(apiKey: "", model: "cloud") }
        #endif

        return CredentialStore.loadLLMConfig()
    }
}
