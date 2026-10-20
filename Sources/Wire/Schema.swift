/// Small builders for the JSON Schema of tool inputs.
public enum Schema {
    public static func object(_ properties: [String: JSON], required: [String] = [], closed: Bool = true) -> JSON {
        var schema: [String: JSON] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        if closed { schema["additionalProperties"] = false }
        return .object(schema)
    }

    public static func text(_ about: String) -> JSON { ["type": "string", "description": .string(about)] }
    public static func flag(_ about: String) -> JSON { ["type": "boolean", "description": .string(about)] }
    public static func whole(_ about: String) -> JSON { ["type": "integer", "description": .string(about)] }
    public static func decimal(_ about: String) -> JSON { ["type": "number", "description": .string(about)] }

    public static func choice(_ values: [String], _ about: String) -> JSON {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(about)]
    }

    public static func list(of item: JSON, _ about: String) -> JSON { ["type": "array", "items": item, "description": .string(about)] }
    public static func texts(_ about: String) -> JSON { list(of: ["type": "string"], about) }
    public static func wholes(_ about: String) -> JSON { list(of: ["type": "integer"], about) }

    /// A value that may also be JSON null, for "clear this field".
    public static func clearable(_ schema: JSON) -> JSON {
        guard case .object(var fields) = schema, let type = fields["type"] else { return schema }
        fields["type"] = [type, "null"]
        return .object(fields)
    }

    /// Free-form: anything goes, the description says what.
    public static func any(_ about: String) -> JSON { ["description": .string(about)] }
}
