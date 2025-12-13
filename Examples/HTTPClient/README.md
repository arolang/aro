# HTTPClient

Demonstrates making HTTP requests using the `<Request>` action.

## What It Does

Fetches weather data from the Open-Meteo API using a simple GET request. Shows the streamlined syntax for HTTP client operations.

## Features Tested

- **Request action** - `<Request>` for HTTP GET operations
- **URL handling** - URL as string literal
- **Response logging** - Displaying JSON response data
- **Stateless HTTP calls** - One-shot request without session management

## Related Proposals

- [ARO-0021: HTTP Client](../../Proposals/ARO-0021-http-client.md)

## Usage

```bash
# Interpreted
aro run ./Examples/HTTPClient

# Compiled
aro build ./Examples/HTTPClient
./Examples/HTTPClient/HTTPClient
```

## Example Output

```
HTTP Client Demo
Fetching weather data from Open-Meteo API...
Weather data received:
{
  "latitude": 52.52,
  "longitude": 13.41,
  "current_weather": {
    "temperature": 15.2,
    ...
  }
}
```

---

*HTTP requests as first-class operations. No client instantiation, no configuration objects.*
