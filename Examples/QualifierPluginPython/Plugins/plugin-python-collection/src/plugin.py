"""
ARO Plugin - Python Collection Qualifiers

This plugin provides collection qualifiers for ARO.
Uses the ARO Plugin SDK decorator API.
"""

from typing import Any, List

from aro_plugin_sdk import AROInput, export_abi, plugin, qualifier, run


@plugin(name="plugin-python-collection", version="1.0.0", handle="Collections")
class CollectionPlugin:
    pass


# MARK: - Qualifier handlers

@qualifier(name="sort", description="Sorts a list in ascending order")
def qualifier_sort(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "sort requires a list"}
    try:
        sorted_list = sorted(value)
    except TypeError:
        sorted_list = sorted(value, key=str)
    return {"result": sorted_list}


@qualifier(name="unique", description="Returns unique elements from a list")
def qualifier_unique(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "unique requires a list"}
    seen: set = set()
    unique_list: List[Any] = []
    for item in value:
        key = tuple(item) if isinstance(item, list) else item
        if key not in seen:
            seen.add(key)
            unique_list.append(item)
    return {"result": unique_list}


@qualifier(name="sum", description="Returns the sum of numeric list elements")
def qualifier_sum(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "sum requires a list"}
    numeric_values = [v for v in value if isinstance(v, (int, float))]
    if not numeric_values:
        return {"error": "sum requires numeric list elements"}
    total = sum(numeric_values)
    if all(isinstance(v, int) for v in numeric_values) and total == int(total):
        total = int(total)
    return {"result": total}


@qualifier(name="avg", description="Returns the average of numeric list elements")
def qualifier_avg(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "avg requires a list"}
    numeric_values = [v for v in value if isinstance(v, (int, float))]
    if not numeric_values:
        return {"error": "avg requires numeric list elements"}
    average = sum(numeric_values) / len(numeric_values)
    return {"result": average}


@qualifier(name="min", description="Returns the minimum element")
def qualifier_min(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "min requires a list"}
    if not value:
        return {"error": "min requires a non-empty list"}
    try:
        minimum = min(value)
    except TypeError:
        minimum = min(value, key=str)
    return {"result": minimum}


@qualifier(name="max", description="Returns the maximum element")
def qualifier_max(input: AROInput) -> dict:
    value = input.get("value")
    if not isinstance(value, list):
        return {"error": "max requires a list"}
    if not value:
        return {"error": "max requires a non-empty list"}
    try:
        maximum = max(value)
    except TypeError:
        maximum = max(value, key=str)
    return {"result": maximum}


# Generate backward-compatible module-level functions for the ARO runtime
export_abi(globals())

if __name__ == "__main__":
    run()
