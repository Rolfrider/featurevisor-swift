import FeaturevisorTypes
import Foundation

public typealias ConfigureBucketKey = (Feature, Context, BucketKey) -> BucketKey
public typealias ConfigureBucketValue = (Feature, Context, BucketValue) -> BucketValue
public typealias InterceptContext = (Context) -> Context
public typealias DatafileFetchHandler = (_ datafileUrl: String) -> Result<DatafileContent, Error>

public struct Statuses {
    public var ready: Bool
    public var refreshInProgress: Bool
}

public enum EvaluationReason: String {
    case notFound = "not_found"
    case noVariations = "no_variations"
    case disabled
    case required
    case outOfRange = "out_of_range"
    case forced
    case initial
    case sticky
    case rule
    case allocated
    case defaulted
    case override
    case error
}

public struct Evaluation {
    // required
    public let featureKey: FeatureKey
    public let reason: EvaluationReason

    // common
    public let bucketValue: BucketValue?
    public let ruleKey: RuleKey?
    public let error: Error?
    public let enabled: Bool?
    public let traffic: Traffic?
    public let sticky: OverrideFeature?
    public let initial: OverrideFeature?

    // variation
    public let variation: Variation?
    public let variationValue: VariationValue?

    // variable
    public let variableKey: VariableKey?
    public let variableValue: VariableValue?
    public let variableSchema: VariableSchema?

    public init(
            featureKey: FeatureKey,
            reason: EvaluationReason,
            bucketValue: BucketValue? = nil,
            ruleKey: RuleKey? = nil,
            error: Error? = nil,
            enabled: Bool? = nil,
            traffic: Traffic? = nil,
            sticky: OverrideFeature? = nil,
            initial: OverrideFeature? = nil,
            variation: Variation? = nil,
            variationValue: VariationValue? = nil,
            variableKey: VariableKey? = nil,
            variableValue: VariableValue? = nil,
            variableSchema: VariableSchema? = nil) {
        self.featureKey = featureKey
        self.reason = reason
        self.bucketValue = bucketValue
        self.ruleKey = ruleKey
        self.error = error
        self.enabled = enabled
        self.traffic = traffic
        self.sticky = sticky
        self.initial = initial
        self.variation = variation
        self.variationValue = variationValue
        self.variableKey = variableKey
        self.variableValue = variableValue
        self.variableSchema = variableSchema
    }
}

let emptyDatafile = DatafileContent(
    schemaVersion: "1",
    revision: "unknown",
    attributes: [],
    segments: [],
    features: []
)

public class FeaturevisorInstance {
    // from options
    private var bucketKeySeparator: String
    private var configureBucketKey: ConfigureBucketKey?
    private var configureBucketValue: ConfigureBucketValue?
    private var datafileUrl: String?
    private var handleDatafileFetch: DatafileFetchHandler?
    private var initialFeatures: InitialFeatures?
    private var interceptContext: InterceptContext?
    private var logger: Logger
    private var refreshInterval: TimeInterval?  // seconds
    private var stickyFeatures: StickyFeatures?

    // internally created
    private var datafileReader: DatafileReader
    private var emitter: Emitter
    private var statuses: Statuses
    internal var urlSession: URLSession
    private var timer: Timer?

    // exposed from emitter
    public var on: ((EventName, @escaping Listener) -> Void)?
    public var addListener: ((EventName, @escaping Listener) -> Void)?
    public var off: ((EventName, Listener) -> Void)?
    public var removeListener: ((EventName, Listener) -> Void)?
    public var removeAllListeners: ((EventName?) -> Void)?

