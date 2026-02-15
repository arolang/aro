package com.arolang.aro.settings;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.*;

class AROPathValidatorTest {

    @Test
    void testNullPath() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate(null);
        assertFalse(result.valid);
        assertEquals("Path not configured", result.message);
    }

    @Test
    void testEmptyPath() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("");
        assertFalse(result.valid);
        assertEquals("Path not configured", result.message);
    }

    @Test
    void testWhitespacePath() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("   ");
        assertFalse(result.valid);
        assertEquals("Path not configured", result.message);
    }

    @Test
    void testSuspiciousCharactersSemicolon() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/bin/aro; rm -rf /");
        assertFalse(result.valid);
        assertEquals("Invalid characters in path", result.message);
    }

    @Test
    void testSuspiciousCharactersPipe() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/bin/aro | cat /etc/passwd");
        assertFalse(result.valid);
        assertEquals("Invalid characters in path", result.message);
    }

    @Test
    void testSuspiciousCharactersBacktick() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/bin/`whoami`");
        assertFalse(result.valid);
        assertEquals("Invalid characters in path", result.message);
    }

    @Test
    void testSuspiciousCharactersDollar() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/bin/$(whoami)");
        assertFalse(result.valid);
        assertEquals("Invalid characters in path", result.message);
    }

    @Test
    void testSuspiciousCharactersRedirect() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/bin/aro > /tmp/output");
        assertFalse(result.valid);
        assertEquals("Invalid characters in path", result.message);
    }

    @Test
    void testPathTraversalDoubleDot() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("../../etc/passwd");
        assertFalse(result.valid);
        assertEquals("Path traversal not allowed", result.message);
    }

    @Test
    void testPathTraversalInMiddle() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/usr/../bin/aro");
        assertFalse(result.valid);
        assertEquals("Path traversal not allowed", result.message);
    }

    @Test
    void testNonExistentFile() {
        AROPathValidator.ValidationResult result = AROPathValidator.validate("/nonexistent/path/to/aro");
        assertFalse(result.valid);
        assertTrue(result.message.contains("File not found") || result.message.contains("Invalid path"));
    }

    @Test
    void testNonExecutableFile(@TempDir Path tempDir) throws IOException {
        // Create a non-executable file
        Path file = tempDir.resolve("aro");
        Files.createFile(file);

        AROPathValidator.ValidationResult result = AROPathValidator.validate(file.toString());
        assertFalse(result.valid);
        assertTrue(result.message.contains("not executable") || result.message.contains("Invalid path"));
    }

    @Test
    void testInvalidVersionOutput(@TempDir Path tempDir) throws IOException {
        // Create a mock executable that returns invalid output
        Path mockScript = createMockScript(tempDir, "echo 'Hello World'");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertFalse(result.valid);
        assertTrue(result.message.contains("Not a valid ARO binary"));
    }

    @Test
    void testValidAROBinary(@TempDir Path tempDir) throws IOException {
        // Create a mock executable that returns valid version output
        Path mockScript = createMockScript(tempDir, "echo 'ARO version 1.0.0'");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertTrue(result.valid);
        assertTrue(result.message.contains("ARO version 1.0.0"));
    }

    @Test
    void testValidAROBinaryDifferentFormat(@TempDir Path tempDir) throws IOException {
        // Test different version formats
        Path mockScript = createMockScript(tempDir, "echo 'aro VERSION 2.5.3'");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertTrue(result.valid);
    }

    @Test
    void testValidAROBinaryBetaVersion(@TempDir Path tempDir) throws IOException {
        // Test beta version format like "0.3.0-beta.11"
        Path mockScript = createMockScript(tempDir, "echo '0.3.0-beta.11'");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertTrue(result.valid);
    }

    @Test
    void testNonZeroExitCode(@TempDir Path tempDir) throws IOException {
        // Create a script that exits with error code
        Path mockScript = createMockScript(tempDir, "exit 1");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertFalse(result.valid);
        assertTrue(result.message.contains("Command failed with exit code: 1"));
    }

    @Test
    void testStderrCaptured(@TempDir Path tempDir) throws IOException {
        // Create a script that writes to stderr
        Path mockScript = createMockScript(tempDir, "echo 'Error message' >&2; exit 1");

        AROPathValidator.ValidationResult result = AROPathValidator.validate(mockScript.toString());
        assertFalse(result.valid);
        assertTrue(result.message.contains("Error message"));
    }

    // Helper method to create a mock executable script
    private Path createMockScript(Path tempDir, String command) throws IOException {
        Path script = tempDir.resolve("aro");

        // Create shell script based on OS
        String shebang = System.getProperty("os.name").toLowerCase().contains("win")
            ? "@echo off\n"
            : "#!/bin/sh\n";

        Files.writeString(script, shebang + command + "\n");

        // Make executable on Unix-like systems
        if (!System.getProperty("os.name").toLowerCase().contains("win")) {
            script.toFile().setExecutable(true);
        }

        return script;
    }
}
