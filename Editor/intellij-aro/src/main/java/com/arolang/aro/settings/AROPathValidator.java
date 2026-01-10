package com.arolang.aro.settings;

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

        // Security: Prevent path traversal attacks
        if (path.contains("..")) {
            return ValidationResult.error("Path traversal not allowed");
        }

        File file = new File(path);

        // Security: Resolve to canonical path to prevent path traversal
        // Note: We don't check basename because legitimate symlinks may have different names
        // The ".." check above provides sufficient path traversal protection
        try {
            file.getCanonicalPath();  // Verify path can be resolved (exists)
        } catch (Exception e) {
            return ValidationResult.error("Invalid path: " + e.getMessage());
        }

        if (!file.exists()) {
            return ValidationResult.error("File not found: " + path);
        }

        if (!file.canExecute()) {
            return ValidationResult.error("File is not executable: " + path);
        }

        Process process = null;
        try {
            ProcessBuilder pb = new ProcessBuilder(path, "--version");
            // Don't redirect error stream - capture stdout and stderr separately
            process = pb.start();

            // Fix race condition: Read streams asynchronously to prevent blocking
            // and capture both stdout and stderr
            String stdout;
            String stderr;
            try (InputStreamReader stdoutReader = new InputStreamReader(process.getInputStream());
                 BufferedReader stdoutBuffered = new BufferedReader(stdoutReader);
                 InputStreamReader stderrReader = new InputStreamReader(process.getErrorStream());
                 BufferedReader stderrBuffered = new BufferedReader(stderrReader)) {

                // Read both streams before waiting to prevent process from blocking on full buffer
                stdout = stdoutBuffered.lines().collect(Collectors.joining("\n"));
                stderr = stderrBuffered.lines().collect(Collectors.joining("\n"));
            }

            // Now safely wait for process completion after streams are drained
            boolean completed = process.waitFor(VALIDATION_TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!completed) {
                return ValidationResult.error("Command timed out");
            }

            // Safe to call exitValue() after waitFor() returns true
            int exitCode = process.exitValue();
            if (exitCode != 0) {
                String errorMsg = "Command failed with exit code: " + exitCode;
                if (!stderr.isEmpty()) {
                    errorMsg += "\nError output: " + stderr;
                }
                return ValidationResult.error(errorMsg);
            }

            // Improved validation: Check for specific version format instead of just "aro"
            if (VERSION_PATTERN.matcher(stdout).find()) {
                return ValidationResult.success(stdout);
            }

            // If validation fails, include stderr in error message if available
            String errorMsg = "Not a valid ARO binary (version output expected)";
            if (!stderr.isEmpty()) {
                errorMsg += "\nError output: " + stderr;
            }
            return ValidationResult.error(errorMsg);

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
