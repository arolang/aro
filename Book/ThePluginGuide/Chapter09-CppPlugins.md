# Chapter 9: C++ Plugins

*"C makes it easy to shoot yourself in the foot; C++ makes it harder, but when you do it blows your whole leg off." — Bjarne Stroustrup*

---

C++ combines C's low-level control with high-level abstractions. For ARO plugins, this means access to powerful C++ libraries while maintaining the C ABI that ARO expects. This chapter shows you how to wrap C++ code for use in ARO.

## 9.1 Why C++?

C++ brings unique strengths to plugin development:

**Rich Libraries**: Boost, Eigen, OpenCV, FFTW, Qt—decades of battle-tested C++ libraries are at your disposal.

**RAII**: Resource Acquisition Is Initialization ensures proper cleanup without manual memory management.

**Templates**: Generic programming enables efficient, type-safe code without runtime overhead.

**Modern Features**: C++17 and C++20 provide optional types, string views, ranges, and coroutines.

The challenge is bridging C++'s features to C's ABI. We'll show you how.

## 9.2 The Bridge: extern "C"

C++ uses name mangling—function names are encoded with their parameter types to support overloading. This breaks C ABI compatibility.

The solution is `extern "C"`:

```cpp
// Without extern "C":
// Function might be named _Z15aro_plugin_infov (mangled)

// With extern "C":
// Function is named exactly aro_plugin_info
extern "C" {
    char* aro_plugin_info(void);
    char* aro_plugin_execute(const char* action, const char* input_json);
    void aro_plugin_free(char* ptr);
}
```

The `extern "C"` block tells the compiler to:
- Use C calling conventions
- Don't mangle function names
- Make functions visible to C code (and ARO)

## 9.3 Project Structure

```
Plugins/
└── plugin-cpp-math/
    ├── plugin.yaml
    └── src/
        ├── math_plugin.cpp
        └── math_ops.hpp
```

### plugin.yaml

```yaml
name: plugin-cpp-math
version: 1.0.0
description: "Mathematical operations using C++ libraries"
aro-version: ">=0.1.0"

provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      flags:
        - -O2
        - -fPIC
        - -shared
        - -std=c++17
      output: libmath_plugin.dylib
```

Note the differences from C:
- Compiler is `clang++` (or `g++`)
- Flag `-std=c++17` enables modern C++ features

## 9.4 Your First C++ Plugin: Custom Actions

Let's build a mathematical plugin that uses C++'s standard library and demonstrates RAII-safe resource management.

### Implementation

