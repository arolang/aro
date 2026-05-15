# Build a store file demo with file-backed repositories

Create an ARO application that demonstrates `.store` files for seeding repositories with YAML data.

The application needs two files:

- `products.store` -- A YAML file that seeds the `products-repository` (the filename determines the repository name). Contains a list of product objects with id, name, price, and category fields. This file is read-only by default.

- `main.aro` -- The `Application-Start` feature set. Retrieve all products from `<products-repository>`, compute the count, and log it. Retrieve filtered products where category is "hardware" and log the count. Retrieve a specific product where id is "p1", extract its name, and log it.
