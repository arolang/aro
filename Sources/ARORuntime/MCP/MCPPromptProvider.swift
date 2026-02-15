// ============================================================
// MCPPromptProvider.swift
// ARO MCP - Prompt Templates
// ============================================================

import Foundation

/// Provides MCP prompts for guided ARO workflows
public struct MCPPromptProvider: Sendable {

    public init() {}

    /// List all available prompts
    public func listPrompts() -> MCPPromptsListResult {
        MCPPromptsListResult(prompts: [
            MCPPrompt(
                name: "create_feature_set",
                description: "Guide to create a new ARO feature set",
                arguments: [
                    MCPPromptArgument(name: "name", description: "Name of the feature set", required: true),
                    MCPPromptArgument(name: "purpose", description: "What the feature set should do", required: false)
                ]
            ),
            MCPPrompt(
                name: "create_http_api",
                description: "Guide to create a contract-first HTTP API with ARO",
                arguments: [
                    MCPPromptArgument(name: "resource", description: "Name of the resource (e.g., 'users', 'orders')", required: true),
                    MCPPromptArgument(name: "operations", description: "CRUD operations needed (e.g., 'list,get,create,update,delete')", required: false)
                ]
            ),
            MCPPrompt(
                name: "create_event_handler",
                description: "Guide to create an event handler feature set",
                arguments: [
                    MCPPromptArgument(name: "event", description: "Name of the event to handle (e.g., 'UserCreated')", required: true),
                    MCPPromptArgument(name: "action", description: "What should happen when the event is received", required: false)
                ]
            ),
            MCPPrompt(
                name: "debug_error",
                description: "Help debug an ARO compilation or runtime error",
                arguments: [
                    MCPPromptArgument(name: "error", description: "The error message", required: true),
                    MCPPromptArgument(name: "code", description: "The ARO code that caused the error", required: false)
                ]
            ),
            MCPPrompt(
                name: "create_plugin",
                description: "Guide to create an ARO plugin in a specific language",
                arguments: [
                    MCPPromptArgument(name: "language", description: "Plugin language: swift, rust, c, python", required: true),
                    MCPPromptArgument(name: "action", description: "Name of the custom action to provide", required: true)
                ]
            ),
            MCPPrompt(
                name: "convert_to_aro",
                description: "Help convert code or requirements to ARO syntax",
                arguments: [
                    MCPPromptArgument(name: "description", description: "What the code should do", required: true),
                    MCPPromptArgument(name: "existing_code", description: "Existing code to convert (optional)", required: false)
                ]
            )
        ])
    }

    /// Get a specific prompt with arguments substituted
    public func getPrompt(name: String, arguments: [String: String]?) -> MCPPromptGetResult? {
        switch name {
        case "create_feature_set":
            return createFeatureSetPrompt(arguments: arguments)
        case "create_http_api":
            return createHttpApiPrompt(arguments: arguments)
        case "create_event_handler":
            return createEventHandlerPrompt(arguments: arguments)
        case "debug_error":
            return debugErrorPrompt(arguments: arguments)
        case "create_plugin":
            return createPluginPrompt(arguments: arguments)
        case "convert_to_aro":
            return convertToAroPrompt(arguments: arguments)
        default:
            return nil
        }
    }

    // MARK: - Prompt Implementations

    private func createFeatureSetPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let name = arguments?["name"] ?? "MyFeature"
        let purpose = arguments?["purpose"] ?? "perform a specific task"

        let content = """
        Create an ARO feature set with the following specifications:

        **Name**: \(name)
        **Purpose**: \(purpose)

        ## ARO Feature Set Guidelines

        1. **Feature Set Structure**:
        ```aro
        (\(name): Business Domain) {
            (* Implementation here *)
        }
        ```

        2. **Statement Pattern**: Every statement follows Action-Result-Object:
        ```aro
        <Action> the <result: qualifier> preposition the <object: qualifier>.
        ```

        3. **Common Actions**:
        - `<Extract>` - Get data from input
        - `<Compute>` - Transform data
        - `<Validate>` - Check data
        - `<Log>` - Output to console
        - `<Return>` - Return result

        4. **Always end with a Return statement**:
        ```aro
        <Return> an <OK: status> for the <result>.
        ```

        ## Example Feature Set

        ```aro
        (\(name): Example) {
            (* Extract input data *)
            <Extract> the <input> from the <request: body>.

            (* Process the data *)
            <Compute> the <result> from the <input>.

            (* Log for debugging *)
            <Log> <result> to the <console>.

            (* Return success *)
            <Return> an <OK: status> with <result>.
        }
        ```

        Please create the feature set implementation for: \(purpose)
        """

