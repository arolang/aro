package com.krissimon.aro;

import com.intellij.openapi.project.Project;
import com.redhat.devtools.lsp4ij.LanguageServerFactory;
import com.redhat.devtools.lsp4ij.client.LanguageClientImpl;
import com.redhat.devtools.lsp4ij.server.StreamConnectionProvider;
import com.redhat.devtools.lsp4ij.server.ProcessStreamConnectionProvider;
import org.eclipse.lsp4j.services.LanguageServer;
import org.jetbrains.annotations.NotNull;

import java.util.Arrays;
import java.util.List;

/**
 * LSP server factory for ARO language support.
 * Provides advanced IDE features through the ARO Language Server.
 */
public class AROLspServerDescriptor implements LanguageServerFactory {

    @Override
    public @NotNull StreamConnectionProvider createConnectionProvider(@NotNull Project project) {
        List<String> commands = Arrays.asList("aro", "lsp");
        return new ProcessStreamConnectionProvider(commands) {
            // ProcessStreamConnectionProvider handles the process lifecycle
        };
    }

    @Override
    public @NotNull Class<? extends LanguageServer> getServerInterface() {
        return LanguageServer.class;
    }
}
