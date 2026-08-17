import XCTest
@testable import Type4Me

final class CredentialStoreTests: XCTestCase {

    private var originalProvider: ASRProvider!
    private var originalMigrationMarker: Any?
    private var temporaryDirectory: URL!
    private var credentialsURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        originalProvider = CredentialStore.selectedASRProvider
        originalMigrationMarker = UserDefaults.standard.object(forKey: "tf_migratedFromTypeFlow")
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        credentialsURL = temporaryDirectory.appendingPathComponent("credentials.json")
        CredentialStore.useCredentialsFileForTesting(credentialsURL)
    }

    override func tearDownWithError() throws {
        CredentialStore.useCredentialsFileForTesting(nil)
        CredentialStore.selectedASRProvider = originalProvider
        restoreUserDefault(key: "tf_migratedFromTypeFlow", value: originalMigrationMarker)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        originalProvider = nil
        originalMigrationMarker = nil
        temporaryDirectory = nil
        credentialsURL = nil
        try super.tearDownWithError()
    }

    func testSaveAndLoad() throws {
        try CredentialStore.save(key: "test_key", value: "secret123")
        let loaded = CredentialStore.load(key: "test_key")
        XCTAssertEqual(loaded, "secret123")
    }

    func testOverwrite() throws {
        try CredentialStore.save(key: "test_key", value: "old")
        try CredentialStore.save(key: "test_key", value: "new")
        XCTAssertEqual(CredentialStore.load(key: "test_key"), "new")
    }

    func testLoadMissing() {
        let result = CredentialStore.load(key: "nonexistent_key_xyz")
        XCTAssertNil(result)
    }

    func testDelete() throws {
        try CredentialStore.save(key: "test_key", value: "value")
        CredentialStore.delete(key: "test_key")
        XCTAssertNil(CredentialStore.load(key: "test_key"))
    }

    func testLoadCredentialsFromFile() throws {
        let original = CredentialStore.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? CredentialStore.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? CredentialStore.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try CredentialStore.saveASRCredentials(for: .volcano, values: [
            "apiKey": "myApiKey",
            "resourceId": "myResource",
        ])

        let config = CredentialStore.loadASRConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.apiKey, "myApiKey")
        XCTAssertEqual(config?.authMode, VolcanoASRConfig.authModeAPIKey)
        XCTAssertEqual(config?.resourceId, "myResource")
    }

    func testCompatibleASRCredentials_backfillsVolcanoResourceIdForOldValues() throws {
        let values = CredentialStore.compatibleASRCredentials(
            for: .volcano,
            stored: [
                "apiKey": "myApiKey",
            ]
        )

        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(VolcanoASRConfig(credentials: values))
    }

    func testCompatibleASRCredentials_preservesLegacyVolcanoAuthFields() throws {
        let values = CredentialStore.compatibleASRCredentials(
            for: .volcano,
            stored: [
                "appKey": "legacyAppID",
                "accessKey": "legacyAccessToken",
            ]
        )

        XCTAssertEqual(values["authMode"], VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(values["appKey"], "legacyAppID")
        XCTAssertEqual(values["accessKey"], "legacyAccessToken")
        XCTAssertNotNil(VolcanoASRConfig(credentials: values))
    }

    func testCompatibleLLMCredentials_backfillsModelAndBaseURLForOldValues() throws {
        let values = CredentialStore.compatibleLLMCredentials(
            for: .doubao,
            stored: ["apiKey": "myApiKey"]
        )

        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(OpenAICompatibleLLMConfig<DoubaoLLMTag>(credentials: values))
    }

    func testCompatibleCredentialsPreferStoredValuesOverLegacyFallbacks() throws {
        let values = CredentialStore.compatibleASRCredentials(
            for: .volcano,
            stored: ["apiKey": "newApiKey"],
            legacy: [
                "apiKey": "oldApiKey",
                "resourceId": "oldResourceId",
            ]
        )

        XCTAssertEqual(values["apiKey"], "newApiKey")
        XCTAssertEqual(values["resourceId"], "oldResourceId")
    }

    func testLoadASRCredentialsBackfillsDefaultsWhenOnlyAPIKeyIsStored() throws {
        let original = CredentialStore.loadASRCredentials(for: .volcano)
        defer {
            if let original {
                try? CredentialStore.saveASRCredentials(for: .volcano, values: original)
            } else {
                try? CredentialStore.saveASRCredentials(for: .volcano, values: [:])
            }
        }

        try CredentialStore.saveASRCredentials(for: .volcano, values: [
            "apiKey": "myApiKey",
        ])

        let values = try XCTUnwrap(CredentialStore.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["resourceId"], VolcanoASRConfig.resourceIdAuto)
        XCTAssertNotNil(CredentialStore.loadASRConfig(for: .volcano))
    }

    func testLoadLLMCredentials_backfillsDefaultsWhenOnlyAPIKeyIsStored() throws {
        let original = CredentialStore.loadLLMCredentials(for: .doubao)
        defer {
            if let original {
                try? CredentialStore.saveLLMCredentials(for: .doubao, values: original)
            } else {
                try? CredentialStore.saveLLMCredentials(for: .doubao, values: [:])
            }
        }

        try CredentialStore.saveLLMCredentials(for: .doubao, values: [
            "apiKey": "myApiKey",
        ])

        let values = try XCTUnwrap(CredentialStore.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "myApiKey")
        XCTAssertEqual(values["model"], LLMProvider.doubao.modelOptions.first?.value)
        XCTAssertEqual(values["baseURL"], LLMProvider.doubao.defaultBaseURL)
        XCTAssertNotNil(CredentialStore.loadLLMProviderConfig(for: .doubao))
    }

    func testMigrateStoredCredentialsCleansLegacyFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_appKey", "tf_accessKey", "tf_resourceId"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, CredentialStore.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? CredentialStore.save(key: key, value: value)
                } else {
                    CredentialStore.delete(key: key)
                }
            }
        }

        try CredentialStore.saveASRCredentials(for: .volcano, values: [:])
        UserDefaults.standard.set("legacyAppKey", forKey: "tf_appKey")
        try CredentialStore.save(key: "tf_accessKey", value: "legacyAccessKey")
        UserDefaults.standard.set("legacyResource", forKey: "tf_resourceId")

        CredentialStore.migrateStoredCredentials()

        let values = try XCTUnwrap(CredentialStore.loadASRCredentials(for: .volcano))
        XCTAssertEqual(values["resourceId"], "legacyResource")
        XCTAssertEqual(values["authMode"], VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(values["appKey"], "legacyAppKey")
        XCTAssertEqual(values["accessKey"], "legacyAccessKey")
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_appKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_resourceId"))
        XCTAssertNil(CredentialStore.load(key: "tf_accessKey"))
    }

    func testMigrateStoredCredentialsCleansLegacyLLMFallbackSourcesAfterBackfill() throws {
        let legacyKeys = ["tf_llmApiKey", "tf_llmModel", "tf_llmEndpointId", "tf_llmBaseURL"]
        let originalDefaults = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        )
        let originalScalarValues = Dictionary(
            uniqueKeysWithValues: legacyKeys.map { ($0, CredentialStore.load(key: $0)) }
        )
        defer {
            for key in legacyKeys {
                restoreUserDefault(key: key, value: originalDefaults[key] ?? nil)
                if let value = originalScalarValues[key] ?? nil {
                    try? CredentialStore.save(key: key, value: value)
                } else {
                    CredentialStore.delete(key: key)
                }
            }
        }

        try CredentialStore.saveLLMCredentials(for: .doubao, values: [:])
        try CredentialStore.save(key: "tf_llmApiKey", value: "legacyLLMKey")
        UserDefaults.standard.set("legacy-model", forKey: "tf_llmEndpointId")
        UserDefaults.standard.set("https://legacy.example/v1", forKey: "tf_llmBaseURL")

        CredentialStore.migrateStoredCredentials()

        let values = try XCTUnwrap(CredentialStore.loadLLMCredentials(for: .doubao))
        XCTAssertEqual(values["apiKey"], "legacyLLMKey")
        XCTAssertEqual(values["model"], "legacy-model")
        XCTAssertEqual(values["baseURL"], "https://legacy.example/v1")
        XCTAssertNil(CredentialStore.load(key: "tf_llmApiKey"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmEndpointId"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "tf_llmBaseURL"))
    }

    func testSaveASRCredentialsStoresAllFieldsInProtectedFile() throws {
        try CredentialStore.saveASRCredentials(for: .volcano, values: [
            "apiKey": "myApiKey",
            "resourceId": "myResource",
        ])

        let fileData = try Data(contentsOf: credentialsURL)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let stored = try XCTUnwrap(json["tf_asr_volcano"] as? [String: String])
        let attributes = try FileManager.default.attributesOfItem(atPath: credentialsURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(stored["resourceId"], "myResource")
        XCTAssertEqual(stored["apiKey"], "myApiKey")
        XCTAssertEqual(permissions.intValue, 0o600)
        XCTAssertEqual(CredentialStore.loadASRCredentials(for: .volcano)?["apiKey"], "myApiKey")
    }

    func testSelectedASRProviderPostsNotificationOnChange() {
        let targetProvider: ASRProvider = originalProvider == .bailian ? .volcano : .bailian
        let expectation = expectation(description: "provider change notification")
        let token = NotificationCenter.default.addObserver(
            forName: .asrProviderDidChange,
            object: nil,
            queue: .main
        ) { note in
            XCTAssertEqual(note.object as? ASRProvider, targetProvider)
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        CredentialStore.selectedASRProvider = targetProvider

        wait(for: [expectation], timeout: 1.0)
    }

    private func restoreUserDefault(key: String, value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