        return MCPPromptGetResult(
            description: "Guide to create the '\(name)' feature set",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }

    private func createHttpApiPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let resource = arguments?["resource"] ?? "items"
        let operations = arguments?["operations"] ?? "list,get,create,update,delete"

        let content = """
        Create a contract-first HTTP API for the '\(resource)' resource.

        **Resource**: \(resource)
        **Operations**: \(operations)

        ## Step 1: Create openapi.yaml

        ARO uses contract-first development. Start with the OpenAPI spec:

        ```yaml
        openapi: 3.0.3
        info:
          title: \(resource.capitalized) API
          version: 1.0.0
        paths:
          /\(resource):
            get:
              operationId: list\(resource.capitalized)
              summary: List all \(resource)
            post:
              operationId: create\(resource.capitalized.dropLast())
              summary: Create a new \(resource.dropLast())
              requestBody:
                content:
                  application/json:
                    schema:
                      $ref: '#/components/schemas/\(resource.capitalized.dropLast())Input'
          /\(resource)/{id}:
            get:
              operationId: get\(resource.capitalized.dropLast())
              summary: Get a \(resource.dropLast()) by ID
              parameters:
                - name: id
                  in: path
                  required: true
                  schema:
                    type: string
        ```

        ## Step 2: Create Feature Sets

        Name each feature set after the `operationId`:

        ```aro
        (* GET /\(resource) *)
        (list\(resource.capitalized): \(resource.capitalized) API) {
            <Retrieve> the <\(resource)> from the <\(resource.dropLast())-repository>.
            <Return> an <OK: status> with <\(resource)>.
        }

        (* GET /\(resource)/{id} *)
        (get\(resource.capitalized.dropLast()): \(resource.capitalized) API) {
            <Extract> the <id> from the <pathParameters: id>.
            <Retrieve> the <\(resource.dropLast())> from the <\(resource.dropLast())-repository> where id = <id>.
            <Return> an <OK: status> with <\(resource.dropLast())>.
        }

        (* POST /\(resource) *)
        (create\(resource.capitalized.dropLast()): \(resource.capitalized) API) {
            <Extract> the <data> from the <request: body>.
            <Create> the <\(resource.dropLast())> with <data>.
            <Store> the <\(resource.dropLast())> in the <\(resource.dropLast())-repository>.
            <Return> a <Created: status> with <\(resource.dropLast())>.
        }
        ```

        ## Step 3: Application-Start

        ```aro
        (Application-Start: \(resource.capitalized) Service) {
            <Log> "Starting \(resource.capitalized) API..." to the <console>.
            <Start> the <http-server> with <contract>.
            <Keepalive> the <application> for the <events>.
            <Return> an <OK: status> for the <startup>.
        }
        ```

        Please implement the complete API for: \(resource) with operations: \(operations)
        """

        return MCPPromptGetResult(
            description: "Guide to create HTTP API for '\(resource)'",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }

    private func createEventHandlerPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let event = arguments?["event"] ?? "UserCreated"
        let action = arguments?["action"] ?? "process the event data"

        let content = """
        Create an ARO event handler for the '\(event)' event.

        **Event**: \(event)
        **Action**: \(action)

        ## Event Handler Pattern

        Event handlers have a special naming convention:

        ```aro
        (Descriptive Name: \(event) Handler) {
            (* Extract event data *)
            <Extract> the <data> from the <event: data>.

            (* Process the event *)
            (* ... your logic here ... *)

            (* Always return a status *)
            <Return> an <OK: status> for the <handler>.
        }
        ```

        ## Event Handler Examples

        ### Send notification on UserCreated
        ```aro
        (Send Welcome Email: UserCreated Handler) {
            <Extract> the <user> from the <event: user>.
            <Extract> the <email> from the <user: email>.
            <Send> the <welcome-email> to the <email>.
            <Log> "Welcome email sent" to the <console>.
            <Return> an <OK: status> for the <notification>.
        }
        ```

        ### Update inventory on OrderPlaced
        ```aro
        (Update Inventory: OrderPlaced Handler) {
            <Extract> the <items> from the <event: items>.
            <Update> the <inventory> with <items>.
            <Return> an <OK: status> for the <inventory-update>.
        }
        ```

        ## Emitting Events

        Events are emitted from other feature sets:

        ```aro
        <Emit> a <\(event): event> with <payload>.
        ```

        Please create the event handler for: \(event) to \(action)
        """

