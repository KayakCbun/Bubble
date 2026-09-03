import Foundation

enum AgenticUILimits {
    static let maxBytes = 64 * 1_024
    static let maxElements = 64
    static let maxDepth = 8
    static let maxChildren = 32
    static let maxChartPoints = 500
    static let maxChartSeries = 8
    static let maxTableRows = 100
    static let maxTableColumns = 12
    static let maxStringLength = 8 * 1_024
    static let maxSummaryLength = 2 * 1_024
}

enum AgenticUIComponentType: String, Codable, CaseIterable, Sendable {
    case stack = "Stack"
    case card = "Card"
    case heading = "Heading"
    case text = "Text"
    case metric = "Metric"
    case table = "Table"
    case barChart = "BarChart"
    case lineChart = "LineChart"
    case donutChart = "DonutChart"
}

enum AgenticUIJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AgenticUIJSONValue])
    case object([String: AgenticUIJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AgenticUIJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AgenticUIJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var number: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var array: [AgenticUIJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var object: [String: AgenticUIJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var displayText: String {
        switch self {
        case .null: ""
        case .bool(let value): value ? "Yes" : "No"
        case .number(let value):
            if value.rounded() == value,
               value >= Double(Int.min),
               value <= Double(Int.max) {
                String(Int(value))
            } else {
                value.formatted(.number.precision(.fractionLength(0...3)))
            }
        case .string(let value): value
        case .array, .object: ""
        }
    }

    fileprivate var stringsAreWithinLimit: Bool {
        switch self {
        case .null, .bool, .number:
            true
        case .string(let value):
            value.count <= AgenticUILimits.maxStringLength
        case .array(let values):
            values.allSatisfy(\.stringsAreWithinLimit)
        case .object(let object):
            object.allSatisfy {
                $0.key.count <= AgenticUILimits.maxStringLength && $0.value.stringsAreWithinLimit
            }
        }
    }
}

struct AgenticUIElement: Codable, Equatable, Sendable {
    var type: AgenticUIComponentType
    var props: [String: AgenticUIJSONValue]
    var children: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case props
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(AgenticUIComponentType.self, forKey: .type)
        props = try container.decodeIfPresent([String: AgenticUIJSONValue].self, forKey: .props) ?? [:]
        children = try container.decodeIfPresent([String].self, forKey: .children) ?? []
    }

    init(type: AgenticUIComponentType, props: [String: AgenticUIJSONValue] = [:], children: [String] = []) {
        self.type = type
        self.props = props
        self.children = children
    }
}

struct AgenticUIChartPoint: Equatable, Sendable, Identifiable {
    var label: String
    var value: Double
    var series: String?

    var id: String { "\(series ?? "")\u{1F}\(label)" }
}

struct AgenticUITableColumn: Equatable, Sendable {
    var key: String
    var label: String
}

struct AgenticUISpec: Codable, Equatable, Sendable {
    var root: String
    var elements: [String: AgenticUIElement]

    func chartPoints(for elementID: String) -> [AgenticUIChartPoint] {
        guard let values = elements[elementID]?.props["points"]?.array else { return [] }
        return values.compactMap { value in
            guard let object = value.object,
                  let label = object["label"]?.string,
                  let number = object["value"]?.number else { return nil }
            return AgenticUIChartPoint(label: label, value: number, series: object["series"]?.string)
        }
    }

    func tableColumns(for elementID: String) -> [AgenticUITableColumn] {
        guard let values = elements[elementID]?.props["columns"]?.array else { return [] }
        return values.compactMap { value in
            guard let object = value.object,
                  let key = object["key"]?.string,
                  let label = object["label"]?.string else { return nil }
            return AgenticUITableColumn(key: key, label: label)
        }
    }

    func tableRows(for elementID: String) -> [[String: AgenticUIJSONValue]] {
        elements[elementID]?.props["rows"]?.array?.compactMap(\.object) ?? []
    }
}

struct AgenticUIRequest: Codable, Equatable, Sendable {
    var blockID: String? = nil
    var summary: String
    var spec: AgenticUISpec

    static func decodeAndValidate(_ raw: Any?) -> AgenticUIRequest? {
        guard let raw,
              JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw),
              data.count <= AgenticUILimits.maxBytes,
              let request = try? JSONDecoder().decode(AgenticUIRequest.self, from: data),
              AgenticUICatalog.validate(request) else { return nil }
        return request
    }
}

enum AgenticUICatalog {
    static func validate(_ request: AgenticUIRequest) -> Bool {
        let summary = request.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty,
              summary.count <= AgenticUILimits.maxSummaryLength,
              request.blockID.map({ !$0.isEmpty && $0.count <= 256 }) ?? true,
              !request.spec.root.isEmpty,
              request.spec.elements.indices.count <= AgenticUILimits.maxElements,
              request.spec.elements[request.spec.root] != nil else { return false }

        for (id, element) in request.spec.elements {
            guard !id.isEmpty,
                  id.count <= 128,
                  element.children.count <= AgenticUILimits.maxChildren,
                  Set(element.children).count == element.children.count,
                  element.children.allSatisfy({ request.spec.elements[$0] != nil }),
                  element.props.values.allSatisfy(\.stringsAreWithinLimit),
                  validateProps(element, spec: request.spec, elementID: id) else { return false }
        }

        var visiting = Set<String>()
        var visited = Set<String>()
        var deepestVisit: [String: Int] = [:]
        guard visit(
            request.spec.root,
            depth: 1,
            spec: request.spec,
            visiting: &visiting,
            visited: &visited,
            deepestVisit: &deepestVisit
        ) else { return false }
        return visited.count == request.spec.elements.count
    }

    private static func visit(
        _ id: String,
        depth: Int,
        spec: AgenticUISpec,
        visiting: inout Set<String>,
        visited: inout Set<String>,
        deepestVisit: inout [String: Int]
    ) -> Bool {
        guard depth <= AgenticUILimits.maxDepth,
              !visiting.contains(id),
              let element = spec.elements[id] else { return false }
        if let priorDepth = deepestVisit[id], priorDepth >= depth { return true }
        deepestVisit[id] = depth
        visiting.insert(id)
        visited.insert(id)
        for child in element.children {
            guard visit(
                child,
                depth: depth + 1,
                spec: spec,
                visiting: &visiting,
                visited: &visited,
                deepestVisit: &deepestVisit
            ) else {
                return false
            }
        }
        visiting.remove(id)
        return true
    }

    private static func validateProps(
        _ element: AgenticUIElement,
        spec: AgenticUISpec,
        elementID: String
    ) -> Bool {
        let allowed: Set<String>
        switch element.type {
        case .stack:
            allowed = ["axis", "spacing", "alignment"]
            guard optionalString(element.props["axis"], allowed: ["vertical", "horizontal"]),
                  optionalString(element.props["alignment"], allowed: ["leading", "center", "trailing"]),
                  optionalNumber(element.props["spacing"], range: 0...48) else { return false }
        case .card:
            allowed = ["title", "subtitle"]
            guard optionalString(element.props["title"]), optionalString(element.props["subtitle"]) else { return false }
        case .heading:
            allowed = ["text", "level"]
            guard requiredString(element.props["text"]),
                  optionalNumber(element.props["level"], range: 1...3),
                  element.children.isEmpty else { return false }
        case .text:
            allowed = ["text", "style"]
            guard requiredString(element.props["text"]),
                  optionalString(element.props["style"], allowed: ["body", "secondary", "caption"]),
                  element.children.isEmpty else { return false }
        case .metric:
            allowed = ["label", "value", "detail", "trend"]
            guard requiredString(element.props["label"]),
                  scalar(element.props["value"]),
                  optionalString(element.props["detail"]),
                  optionalNumber(element.props["trend"], range: -1_000_000...1_000_000),
                  element.children.isEmpty else { return false }
        case .table:
            allowed = ["title", "columns", "rows"]
            guard optionalString(element.props["title"]),
                  validateTable(element, spec: spec, elementID: elementID),
                  element.children.isEmpty else { return false }
        case .barChart, .lineChart, .donutChart:
            allowed = ["title", "unit", "points"]
            guard requiredString(element.props["title"]),
                  optionalString(element.props["unit"]),
                  validateChart(element, spec: spec, elementID: elementID),
                  element.children.isEmpty else { return false }
        }
        return Set(element.props.keys).isSubset(of: allowed)
    }

    private static func validateChart(
        _ element: AgenticUIElement,
        spec: AgenticUISpec,
        elementID: String
    ) -> Bool {
        let points = spec.chartPoints(for: elementID)
        guard let rawPoints = element.props["points"]?.array,
              !points.isEmpty,
              points.count == rawPoints.count,
              points.count <= AgenticUILimits.maxChartPoints,
              points.allSatisfy({ !$0.label.isEmpty && $0.value.isFinite }),
              Set(points.map(\.id)).count == points.count,
              Set(points.compactMap(\.series)).count <= AgenticUILimits.maxChartSeries else { return false }
        for rawPoint in rawPoints {
            guard let object = rawPoint.object,
                  Set(object.keys).isSubset(of: ["label", "value", "series"]),
                  optionalString(object["series"]) else { return false }
        }
        if element.type == .donutChart {
            return points.allSatisfy { $0.value >= 0 && $0.series == nil }
                && Set(points.map(\.label)).count == points.count
                && points.contains { $0.value > 0 }
        }
        return true
    }

    private static func validateTable(
        _ element: AgenticUIElement,
        spec: AgenticUISpec,
        elementID: String
    ) -> Bool {
        let columns = spec.tableColumns(for: elementID)
        let rows = spec.tableRows(for: elementID)
        guard let rawColumns = element.props["columns"]?.array,
              let rawRows = element.props["rows"]?.array,
              !columns.isEmpty,
              columns.count == rawColumns.count,
              columns.count <= AgenticUILimits.maxTableColumns,
              Set(columns.map(\.key)).count == columns.count,
              rows.count == rawRows.count,
              rows.count <= AgenticUILimits.maxTableRows else { return false }
        for rawColumn in rawColumns {
            guard let object = rawColumn.object,
                  Set(object.keys) == ["key", "label"],
                  requiredString(object["key"]),
                  requiredString(object["label"]) else { return false }
        }
        let keys = Set(columns.map(\.key))
        return rows.allSatisfy { row in
            Set(row.keys).isSubset(of: keys) && row.values.allSatisfy(scalar)
        }
    }

    private static func requiredString(_ value: AgenticUIJSONValue?) -> Bool {
        guard let value = value?.string else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func optionalString(
        _ value: AgenticUIJSONValue?,
        allowed: Set<String>? = nil
    ) -> Bool {
        guard let value else { return true }
        guard let string = value.string else { return false }
        return allowed?.contains(string) ?? true
    }

    private static func optionalNumber(
        _ value: AgenticUIJSONValue?,
        range: ClosedRange<Double>
    ) -> Bool {
        guard let value else { return true }
        guard let number = value.number else { return false }
        return number.isFinite && range.contains(number)
    }

    private static func scalar(_ value: AgenticUIJSONValue?) -> Bool {
        guard let value else { return false }
        switch value {
        case .null, .bool, .number, .string: return true
        case .array, .object: return false
        }
    }
}

enum AgenticUITransportPolicy {
    static func isRenderToolUpdate(_ update: [String: Any]) -> Bool {
        let title = (update["title"] as? String)?.lowercased() ?? ""
        let kind = (update["kind"] as? String)?.lowercased() ?? ""
        return title.contains("bubble_render")
            || title.contains("native visualization")
            || kind == "bubble_render"
    }
}

enum AgenticUIBlockIdentity {
    static func matches(_ candidate: AgenticUIRequest, _ existing: AgenticUIRequest?) -> Bool {
        guard let blockID = candidate.blockID, !blockID.isEmpty else { return false }
        return existing?.blockID == blockID
    }
}
