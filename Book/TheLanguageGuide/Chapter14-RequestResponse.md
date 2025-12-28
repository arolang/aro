# Chapter 14: Advanced HTTP Patterns

*"Beyond CRUD lies transformation."*

---

> **See Chapter 13** for HTTP handler basics including the request-response cycle, CRUD operations, request data access, and basic response patterns.

This chapter covers advanced patterns that build on the fundamentals.

---

## 13.1 Transformation Patterns

Transformation is the heart of request processing. You take input data and produce output data through various operations.

**Entity creation** transforms raw input into domain objects. You extract unstructured data from the request, perhaps validate it, and create a typed entity. The created entity has a well-defined structure and possibly additional computed properties.

```aro
(createProduct: Product API) {
    <Extract> the <data> from the <request: body>.

    (* Transform raw input into domain entity *)
    <Create> the <product> with {
        name: <data>.name,
        slug: <data>.name.lowercase.replace(" ", "-"),
        price: <data>.price,
        createdAt: <current-timestamp>
    }.

    <Store> the <product> in the <product-repository>.
    <Return> a <Created: status> with <product>.
}
```

**Data enrichment** augments core data with related information. You retrieve a primary entity and then retrieve additional entities referenced by the primary one.

```aro
(getOrderDetails: Order API) {
    <Extract> the <id> from the <pathParameters: id>.

    (* Retrieve primary entity *)
    <Retrieve> the <order> from the <order-repository> where id = <id>.

    (* Enrich with related data *)
    <Retrieve> the <customer> from the <customer-repository> where id = <order>.customerId.
    <Retrieve> the <items> from the <item-repository> where orderId = <id>.

    (* Combine into enriched response *)
    <Create> the <response> with {
        order: <order>,
        customer: <customer>,
        items: <items>
    }.

    <Return> an <OK: status> with <response>.
}
```

**Aggregation** computes summary values from collections.

```aro
(getOrderSummary: Analytics API) {
    <Extract> the <customer-id> from the <pathParameters: customerId>.

    <Retrieve> the <orders> from the <order-repository> where customerId = <customer-id>.

    (* Compute aggregates *)
    <Compute> the <total-count: count> from the <orders>.
    <Compute> the <total-value> from the <orders>.total.sum.

    <Create> the <summary> with {
        customerId: <customer-id>,
        orderCount: <total-count>,
        totalValue: <total-value>
    }.

    <Return> an <OK: status> with <summary>.
}
```

**Format transformation** converts between representations.

```aro
(exportProducts: Export API) {
    <Retrieve> the <products> from the <product-repository>.

    (* Transform each product to export format *)
    <Transform> the <export-data> from the <products> with {
        sku: product.id,
        title: product.name,
        amount: product.price.format("0.00")
    }.

    <Return> an <OK: status> with <export-data>.
}
```

---

## 13.2 Advanced Operation Patterns

Several patterns recur across APIs and have established solutions in ARO.

**Get-or-create** retrieves an existing resource if it exists or creates a new one if it does not. This pattern is useful for idempotent operations.

```aro
(ensureCustomer: Customer API) {
    <Extract> the <email> from the <request: body>.

    (* Try to find existing *)
    <Retrieve> the <existing> from the <customer-repository> where email = <email>.

    (* Return existing if found *)
    <Return> an <OK: status> with <existing> when <existing> is not empty.

    (* Create new if not found *)
    <Create> the <customer> with { email: <email>, createdAt: <current-timestamp> }.
    <Store> the <customer> in the <customer-repository>.
    <Return> a <Created: status> with <customer>.
}
```

**Upsert** updates an existing resource if found or creates it if not.

```aro
(upsertPreferences: Preferences API) {
    <Extract> the <user-id> from the <pathParameters: userId>.
    <Extract> the <prefs> from the <request: body>.

    <Retrieve> the <existing> from the <preferences-repository> where userId = <user-id>.

    (* Update if exists *)
    <Update> the <existing> with <prefs> when <existing> is not empty.
    <Store> the <existing> in the <preferences-repository> when <existing> is not empty.
    <Return> an <OK: status> with <existing> when <existing> is not empty.

    (* Create if not exists *)
    <Create> the <new-prefs> with { userId: <user-id>, settings: <prefs> }.
    <Store> the <new-prefs> in the <preferences-repository>.
    <Return> a <Created: status> with <new-prefs>.
}
```

