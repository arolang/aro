package com.krissimon.aro.settings;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.util.concurrent.TimeUnit;
import java.util.regex.Pattern;
import java.util.stream.Collectors;

public class AROPathValidator {

    private static final long VALIDATION_TIMEOUT_SECONDS = 5;
    private static final Pattern VERSION_PATTERN = Pattern.compile("(?i)aro\\s+version\\s+\\d+\\.\\d+(\\.\\d+)?");
    // Prevent command injection by checking for suspicious characters
    private static final Pattern SUSPICIOUS_CHARS = Pattern.compile("[;&|`$<>]");

    public static ValidationResult validate(String path) {
        if (path == null || path.trim().isEmpty()) {
            return ValidationResult.error("Path not configured");
        }

        // Security: Check for suspicious characters that could indicate command injection
        if (SUSPICIOUS_CHARS.matcher(path).find()) {
            return ValidationResult.error("Invalid characters in path");
        }

        File file = new File(path);
        if (!file.exists()) {
            return ValidationResult.error("File not found: " + path);
        }

        if (!file.canExecute()) {
            return ValidationResult.error("File is not executable: " + path);
        }

        Process process = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(path, "--version");
            pb.redirectErrorStream(true);
            process = pb.start();

            // Fix resource leak: Use try-with-resources for both InputStreamReader and BufferedReader
            String output;
            try (InputStreamReader isr = new InputStreamReader(process.getInputStream());
                 BufferedReader reader = new BufferedReader(isr)) {
                output = reader.lines().collect(Collectors.joining("\n"));
            }

            // Fix process hang risk: Add timeout to waitFor
            boolean completed = process.waitFor(VALIDATION_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!completed) {
                return ValidationResult.error("Command timed out");
            }

            int exitCode = process.exitValue();
            if (exitCode != 0) {
                return ValidationResult.error("Command failed with exit code: " + exitCode);
            }

            // Improved validation: Check for specific version format instead of just "aro"
            if (VERSION_PATTERN.matcher(output).find()) {
                return ValidationResult.success(output);
            }

            return ValidationResult.error("Not a valid ARO binary (version output expected)");

        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            return ValidationResult.error("Validation interrupted: " + e.getMessage());
        } catch (Exception e) {
            return ValidationResult.error("Failed to execute: " + e.getMessage());
        } finally {
            // Fix process resource leak: Ensure process is cleaned up
            if (process != null && process.isAlive()) {
                process.destroy();
                try {
                    // Give process 1 second to terminate gracefully, then force kill
                    if (!process.waitFor(1, TimeUnit.SECONDS)) {
                        process.destroyForcibly();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    process.destroyForcibly();
                }
            }
        }
    }

    public static class ValidationResult {
        public final boolean valid;
        public final String message;

        private ValidationResult(boolean valid, String message) {
            this.valid = valid;
            this.message = message;
        }

        public static ValidationResult success(String message) {
            return new ValidationResult(true, message);
        }

        public static ValidationResult error(String message) {
            return new ValidationResult(false, message);
        }
    }
}