```cpp
// math_plugin.cpp

#include <cstring>
#include <cstdlib>
#include <cmath>
#include <string>
#include <sstream>
#include <vector>
#include <numeric>
#include <algorithm>
#include <optional>
#include <memory>

// JSON parsing with nlohmann/json (single header)
// For production, include json.hpp from https://github.com/nlohmann/json
// For this example, we'll use simple string parsing

namespace {

// Simple JSON string extraction (use nlohmann/json in production)
std::optional<std::string> extract_string(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return std::nullopt;

    pos = json.find('"', pos + search.length());
    if (pos == std::string::npos) return std::nullopt;

    auto end = json.find('"', pos + 1);
    if (end == std::string::npos) return std::nullopt;

    return json.substr(pos + 1, end - pos - 1);
}

std::optional<double> extract_number(const std::string& json, const std::string& key) {
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return std::nullopt;

    pos += search.length();
    while (pos < json.length() && (json[pos] == ' ' || json[pos] == '\t')) pos++;

    try {
        size_t idx;
        double value = std::stod(json.substr(pos), &idx);
        return value;
    } catch (...) {
        return std::nullopt;
    }
}

std::vector<double> extract_array(const std::string& json, const std::string& key) {
    std::vector<double> result;
    std::string search = "\"" + key + "\":";
    auto pos = json.find(search);
    if (pos == std::string::npos) return result;

    pos = json.find('[', pos);
    if (pos == std::string::npos) return result;

    auto end = json.find(']', pos);
    if (end == std::string::npos) return result;

    std::string arr = json.substr(pos + 1, end - pos - 1);
    std::stringstream ss(arr);
    double value;
    while (ss >> value) {
        result.push_back(value);
        if (ss.peek() == ',') ss.ignore();
    }

    return result;
}

// Result builder
std::string success_result(const std::string& json_body) {
    return "{" + json_body + "}";
}

std::string error_result(const std::string& message) {
    return "{\"error\":\"" + message + "\"}";
}

// Duplicate string for C interface
char* to_c_string(const std::string& str) {
    char* result = static_cast<char*>(std::malloc(str.length() + 1));
    if (result) {
        std::strcpy(result, str.c_str());
    }
    return result;
}

} // anonymous namespace

// ============================================================
// Mathematical Operations
// ============================================================

namespace math_ops {

// Basic statistics
struct Statistics {
    double mean;
    double median;
    double stddev;
    double min;
    double max;
    double sum;
    size_t count;
};

Statistics compute_statistics(std::vector<double> values) {
    if (values.empty()) {
        return {0, 0, 0, 0, 0, 0, 0};
    }

    Statistics stats;
    stats.count = values.size();
    stats.sum = std::accumulate(values.begin(), values.end(), 0.0);
    stats.mean = stats.sum / stats.count;

    stats.min = *std::min_element(values.begin(), values.end());
    stats.max = *std::max_element(values.begin(), values.end());

    // Median
    std::sort(values.begin(), values.end());
    if (stats.count % 2 == 0) {
        stats.median = (values[stats.count/2 - 1] + values[stats.count/2]) / 2.0;
    } else {
        stats.median = values[stats.count/2];
    }

    // Standard deviation
    double sq_sum = 0;
    for (double v : values) {
        sq_sum += (v - stats.mean) * (v - stats.mean);
    }
    stats.stddev = std::sqrt(sq_sum / stats.count);

    return stats;
}

// Matrix operations
class Matrix {
public:
    Matrix(size_t rows, size_t cols)
        : rows_(rows), cols_(cols), data_(rows * cols, 0.0) {}

    double& at(size_t r, size_t c) { return data_[r * cols_ + c]; }
    double at(size_t r, size_t c) const { return data_[r * cols_ + c]; }

    size_t rows() const { return rows_; }
    size_t cols() const { return cols_; }

    Matrix transpose() const {
        Matrix result(cols_, rows_);
        for (size_t r = 0; r < rows_; ++r) {
            for (size_t c = 0; c < cols_; ++c) {
                result.at(c, r) = at(r, c);
            }
        }
        return result;
    }

    double determinant() const {
        if (rows_ != cols_) return 0;
        if (rows_ == 2) {
            return at(0,0) * at(1,1) - at(0,1) * at(1,0);
        }
        // For larger matrices, use LU decomposition (simplified here)
        return 0; // Placeholder
    }

private:
    size_t rows_, cols_;
    std::vector<double> data_;
};

// Polynomial evaluation (Horner's method)
double evaluate_polynomial(const std::vector<double>& coefficients, double x) {
    double result = 0;
    for (auto it = coefficients.rbegin(); it != coefficients.rend(); ++it) {
        result = result * x + *it;
    }
    return result;
}

// Numerical integration (Simpson's rule)
double integrate(double (*f)(double), double a, double b, int n = 1000) {
    double h = (b - a) / n;
    double sum = f(a) + f(b);

    for (int i = 1; i < n; i += 2) {
        sum += 4 * f(a + i * h);
    }
    for (int i = 2; i < n; i += 2) {
        sum += 2 * f(a + i * h);
    }

    return sum * h / 3;
}

} // namespace math_ops

// ============================================================
// Plugin Interface
// ============================================================

extern "C" {

char* aro_plugin_info(void) {
    return to_c_string(
        "{"
        "\"name\":\"plugin-cpp-math\","
        "\"version\":\"1.0.0\","
        "\"language\":\"cpp\","
        "\"actions\":[\"statistics\",\"polynomial\",\"factorial\",\"fibonacci\"]"
        "}"
    );
}

char* aro_plugin_execute(const char* action, const char* input_json) {
    if (!action || !input_json) {
        return to_c_string(error_result("Null input"));
    }

    std::string action_str(action);
    std::string input(input_json);

    try {
        if (action_str == "statistics") {
            auto values = extract_array(input, "values");
            if (values.empty()) {
                return to_c_string(error_result("Missing or empty 'values' array"));
            }

            auto stats = math_ops::compute_statistics(values);

            std::ostringstream oss;
            oss << "\"mean\":" << stats.mean << ","
                << "\"median\":" << stats.median << ","
                << "\"stddev\":" << stats.stddev << ","
                << "\"min\":" << stats.min << ","
                << "\"max\":" << stats.max << ","
                << "\"sum\":" << stats.sum << ","
                << "\"count\":" << stats.count;

            return to_c_string(success_result(oss.str()));
        }
        else if (action_str == "polynomial") {
            auto coefficients = extract_array(input, "coefficients");
            auto x = extract_number(input, "x");

            if (coefficients.empty()) {
                return to_c_string(error_result("Missing 'coefficients' array"));
            }
            if (!x) {
                return to_c_string(error_result("Missing 'x' value"));
            }

            double result = math_ops::evaluate_polynomial(coefficients, *x);

            std::ostringstream oss;
            oss << "\"result\":" << result << ","
                << "\"x\":" << *x << ","
                << "\"degree\":" << (coefficients.size() - 1);

            return to_c_string(success_result(oss.str()));
        }
        else if (action_str == "factorial") {
            auto n = extract_number(input, "n");
            if (!n || *n < 0 || *n > 20) {
                return to_c_string(error_result("Invalid 'n' (must be 0-20)"));
            }

            unsigned long long result = 1;
            for (int i = 2; i <= static_cast<int>(*n); ++i) {
                result *= i;
            }

            std::ostringstream oss;
            oss << "\"result\":" << result << ","
                << "\"n\":" << static_cast<int>(*n);

            return to_c_string(success_result(oss.str()));
        }
        else if (action_str == "fibonacci") {
            auto n = extract_number(input, "n");
            if (!n || *n < 0 || *n > 50) {
                return to_c_string(error_result("Invalid 'n' (must be 0-50)"));
            }

            int count = static_cast<int>(*n);
            std::vector<unsigned long long> fib;
            fib.reserve(count);

            for (int i = 0; i < count; ++i) {
                if (i == 0) fib.push_back(0);
                else if (i == 1) fib.push_back(1);
                else fib.push_back(fib[i-1] + fib[i-2]);
            }

            std::ostringstream oss;
            oss << "\"sequence\":[";
            for (size_t i = 0; i < fib.size(); ++i) {
                if (i > 0) oss << ",";
                oss << fib[i];
            }
            oss << "],\"count\":" << count;

            return to_c_string(success_result(oss.str()));
        }
        else {
            return to_c_string(error_result("Unknown action: " + action_str));
        }
    }
    catch (const std::exception& e) {
        return to_c_string(error_result(std::string("Exception: ") + e.what()));
    }
    catch (...) {
        return to_c_string(error_result("Unknown exception"));
    }
}

void aro_plugin_free(char* ptr) {
    std::free(ptr);
}

} // extern "C"
```