**Bulk operations** process multiple items in a single request.

```aro
(bulkCreateProducts: Product API) {
    <Extract> the <items> from the <request: body>.

    <Create> the <results> with [].

    for each <item> in <items> {
        <Create> the <product> with <item>.
        <Store> the <product> in the <product-repository>.
        <Append> the <product> to the <results>.
    }

    <Return> a <Created: status> with { created: <results>.length, items: <results> }.
}
```

**Search with filters** handles complex queries through a single endpoint.

```aro
(searchProducts: Search API) {
    <Extract> the <query> from the <queryParameters: q>.
    <Extract> the <category> from the <queryParameters: category>.
    <Extract> the <min-price> from the <queryParameters: minPrice>.
    <Extract> the <max-price> from the <queryParameters: maxPrice>.

    (* Build query from provided filters *)
    <Retrieve> the <products> from the <product-repository>
        where name contains <query>
        and category = <category>
        and price >= <min-price>
        and price <= <max-price>.

    <Return> an <OK: status> with <products>.
}
```

---

## 13.3 Response Headers

Beyond the status code and body, responses can include headers that provide additional metadata.

**Content disposition** controls how browsers handle downloads:

```aro
(downloadReport: Reports API) {
    <Extract> the <id> from the <pathParameters: id>.
    <Retrieve> the <report> from the <report-repository> where id = <id>.

    <Return> an <OK: status> with <report>.content
        with header "Content-Disposition" = "attachment; filename=\"report.pdf\"".
}
```

**Cache control** tells clients how long to cache responses:

```aro
(getStaticConfig: Config API) {
    <Retrieve> the <config> from the <config-repository>.

    <Return> an <OK: status> with <config>
        with header "Cache-Control" = "public, max-age=3600".
}
```

**Custom headers** carry application-specific metadata:

```aro
(listItems: Items API) {
    <Extract> the <page> from the <queryParameters: page>.
    <Retrieve> the <items> from the <item-repository> page <page>.
    <Compute> the <total: count> from the <item-repository>.

    <Return> an <OK: status> with <items>
        with header "X-Total-Count" = <total>
        with header "X-Page" = <page>.
}
```

---

## 13.4 Pagination Patterns

Large collections require pagination to avoid overwhelming clients and servers.

**Offset-based pagination** uses page numbers:

```aro
(listProducts: Product API) {
    <Extract> the <page> from the <queryParameters: page>.
    <Extract> the <size> from the <queryParameters: size>.

    <Create> the <page-num> with <page> or 1.
    <Create> the <page-size> with <size> or 20.

    <Retrieve> the <products> from the <product-repository>
        offset (<page-num> - 1) * <page-size>
        limit <page-size>.

    <Compute> the <total: count> from the <product-repository>.

    <Create> the <response> with {
        data: <products>,
        meta: {
            page: <page-num>,
            pageSize: <page-size>,
            totalItems: <total>,
            totalPages: (<total> / <page-size>).ceiling
        }
    }.

    <Return> an <OK: status> with <response>.
}
```

**Cursor-based pagination** uses opaque tokens for stable pagination:

```aro
(listActivities: Activity API) {
    <Extract> the <cursor> from the <queryParameters: cursor>.
    <Extract> the <limit> from the <queryParameters: limit>.

    <Create> the <page-limit> with <limit> or 50.

    <Retrieve> the <activities> from the <activity-repository>
        after <cursor>
        limit <page-limit> + 1.

    (* Check if there are more results *)
    <Create> the <has-more> with <activities>.length > <page-limit>.
    <Create> the <items> with <activities>.take(<page-limit>).
    <Create> the <next-cursor> with <items>.last.id when <has-more>.

    <Create> the <response> with {
        data: <items>,
        nextCursor: <next-cursor>
    }.

    <Return> an <OK: status> with <response>.
}
```

---

## 13.5 Best Practices

**Use meaningful response structures.** Consistent response shapes across your API make client development easier. Consider wrapping data in a "data" field and including metadata in a "meta" field.

**Handle edge cases explicitly.** What happens when a list endpoint finds no matching items—an empty array or a 404? What happens when an optional related resource is missing? Decide these behaviors intentionally and implement them consistently.

**Document your response shapes.** The OpenAPI specification should document not just the types but also the structure and meaning of responses. Good documentation reduces client development time and support requests.

---

*Next: Chapter 15 — Built-in Services*