        return MCPPromptGetResult(
            description: "Guide to create event handler for '\(event)'",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }

    private func debugErrorPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let error = arguments?["error"] ?? "Unknown error"
        let code = arguments?["code"]

        var content = """
        Help debug this ARO error:

        **Error**: \(error)
        """

        if let code = code {
            content += """


            **Code**:
            ```aro
            \(code)
            ```
            """
        }

        content += """


        ## Common ARO Errors and Solutions

        ### Syntax Errors

        1. **Missing period at end of statement**
           - Every statement must end with `.`
           - Wrong: `<Log> "Hello" to the <console>`
           - Right: `<Log> "Hello" to the <console>.`

        2. **Missing angle brackets**
           - Actions, results, and objects use `<>`
           - Wrong: `Extract the user from the request`
           - Right: `<Extract> the <user> from the <request>.`

        3. **Invalid preposition**
           - Each action has valid prepositions
           - Check with `aro_actions` tool

        ### Runtime Errors

        1. **Variable not found**
           - Variables must be defined before use
           - Check spelling and qualifier

        2. **Repository not found**
           - Repository names use `{entity}-repository` pattern
           - Example: `user-repository`, `order-repository`

        3. **No Application-Start**
           - Every application needs exactly one `Application-Start` feature set

        ### HTTP Errors

        1. **Route not found**
           - Feature set name must match `operationId` in openapi.yaml
           - Check case sensitivity

        2. **Missing openapi.yaml**
           - Contract-first: HTTP requires openapi.yaml file

        Please analyze the error and suggest a fix.
        """

        return MCPPromptGetResult(
            description: "Help debug ARO error",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }

    private func createPluginPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let language = arguments?["language"] ?? "swift"
        let action = arguments?["action"] ?? "MyCustomAction"

        let content = """
        Create an ARO plugin in \(language) providing the '\(action)' action.

        **Language**: \(language)
        **Action**: \(action)

        ## Plugin Structure

        ```
        Plugins/
        └── plugin-\(language)-\(action.lowercased())/
            ├── plugin.yaml      # Plugin manifest
            ├── src/             # Source files
            └── README.md        # Documentation
        ```

        ## plugin.yaml

        ```yaml
        name: plugin-\(language)-\(action.lowercased())
        version: 1.0.0
        description: Provides \(action) action
        aro-version: '>=0.2.0'

        provides:
          - type: \(language)-plugin
            entry: src/plugin
        ```

        ## Implementation by Language

        \(pluginImplementation(for: language, action: action))

        ## Using the Plugin in ARO

        ```aro
        (Use Plugin: Demo) {
            <\(action)> the <result> from the <input>.
            <Return> an <OK: status> with <result>.
        }
        ```

        Please create the complete plugin implementation.
        """

        return MCPPromptGetResult(
            description: "Guide to create \(language) plugin for '\(action)'",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }

