package com.arolang.aro;

import com.arolang.aro.settings.AROSettingsState;

import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Resolves the ARO binary path from settings with fallback to common installation paths.
 */
public final class AROPathResolver {

    private static final String[] COMMON_PATHS = {
        "/opt/homebrew/bin/aro",
        "/usr/local/bin/aro",
        "/usr/bin/aro"
    };

    private AROPathResolver() {}

    public static String resolve() {
        return resolve(AROSettingsState.getInstance().aroPath);
    }

    public static String resolve(String configuredPath) {
        // If it's an absolute path that exists, use it directly
        if (configuredPath != null && !configuredPath.isEmpty()) {
            Path path = Path.of(configuredPath);
            if (path.isAbsolute() && Files.exists(path) && Files.isExecutable(path)) {
                return configuredPath;
            }
        }

        // If path is "aro" or not configured, check common installation paths
        if (configuredPath == null || configuredPath.isEmpty() || configuredPath.equals("aro")) {
            for (String pathStr : COMMON_PATHS) {
                Path path = Path.of(pathStr);
                if (Files.exists(path) && Files.isExecutable(path)) {
                    return pathStr;
                }
            }
        }

        // Fall back to the configured path (may work if it's in PATH)
        return configuredPath != null ? configuredPath : "aro";
    }
}
