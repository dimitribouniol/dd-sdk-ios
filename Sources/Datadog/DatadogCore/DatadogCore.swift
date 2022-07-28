/*
 * Unless explicitly stated otherwise all files in this repository are licensed under the Apache License Version 2.0.
 * This product includes software developed at Datadog (https://www.datadoghq.com/).
 * Copyright 2019-2020 Datadog, Inc.
 */

import Foundation

/// Feature-agnostic SDK configuration.
internal typealias CoreConfiguration = FeaturesConfiguration.Common

/// Core implementation of Datadog SDK.
///
/// The core provides a storage and upload mechanism for each registered Feature
/// based on their respective configuration.
///
/// By complying with `DatadogCoreProtocol`, the core can
/// provide context and writing scopes to Features for event recording.
internal final class DatadogCore {
    /// The root location for storing Features data in this instance of the SDK.
    /// For each Feature a set of subdirectories is created inside `CoreDirectory` based on their storage configuration.
    let directory: CoreDirectory

    /// The storage r/w GDC queue.
    let readWriteQueue = DispatchQueue(
        label: "com.datadoghq.ios-sdk-read-write",
        target: .global(qos: .utility)
    )

    /// The system date provider.
    let dateProvider: DateProvider

    /// The user consent provider.
    let consentProvider: ConsentProvider

    /// The user info provider that provide values to the
    /// `v1Context`.
    let userInfoProvider: UserInfoProvider

    /// The core SDK performance presets.
    let performance: PerformancePreset

    /// The HTTP Client for uploads.
    let httpClient: HTTPClient

    /// The on-disk data encryption.
    let encryption: DataEncryption?

    /// The user info publisher that publishes value to the
    /// `contextProvider`
    let userInfoPublisher = UserInfoPublisher()

    /// Registery for v1 features.
    private var v1Features: [String: Any] = [:]

    /// The SDK Context for V1.
    internal private(set) var v1Context: DatadogV1Context

    /// The core context provider.
    private let contextProvider: DatadogContextProvider

    /// Creates a core instance.
    ///
    /// - Parameters:
    ///   - directory: The core directory for this instance of the SDK.
    ///   - dateProvider: The system date provider.
    ///   - consentProvider: The user consent provider.
    ///   - userInfoProvider: The user info provider.
    ///   - performance: The core SDK performance presets.
    ///   - httpClient: The HTTP Client for uploads.
    ///   - encryption: The on-disk data encryption.
    ///   - v1Context: The v1 context.
    ///   - contextProvider: The core context provider.
    init(
        directory: CoreDirectory,
        dateProvider: DateProvider,
        consentProvider: ConsentProvider,
        userInfoProvider: UserInfoProvider,
    	performance: PerformancePreset,
    	httpClient: HTTPClient,
    	encryption: DataEncryption?,
        v1Context: DatadogV1Context,
        contextProvider: DatadogContextProvider
    ) {
        self.directory = directory
        self.dateProvider = dateProvider
        self.consentProvider = consentProvider
        self.userInfoProvider = userInfoProvider
        self.performance = performance
        self.httpClient = httpClient
        self.encryption = encryption
        self.v1Context = v1Context
        self.contextProvider = contextProvider
        self.contextProvider.subscribe(\.userInfo, to: userInfoPublisher)
    }

    /// Sets current user information.
    ///
    /// Those will be added to logs, traces and RUM events automatically.
    /// 
    /// - Parameters:
    ///   - id: User ID, if any
    ///   - name: Name representing the user, if any
    ///   - email: User's email, if any
    ///   - extraInfo: User's custom attributes, if any
    func setUserInfo(
        id: String? = nil,
        name: String? = nil,
        email: String? = nil,
        extraInfo: [AttributeKey: AttributeValue] = [:]
    ) {
        let userInfo = UserInfo(
            id: id,
            name: name,
            email: email,
            extraInfo: extraInfo
        )

        userInfoPublisher.current = userInfo
        userInfoProvider.value = userInfo
    }

    /// Sets the tracking consent regarding the data collection for the Datadog SDK.
    /// 
    /// - Parameter trackingConsent: new consent value, which will be applied for all data collected from now on
    func set(trackingConsent: TrackingConsent) {
        consentProvider.changeConsent(to: trackingConsent)
    }
}

extension DatadogCore: DatadogV1CoreProtocol {
    // MARK: - V1 interface

    /// Creates V1 Feature using its V2 configuration.
    ///
    /// `DatadogCore` uses its core `configuration` to inject feature-agnostic parts of V1 setup.
    /// Feature-specific part is provided explicitly with `featureSpecificConfiguration`.
    ///
    /// - Returns: an instance of V1 feature
    func create<Feature: V1FeatureInitializable>(
        storageConfiguration: FeatureStorageConfiguration,
        uploadConfiguration: FeatureV1UploadConfiguration,
        featureSpecificConfiguration: Feature.Configuration
    ) throws -> Feature {
        let featureDirectories = try directory.getFeatureDirectories(configuration: storageConfiguration)

        let storage = FeatureStorage(
            featureName: storageConfiguration.featureName,
            queue: readWriteQueue,
            directories: featureDirectories,
            dateProvider: dateProvider,
            consentProvider: consentProvider,
            performance: performance,
            encryption: encryption
        )

        let upload = FeatureUpload(
            featureName: uploadConfiguration.featureName,
            contextProvider: contextProvider,
            fileReader: storage.reader,
            requestBuilder: uploadConfiguration.requestBuilder,
            httpClient: httpClient,
            performance: performance
        )

        return Feature(
            storage: storage,
            upload: upload,
            configuration: featureSpecificConfiguration
        )
    }

