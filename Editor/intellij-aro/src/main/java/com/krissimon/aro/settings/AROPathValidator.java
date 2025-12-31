package com.krissimon.aro.settings;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.util.stream.Collectors;

public class AROPathValidator {

    public static ValidationResult validate(String path) {
        if (path == null || path.trim().isEmpty()) {
            return ValidationResult.error("Path not configured");
        }

        File file = new File(path);
        if (!file.exists()) {
            return ValidationResult.error("File not found: " + path);
        }

        if (!file.canExecute()) {
            return ValidationResult.error("File is not executable: " + path);
        }

        try {
            ProcessBuilder pb = new ProcessBuilder(path, "--version");
            pb.redirectErrorStream(true);
            Process process = pb.start();

            BufferedReader reader = new BufferedReader(
                new InputStreamReader(process.getInputStream())
            );
            String output = reader.lines().collect(Collectors.joining("\n"));

            int exitCode = process.waitFor();
            if (exitCode != 0) {
                return ValidationResult.error("Command failed");
            }

            if (output.toLowerCase().contains("aro")) {
                return ValidationResult.success(output);
            }

            return ValidationResult.error("Not a valid ARO binary");

        } catch (Exception e) {
            return ValidationResult.error("Failed to execute: " + e.getMessage());
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