    internal init(options: InstanceOptions) throws {
        // from options
        bucketKeySeparator = options.bucketKeySeparator
        configureBucketKey = options.configureBucketKey
        configureBucketValue = options.configureBucketValue
        datafileUrl = options.datafileUrl
        handleDatafileFetch = options.handleDatafileFetch
        initialFeatures = options.initialFeatures
        interceptContext = options.interceptContext
        logger = options.logger ?? createLogger()
        refreshInterval = options.refreshInterval
        stickyFeatures = options.stickyFeatures

        // internal
        urlSession = URLSession(configuration: options.sessionConfiguration)
        emitter = Emitter()
        statuses = Statuses(ready: false, refreshInProgress: false)

        // register events
        if let onReady = options.onReady {
            emitter.addListener(.ready, onReady)
        }

        if let onRefresh = options.onRefresh {
            emitter.addListener(.refresh, onRefresh)
        }

        if let onUpdate = options.onUpdate {
            emitter.addListener(.update, onUpdate)
        }

        if let onActivation = options.onActivation {
            emitter.addListener(.activation, onActivation)
        }

        // expose emitter methods
        on = emitter.addListener
        addListener = emitter.addListener
        off = emitter.removeListener
        removeListener = emitter.removeListener
        removeAllListeners = emitter.removeAllListeners

        // datafile
        if let datafileUrl = options.datafileUrl {
            datafileReader = DatafileReader(datafileContent: options.datafile ?? emptyDatafile)

            try fetchDatafileContent(from: datafileUrl, handleDatafileFetch: handleDatafileFetch) { [weak self] result in
                switch result {
                    case .success(let datafileContent):
                        self?.datafileReader = DatafileReader(datafileContent: datafileContent)

                        self?.statuses.ready = true
                        self?.emitter.emit(EventName.ready)

                        if self?.refreshInterval != nil {
                            self?.startRefreshing()
                        }
                    case .failure(let error):
                        self?.logger.error("Failed to fetch datafile: \(error)")
                }
            }
        } else if let datafile = options.datafile {
            datafileReader = DatafileReader(datafileContent: datafile)
            statuses.ready = true

            emitter.emit(EventName.ready)
        } else {
            throw FeaturevisorError.missingDatafileOptions
        }
    }

    func setDatafile(_ datafileJSON: String) {

        guard let data = datafileJSON.data(using: .utf8) else {
            logger.error("could not get datafile as data representation")
            return
        }

        do {
            let datafileContent = try JSONDecoder().decode(DatafileContent.self, from: data)
            datafileReader = DatafileReader(datafileContent: datafileContent)
        } catch {
            logger.error("could not parse datafile", ["error": error])
        }
    }

    func setDatafile(_ datafileContent: DatafileContent) {
        datafileReader = DatafileReader(datafileContent: datafileContent)
    }

    func setStickyFeatures(stickyFeatures: StickyFeatures?) {
        self.stickyFeatures = stickyFeatures
    }

    func getRevision() -> String {
        return self.datafileReader.getRevision()
    }

    // MARK: - Bucketing

    private func getFeature(byKey featureKey: String) -> Feature? {
        return self.datafileReader.getFeature(featureKey)
    }

    private func getBucketKey(feature: Feature, context: Context) -> BucketKey {
        let featureKey = feature.key

        var type: String
        var attributeKeys: [AttributeKey]

        switch feature.bucketBy {
            case .single(let bucketBy):
                type = "plain"
                attributeKeys = [bucketBy]
            case .and(let bucketBy):
                type = "and"
                attributeKeys = bucketBy
            case .or(let bucketBy):
                type = "or"
                attributeKeys = bucketBy.or
        }

        var bucketKey: [AttributeValue] = []

        attributeKeys.forEach { attributeKey in
            guard let attributeValue = context[attributeKey] else {
                return
            }

            if type == "plain" || type == "and" {
                bucketKey.append(attributeValue)
            }
            else {  // or
                if bucketKey.isEmpty {
                    bucketKey.append(attributeValue)
                }
            }
        }

        bucketKey.append(.string(featureKey))

        let result = bucketKey.map { $0.stringValue }.joined(separator: self.bucketKeySeparator)

        if let configureBucketKey = self.configureBucketKey {
            return configureBucketKey(feature, context, result)
        }

        return result
    }

    private func getBucketValue(feature: Feature, context: Context) -> BucketValue {
        let bucketKey = getBucketKey(feature: feature, context: context)
        let value = Bucket.resolveNumber(forKey: bucketKey)

        if let configureBucketValue = self.configureBucketValue {
            return configureBucketValue(feature, context, value)
        }

        return value
    }

    // MARK: - Statuses

    func isReady() -> Bool {
        return statuses.ready
    }

    // MARK: - Refresh

