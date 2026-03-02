# Source Structure Example

Demonstrates organizing `.aro` files in a `sources/` subdirectory with nested structure.

## Directory Structure

```
SourceStructure/
├── main.aro                      # Entry point (Application-Start)
├── sources/                      # Source files subdirectory
│   ├── users/
│   │   └── users.aro             # User feature sets
│   └── orders/
│       └── orders.aro            # Order feature sets
└── README.md
```

## Key Concepts

1. **Automatic Discovery**: The ARO runtime recursively discovers all `.aro` files in the application directory and its subdirectories.

2. **No Imports Needed**: Feature sets from `sources/users/users.aro` and `sources/orders/orders.aro` are automatically available without any import statements.

3. **Global Visibility**: Events emitted in `main.aro` can trigger handlers defined in subdirectory files.

4. **Flexible Organization**: You can use any directory structure that makes sense for your project - `sources/`, domain-based directories, or flat files.

## Running

```bash
aro run Examples/SourceStructure
```

## Output

The example creates a user and an order, demonstrating that feature sets from different subdirectories work together seamlessly.
