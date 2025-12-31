# Chapter 15: HTTP Feature Sets

*"Every endpoint tells a story."*

---

## 12.1 HTTP Handler Basics

HTTP feature sets handle requests routed through the OpenAPI contract. When a request matches a path and method defined in your specification, the corresponding feature set executes with the request data available for extraction.

The feature set name must exactly match the operationId from your OpenAPI specification. This matching is case-sensitive. If your specification defines an operation with operationId "getUser", you must create a feature set named "getUser"—not "GetUser", not "get-user", not "getuser". The names must be identical.

A typical HTTP handler follows a predictable pattern. It extracts data from the request, performs some processing, and returns a response. The extraction pulls relevant information from path parameters, query parameters, headers, or the request body. The processing might retrieve data from repositories, create new entities, validate inputs, or compute results. The response returns an appropriate status code with optional data.

The business activity (the text after the colon in the feature set declaration) can be anything descriptive. Common choices include the name of the API or service, a description of the resource being managed, or a broader category that groups related operations. This text appears in logs and helps readers understand the context.

---

## 12.2 CRUD Operations

Most HTTP APIs implement CRUD operations—Create, Read, Update, and Delete—for their resources. Each operation has a characteristic pattern in ARO.

List operations retrieve collections of resources. They typically extract pagination parameters from the query string, retrieve matching records from a repository, and return the collection. The response often includes metadata about the total count, current page, and whether more records exist.

Read operations retrieve a single resource by identifier. They extract the identifier from the path, retrieve the matching record, and return it. If no record matches, the runtime generates a not-found error that becomes a 404 response.

Create operations make new resources. They extract data from the request body, validate it against a schema, create the new entity, store it in a repository, and return it with a Created status. They often emit an event so other parts of the system can react to the new resource.

Update operations modify existing resources. They extract the identifier from the path and the update data from the body, retrieve the existing record, merge the updates, store the result, and return the updated entity. Full updates (PUT) replace all fields; partial updates (PATCH) modify only the provided fields.

Delete operations remove resources. They extract the identifier from the path, delete the matching record from the repository, and return a NoContent status indicating success. They often emit an event so other parts of the system can react to the deletion.

---

## 12.3 Request Data Access

HTTP handlers have access to various parts of the incoming request through special context identifiers. Each type of request data has its own identifier and access pattern.

Path parameters are values embedded in the URL path based on the template defined in your OpenAPI specification. A template like /users/{id}/orders/{orderId} defines two path parameters: "id" and "orderId". You extract these using the pathParameters identifier with the parameter name as a qualifier.

Query parameters are the key-value pairs in the URL's query string. A request to /search?q=widgets&page=2 has query parameters "q" and "page". You extract these using the queryParameters identifier. Query parameters are typically optional; extracting one that was not provided yields an empty value rather than an error.

The request body contains data sent with POST, PUT, and PATCH requests. For JSON content, the runtime parses the body into a structured object. You extract it using the request identifier with "body" as the qualifier. You can then extract individual fields from the body using additional qualifiers.

Headers contain metadata about the request. Authentication tokens typically arrive in the Authorization header. Content type information appears in the Content-Type header. Custom headers can carry application-specific data. You extract headers using the headers identifier with the header name as a qualifier.

The full request object provides access to additional information including the HTTP method, the original path, and all headers as a collection. This is useful for debugging or when you need information not available through the specific accessors.

---

## 12.4 Response Patterns

ARO provides a variety of status qualifiers for different response scenarios. Choosing the right status communicates the outcome clearly to clients.

Success responses indicate the operation completed as expected. OK (200) is the standard success status for retrieving data or completing an operation. Created (201) indicates a new resource was created, typically used with POST requests. Accepted (202) indicates the request was received for asynchronous processing. NoContent (204) indicates success with no response body, typically used for DELETE operations.

Error responses indicate something prevented successful completion. BadRequest (400) indicates the client sent invalid data. Unauthorized (401) indicates authentication is required. Forbidden (403) indicates the client lacks permission for the operation. NotFound (404) indicates the requested resource does not exist. Conflict (409) indicates the request conflicts with current state, such as creating a duplicate.

The response body can be a single object, an array, or an object literal constructed inline. For single resources, return the entity directly. For collections, return an array or a structured object with the array and metadata. For errors, return a structured object with error details.

Collection responses often include pagination metadata. Beyond the data array, include the total count, current page, page size, and whether more pages exist. This information helps clients navigate through large result sets.

---

## 12.5 Authentication and Authorization

Many APIs require authentication to identify the caller and authorization to verify permissions. ARO handles these concerns through request data extraction and validation.

Authentication typically involves extracting a token from the Authorization header, validating it against an authentication service or by verifying its signature, and extracting identity information such as a user identifier or role list. The validated identity becomes available for use in subsequent statements.

Authorization checks whether the authenticated identity has permission for the requested operation. This might involve checking a role list against required roles, querying a permissions service, or applying custom authorization logic. If authorization fails, you return a Forbidden status.

The pattern is to extract and validate authentication early in the feature set, before performing any business logic. This ensures that unauthenticated or unauthorized requests fail fast with appropriate error responses rather than partially executing before failing.