    func refresh() {
        logger.debug("refreshing datafile")

        if statuses.refreshInProgress {
            logger.warn("refresh in progress, skipping");
            return
        }

        guard let datafileUrl else {
            logger.error("cannot refresh since `datafileUrl` is not provided")
            return
        }

        statuses.refreshInProgress = true

        try? fetchDatafileContent(from: datafileUrl, handleDatafileFetch: handleDatafileFetch) { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let datafileContent):
                let currentRevision = self.getRevision()
                let newRevision = datafileContent.revision
                let isNotSameRevision = currentRevision != newRevision

                self.datafileReader = DatafileReader(datafileContent: datafileContent)
                logger.info("refreshed datafile")

                self.emitter.emit(.refresh)

                if isNotSameRevision {
                    self.emitter.emit(.update)
                }

                self.statuses.refreshInProgress = false

            case .failure(let error):
                self.logger.error("failed to refresh datafile", ["error": error])
                self.statuses.refreshInProgress = false
            }
        }
    }

    func startRefreshing() {

        guard let datafileUrl else {
            logger.error("cannot start refreshing since `datafileUrl` is not provided")
            return
        }

        guard timer == nil else {
            logger.warn("refreshing has already started")
            return
        }

        guard let refreshInterval else {
            logger.warn("no `refreshInterval` option provided")
            return
        }

        DispatchQueue.global().async { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshInterval), repeats: true) { _ in
                self?.refresh()
            }

            if let timer = self?.timer {
                RunLoop.current.add(timer, forMode: .common)
                RunLoop.current.run()
            }
        }
    }

    func stopRefreshing() {

        DispatchQueue.global().async { [weak self] in

            guard let intervalId = self?.timer else {
                self?.logger.warn("refreshing has not started yet")
                return
            }

            intervalId.invalidate()
            self?.timer = nil
        }

        logger.warn("refreshing has stopped")
    }

    // MARK: - Flag
    func evaluateFlag(featureKey: FeatureKey, context: Context = [:]) -> Evaluation {
        let evaluation: Evaluation

        // sticky
        if let stickyFeature = stickyFeatures?[featureKey] {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .sticky,
                    enabled: stickyFeature.enabled,
                    sticky: stickyFeature)

                  logger.debug("using sticky enabled", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // initial
        if statuses.ready, let initialFeature = initialFeatures?[featureKey] {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .initial,
                    enabled: initialFeature.enabled,
                    initial: initialFeature)

            logger.debug("using initial enabled", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        let feature = getFeature(byKey: featureKey);

        // not found
        guard let feature else {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .notFound)

            logger.warn("feature not found", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // deprecated
        if feature.deprecated == true {
            logger.warn("feature is deprecated", ["featureKey": feature.key])
        }

        let finalContext = interceptContext != nil ? interceptContext!(context) : context

        // forced
        let force = findForceFromFeature(feature, context: context, datafileReader: datafileReader);

        if let force, force.enabled != nil {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .forced,
                    enabled: force.enabled)

            logger.debug("forced enabled found", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // required
        if !feature.required.isEmpty {
            let requiredFeaturesAreEnabled = feature.required.allSatisfy({ item in
                let requiredKey: FeatureKey
                let requiredVariation: VariationValue?

                switch item {
                case .featureKey(let featureKey):
                    requiredKey = featureKey
                    requiredVariation = nil
                case .withVariation(let variation):
                    requiredKey = variation.key
                    requiredVariation = variation.variation
                }

                let requiredIsEnabled = isEnabled(featureKey: requiredKey, context: finalContext)

                if (!requiredIsEnabled) {
                    return false
                }

                if let requiredVariation, let requiredVariationValue = getVariation(featureKey: requiredKey, context: finalContext) {
                    return requiredVariationValue == requiredVariation
                }

                return true
            })

            if (!requiredFeaturesAreEnabled) {
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .required,
                        enabled: requiredFeaturesAreEnabled)

                return evaluation
            }
        }

        // bucketing
        let bucketValue = getBucketValue(feature: feature, context: finalContext);

        let matchedTraffic = getMatchedTraffic(
                traffic: feature.traffic,
                context: finalContext,
                datafileReader: datafileReader)

        if let matchedTraffic {

            if !feature.ranges.isEmpty {

                let matchedRange = feature.ranges.first(where: { range in
                    return bucketValue >= range.start && bucketValue < range.end
                });

                // matched
                if (matchedRange != nil) {
                    evaluation = Evaluation(
                            featureKey: feature.key,
                            reason: .allocated,
                            bucketValue: bucketValue,
                            enabled: matchedTraffic.enabled ?? true)

                    return evaluation
                }

                // no match
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .outOfRange,
                        bucketValue: bucketValue,
                        enabled: false)

                logger.debug("not matched", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                return evaluation
            }

            // override from rule
            if let matchedTrafficEnabled = matchedTraffic.enabled {
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .override,
                        bucketValue: bucketValue,
                        ruleKey: matchedTraffic.key,
                        enabled: matchedTrafficEnabled,
                        traffic: matchedTraffic)

                logger.debug("override from rule", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                return evaluation
            }

            // treated as enabled because of matched traffic
            if bucketValue < matchedTraffic.percentage {
                // @TODO: verify if range check should be inclusive or not
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .rule,
                        bucketValue: bucketValue,
                        ruleKey: matchedTraffic.key,
                        enabled: true,
                        traffic: matchedTraffic)

                return evaluation
            }
        }

        // nothing matched
        evaluation = Evaluation(
            featureKey: feature.key,
            reason: .error,
            bucketValue: bucketValue,
            enabled: false)

        return evaluation
    }

    public func isEnabled(featureKey: FeatureKey, context: Context = [:]) -> Bool {
        let evaluation = evaluateFlag(featureKey: featureKey, context: context)
        return evaluation.enabled == true
    }

    func evaluateVariation(featureKey: FeatureKey, context: Context = [:]) -> Evaluation {
        let evaluation: Evaluation

        let flag = evaluateFlag(featureKey: featureKey, context: context)

        if flag.enabled == false {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .disabled)

            logger.debug("feature is disabled", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // sticky
        if let variationValue = stickyFeatures?[featureKey]?.variation {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .sticky,
                    variationValue: variationValue)

            logger.debug("using sticky variation", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // initial
        if !statuses.ready, let variationValue = initialFeatures?[featureKey]?.variation {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .initial,
                    variationValue: variationValue)

            logger.debug("using initial variation", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        guard let feature = getFeature(byKey: featureKey) else {
            // not found
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .notFound)

            logger.warn("feature not found", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        guard !feature.variations.isEmpty else {
            // no variations
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .noVariations)

        logger.warn("no variations", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        let finalContext = interceptContext != nil ? interceptContext!(context) : context

        // forced
        if let force = findForceFromFeature(feature, context: context, datafileReader: datafileReader) {
            let variation = feature.variations.first(where: { variation in
                return variation.value == force.variation
            })

            if let variation {
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .forced,
                        variation: variation)

                logger.debug("forced variation found", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                return evaluation
            }
        }

        // bucketing
        let bucketValue = getBucketValue(feature: feature, context: finalContext)

        let matchedTrafficAndAllocation = getMatchedTrafficAndAllocation(
                traffic: feature.traffic,
                context: finalContext,
                bucketValue: bucketValue,
                datafileReader: datafileReader,
                logger: logger)

        if let matchedTraffic = matchedTrafficAndAllocation.matchedTraffic {

            // override from rule
            if let matchedTrafficVariationValue = matchedTraffic.variation {

                let variation = feature.variations.first(where: { variation in
                    return variation.value == matchedTrafficVariationValue
                })

                if let variation {
                    evaluation = Evaluation(
                            featureKey: feature.key,
                            reason: .rule,
                            bucketValue: bucketValue,
                            ruleKey: matchedTraffic.key,
                            variation: variation)

                logger.debug("override from rule", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                    return evaluation
                }
            }

            // regular allocation
            if let matchedAllocation = matchedTrafficAndAllocation.matchedAllocation {

                let variation = feature.variations.first(where: { variation in
                    variation.value == matchedAllocation.variation
                })

                if let variation {
                    evaluation = Evaluation(
                            featureKey: feature.key,
                            reason: .allocated,
                            bucketValue: bucketValue,
                            variation: variation)

                        logger.debug("allocated variation", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                    return evaluation
                }
            }
        }

        // nothing matched
        evaluation = Evaluation(
                featureKey: feature.key,
                reason: .error,
                bucketValue: bucketValue)

        logger.debug("no matched variation", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

        return evaluation
    }

    public func getVariation(featureKey: FeatureKey, context: Context) -> VariationValue? {
        let evaluation = evaluateVariation(featureKey: featureKey, context: context)

        if let variationValue = evaluation.variationValue {
            return variationValue
        }

        if let variation = evaluation.variation {
            return variation.value
        }

        return nil
    }

    // MARK: - Activate

    func activate(featureKey: FeatureKey, context: Context = [:]) -> VariationValue? {
        do {
            let evaluation = evaluateVariation(featureKey: featureKey, context: context)
            let variationValue = evaluation.variation?.value ?? evaluation.variationValue

            guard let variationValue else {
                return nil
            }

            let finalContext = interceptContext != nil ? interceptContext!(context) : context

            var captureContext: Context = [:]

            let attributesForCapturing = datafileReader.getAllAttributes().filter { $0.capture == true }

            attributesForCapturing.forEach({ attribute in
                if finalContext[attribute.key] != nil {
                    captureContext[attribute.key] = context[attribute.key]
                }
            })

            emitter.emit(EventName.activation, featureKey, variationValue, finalContext, captureContext, evaluation)

            return variationValue
        } catch {
            logger.error("activate", ["featureKey": featureKey, "error": error])
            return nil
        }
    }

    // MARK: - Variable

    func evaluateVariable(
            featureKey: FeatureKey,
            variableKey: VariableKey,
            context: Context = [:]) -> Evaluation {

        let evaluation: Evaluation

        let flag = evaluateFlag(featureKey: featureKey, context: context)

        if flag.enabled == false {
            evaluation = Evaluation(featureKey: featureKey, reason: .disabled)

            logger.debug("feature is disabled", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // sticky
        if let variableValue = stickyFeatures?[featureKey]?.variables?[variableKey] {
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .sticky,
                    variableKey: variableKey,
                    variableValue: variableValue)

            logger.debug("using sticky variable", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // initial
        if !statuses.ready, let initialFeature = initialFeatures?[featureKey] {

            if let variableValue = initialFeature.variables?[variableKey] {
                evaluation = Evaluation(
                        featureKey: featureKey,
                        reason: .initial,
                        variableKey: variableKey,
                        variableValue: variableValue)

                logger.debug("using initial variable", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                return evaluation
            }
        }

        guard let feature = getFeature(byKey: featureKey) else {
            // not found
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .notFound,
                    variableKey: variableKey)

            logger.warn("feature not found in datafile", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        let variableSchema = feature.variablesSchema.first(where: { variableSchema in
            variableSchema.key == variableKey
        })

        guard let variableSchema else {
            // variable schema not found
            evaluation = Evaluation(
                    featureKey: featureKey,
                    reason: .notFound,
                    variableKey: variableKey)

            logger.warn("variable schema not found", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        let finalContext = interceptContext != nil ? interceptContext!(context) : context

        // forced
        let force = findForceFromFeature(feature, context: context, datafileReader: datafileReader)

        if let force, let variableValue = force.variables[variableKey] {
            evaluation = Evaluation(
                    featureKey: feature.key,
                    reason: .forced,
                    variableKey: variableKey,
                    variableValue: variableValue,
                    variableSchema: variableSchema)

            logger.debug("forced variable", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

            return evaluation
        }

        // bucketing
        let bucketValue = getBucketValue(feature: feature, context: finalContext)

        let matchedTrafficAndAllocation = getMatchedTrafficAndAllocation(
                traffic: feature.traffic,
                context: finalContext,
                bucketValue: bucketValue,
                datafileReader: datafileReader,
                logger: logger)

        if let matchedTraffic = matchedTrafficAndAllocation.matchedTraffic {
            // override from rule
            if let variableValue = matchedTraffic.variables?[variableKey] {
                evaluation = Evaluation(
                        featureKey: feature.key,
                        reason: .rule,
                        bucketValue: bucketValue,
                        ruleKey: matchedTraffic.key,
                        variableKey: variableKey,
                        variableValue: variableValue,
                        variableSchema: variableSchema)

                logger.debug("override from rule", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                return evaluation
            }

            // regular allocation
            if let matchedAllocation = matchedTrafficAndAllocation.matchedAllocation {

                let variation = feature.variations.first(where: { variation in
                    return variation.value == matchedAllocation.variation
                })

                if let variationVariables = variation?.variables {
                    let variableFromVariation = variationVariables.first(where: { variable in
                        return variable.key == variableKey
                    })

                    if let overrides = variableFromVariation?.overrides {
                        let override = overrides.first(where: { override in
                            if let condition = override.conditions {
                                return allConditionsAreMatched(
                                        condition: condition,
                                        context: finalContext)
                            }

                            if let segments = override.segments {
                                return allGroupSegmentsAreMatched(
                                        groupSegments: segments,
                                        context: finalContext,
                                        datafileReader: datafileReader)
                            }

                            return false
                        })

                        if let override {
                            evaluation = Evaluation(
                                    featureKey: feature.key,
                                    reason: .override,
                                    bucketValue: bucketValue,
                                    ruleKey: matchedTraffic.key,
                                    variableKey: variableKey,
                                    variableValue: override.value,
                                    variableSchema: variableSchema)

                            logger.debug("variable override", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                            return evaluation
                        }
                    }

                    if let variableFromVariationValue = variableFromVariation?.value {
                        evaluation = Evaluation(
                                featureKey: feature.key,
                                reason: .allocated,
                                bucketValue: bucketValue,
                                ruleKey: matchedTraffic.key,
                                variableKey: variableKey,
                                variableValue: variableFromVariationValue,
                                variableSchema: variableSchema)

                        logger.debug("allocated variable", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

                        return evaluation
                    }
                }
            }
        }

        // fall back to default
        evaluation = Evaluation(
                featureKey: feature.key,
                reason: .defaulted,
                bucketValue: bucketValue,
                variableKey: variableKey,
                variableValue: variableSchema.defaultValue,
                variableSchema: variableSchema)

        logger.debug("using default value", ["featureKey": featureKey]) // TODO: Log evaluation object. Make it encodable

        return evaluation;
    }

    func getVariable(
        featureKey: FeatureKey,
        variableKey: VariableKey,
        context: Context = [:]) ->  VariableValue? {
            let evaluation = evaluateVariable(featureKey: featureKey, variableKey: variableKey, context: context)

            guard let variableValue = evaluation.variableValue else {
                return nil
            }

            return variableValue
    }
      func getVariableBoolean(
        featureKey: FeatureKey,
        variableKey: VariableKey,
        context: Context) -> Bool? {
            return getVariable(featureKey: featureKey, variableKey: variableKey, context: context)?.value as? Bool
      }

      func getVariableString(
        featureKey: FeatureKey,
        variableKey: VariableKey,
        context: Context) ->  String? {
          return getVariable(featureKey: featureKey, variableKey: variableKey, context: context)?.value as? String
      }

      func getVariableInteger(
        featureKey: FeatureKey,
        variableKey: VariableKey,
        context: Context) ->  Int? {
          return getVariable(featureKey: featureKey, variableKey: variableKey, context: context)?.value as? Int
      }

      func getVariableDouble(
        featureKey: FeatureKey,
        variableKey: VariableKey,
        context: Context) -> Double? {
          return getVariable(featureKey: featureKey, variableKey: variableKey, context: context)?.value as? Double
      }

      func getVariableArray(
        featureKey: FeatureKey,
        variableKey: String,
        context: Context) -> [String]? {
          return getVariable(featureKey: featureKey, variableKey: variableKey, context: context)?.value as? [String]
      }

    func getVariableObject<T: Decodable>(
        featureKey: FeatureKey,
        variableKey: String,
        context: Context) -> T? {

          let object = getVariable(
                  featureKey: featureKey,
                  variableKey: variableKey,
                  context: context)?.value as? VariableObjectValue

          guard let data = try? JSONEncoder().encode(object) else {
              return nil
          }

          return try? JSONDecoder().decode(T.self, from: data)
      }

    func getVariableJSON<T: Decodable>(
            featureKey: FeatureKey,
            variableKey: String,
            context: Context) -> T? {

        guard let json = getVariable(
                featureKey: featureKey,
                variableKey: variableKey,
                context: context)?.value as? String else {
            return nil
        }

        guard let data = json.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }
}

public func createInstance(options: InstanceOptions) -> FeaturevisorInstance? {
    do {
        let instance = try FeaturevisorInstance(options: options)
        return instance
        // TODO: What to do in case initialisation fails?
        //  } catch FeaturevisorError.missingDatafileOptions{
        //  } catch FeaturevisorError.invalidURL {
        //  } catch FeaturevisorError.downloadingDatafile(let datafileUrl) {
    }
    catch let error {
        print(error.localizedDescription)
    }

    return nil
}
