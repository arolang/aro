# Chapter 15: Request/Response Patterns

*"Input, transform, output. The rhythm of every API."*

---

## 13.1 The Request-Response Cycle

<div style="text-align: center; margin: 2em 0;">
<svg width="400" height="100" viewBox="0 0 400 100" xmlns="http://www.w3.org/2000/svg">  <!-- Extract -->  <rect x="20" y="30" width="90" height="40" rx="5" fill="#dbeafe" stroke="#3b82f6" stroke-width="2"/>  <text x="65" y="48" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#1e40af">EXTRACT</text>  <text x="65" y="62" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#3b82f6">path, query, body</text>  <!-- Arrow -->  <line x1="110" y1="50" x2="140" y2="50" stroke="#6b7280" stroke-width="2"/>  <polygon points="140,50 133,45 133,55" fill="#6b7280"/>  <!-- Process -->  <rect x="145" y="30" width="90" height="40" rx="5" fill="#dcfce7" stroke="#22c55e" stroke-width="2"/>  <text x="190" y="48" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#166534">PROCESS</text>  <text x="190" y="62" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#22c55e">validate, transform</text>  <!-- Arrow -->  <line x1="235" y1="50" x2="265" y2="50" stroke="#6b7280" stroke-width="2"/>  <polygon points="265,50 258,45 258,55" fill="#6b7280"/>  <!-- Return -->  <rect x="270" y="30" width="90" height="40" rx="5" fill="#fce7f3" stroke="#ec4899" stroke-width="2"/>  <text x="315" y="48" text-anchor="middle" font-family="sans-serif" font-size="10" font-weight="bold" fill="#9d174d">RETURN</text>  <text x="315" y="62" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#ec4899">status + data</text>  <!-- Labels below -->  <text x="65" y="88" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#9ca3af">input</text>  <text x="190" y="88" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#9ca3af">business logic</text>  <text x="315" y="88" text-anchor="middle" font-family="sans-serif" font-size="8" fill="#9ca3af">output</text></svg>
</div>

Every HTTP handler follows a fundamental cycle: receive a request, process it, and return a response. This cycle structures how you think about and write HTTP feature sets in ARO.

The cycle begins with extraction. Data arrives in the request through various channels—path parameters embedded in the URL, query parameters in the query string, headers containing metadata, and a body containing the primary payload. Your feature set pulls out the pieces it needs using Extract actions.

The middle of the cycle is processing. This is where your business logic lives. You might validate the extracted data against schemas or business rules. You might retrieve existing data from repositories. You might create new entities, compute derived values, or transform data between formats. You might store results or emit events.

The cycle concludes with the response. You return a status indicating the outcome and optionally include data in the response body. The status code communicates success or failure; the body provides details. The runtime serializes your response and sends it to the client.

This cycle is the same regardless of what your API does. A simple health check endpoint and a complex multi-step transaction both follow the same pattern: extract, process, return.

---

## 13.2 Extraction Patterns

Extraction is the first step in handling any request. You need to get data out of the request and into local bindings where you can work with it.

Simple extraction pulls a single value from a known location. Extracting a user identifier from path parameters, a search query from query parameters, or an authentication token from headers are all simple extractions. Each uses the Extract action with the appropriate context identifier and qualifier.

Nested extraction navigates into structured data. The request body is often a JSON object with nested properties. You can extract the entire body and then extract individual fields from it, or you can use chained qualifiers to navigate directly to nested values.

Default values handle optional data. Query parameters are typically optional—clients may or may not include them. When you extract an optional parameter, you might get an empty value. You can use the Create action with an "or" clause to provide a default when the extracted value is missing.

Multiple extractions gather all the data you need. A complex handler might extract several path parameters, multiple query parameters, the request body, and one or more headers. Each extraction creates a binding that subsequent statements can use.

The pattern is to perform all extractions early in the feature set, before any processing logic. This makes it clear what data the handler needs and ensures that missing required data causes immediate failure rather than partial processing.

---

## 13.3 Validation Patterns

Validation ensures that extracted data meets expectations before you use it in business logic. Invalid data caught early produces clear error messages; invalid data caught late produces confusing failures.

Schema validation checks that data conforms to a defined structure. OpenAPI specifications include schemas for request bodies, and ARO can validate against these schemas. The Validate action compares data against a schema and fails if the data does not conform.

Business rule validation checks constraints beyond structure. A quantity must be positive. A date range must have the start before the end. An email must be in a valid format. These rules express business requirements that pure schema validation cannot capture.

Cross-field validation checks relationships between multiple values. A password confirmation must match the password. A shipping address is required when the delivery method is not pickup. These validations involve multiple extracted values and their relationships.