### Usage in ARO

With custom actions registered, use native ARO syntax:

```aro
(Math Demo: Application-Start) {
    (* Calculate statistics using custom action *)
    <Statistics> the <stats> from [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].
    Log "Mean: " with <stats: mean> to the <console>.
    Log "Std Dev: " with <stats: stddev> to the <console>.

    (* Evaluate polynomial: 2x^2 + 3x + 1 at x=5 *)
    <Polynomial> the <poly> from [1, 3, 2] with { x: 5 }.
    Log "Polynomial result: " with <poly: result> to the <console>.

    (* Generate Fibonacci sequence using custom action *)
    <Fibonacci> the <fib> from 10.
    Log "Fibonacci: " with <fib: sequence> to the <console>.

    Return an <OK: status> for the <startup>.
}
```

The `<Statistics>`, `<Polynomial>`, and `<Fibonacci>` actions feel native to ARO!

## 9.5 RAII and Resource Management

C++ excels at automatic resource management through RAII. Here's how to use it safely across the C boundary:

### Smart Pointers for Internal Use

```cpp
#include <memory>

class DatabaseConnection {
public:
    DatabaseConnection(const std::string& conn_str) {
        // Open connection...
    }
    ~DatabaseConnection() {
        // Close connection automatically
    }

    std::string query(const std::string& sql) {
        // Execute query...
        return "result";
    }
};

// Store connections using smart pointers
static std::unordered_map<int, std::unique_ptr<DatabaseConnection>> connections;
static int next_id = 1;
static std::mutex connections_mutex;

extern "C" {

char* aro_plugin_execute(const char* action, const char* input_json) {
    std::string action_str(action);

    if (action_str == "connect") {
        auto conn_str = extract_string(input_json, "connection_string");
        if (!conn_str) {
            return to_c_string(error_result("Missing connection_string"));
        }

        try {
            auto conn = std::make_unique<DatabaseConnection>(*conn_str);

            std::lock_guard<std::mutex> lock(connections_mutex);
            int id = next_id++;
            connections[id] = std::move(conn);

            return to_c_string("{\"connection_id\":" + std::to_string(id) + "}");
        }
        catch (const std::exception& e) {
            return to_c_string(error_result(e.what()));
        }
    }
    else if (action_str == "disconnect") {
        auto id = extract_number(input_json, "connection_id");
        if (!id) {
            return to_c_string(error_result("Missing connection_id"));
        }

        std::lock_guard<std::mutex> lock(connections_mutex);
        connections.erase(static_cast<int>(*id));
        // unique_ptr automatically closes connection

        return to_c_string("{\"disconnected\":true}");
    }

    return to_c_string(error_result("Unknown action"));
}

} // extern "C"
```

