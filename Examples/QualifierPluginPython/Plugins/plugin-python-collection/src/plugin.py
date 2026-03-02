"""
ARO Plugin - Python Collection Qualifiers

This plugin provides collection qualifiers for ARO.
It implements the ARO Python plugin interface with qualifier support.
"""

import json
import random
from typing import Any, Dict, List


def aro_plugin_info() -> Dict[str, Any]:
    """Return plugin metadata with qualifiers."""
    return {
        "name": "plugin-python-collection",
        "version": "1.0.0",
        "actions": [],
        "qualifiers": [
            {
                "name": "sort",
                "inputTypes": ["List"],
                "description": "Sorts a list in ascending order"
            },
            {
                "name": "unique",
                "inputTypes": ["List"],
                "description": "Returns unique elements from a list"
            },
            {
                "name": "sum",
                "inputTypes": ["List"],
                "description": "Returns the sum of numeric list elements"
            },
            {
                "name": "avg",
                "inputTypes": ["List"],
                "description": "Returns the average of numeric list elements"
            },
            {
                "name": "min",
                "inputTypes": ["List"],
                "description": "Returns the minimum element"
            },
            {
                "name": "max",
                "inputTypes": ["List"],
                "description": "Returns the maximum element"
            }
        ]
    }


def aro_plugin_qualifier(qualifier: str, input_json: str) -> str:
    """Execute a qualifier transformation."""
    params = json.loads(input_json)
    value = params.get("value")
    value_type = params.get("type", "Unknown")

    try:
        if qualifier == "sort":
            if not isinstance(value, list):
                return json.dumps({"error": "sort requires a list"})
            # Sort, handling mixed types by converting to string for comparison
            try:
                sorted_list = sorted(value)
            except TypeError:
                sorted_list = sorted(value, key=str)
            return json.dumps({"result": sorted_list})

        elif qualifier == "unique":
            if not isinstance(value, list):
                return json.dumps({"error": "unique requires a list"})
            # Preserve order while removing duplicates
            seen = set()
            unique_list = []
            for item in value:
                # Convert to tuple for hashability if it's a list
                key = tuple(item) if isinstance(item, list) else item
                if key not in seen:
                    seen.add(key)
                    unique_list.append(item)
            return json.dumps({"result": unique_list})

        elif qualifier == "sum":
            if not isinstance(value, list):
                return json.dumps({"error": "sum requires a list"})
            # Sum numeric values
            numeric_values = [v for v in value if isinstance(v, (int, float))]
            if not numeric_values:
                return json.dumps({"error": "sum requires numeric list elements"})
            total = sum(numeric_values)
            # Return int if all values were ints and result is whole
            if all(isinstance(v, int) for v in numeric_values) and total == int(total):
                total = int(total)
            return json.dumps({"result": total})

        elif qualifier == "avg":
            if not isinstance(value, list):
                return json.dumps({"error": "avg requires a list"})
            # Average numeric values
            numeric_values = [v for v in value if isinstance(v, (int, float))]
            if not numeric_values:
                return json.dumps({"error": "avg requires numeric list elements"})
            average = sum(numeric_values) / len(numeric_values)
            return json.dumps({"result": average})

        elif qualifier == "min":
            if not isinstance(value, list):
                return json.dumps({"error": "min requires a list"})
            if not value:
                return json.dumps({"error": "min requires a non-empty list"})
            try:
                minimum = min(value)
            except TypeError:
                minimum = min(value, key=str)
            return json.dumps({"result": minimum})

        elif qualifier == "max":
            if not isinstance(value, list):
                return json.dumps({"error": "max requires a list"})
            if not value:
                return json.dumps({"error": "max requires a non-empty list"})
            try:
                maximum = max(value)
            except TypeError:
                maximum = max(value, key=str)
            return json.dumps({"result": maximum})

        else:
            return json.dumps({"error": f"Unknown qualifier: {qualifier}"})

    except Exception as e:
        return json.dumps({"error": str(e)})


# For testing
if __name__ == "__main__":
    print("Plugin Info:")
    print(json.dumps(aro_plugin_info(), indent=2))

    test_cases = [
        ("sort", {"value": [3, 1, 4, 1, 5, 9], "type": "List"}),
        ("unique", {"value": [1, 2, 2, 3, 3, 3], "type": "List"}),
        ("sum", {"value": [1, 2, 3, 4, 5], "type": "List"}),
        ("avg", {"value": [10, 20, 30], "type": "List"}),
        ("min", {"value": [5, 2, 8, 1, 9], "type": "List"}),
        ("max", {"value": [5, 2, 8, 1, 9], "type": "List"}),
    ]

    print("\nQualifier Tests:")
    for qualifier, input_data in test_cases:
        result = aro_plugin_qualifier(qualifier, json.dumps(input_data))
        print(f"  {qualifier}: {input_data['value']} -> {json.loads(result)}")
