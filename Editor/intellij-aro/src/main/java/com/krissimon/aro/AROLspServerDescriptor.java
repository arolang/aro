package com.krissimon.aro;

import com.intellij.openapi.project.Project;
import com.krissimon.aro.settings.AROSettingsState;
import com.redhat.devtools.lsp4ij.LanguageServerFactory;
import com.redhat.devtools.lsp4ij.client.LanguageClientImpl;
import com.redhat.devtools.lsp4ij.server.StreamConnectionProvider;
import com.redhat.devtools.lsp4ij.server.ProcessStreamConnectionProvider;
import org.eclipse.lsp4j.services.LanguageServer;
import org.jetbrains.annotations.NotNull;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * LSP server factory for ARO language support.
 * Provides advanced IDE features through the ARO Language Server.
 */
public class AROLspServerDescriptor implements LanguageServerFactory {

    @Override
    public @NotNull StreamConnectionProvider createConnectionProvider(@NotNull Project project) {
        AROSettingsState settings = AROSettingsState.getInstance();
        String aroPath = settings.aroPath;

        List<String> commands = new ArrayList<>();
        commands.add(aroPath);
        commands.add("lsp");

        if (settings.enableDebugLogging) {
            commands.add("--debug");
        }

        return new ProcessStreamConnectionProvider(commands) {
            // ProcessStreamConnectionProvider handles the process lifecycle
        };
    }

    @Override
    public @NotNull Class<? extends LanguageServer> getServerInterface() {
        return LanguageServer.class;
    }
}