### Scope Guards

For cleanup that doesn't fit RAII patterns:

```cpp
#include <functional>

class ScopeGuard {
public:
    explicit ScopeGuard(std::function<void()> cleanup)
        : cleanup_(std::move(cleanup)), active_(true) {}

    ~ScopeGuard() {
        if (active_) cleanup_();
    }

    void dismiss() { active_ = false; }

private:
    std::function<void()> cleanup_;
    bool active_;
};

extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    FILE* file = fopen("temp.txt", "w");
    if (!file) {
        return to_c_string(error_result("Cannot open file"));
    }

    // File will be closed when we exit this scope
    ScopeGuard file_guard([file]() { fclose(file); });

    // Process...
    fprintf(file, "data");

    // Success - file_guard will still close the file
    return to_c_string("{\"success\":true}");
}
```

## 9.6 Using C++ Libraries

### nlohmann/json for Robust JSON Handling

Download the single-header library from https://github.com/nlohmann/json:

```cpp
#include "json.hpp"
using json = nlohmann::json;

extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    try {
        auto input = json::parse(input_json);

        if (std::string(action) == "process") {
            std::string data = input.at("data").get<std::string>();

            json result;
            result["processed"] = data;
            result["length"] = data.length();

            return to_c_string(result.dump());
        }

        return to_c_string(json{{"error", "Unknown action"}}.dump());
    }
    catch (const json::exception& e) {
        return to_c_string(json{{"error", e.what()}}.dump());
    }
}
```

### Eigen for Linear Algebra

```yaml
# plugin.yaml
provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      flags:
        - -O3
        - -fPIC
        - -shared
        - -std=c++17
        - -I/usr/local/include/eigen3
      output: liblinear_plugin.dylib
```

```cpp
#include <Eigen/Dense>

extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    if (std::string(action) == "solve") {
        // Solve system of linear equations Ax = b
        Eigen::Matrix3d A;
        A << 1, 2, 3,
             4, 5, 6,
             7, 8, 10;

        Eigen::Vector3d b(3, 3, 4);
        Eigen::Vector3d x = A.colPivHouseholderQr().solve(b);

        std::ostringstream oss;
        oss << "{\"solution\":[" << x[0] << "," << x[1] << "," << x[2] << "]}";
        return to_c_string(oss.str());
    }

    return to_c_string("{\"error\":\"Unknown action\"}");
}
```

### OpenCV for Image Processing

```yaml
# plugin.yaml
provides:
  - type: cpp-plugin
    path: src/
    build:
      compiler: clang++
      flags:
        - -O2
        - -fPIC
        - -shared
        - -std=c++17
      link:
        - -lopencv_core
        - -lopencv_imgproc
        - -lopencv_imgcodecs
      output: libimage_plugin.dylib
```

