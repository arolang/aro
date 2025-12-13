# ExternalService

Demonstrates calling external HTTP APIs using the `<Call>` action with the HTTP service.

## What It Does

Fetches real-time weather data from the Open-Meteo API (a free, no-auth weather service) and displays the response. Shows the pattern for integrating with external REST APIs.

## Features Tested

- **HTTP service calls** - `<Call>` with `http: get` method
- **External API integration** - Real HTTP request to third-party service
- **Response extraction** - `<Extract>` to get body from response
- **Application lifecycle** - `Application-End: Success` for completion message

## Related Proposals

- [ARO-0021: HTTP Client](../../Proposals/ARO-0021-http-client.md)
- [ARO-0020: Action Framework](../../Proposals/ARO-0020-action-framework.md)

## Usage

```bash
# Interpreted
aro run ./Examples/ExternalService

# Compiled
aro build ./Examples/ExternalService
./Examples/ExternalService/ExternalService
```

## Example Output

```
Fetching weather data from Open-Meteo API...
Weather data received:
{
  "current_weather": {
    "temperature": 15.2,
    "windspeed": 12.5,
    ...
  }
}
External service demo completed.
```

---

*The outside world is just another service call away. No special client libraries, no configuration files.*