Custom validation actions encapsulate complex validation logic. When validation rules are elaborate or shared across multiple handlers, implementing them as custom actions keeps your feature sets focused on the business flow rather than validation details.

---

## 13.4 Transformation Patterns

Transformation is the heart of request processing. You take input data and produce output data through various operations.

Entity creation transforms raw input into domain objects. You extract unstructured data from the request, perhaps validate it, and create a typed entity. The created entity has a well-defined structure and possibly additional computed properties.

Data enrichment augments core data with related information. You retrieve a primary entity and then retrieve additional entities referenced by the primary one. The enriched result combines the primary entity with its related data.

Aggregation computes summary values from collections. You retrieve a set of records and compute totals, counts, averages, or other aggregate values. The response includes these computed values rather than or in addition to the raw records.

Format transformation converts between representations. You might transform an internal entity into an API response format, convert between date representations, or restructure nested data into a flat format.

Each transformation takes bound values as input and produces new bindings as output. The sequence of transformations builds up the data needed for the response.

---

## 13.5 Response Patterns

Response patterns determine how you communicate outcomes to clients. The combination of status code and response body tells clients what happened and provides any resulting data.

Success with data returns a status indicating success along with the relevant data. For retrievals, this is typically OK with the retrieved entity. For creations, this is typically Created with the new entity. The data might be a single object, an array, or a structured object containing data and metadata.

Success without data indicates the operation completed but there is nothing to return. Delete operations typically use NoContent because the deleted resource no longer exists. Some update operations might also return NoContent if the updated state is not needed by the client.

Collection responses return multiple items, often with pagination metadata. Beyond the array of items, include information about the total count, current page, page size, and whether additional pages exist. This metadata helps clients navigate large result sets.

Error responses indicate what went wrong. The status code categorizes the error—client error versus server error, not found versus forbidden. The response body provides details including an error message and possibly additional context like field-level validation errors.

Structured responses maintain consistency across endpoints. Rather than returning raw data for success and structured objects for errors, consider always returning a consistent structure with "data" and "error" fields, or "data" and "meta" fields. Consistency makes your API easier for clients to consume.

---

## 13.6 Common Patterns

Several patterns recur across APIs and have established solutions in ARO.

Get-or-create retrieves an existing resource if it exists or creates a new one if it does not. This pattern is useful for idempotent operations where clients want to ensure a resource exists without caring whether it was already present.

Upsert updates an existing resource if found or creates it if not. Unlike get-or-create, upsert applies updates to existing resources rather than returning them unchanged. The identifier might be a natural key like an email address rather than a generated identifier.

Bulk operations process multiple items in a single request. Creating, updating, or deleting multiple resources at once reduces round trips compared to processing each item individually. The response might summarize results rather than returning all processed items.

Search with filters handles complex queries. Rather than defining separate endpoints for each query variation, a single search endpoint accepts filter parameters that constrain the results. The handler builds a query from the provided filters and executes it against an index or database.

---

## 13.7 Response Headers

Beyond the status code and body, responses can include headers that provide additional metadata or instructions to clients.

Content disposition headers control how browsers handle downloaded files. For file downloads, you set the Content-Disposition header to indicate that the response should be saved as a file with a particular name.

Cache control headers tell clients and intermediaries how long to cache the response. Setting appropriate cache headers reduces load on your server and improves client performance for responses that do not change frequently.

Custom headers can carry application-specific metadata. Rate limit information, correlation identifiers, and pagination links are examples of data that might travel in headers rather than the body.

The Return action can include header specifications that the runtime applies to the HTTP response. Headers are key-value pairs that augment the response status and body.

---

## 13.8 Best Practices

Extract and validate early. Get all the data you need from the request at the beginning of your handler. Validate it immediately after extraction. This pattern ensures that invalid requests fail fast with clear errors.

Use meaningful response structures. Consistent response shapes across your API make client development easier. Consider standard patterns like wrapping data in a "data" field and including metadata in a "meta" field.

Be consistent across endpoints. If one endpoint returns pagination in a particular format, all endpoints with pagination should use the same format. If one endpoint includes error details in a particular structure, all endpoints should use the same structure.

Document your response shapes. Clients need to know what to expect from your API. The OpenAPI specification should document not just the types but also the structure and meaning of responses. Good documentation reduces client development time and support requests.

Handle edge cases explicitly. What happens when a list endpoint finds no matching items—an empty array or a 404? What happens when an optional related resource is missing? Decide these behaviors intentionally and implement them consistently.

---

*Next: Chapter 16 — Built-in Services*