    private func pluginImplementation(for language: String, action: String) -> String {
        switch language.lowercased() {
        case "swift":
            return """
            ### Swift Plugin

            ```swift
            import Foundation

            @_cdecl("aro_plugin_info")
            public func aro_plugin_info() -> UnsafeMutablePointer<CChar> {
                let info = \"""
                {"name": "plugin-swift-\(action.lowercased())", "version": "1.0.0", "actions": ["\(action)"]}
                \"""
                return strdup(info)!
            }

            @_cdecl("aro_plugin_execute")
            public func aro_plugin_execute(action: UnsafePointer<CChar>, input: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar> {
                let actionName = String(cString: action)
                let inputJson = String(cString: input)

                if actionName == "\(action)" {
                    // Your implementation here
                    let result = "{\\"output\\": \\"processed\\"}"
                    return strdup(result)!
                }

                return strdup("{\\"error\\": \\"Unknown action\\"}")!
            }

            @_cdecl("aro_plugin_free")
            public func aro_plugin_free(ptr: UnsafeMutablePointer<CChar>) {
                free(ptr)
            }
            ```
            """

        case "rust":
            return """
            ### Rust Plugin

            ```rust
            use std::ffi::{CStr, CString};
            use std::os::raw::c_char;

            #[no_mangle]
            pub extern "C" fn aro_plugin_info() -> *mut c_char {
                let info = r#"{"name": "plugin-rust-\(action.lowercased())", "version": "1.0.0", "actions": ["\(action)"]}"#;
                CString::new(info).unwrap().into_raw()
            }

            #[no_mangle]
            pub extern "C" fn aro_plugin_execute(action: *const c_char, input: *const c_char) -> *mut c_char {
                let action_name = unsafe { CStr::from_ptr(action).to_str().unwrap() };
                let _input_json = unsafe { CStr::from_ptr(input).to_str().unwrap() };

                let result = if action_name == "\(action)" {
                    // Your implementation here
                    r#"{"output": "processed"}"#
                } else {
                    r#"{"error": "Unknown action"}"#
                };

                CString::new(result).unwrap().into_raw()
            }

            #[no_mangle]
            pub extern "C" fn aro_plugin_free(ptr: *mut c_char) {
                if !ptr.is_null() {
                    unsafe { drop(CString::from_raw(ptr)); }
                }
            }
            ```
            """

        case "c":
            return """
            ### C Plugin

            ```c
            #include <stdlib.h>
            #include <string.h>

            char* aro_plugin_info(void) {
                const char* info = "{\\"name\\": \\"plugin-c-\(action.lowercased())\\", \\"version\\": \\"1.0.0\\", \\"actions\\": [\\"\(action)\\"]}";
                return strdup(info);
            }

            char* aro_plugin_execute(const char* action, const char* input) {
                if (strcmp(action, "\(action)") == 0) {
                    // Your implementation here
                    return strdup("{\\"output\\": \\"processed\\"}");
                }
                return strdup("{\\"error\\": \\"Unknown action\\"}");
            }

            void aro_plugin_free(char* ptr) {
                if (ptr) free(ptr);
            }
            ```
            """

        case "python":
            return """
            ### Python Plugin

            ```python
            import json

            def aro_plugin_info():
                return json.dumps({
                    "name": "plugin-python-\(action.lowercased())",
                    "version": "1.0.0",
                    "actions": ["\(action)"]
                })

            def aro_action_\(action.lowercased())(input_data):
                # Your implementation here
                return {"output": "processed"}
            ```
            """

        default:
            return "Unknown language: \(language). Supported: swift, rust, c, python"
        }
    }

    private func convertToAroPrompt(arguments: [String: String]?) -> MCPPromptGetResult {
        let description = arguments?["description"] ?? "a task"
        let existingCode = arguments?["existing_code"]

        var content = """
        Convert the following requirements to ARO code:

        **Description**: \(description)
        """

        if let code = existingCode {
            content += """


            **Existing Code**:
            ```
            \(code)
            ```
            """
        }

        content += """


        ## ARO Conversion Guidelines

        1. **Think in features, not functions**
           - Each capability becomes a feature set
           - Name describes the business activity

        2. **Use Action-Result-Object pattern**
           ```aro
           <Action> the <result> preposition the <object>.
           ```

        3. **Data flows through statements**
           - Extract input data
           - Transform/compute as needed
           - Return or export results

        4. **Common conversions**:
           - Function → Feature Set
           - Variable assignment → `<Compute>` or `<Extract>`
           - If statement → `<When>` guard
           - Return → `<Return>`
           - Console.log → `<Log> ... to the <console>.`

        ## Example Conversion

        **JavaScript**:
        ```javascript
        function calculateTotal(items) {
          let sum = 0;
          for (const item of items) {
            sum += item.price * item.quantity;
          }
          console.log("Total:", sum);
          return sum;
        }
        ```

        **ARO**:
        ```aro
        (Calculate Total: Order Processing) {
            <Extract> the <items> from the <request: items>.
            <Compute> the <total> from <items> using sum(price * quantity).
            <Log> <total> to the <console>.
            <Return> an <OK: status> with <total>.
        }
        ```

        Please convert the requirements to ARO.
        """

        return MCPPromptGetResult(
            description: "Convert requirements to ARO",
            messages: [
                MCPPromptMessage(role: "user", content: .text(content))
            ]
        )
    }
}