```cpp
#include <opencv2/opencv.hpp>
#include <base64.h>  // You'll need a base64 library

extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    if (std::string(action) == "resize") {
        auto path = extract_string(input_json, "path");
        auto width = extract_number(input_json, "width");
        auto height = extract_number(input_json, "height");

        if (!path || !width || !height) {
            return to_c_string("{\"error\":\"Missing parameters\"}");
        }

        cv::Mat image = cv::imread(*path);
        if (image.empty()) {
            return to_c_string("{\"error\":\"Cannot read image\"}");
        }

        cv::Mat resized;
        cv::resize(image, resized, cv::Size(static_cast<int>(*width),
                                             static_cast<int>(*height)));

        std::string output_path = *path + ".resized.jpg";
        cv::imwrite(output_path, resized);

        return to_c_string("{\"output\":\"" + output_path + "\"}");
    }

    return to_c_string("{\"error\":\"Unknown action\"}");
}
```

## 9.7 Exception Safety Across the C Boundary

Exceptions must not cross the `extern "C"` boundary—it causes undefined behavior. Always catch and convert:

```cpp
extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    try {
        // Your C++ code that might throw
        return process(action, input_json);
    }
    catch (const std::invalid_argument& e) {
        return to_c_string(json{
            {"error", "Invalid argument"},
            {"details", e.what()}
        }.dump());
    }
    catch (const std::runtime_error& e) {
        return to_c_string(json{
            {"error", "Runtime error"},
            {"details", e.what()}
        }.dump());
    }
    catch (const std::exception& e) {
        return to_c_string(json{
            {"error", "Exception"},
            {"details", e.what()}
        }.dump());
    }
    catch (...) {
        return to_c_string("{\"error\":\"Unknown exception\"}");
    }
}
```

## 9.8 Thread Safety with C++

C++ provides better thread safety primitives than C:

```cpp
#include <mutex>
#include <shared_mutex>
#include <atomic>

// Read-heavy workloads: shared_mutex allows multiple readers
class Cache {
public:
    std::optional<std::string> get(const std::string& key) const {
        std::shared_lock lock(mutex_);
        auto it = data_.find(key);
        return it != data_.end() ? std::optional(it->second) : std::nullopt;
    }

    void set(const std::string& key, const std::string& value) {
        std::unique_lock lock(mutex_);
        data_[key] = value;
    }

private:
    mutable std::shared_mutex mutex_;
    std::unordered_map<std::string, std::string> data_;
};

// Lock-free counter
static std::atomic<uint64_t> call_counter{0};

extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    uint64_t call_id = ++call_counter;  // Atomic increment, no lock needed

    // ... process ...
}
```

## 9.9 Audio Processing Example

Here's a more complex example using C++ for audio processing:

```cpp
#include <cmath>
#include <vector>
#include <complex>
#include <algorithm>

namespace audio {

// Simple FFT implementation (Cooley-Tukey)
class FFT {
public:
    static std::vector<std::complex<double>> forward(
        const std::vector<double>& signal
    ) {
        size_t n = signal.size();
        // Pad to power of 2
        size_t n2 = 1;
        while (n2 < n) n2 *= 2;

        std::vector<std::complex<double>> data(n2);
        for (size_t i = 0; i < n; ++i) {
            data[i] = signal[i];
        }

        fft_impl(data);
        return data;
    }

    static std::vector<double> magnitude_spectrum(
        const std::vector<std::complex<double>>& fft_result
    ) {
        std::vector<double> magnitudes;
        magnitudes.reserve(fft_result.size() / 2);

        for (size_t i = 0; i < fft_result.size() / 2; ++i) {
            magnitudes.push_back(std::abs(fft_result[i]));
        }

        return magnitudes;
    }

private:
    static void fft_impl(std::vector<std::complex<double>>& x) {
        size_t n = x.size();
        if (n <= 1) return;

        // Bit-reversal permutation
        for (size_t i = 1, j = 0; i < n; ++i) {
            size_t bit = n >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(x[i], x[j]);
        }

        // Cooley-Tukey FFT
        for (size_t len = 2; len <= n; len <<= 1) {
            double angle = -2 * M_PI / len;
            std::complex<double> wlen(cos(angle), sin(angle));

            for (size_t i = 0; i < n; i += len) {
                std::complex<double> w(1);
                for (size_t j = 0; j < len / 2; ++j) {
                    auto u = x[i + j];
                    auto v = x[i + j + len/2] * w;
                    x[i + j] = u + v;
                    x[i + j + len/2] = u - v;
                    w *= wlen;
                }
            }
        }
    }
};

// Generate common waveforms
class WaveGenerator {
public:
    static std::vector<double> sine(double frequency, double sample_rate, double duration) {
        size_t samples = static_cast<size_t>(sample_rate * duration);
        std::vector<double> wave(samples);

        for (size_t i = 0; i < samples; ++i) {
            double t = static_cast<double>(i) / sample_rate;
            wave[i] = sin(2.0 * M_PI * frequency * t);
        }

        return wave;
    }

    static std::vector<double> square(double frequency, double sample_rate, double duration) {
        auto sine_wave = sine(frequency, sample_rate, duration);
        std::vector<double> wave(sine_wave.size());

        for (size_t i = 0; i < sine_wave.size(); ++i) {
            wave[i] = sine_wave[i] >= 0 ? 1.0 : -1.0;
        }

        return wave;
    }
};

} // namespace audio

extern "C" {

char* aro_plugin_execute(const char* action, const char* input_json) {
    try {
        std::string action_str(action);

        if (action_str == "generate-sine") {
            auto freq = extract_number(input_json, "frequency").value_or(440.0);
            auto rate = extract_number(input_json, "sample_rate").value_or(44100.0);
            auto duration = extract_number(input_json, "duration").value_or(1.0);

            auto wave = audio::WaveGenerator::sine(freq, rate, duration);

            // Return first 100 samples as preview
            std::ostringstream oss;
            oss << "{\"samples\":[";
            for (size_t i = 0; i < std::min(wave.size(), size_t(100)); ++i) {
                if (i > 0) oss << ",";
                oss << wave[i];
            }
            oss << "],\"total_samples\":" << wave.size() << "}";

            return to_c_string(oss.str());
        }
        else if (action_str == "analyze-spectrum") {
            auto samples = extract_array(input_json, "samples");
            if (samples.empty()) {
                return to_c_string("{\"error\":\"Missing samples array\"}");
            }

            auto fft_result = audio::FFT::forward(samples);
            auto magnitudes = audio::FFT::magnitude_spectrum(fft_result);

            // Find dominant frequency bin
            auto max_it = std::max_element(magnitudes.begin(), magnitudes.end());
            size_t dominant_bin = std::distance(magnitudes.begin(), max_it);

            std::ostringstream oss;
            oss << "{\"dominant_bin\":" << dominant_bin
                << ",\"peak_magnitude\":" << *max_it
                << ",\"spectrum_size\":" << magnitudes.size() << "}";

            return to_c_string(oss.str());
        }

        return to_c_string("{\"error\":\"Unknown action\"}");
    }
    catch (const std::exception& e) {
        return to_c_string(std::string("{\"error\":\"") + e.what() + "\"}");
    }
}

} // extern "C"
```

## 9.10 Best Practices

### Minimize C++ in the Interface Layer

Keep `extern "C"` functions thin:

```cpp
// GOOD: Thin interface, heavy lifting in C++
extern "C" char* aro_plugin_execute(const char* action, const char* input_json) {
    try {
        return process_request(action, input_json);  // C++ function
    }
    catch (...) {
        return to_c_string("{\"error\":\"Internal error\"}");
    }
}

// C++ implementation
char* process_request(const std::string& action, const std::string& input) {
    // All C++ features available here
}
```

### Use Modern C++ Features

```cpp
// std::optional for nullable values
std::optional<int> find_value(const std::string& key);

// std::string_view for zero-copy string handling
void process(std::string_view data);

// Structured bindings
auto [key, value] = parse_pair(input);

// Range-based algorithms (C++20)
auto result = input | std::views::filter(is_valid)
                    | std::views::transform(process);
```

### Compile with Warnings

```yaml
build:
  compiler: clang++
  flags:
    - -Wall
    - -Wextra
    - -Wpedantic
    - -Werror  # Treat warnings as errors
```

## 9.11 Summary

C++ plugins combine C's ABI compatibility with modern language features:

- **`extern "C"`** blocks export functions with C linkage
- **RAII** ensures automatic resource cleanup
- **Smart pointers** manage dynamic memory safely
- **Standard library** provides containers, algorithms, and utilities
- **Exception handling** must not cross the C boundary—always catch and convert
- **Libraries**: Eigen, OpenCV, Boost, and countless others are available

The pattern is consistent: wrap C++ capabilities in a C interface, letting ARO interact with your sophisticated implementations through a simple, stable ABI.

Next, we explore Python plugins—where the ecosystem gets truly vast.