    func register<T>(feature instance: T?) {
        let key = String(describing: T.self)
        v1Features[key] = instance
    }

    func feature<T>(_ type: T.Type) -> T? {
        let key = String(describing: T.self)
        return v1Features[key] as? T
    }

    func scope<T>(for featureType: T.Type) -> FeatureV1Scope? {
        let key = String(describing: T.self)

        guard let feature = v1Features[key] as? V1Feature else {
            return nil
        }

        return DatadogCoreFeatureScope(
            context: v1Context,
            storage: feature.storage
        )
    }

    var context: DatadogV1Context? {
        return v1Context
    }
}

/// A v1 Feature with an associated stroage.
internal protocol V1Feature {
    /// The feature's storage.
    var storage: FeatureStorage { get }
}

/// This Scope complies with `V1FeatureScope` to provide context and writer to
/// v1 Features.
///
/// The execution block is currently running in `sync`, this will change once the
/// context is provided on it's own queue.
internal struct DatadogCoreFeatureScope: FeatureV1Scope {
    let context: DatadogV1Context
    let storage: FeatureStorage

    func eventWriteContext(_ block: (DatadogV1Context, Writer) throws -> Void) {
        do {
            try block(context, storage.writer)
        } catch {
            DD.telemetry.error("Failed to execute feature scope", error: error)
        }
    }
}

extension DatadogV1Context {
    /// Create V1 context with the given congiguration and provider.
    ///
    /// - Parameters:
    ///   - configuration: The configuration.
    ///   - device: The device description.
    ///   - dateProvider: The local date provider.
    ///   - dateCorrector: The server date corrector.
    ///   - networkConnectionInfoProvider: The network info provider.
    ///   - carrierInfoProvider: The carrier info provider.
    ///   - userInfoProvider: The user info provider.
    ///   - appStateListener: The application state listener.
    ///   - launchTimeProvider: The launch time provider.
    init(
        configuration: CoreConfiguration,
        device: DeviceInfo,
        dateProvider: DateProvider,
        dateCorrector: DateCorrector,
        networkConnectionInfoProvider: NetworkConnectionInfoProviderType,
        carrierInfoProvider: CarrierInfoProviderType,
        userInfoProvider: UserInfoProvider,
        appStateListener: AppStateListening,
        launchTimeProvider: LaunchTimeProviderType
    ) {
        self.site = configuration.site
        self.clientToken = configuration.clientToken
        self.service = configuration.serviceName
        self.env = configuration.environment
        self.version = configuration.applicationVersion
        self.source = configuration.source
        self.sdkVersion = configuration.sdkVersion
        self.ciAppOrigin = configuration.origin
        self.applicationName = configuration.applicationName
        self.applicationBundleIdentifier = configuration.applicationBundleIdentifier

        self.sdkInitDate = dateProvider.now
        self.device = device
        self.dateProvider = dateProvider
        self.dateCorrector = dateCorrector
        self.networkConnectionInfoProvider = networkConnectionInfoProvider
        self.carrierInfoProvider = carrierInfoProvider
        self.userInfoProvider = userInfoProvider
        self.appStateListener = appStateListener
        self.launchTimeProvider = launchTimeProvider
    }
}

extension DatadogContextProvider {
    /// Creates a core context provider with the given configuration,
    ///
    /// - Parameters:
    ///   - configuration: The configuration.
    ///   - device: The device description.
    ///   - dateProvider: The local date provider.
    convenience init(
        configuration: CoreConfiguration,
        device: DeviceInfo,
        dateProvider: DateProvider
    ) {
        let context = DatadogContext(
            site: configuration.site,
            clientToken: configuration.clientToken,
            service: configuration.serviceName,
            env: configuration.environment,
            version: configuration.applicationVersion,
            source: configuration.source,
            sdkVersion: configuration.sdkVersion,
            ciAppOrigin: configuration.origin,
            applicationName: configuration.applicationName,
            applicationBundleIdentifier: configuration.applicationBundleIdentifier,
            sdkInitDate: dateProvider.now,
            device: device
        )

        self.init(context: context)

        subscribe(\.serverTimeOffset, to: KronosClockPublisher())
        assign(reader: LaunchTimeReader(), to: \.launchTime)

        if #available(iOS 12, tvOS 12, *) {
            subscribe(\.networkConnectionInfo, to: NWPathMonitorPublisher())
        } else {
            assign(reader: SCNetworkReachabilityReader(), to: \.networkConnectionInfo)
        }

        #if os(iOS)
        if #available(iOS 12, *) {
            subscribe(\.carrierInfo, to: iOS12CarrierInfoPublisher())
        } else {
            assign(reader: iOS11CarrierInfoReader(), to: \.carrierInfo)
        }
        #endif

        #if os(iOS) && !targetEnvironment(simulator)
        assign(reader: BatteryStatusReader(), to: \.batteryStatus)
        #endif

        #if os(iOS) || os(tvOS)
        DispatchQueue.main.async {
            // must be call on the main thread to read `UIApplication.State`
            let applicationStatePublisher = ApplicationStatePublisher(dateProvider: dateProvider)
            self.subscribe(\.applicationStateHistory, to: applicationStatePublisher)
        }
        #endif
    }
}

/// A shim interface for allowing V1 Features generic initialization in `DatadogCore`.
internal protocol V1FeatureInitializable {
    /// The configuration specific to this Feature.
    /// In V2 this will likely become a part of the public interface for the Feature module.
    associatedtype Configuration

    init(
        storage: FeatureStorage,
        upload: FeatureUpload,
        configuration: Configuration
    )
}
