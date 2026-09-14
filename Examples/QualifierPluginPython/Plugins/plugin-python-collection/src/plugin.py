"""
ARO Plugin - Python Collection Qualifiers

This plugin provides collection qualifiers for ARO.
Uses the ARO Plugin SDK decorator API.

## What a qualifier handler returns

**The bare transformed value** — not a dict wrapping it.

`export_abi`'s `aro_plugin_qualifier` wraps whatever the handler returns in
`{"result": ...}` on its own, and the runtime's `QualifierOutput` decoder reads
`result` and hands back its contents verbatim. So returning `{"result": x}`
here produced `{"result": {"result": x}}` on the wire, and
`Compute the <sorted: Collections.sort> from <numbers>.` bound the *dict*
`{"result": [1, 2, 3]}` instead of the list — which is how this example came to
print `result: 1, 2, 3, 5, 8, 9` (GitLab #551).

Errors go through `raise`, not through a returned `{"error": ...}`: the wrapper
turns an exception into `{"error": str(e)}`, which is the shape the runtime
reports, while a returned dict would be wrapped as a *value* like any other and
the failure would be silently bound instead of raised.
"""

from typing import Any, List

from aro_plugin_sdk import AROInput, export_abi, plugin, qualifier, run


@plugin(name="plugin-python-collection", version="1.0.0", handle="Collections")
class CollectionPlugin:
    pass


def _require_list(input: AROInput, qualifier_name: str) -> List[Any]:
    """The input value as a list, or an exception the runtime can report."""
    value = input.get("value")
    if not isinstance(value, list):
        raise ValueError(f"{qualifier_name} requires a list")
    return value


def _numbers(value: List[Any], qualifier_name: str) -> List[Any]:
    numeric_values = [v for v in value if isinstance(v, (int, float))]
    if not numeric_values:
        raise ValueError(f"{qualifier_name} requires numeric list elements")
    return numeric_values


# MARK: - Qualifier handlers

@qualifier(name="sort", description="Sorts a list in ascending order")
def qualifier_sort(input: AROInput) -> List[Any]:
    value = _require_list(input, "sort")
    try:
        return sorted(value)
    except TypeError:
        # Mixed types have no natural order; fall back to a stable one.
        return sorted(value, key=str)


@qualifier(name="unique", description="Returns unique elements from a list")
def qualifier_unique(input: AROInput) -> List[Any]:
    value = _require_list(input, "unique")
    seen: set = set()
    unique_list: List[Any] = []
    for item in value:
        key = tuple(item) if isinstance(item, list) else item
        if key not in seen:
            seen.add(key)
            unique_list.append(item)
    return unique_list


@qualifier(name="sum", description="Returns the sum of numeric list elements")
def qualifier_sum(input: AROInput) -> Any:
    numeric_values = _numbers(_require_list(input, "sum"), "sum")
    total = sum(numeric_values)
    if all(isinstance(v, int) for v in numeric_values) and total == int(total):
        total = int(total)
    return total


@qualifier(name="avg", description="Returns the average of numeric list elements")
def qualifier_avg(input: AROInput) -> float:
    numeric_values = _numbers(_require_list(input, "avg"), "avg")
    return sum(numeric_values) / len(numeric_values)


@qualifier(name="min", description="Returns the minimum element")
def qualifier_min(input: AROInput) -> Any:
    value = _require_list(input, "min")
    if not value:
        raise ValueError("min requires a non-empty list")
    try:
        return min(value)
    except TypeError:
        return min(value, key=str)


@qualifier(name="max", description="Returns the maximum element")
def qualifier_max(input: AROInput) -> Any:
    value = _require_list(input, "max")
    if not value:
        raise ValueError("max requires a non-empty list")
    try:
        return max(value)
    except TypeError:
        return max(value, key=str)


# Generate backward-compatible module-level functions for the ARO runtime
export_abi(globals())

if __name__ == "__main__":
    run()
