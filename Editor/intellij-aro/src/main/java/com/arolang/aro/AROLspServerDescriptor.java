package com.arolang.aro;

import com.intellij.openapi.project.Project;
import com.intellij.psi.PsiFile;
import com.arolang.aro.settings.AROSettingsState;
import com.redhat.devtools.lsp4ij.LanguageServerFactory;
import com.redhat.devtools.lsp4ij.client.features.LSPClientFeatures;
import com.redhat.devtools.lsp4ij.client.features.LSPDiagnosticFeature;
import com.redhat.devtools.lsp4ij.client.features.LSPDocumentLinkFeature;
import com.redhat.devtools.lsp4ij.server.StreamConnectionProvider;
import com.redhat.devtools.lsp4ij.server.ProcessStreamConnectionProvider;
import org.eclipse.lsp4j.services.LanguageServer;
import org.jetbrains.annotations.NotNull;

import java.util.ArrayList;
import java.util.List;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * LSP server factory for ARO language support.
 * Provides advanced IDE features through the ARO Language Server.
 */
public class AROLspServerDescriptor implements LanguageServerFactory {

    // Common installation paths for ARO
    private static final String[] COMMON_PATHS = {
        "/opt/homebrew/bin/aro",
        "/usr/local/bin/aro",
        "/usr/bin/aro"
    };

    @Override
    public @NotNull StreamConnectionProvider createConnectionProvider(@NotNull Project project) {
        AROSettingsState settings = AROSettingsState.getInstance();
        String aroPath = resolveAroPath(settings.aroPath);

        List<String> commands = new ArrayList<>();
        commands.add(aroPath);
        commands.add("lsp");

        if (settings.enableDebugLogging) {
            commands.add("--debug");
        }

        ProcessStreamConnectionProvider provider = new ProcessStreamConnectionProvider(commands) {
            // ProcessStreamConnectionProvider handles the process lifecycle
        };

        // Set working directory to project root
        if (project.getBasePath() != null) {
            provider.setWorkingDirectory(project.getBasePath());
        }

        return provider;
    }

    /**
     * Resolve the ARO binary path.
     * If the configured path is just "aro", try common installation paths.
     */
    private String resolveAroPath(String configuredPath) {
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

    @Override
    public @NotNull Class<? extends LanguageServer> getServerInterface() {
        return LanguageServer.class;
    }

    @Override
    public @NotNull LSPClientFeatures createClientFeatures() {
        return new LSPClientFeatures()
            // Disable document links to prevent blue underlines on hover
            .setDocumentLinkFeature(new LSPDocumentLinkFeature() {
                @Override
                public boolean isEnabled(@NotNull PsiFile file) {
                    return false;
                }
            })
            // Disable diagnostics to prevent underlines from LSP warnings
            .setDiagnosticFeature(new LSPDiagnosticFeature() {
                @Override
                public boolean isEnabled(@NotNull PsiFile file) {
                    return false;
                }
            });
    }
}