Custom actions can encapsulate complex authentication and authorization logic. A ValidateToken action might handle JWT verification, signature checking, and expiration validation. A CheckPermission action might query a permissions database or evaluate policy rules. These actions keep your feature sets focused on business logic.

---

## 12.6 Nested Resources

APIs often model relationships between resources through nested URL paths. A user has orders; an order belongs to a user. The path /users/{userId}/orders represents the orders belonging to a specific user.

Nested resource paths involve multiple path parameters. You extract each parameter by name. The parent identifier constrains which records to consider; the child identifier (if present) identifies a specific record within that constraint.

When listing nested resources, include the parent identifier in your repository query. When creating nested resources, include the parent identifier in the stored record. When retrieving or modifying specific nested resources, verify that the child belongs to the specified parent.

The nesting expresses ownership and access control. A request for /users/123/orders/456 should only succeed if order 456 actually belongs to user 123. Your where clause should include both constraints to enforce this relationship.

### Complete Nested Resource Example

Here is a complete example for managing order items as a nested resource under orders:

**OpenAPI specification (partial):**
```yaml
paths:
  /orders/{orderId}/items:
    get:
      operationId: listOrderItems
    post:
      operationId: createOrderItem
  /orders/{orderId}/items/{itemId}:
    get:
      operationId: getOrderItem
    put:
      operationId: updateOrderItem
    delete:
      operationId: deleteOrderItem
```

**ARO handlers:**
```aro
(* List all items for an order *)
(listOrderItems: Order API) {
    <Extract> the <order-id> from the <pathParameters: orderId>.

    (* Verify order exists *)
    <Retrieve> the <order> from the <order-repository> where id = <order-id>.

    (* Get items for this order *)
    <Retrieve> the <items> from the <item-repository> where orderId = <order-id>.

    <Return> an <OK: status> with <items>.
}

(* Get a specific item, verifying it belongs to the order *)
(getOrderItem: Order API) {
    <Extract> the <order-id> from the <pathParameters: orderId>.
    <Extract> the <item-id> from the <pathParameters: itemId>.

    (* Retrieve with both constraints to enforce ownership *)
    <Retrieve> the <item> from the <item-repository>
        where id = <item-id> and orderId = <order-id>.

    <Return> an <OK: status> with <item>.
}

(* Create a new item for an order *)
(createOrderItem: Order API) {
    <Extract> the <order-id> from the <pathParameters: orderId>.
    <Extract> the <item-data> from the <request: body>.

    (* Verify order exists before adding item *)
    <Retrieve> the <order> from the <order-repository> where id = <order-id>.

    (* Create item with parent reference *)
    <Create> the <item> with {
        orderId: <order-id>,
        productId: <item-data>.productId,
        quantity: <item-data>.quantity,
        price: <item-data>.price
    }.

    <Store> the <item> in the <item-repository>.

    (* Recalculate order total *)
    <Emit> an <OrderItemAdded: event> with { order: <order>, item: <item> }.

    <Return> a <Created: status> with <item>.
}

(* Delete an item from an order *)
(deleteOrderItem: Order API) {
    <Extract> the <order-id> from the <pathParameters: orderId>.
    <Extract> the <item-id> from the <pathParameters: itemId>.

    (* Verify ownership before deletion *)
    <Retrieve> the <item> from the <item-repository>
        where id = <item-id> and orderId = <order-id>.

    <Delete> the <item> from the <item-repository>.

    <Emit> an <OrderItemRemoved: event> with { orderId: <order-id>, itemId: <item-id> }.

    <Return> a <NoContent: status> for the <deletion>.
}
```

Key patterns in this example:
- **Parent verification**: Always verify the parent exists before creating nested resources
- **Ownership enforcement**: Include both parent and child IDs in where clauses
- **Event emission**: Notify other handlers when nested resources change

Deep nesting (more than two levels) can make URLs unwieldy and logic complex. Consider whether deep nesting is necessary or whether flatter alternatives would serve your API design better.

---

## 12.7 Best Practices

Keep handlers focused on single responsibilities. A handler that retrieves a user should not also retrieve their orders, payments, and statistics. If clients need aggregated data, provide a separate endpoint or use a pattern like GraphQL that's designed for flexible queries.

Use consistent naming across your API. If you name one operation "listUsers", name similar operations "listOrders" and "listProducts", not "getOrders" or "findProducts". Consistency makes your API predictable and easier to learn.

Emit events for side effects rather than performing them inline. When creating a user, emit a UserCreated event rather than directly sending welcome emails, updating analytics, and notifying administrators. Event handlers keep side effects separate and make the core logic clearer.

Validate inputs early. Extract and validate request data at the beginning of your feature set, before performing any business logic. This ensures that invalid requests fail immediately with clear error messages rather than partially executing.

Return appropriate status codes. Use Created for successful POST requests that create resources. Use NoContent for successful DELETE requests. Use specific error codes rather than generic 500 responses. Clients rely on status codes to understand outcomes.

---

*Next: Chapter 16 — Request/Response Patterns*
